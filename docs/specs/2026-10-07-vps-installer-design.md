# VPS Installer — Design

- **Data:** 2026-10-07
- **Stato:** in revisione
- **Contratto con il pannello:** [`../PANEL-HANDOFF.md`](../PANEL-HANDOFF.md)

## 1. Obiettivo

Un **comando unico** che, lanciato su una VPS OVH appena installata con Debian 13, porta la macchina a uno stato sicuro e pronto per ospitare siti e il pannello di gestione.

**Successo significa:**
- VPS messa in sicurezza con un comando e poche risposte a una procedura guidata.
- Nessun rischio di restare chiusi fuori via SSH.
- Nessun file temporaneo o segreto dell'installer lasciato sulla macchina a fine lavoro.
- Il pannello trova tutto ciò che gli serve in posizioni note e documentate (vedi `PANEL-HANDOFF.md`).

**Fuori dallo scope (lo farà il pannello):** aggiunta/rimozione siti, WordPress, cache FastCGI per sito, backup rclone, configurazione email se saltata, aggiornamento phpMyAdmin, codice del pannello stesso.

## 2. Ambiente di partenza

- VPS OVH, **Debian 13 (trixie)**, amd64 o arm64.
- Utente `debian` con sudo, accesso SSH con password generata dal Manager OVH, porta 22.
- cloud-init attivo (OVH lo usa per il primo avvio).
- Accesso KVM dal Manager OVH come paracadute.

## 3. Distribuzione

Repository GitHub **pubblico** `vps-installer`. Non contiene segreti: tutti i segreti si inseriscono nella procedura guidata.

Comando unico (mostrato nel README di ogni release, con hash reale):

```bash
curl -fsSL https://raw.githubusercontent.com/<utente>/vps-installer/vX.Y/install.sh -o install.sh \
  && echo "<sha256>  install.sh" | sha256sum -c - \
  && sudo bash install.sh
```

**Catena di fiducia:**
1. Il comando verifica l'hash di `install.sh` (versione fissa via tag).
2. `install.sh` contiene l'hash dell'archivio della release, lo scarica, lo verifica e lo estrae in `/root/vps-installer/`.
3. Una GitHub Action, al push di un tag `vX.Y`, crea l'archivio, calcola gli hash e aggiorna README e `install.sh`.

Alternativa senza rete: `scp` del file sul server e `sudo bash install.sh --local <archivio>`.

## 4. Struttura del repository

```
install.sh              # bootstrap: scarica, verifica, estrae, avvia
wizard.sh               # domande whiptail → answers.env
run.sh                  # esegue gli step in ordine, gestisce stato e ripresa
lib/
  common.sh             # log, errori, trap, helper apt
  template.sh           # rendering template (envsubst con lista variabili esplicita)
  validate.sh           # validazione input (dominio, porta, chiave SSH, username)
  cloudflare.sh         # chiamate API Cloudflare (verifica token, zona, record DNS)
steps/
  10-system.sh
  20-user-ssh.sh        # prepara la configurazione SSH (applicata in 99)
  30-firewall.sh
  40-nginx.sh
  50-php.sh
  60-mariadb.sh
  70-redis.sh
  75-mail.sh
  80-ssl.sh
  85-phpmyadmin.sh
  90-panel.sh
  95-vps-tools.sh       # installa /opt/vps/bin, manifest, sudoers
  99-finalize.sh        # test anti-blocco, pulizia, riavvio
templates/              # nginx.conf, vhost, snippet, jail.local, pool php, sshd drop-in, ...
tools/                  # sorgenti degli script che finiscono in /opt/vps/bin
tests/                  # bats
docs/
  specs/
  PANEL-HANDOFF.md
.github/workflows/      # shellcheck + bats su push, release su tag
```

Ogni step è **idempotente**: rilanciarlo non rompe nulla e non duplica configurazioni.

## 5. Procedura guidata

Interfaccia `whiptail`. **Tutte le domande all'inizio**, poi esecuzione senza input fino al test anti-blocco finale.

