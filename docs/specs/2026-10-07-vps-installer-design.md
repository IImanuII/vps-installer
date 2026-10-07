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

Comando unico (pubblicato nelle note di ogni release, con hash reale):

```bash
curl -fsSL https://github.com/<utente>/vps-installer/releases/download/vX.Y.Z/install.sh -o install.sh \
  && echo "<sha256>  install.sh" | sha256sum -c - \
  && sudo bash install.sh
```

**Catena di fiducia:**
1. Il comando verifica l'hash di `install.sh` (asset della release, versione fissa).
2. `install.sh` contiene l'hash dell'archivio della release, lo scarica, lo verifica e lo estrae in `/root/vps-installer/`.
3. Una GitHub Action, al push di un tag `vX.Y.Z`: esegue i test, crea l'archivio con `git archive`, genera `install.sh` con versione, repository e hash dell'archivio già inseriti, pubblica entrambi come asset della release e scrive il comando con l'hash di `install.sh` nelle note. (Il file nel tag non può contenere l'hash dell'archivio costruito dal tag stesso, per questo `install.sh` è un asset generato.)

**Connessione persa:** `install.sh` riparte dentro una sessione `tmux` chiamata `vps-installer`. Se la connessione SSH cade, ci si ricollega e si riprende con `sudo tmux attach -t vps-installer`.

Alternativa senza rete: `scp` del file sul server e `sudo bash install.sh --local <archivio>`.

## 4. Struttura del repository