| # | Sezione | Domande | Default / note |
|---|---|---|---|
| 1 | Controlli | — | Debian 13, eseguito con sudo/root, rete e DNS funzionanti, spazio disco ≥ 5 GB. Se falliscono: messaggio ed uscita. |
| 2 | Sistema | hostname, fuso orario, locale | hostname suggerito dal dominio del pannello; `Europe/Rome`; `it_IT.UTF-8` |
| 3 | Utente | nome utente, password (×2), chiave SSH pubblica | chiave **obbligatoria**, validata con `ssh-keygen -l`. Username diverso da `root`/`debian`/`panel`. |
| 4 | SSH | porta, login root | porta suggerita casuale 20000–60000 (accetta 1024–65535 o 22); root: `no` (default) o `prohibit-password`. Login con password sempre disattivato. |
| 5 | Stack | caselle: Nginx, PHP 8.4, MariaDB, Redis, Certbot, phpMyAdmin | tutte attive di default. Dipendenze: phpMyAdmin richiede Nginx+PHP+MariaDB; il pannello richiede Nginx+PHP+MariaDB+Certbot. UFW, fail2ban, unattended-upgrades sempre attivi. |
| 6 | Cloudflare | casella; se attiva: API token, conferma zona, "limita 80/443 agli IP Cloudflare" | Il token viene verificato subito (`/user/tokens/verify`) e la zona dedotta dal dominio del pannello. |
| 7 | Email | casella **"configura dopo dal pannello"** (default) oppure host, porta, utente, password SMTP, mittente, destinatario avvisi | Se configurata, invio email di prova a fine installazione. |
| 8 | Pannello | dominio del pannello (es. `panel.miosito.it`) | Se non si installa Nginx+PHP+MariaDB+Certbot la sezione viene saltata. |
| 9 | Riepilogo | — | Mostra tutte le scelte (segreti mascherati). Conferma / Modifica / Annulla. |

Le risposte vengono salvate in `/root/vps-installer/answers.env` (root, 600).

## 6. Cosa fa ogni step

### 10-system
- `apt update && apt full-upgrade`.
- hostname, `/etc/hosts`, fuso orario, locale.
- chrony con pool `it.pool.ntp.org`.
- unattended-upgrades: origini Debian (security + updates), riavvio automatico alle 04:00 se necessario. Repo esterni (nginx.org, sury) **non** aggiornati in automatico.
- Strumenti base: `htop git curl unzip 7zip ca-certificates gnupg whiptail`.
- DNS: invariati (quelli di OVH).
- cloud-init: disattivato a fine installazione (`/etc/cloud/cloud-init.disabled`) per evitare che riscriva SSH, hostname o utenti.

### 20-user-ssh
- Crea l'utente, lo aggiunge a `sudo`, installa la chiave in `~/.ssh/authorized_keys`.
- Prepara `/etc/ssh/sshd_config.d/10-vps.conf` (non ancora attivo):
  ```
  Port <porta>
  PermitRootLogin <no|prohibit-password>
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  X11Forwarding no
  AllowUsers <utente>
  MaxAuthTries 3
  LoginGraceTime 30
  ```
  Nota: il file `50-cloud-init.conf` di OVH imposta `PasswordAuthentication yes`; in sshd vale il **primo** valore letto, quindi `10-vps.conf` ha la precedenza.

### 30-firewall
- UFW: default deny in ingresso, allow in uscita.
- Aperte: porta SSH nuova **e** 22 (la 22 viene chiusa solo dopo il test anti-blocco).
- 80/443: aperte a tutti, oppure **solo agli IP Cloudflare** se scelto.
- fail2ban (backend systemd):
  - jail `sshd` sempre attiva sulla porta scelta.
  - jail Nginx (`nginx-limit-req`, `nginx-botsearch`) **solo se Cloudflare è disattivo**. Con Cloudflare il firewall vede solo IP di Cloudflare, quindi bannarli bloccherebbe tutti i visitatori; la protezione HTTP la fa Cloudflare.

### 40-nginx
- Repo `nginx.org` (stable) con chiave verificata.
- Nginx gira come `www-data`.
- `nginx.conf` da template (basato sul tuo attuale, con correzioni):
  - `server_tokens off`, gzip, `client_max_body_size 64m`.
  - `include /etc/nginx/snippets/cloudflare-realip.conf;` (file generato; vuoto se Cloudflare è disattivo).
  - `limit_req_zone` definita e **usata** nei vhost.
  - default server su 80 → `return 444`.
  - default server su 443 → `ssl_reject_handshake on` (non rivela i domini ospitati).
- `snippets/security-headers.conf`: `Strict-Transport-Security`, `X-Content-Type-Options nosniff`, `X-Frame-Options DENY`, `Referrer-Policy strict-origin-when-cross-origin`. Niente `X-Xss-Protection`.
- Log dei vhost in `/var/log/nginx/<dominio>.{access,error}.log`.

### 50-php
- Repo `packages.sury.org`, PHP 8.4 con i moduli attuali: `fpm cli common mysql xml curl gd imagick intl mbstring opcache redis soap zip`.
- `php.ini`: `upload_max_filesize 64M`, `post_max_size 64M`, `expose_php Off`.
- **Pool `www` di default disattivato.** Ogni sito (e il pannello) ha un proprio pool e un proprio utente di sistema.

### 60-mariadb
- MariaDB dal repo Debian (11.8).
- Messa in sicurezza automatica (equivalente di `mysql_secure_installation`): niente utenti anonimi, niente DB `test`, root solo da localhost via `unix_socket`.
- Bind solo su `127.0.0.1`.

### 70-redis
- `redis-server` dal repo Debian, bind `127.0.0.1 ::1`, `protected-mode yes`.

### 75-mail
- Solo se configurata: `msmtp` + `msmtp-mta` (fornisce `sendmail`), configurazione in `/opt/vps/secrets/msmtprc` (root, 600) con symlink `/etc/msmtprc`.
- Alias `root` → destinatario avvisi, così fail2ban, unattended-upgrades e cron mandano mail.
- Altrimenti: installa solo `msmtp` + `msmtp-mta` senza configurazione (il pannello la aggiunge dopo).

### 80-ssl
- `certbot` e `python3-certbot-dns-cloudflare` dal repo Debian.
- Registrazione senza email (`--register-unsafely-without-email`): Let's Encrypt non manda più email di scadenza dal 2025.
- Con Cloudflare: challenge DNS-01, credenziali in `/opt/vps/secrets/cloudflare.ini` (root, 600).
- Senza Cloudflare: challenge webroot su `/var/www/_acme` (cartella condivisa per tutti i vhost, `location /.well-known/acme-challenge/`).
- `snippets/ssl-params.conf`: profilo Mozilla "intermediate" (TLS 1.2/1.3), niente dhparam.
- Deploy hook: `systemctl reload nginx`.

### 85-phpmyadmin
- Ultima versione letta da `https://www.phpmyadmin.net/home_page/version.json`.
- Download dell'archivio, verifica **firma GPG** (chiave del progetto phpMyAdmin) e SHA256. Se una verifica fallisce lo step si ferma.
- Installato in `/opt/vps/phpmyadmin` (root:panel, solo lettura per `panel`).
- `config.inc.php`: `blowfish_secret` casuale, `TempDir` in `/var/www/<pannello>/storage/pma-tmp`, utente di controllo `pma` con permessi **solo** sul DB `phpmyadmin`.
- Servito **solo** su `https://<pannello>/pma`, tramite il pool PHP del pannello, dietro basic auth **bcrypt** (password generata, mostrata a fine installazione).

### 90-panel
- Utente di sistema `panel` (shell `nologin`, home `/var/www/<pannello>`).
- Struttura:
  ```
  /var/www/<pannello>/
  ├── public/       # webroot: pagina segnaposto
  ├── app/
  ├── config/.env   # credenziali DB (panel, 600)
  ├── storage/      # sessioni, cache, pma-tmp
  └── logs/
  ```
  Permessi: cartella `panel:panel` 750; `www-data` nel gruppo `panel` solo per leggere `public/`.
- Pool PHP-FPM `panel`: socket `/run/php/php8.4-fpm-panel.sock`, `open_basedir` limitato a `/var/www/<pannello>`, `/opt/vps/phpmyadmin`, `/opt/vps/manifest.json`, `/tmp`.
- DB `panel` + utente `panel` (permessi solo su `panel`).
- Utente DB `panel_dbadmin`: può creare e gestire **solo** database e utenti con prefisso `site_` (vedi handoff).
- Record DNS A/AAAA proxati su Cloudflare (se attivo), certificato, vhost `/etc/nginx/conf.d/<pannello>.conf`.