```
install.sh              # bootstrap: scarica, verifica, estrae, avvia
wizard.sh               # domande whiptail → answers.env
run.sh                  # esegue gli step in ordine, gestisce stato e ripresa
lib/                    # copiata anche in /opt/vps/lib (la usano gli script wrapper)
  common.sh             # log, errori, trap, stato, apt, segreti, scrittura atomica
  answers.sh            # salvataggio/caricamento risposte, variabili derivate
  validate.sh           # validazione input (dominio, porta, chiave SSH, username...)
  template.sh           # rendering template (envsubst con lista variabili esplicita)
  components.sh         # dipendenze tra componenti
  net.sh                # IP del server, controllo DNS, suffissi di dominio
  preflight.sh          # controlli iniziali, codename OS
  apt.sh                # verifica fingerprint chiavi dei repository
  cloudflare.sh         # API Cloudflare (zona, record DNS)
  cfips.sh              # IP Cloudflare → real_ip Nginx + regole UFW
  sql.sh                # generazione SQL (quoting, utenti, DB)
  mail.sh               # configurazione msmtp, email di prova
  ssl.sh                # rilascio certificati
  pma.sh                # download/verifica/installazione phpMyAdmin
  manifest.sh           # /opt/vps/manifest.json
  summary.sh            # dati del riepilogo finale
  ssh.sh                # verifica sessione dell'utente admin
  tools.sh              # output JSON degli script wrapper
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
  85-panel.sh
  90-phpmyadmin.sh      # dopo il pannello: usa il suo utente, pool e dominio
  95-vps-tools.sh       # installa /opt/vps/{bin,lib,templates}, manifest, sudoers
  99-finalize.sh        # test anti-blocco, pulizia, riavvio
templates/              # copiata anche in /opt/vps/templates
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
| 6 | Pannello | dominio del pannello (es. `panel.miosito.it`) | Se non si installa Nginx+PHP+MariaDB+Certbot la sezione viene saltata. Viene prima di Cloudflare perché la zona si deduce da questo dominio. |
| 7 | Cloudflare | casella; se attiva: API token, "limita 80/443 agli IP Cloudflare" | Il token viene verificato subito cercando la zona del dominio del pannello (o di un dominio chiesto se il pannello non c'è). Senza Cloudflare: avviso se il dominio del pannello non punta ancora all'IP della VPS. |
| 8 | Email | **"configura dopo dal pannello"** (default) oppure host, porta, utente, password SMTP, mittente, destinatario avvisi | Se configurata, invio email di prova a fine installazione. |
| 9 | Riepilogo | — | Mostra tutte le scelte (segreti mascherati) e le correzioni automatiche delle dipendenze. Installa / Ricomincia / Annulla. |

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
- fail2ban (backend systemd), file in `/etc/fail2ban/jail.d/`:
  - jail `sshd` sempre attiva sulla porta scelta (`vps-sshd.local`).
  - jail Nginx (`nginx-limit-req`, `nginx-botsearch`, file `vps-nginx.local`) **solo se Cloudflare è disattivo**, installate dallo step 40 (fail2ban non parte se i log di una jail non esistono ancora). Con Cloudflare il firewall vede solo IP di Cloudflare, quindi bannarli bloccherebbe tutti i visitatori; la protezione HTTP la fa Cloudflare.

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
- **Pool `www` di default disattivato** dallo step 85, dopo aver creato il pool del pannello (PHP-FPM non parte senza almeno un pool). Se il pannello non viene installato, il pool `www` resta (gira come `www-data`). Ogni sito (e il pannello) ha un proprio pool e un proprio utente di sistema.

### 60-mariadb
- MariaDB dal repo Debian (11.8).
- Messa in sicurezza automatica (equivalente di `mysql_secure_installation`): niente utenti anonimi, niente DB `test`, root solo da localhost via `unix_socket`.
- Bind solo su `127.0.0.1`.

### 70-redis
- `redis-server` dal repo Debian, bind `127.0.0.1 ::1`, `protected-mode yes`.

### 75-mail
- Solo se configurata: `msmtp` + `msmtp-mta` (fornisce `sendmail`), configurazione in `/opt/vps/secrets/msmtprc` (root, 600) con symlink `/etc/msmtprc`.
- Alias `root` → destinatario avvisi, così unattended-upgrades, certbot e cron mandano mail. Le notifiche email di fail2ban non sono attive in v1 (eventualmente dal pannello).
- Altrimenti: installa solo `msmtp` + `msmtp-mta` senza configurazione (il pannello la aggiunge dopo).

### 80-ssl
- `certbot` e `python3-certbot-dns-cloudflare` dal repo Debian.
- Registrazione senza email (`--register-unsafely-without-email`): Let's Encrypt non manda più email di scadenza dal 2025.
- Con Cloudflare: challenge DNS-01, credenziali in `/opt/vps/secrets/cloudflare.ini` (root, 600).
- Senza Cloudflare: challenge webroot su `/var/www/_acme` (cartella condivisa per tutti i vhost, `location /.well-known/acme-challenge/`).
- `snippets/ssl-params.conf`: profilo Mozilla "intermediate" (TLS 1.2/1.3), niente dhparam, niente OCSP stapling (Let's Encrypt ha dismesso OCSP nel 2025).
- Deploy hook: `systemctl reload nginx`.

### 85-panel
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
- Pool PHP-FPM `panel`: socket `/run/php/php8.4-fpm-panel.sock`, `open_basedir` limitato a `/var/www/<pannello>`, `/opt/vps/phpmyadmin`, `/opt/vps/manifest.json` (niente `/tmp`: `sys_temp_dir` e `upload_tmp_dir` puntano a `storage/tmp`).
- DB `panel` + utente `panel` (permessi solo su `panel`).
- Utente DB `panel_dbadmin`: tutti i permessi **solo** sui database con prefisso `site_`, nessun permesso globale (niente `CREATE USER`). DB e utenti dei siti li crea lo script root `vps-site` (vedi handoff). Serve per lavorare sui DB dei siti da phpMyAdmin.
- Su un rilancio le password esistenti in `config/.env` vengono riusate.
- Record DNS A/AAAA proxati su Cloudflare (se attivo). Se per il dominio esistono già un CNAME o un A/AAAA verso un altro IP, la procedura guidata li mostra e chiede se sostituirli (default) o lasciarli com'è; se lasciati, il riepilogo finale lo segnala. Poi vhost `/etc/nginx/conf.d/<pannello>.conf` che include `/etc/nginx/snippets/panel.d/*.conf` (lì lo step 90 aggiunge phpMyAdmin).

### 90-phpmyadmin
- Ultima versione letta da `https://www.phpmyadmin.net/home_page/version.json`.
- Download dell'archivio, verifica **firma GPG** (fingerprint del firmatario fissato nel codice) e SHA256. Se una verifica fallisce lo step si ferma.
- Installato in `/opt/vps/phpmyadmin` (root:panel, solo lettura per `panel`); rimosse le cartelle `setup/` ed `examples/`.
- `config.inc.php`: `blowfish_secret` casuale, `TempDir` in `/var/www/<pannello>/storage/pma-tmp`, `AllowRoot false`, utente di controllo `pma` con permessi **solo** sul DB `phpmyadmin`.
- Servito **solo** su `https://<pannello>/pma/`, tramite il pool PHP del pannello, dietro basic auth **bcrypt** (utente = admin, password generata, mostrata a fine installazione).

### 95-vps-tools
- Copia `tools/` in `/opt/vps/bin/` (root:root, 755), `lib/` in `/opt/vps/lib/` e `templates/` in `/opt/vps/templates/` (root:root, 644). Script wrapper elencati in `PANEL-HANDOFF.md`.
- Scrive `/opt/vps/manifest.json` (root:panel, 640).
- `/etc/sudoers.d/vps-panel`: l'utente `panel` può eseguire **solo** quegli script, senza password, convalidato con `visudo -c`.
- Cron settimanale `vps-cf-ips-update` (se Cloudflare è attivo).

### 99-finalize
1. **Test anti-blocco:**
   - Attiva `10-vps.conf`, verifica con `sshd -t`, `systemctl reload ssh` (la sessione attuale resta aperta).
   - Se Debian usa l'attivazione via socket (`ssh.socket`), la disattiva e passa a `ssh.service` (altrimenti la porta non cambierebbe).
   - Mostra: "Apri una NUOVA finestra e accedi con `ssh -p <porta> <utente>@<ip>`, poi scrivi OK".
   - La conferma vale solo se `loginctl` mostra davvero una sessione dell'utente admin.
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
- Se la connessione SSH cade, l'installazione continua dentro `tmux` (vedi sezione 3).
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