### 95-vps-tools
- Copia `tools/` in `/opt/vps/bin/` (root:root, 755). Script wrapper elencati in `PANEL-HANDOFF.md`.
- Scrive `/opt/vps/manifest.json` (root:panel, 640).
- `/etc/sudoers.d/vps-panel`: l'utente `panel` può eseguire **solo** quegli script, senza password, convalidato con `visudo -c`.
- Cron settimanale `vps-cf-ips-update` (se Cloudflare è attivo).

### 99-finalize
1. **Test anti-blocco:**
   - Attiva `10-vps.conf`, verifica con `sshd -t`, `systemctl reload ssh` (la sessione attuale resta aperta).
   - Mostra: "Apri una NUOVA finestra e accedi con `ssh -p <porta> <utente>@<ip>`, poi premi Conferma".
   - Se non arriva conferma entro **10 minuti**: rimuove `10-vps.conf`, ricarica ssh, lascia la 22 aperta, segnala l'errore e si ferma (ripresa possibile).
2. Dopo la conferma: chiude la porta 22 in UFW.
3. Utente `debian`: bloccato subito (password e chiavi disattivate). Viene eliminato al prossimo avvio da un servizio oneshot `vps-firstboot-cleanup.service` che poi rimuove sé stesso (non si può eliminare un utente con sessione aperta).
4. Disattiva cloud-init.
5. Invio email di prova (se configurata).
6. **Riepilogo finale mostrato una sola volta:** comando SSH, URL del pannello, URL e credenziali basic auth di phpMyAdmin, componenti installati.
7. Pulizia: elimina `/root/vps-installer/` (compresi `answers.env` e `state`) e il file `install.sh` scaricato.
8. Riavvio.

## 7. Errori e ripresa

- Tutti gli script: `set -Eeuo pipefail`; `trap ERR` registra step, riga e comando, poi si ferma.
- `/root/vps-installer/state` contiene gli step completati. Rilanciando `install.sh`:
  - se esiste `answers.env` salta la procedura guidata e riparte dal primo step non completato;
  - `install.sh --reset` ricomincia da capo dalla procedura guidata.
- In caso di errore i file **non** vengono cancellati; il messaggio indica come riprendere e avvisa che `answers.env` contiene segreti.
- **Segreti:** mai stampati, mai nel log, mai passati come argomenti (visibili in `ps`). Passano tramite file 600 o stdin.
- Log completo (senza segreti) in `/var/log/vps-installer.log`, che resta sulla macchina.

## 8. Test

- **shellcheck** su tutti gli script (GitHub Actions, a ogni push).
- **bats** per `lib/` (validazione, template, parsing): GitHub Actions.
- **Test completo** su VPS OVH reinstallata o VM Debian 13 locale (non Docker: servono systemd, UFW, sshd reali). Scenari minimi:
  1. tutto attivo con Cloudflare;
  2. tutto attivo senza Cloudflare e senza email;
  3. errore forzato a metà, poi ripresa;
  4. test anti-blocco senza conferma, deve tornare indietro;
  5. rilancio completo su macchina già installata (idempotenza).

## 9. Decisioni prese

| Decisione | Motivo |
|---|---|
| Domande tutte all'inizio, nessun riavvio intermedio | Un servizio systemd dopo un riavvio non ha terminale per fare domande; su Debian non serve riavviare a metà |
| Repo modulare + bootstrap verificato con hash | Manutenibile, template veri invece di `printf` con escape |
| MariaDB e certbot da Debian, Nginx da nginx.org, PHP da sury | Meno repo esterni dove possibile; Nginx/PHP aggiornati dove serve |
| Nginx come `www-data`, un utente e un pool per sito | Un sito compromesso non legge gli altri |
| phpMyAdmin solo sul dominio del pannello | Riduce la superficie d'attacco |
| Due cartelle: `/var/www/<pannello>` (panel) e `/opt/vps` (root) | Niente file sparsi, ma gli script eseguiti come root non sono modificabili dal pannello |
| Segreti di root impostabili ma non rileggibili dal pannello | Pannello compromesso ≠ token Cloudflare/SMTP rubati |
| Email facoltativa, configurabile dal pannello | Non blocca l'installazione; avvisi attivi quando configurata |
