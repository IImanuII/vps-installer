# Passaggio installer → pannello

Contratto tra `vps-installer` e il pannello. Descrive **cosa lascia l'installer sulla macchina**, **cosa il pannello può fare** con ogni cosa e **cosa resta da fare** nel pannello.

Se l'installer cambia una di queste cose, questo file va aggiornato insieme alla versione (`manifest.json → installer_version`).

## 1. Regola generale

- Il pannello **legge** solo i dati non segreti e i propri.
- I segreti di sistema li può **impostare, cambiare e testare, mai rileggere**, tramite gli script in `/opt/vps/bin/` eseguiti con `sudo`.
- Il pannello non scrive mai direttamente in `/etc`, `/opt/vps` o nelle cartelle di altri siti.

## 2. Mappa dei file

### Del pannello (`panel`)

| Percorso | Proprietario / permessi | Contenuto |
|---|---|---|
| `/var/www/<pannello>/` | `panel:panel` 750 | radice del pannello |
| `/var/www/<pannello>/public/` | `panel:panel` 750 (`www-data` nel gruppo `panel`) | webroot |
| `/var/www/<pannello>/app/` | `panel:panel` | codice |
| `/var/www/<pannello>/config/.env` | `panel:panel` 600 | credenziali DB `panel` e `panel_dbadmin` |
| `/var/www/<pannello>/storage/` | `panel:panel` 700 | sessioni, cache, `pma-tmp/` |
| `/var/www/<pannello>/logs/` | `panel:panel` 750 | log applicativi di Plancia e php-error.log del pool |

### Di root (`/opt/vps`)

| Percorso | Proprietario / permessi | Contenuto |
|---|---|---|
| `/opt/vps/bin/` | `root:root` 755 | script wrapper (sez. 4) |
| `/usr/local/sbin/vps-panel-install`, `/usr/local/sbin/vps-panel-update` | link simbolici di root | puntano a `/opt/vps/bin/`: così `sudo vps-panel-install` li trova (`/opt/vps/bin` non è nel `secure_path` di sudo) |
| `/opt/vps/lib/` | `root:root` 755 / file 644 | librerie bash usate dagli script wrapper |
| `/opt/vps/templates/` | `root:root` 755 / file 644 | template di configurazione usati dagli script wrapper |
| `/opt/vps/manifest.json` | `root:panel` 640 | info non segrete (sez. 3) |
| `/opt/vps/secrets/` | `root:root` 700 | segreti di sistema |
| `/opt/vps/secrets/cloudflare.ini` | `root:root` 600 | token API Cloudflare (se attivo) |
| `/opt/vps/secrets/msmtprc` | `root:root` 600 | configurazione SMTP (se configurata) |
| `/opt/vps/secrets/panel-deploy-key` | `root:root` 600 | deploy key GitHub di sola lettura per IImanuII/vps-panel |
| `/opt/vps/panel.git/` | `root:root` 700 | repository git di Plancia, fuori dalla radice del pannello: il pannello non può modificarlo |
| `/opt/vps/backups/panel/` | `root:root` 700 / file 600 | dump del DB del pannello prima di ogni aggiornamento (ultimi 5) |
| `/opt/vps/phpmyadmin/` | `root:panel` 750 / file 640 | phpMyAdmin |
| `/opt/vps/sites/` | `root:panel` 750 / file 640 | registro dei siti di `vps-site` (un JSON per sito, nessun segreto) |
| `/opt/vps/backups/sites/` | `root:root` 700 / file 600 | archivi dei siti eliminati, cancellati dopo 30 giorni. Dalla 1.7.0 `DOMINIO-AAAAMMGG-HHMMSS.tar.gz` nel formato dei backup (`manifest.json`, `files.tar.gz`, `db.sql.gz`): si può ricreare il sito. Quelli fatti prima (tar della cartella + `.sql.gz` a parte) restano, `restorable:false` |
| `/opt/vps/backups/restore/` | `root:root` 700 / file 600 | copie di sicurezza fatte prima di ogni ripristino (stesso formato), 7 giorni |
| `/opt/vps/backups/tmp/` | `root:root` 700 | lavoro del giro e dei ripristini (`bk.*`); svuotata a ogni uso, i residui di oltre 1 giorno si tolgono al giro dopo |
| `/opt/vps/backup/config.json` | `root:root` 600 (cartella 700) | `{"enabled","time","folder"}` di `vps-backup` |
| `/opt/vps/backup/state.json` | `root:root` 600 | `job`, `last_run`, `known`, `last_restore` (sez. `vps-backup`) |
| `/opt/vps/backup/drive.json` | `root:root` 600 | cache dello spazio di Drive per `vps-backup status`: `{"checked_at":epoch,"drive":{used,total}\|null}` (installer ≥ 1.11.1); il pannello non lo legge |
| `/opt/vps/secrets/rclone.conf` | `root:root` 600 | remote `gdrive` (rclone, scope `drive.file`) con il token di Drive; il pannello non lo legge |
| `/etc/systemd/system/vps-backup.service`, `vps-backup.timer` | `root:root` 644 | `Type=oneshot`, `ExecStart=/opt/vps/bin/vps-backup _run`, `TimeoutStartSec=12h`; il timer (`OnCalendar` dal drop-in `vps-backup.timer.d/ora.conf`, `Persistent=true`) è spento finché il backup non è attivato |
| `/run/vps-backup.lock`, `/run/vps-site.<slug>.lock` | root 600 | lock globale di `vps-backup` e lock per sito (esclusivo per giro e ripristino, condiviso per le scritture di `vps-files` e i lavori di `vps-site`) |
| `/opt/vps/monitor/config.json` | `root:root` 600 (cartella 700) | configurazione di `vps-monitor` (con il token del bot: il pannello non la legge, usa `vps-monitor status`) |

### File di sistema (posizioni obbligate)

| Percorso | Note |
|---|---|
| `/etc/nginx/nginx.conf` | template installer |
| `/etc/nginx/conf.d/<pannello>.conf` | vhost pannello |
| `/etc/nginx/snippets/ssl-params.conf` | TLS Mozilla intermediate |
| `/etc/nginx/snippets/security-headers.conf` | header di sicurezza (siti statici e PHP; i vhost WordPress scrivono le stesse intestazioni con `X-Frame-Options SAMEORIGIN` per il Customizer, `burst=60` e una regola per i file statici con `burst=200` e cache del browser di 30 giorni) |
| `/etc/nginx/snippets/cloudflare-realip.conf` | generato da `vps-cf-ips-update` |
| `/etc/nginx/snippets/acme.conf` | `location /.well-known/acme-challenge/` → `/var/www/_acme` |
| `/etc/nginx/snippets/panel.d/pma.conf` | location `/pma/` nel vhost del pannello |
| `/var/www/_acme/` | webroot condivisa per le challenge Let's Encrypt (senza Cloudflare) |
| `/etc/nginx/.htpasswd-pma` | basic auth phpMyAdmin (bcrypt), `root:www-data` 640 |
| `/etc/php/8.4/fpm/pool.d/panel.conf` | pool del pannello |
| `/etc/ssh/sshd_config.d/10-vps.conf` | configurazione SSH |
| `/etc/fail2ban/jail.d/vps-sshd.local` | jail SSH |
| `/etc/fail2ban/jail.d/vps-nginx.local` | jail Nginx (solo senza Cloudflare) |
| `/etc/sudoers.d/vps-panel` | permessi sudo del pannello |
| `/etc/msmtprc` | symlink → `/opt/vps/secrets/msmtprc` |
| `/etc/letsencrypt/` | certificati (gestiti da certbot) |
| `/etc/cron.d/vps` | cron degli script `/opt/vps/bin` |
| `/etc/cron.d/vps-panel` | manutenzione notturna di Plancia (utente panel) |
| `/var/log/vps-installer.log` | log installazione (senza segreti) |
| `/etc/nginx/conf.d/<sito>.conf` | vhost di un sito, scritto da `vps-site` |
| `/etc/php/8.4/fpm/pool.d/site_<slug>.conf` | pool PHP di un sito |
| `/usr/local/bin/wp` | WP-CLI (ultima release, verificata con SHA-512), installato e aggiornato dall'installer (anche con `--tools-only`) |
| `/etc/redis/users.acl` | utenti ACL di Redis (`aclfile`): `default` spento, `vps-admin` e un utente `site_<slug>` per ogni sito WordPress, `root:redis` 640 |
| `/opt/vps/secrets/redis-admin` | password di `vps-admin` (solo per `ACL LOAD`), `root:root` 600 |
| `/var/www/<sito>/wp-config.php` | configurazione WordPress, `root:site_<slug>` 640 (il sito non la riscrive); contiene password DB e password Redis del sito |
| `/etc/cron.d/vps-site-<slug>` | cron di WordPress di un sito (al posto di wp-cron via web) |
| `/etc/logrotate.d/vps-site-site_<slug>` | rotazione dei log di un sito (nota SP2a rimandata: ruota come root, i log PHP in `logs/php/` con `su`) |
| `/etc/logrotate.d/vps` | rotazione settimanale (8 copie, compresse) di `vps-tools.log`, `vps-installer.log`, `msmtp.log` e dei log del pannello (`<radice>/logs/*.log`, come `panel`); riscritto da `--tools-only` e `vps-panel-install` (installer ≥ 1.9.0) |
| `/opt/vps/ssh-tunnel.json` | stato dell'accesso SSH dal browser (installer ≥ 1.10.0): host, id Cloudflare di tunnel, app, policy, record DNS e provider OTP, `users: [{email, user, sudo}]` (installer ≥ 1.11.0; la 1.10.0 aveva `emails` e `user`); non contiene segreti. Esiste solo con l'accesso attivo |
| `/opt/vps/secrets/cf-tunnel.env` | `root:root` 600: `TUNNEL_TOKEN` per `cloudflared` |
| `/etc/ssh/sshd_config.d/20-vps-cfaccess.conf` | drop-in di sshd per l'accesso con certificato breve della CA di Cloudflare Access |
| `/etc/ssh/vps-cf-ca.pub` | chiave pubblica della CA di Access (`TrustedUserCAKeys`) |
| `/etc/ssh/vps-cf-principals/` | un file per utente creato dall'accesso SSH, con dentro il proprio nome (la parte prima della `@` dell'email) |
| `/etc/sudoers.d/vps-ssh-<utente>` | `<utente> ALL=(ALL) NOPASSWD:ALL`, 440 root, solo per chi ha `sudo` (installer ≥ 1.11.0) |
| `/etc/systemd/system/vps-cloudflared.service` | servizio di `cloudflared` (tunnel verso `ssh://localhost`) |
| `/etc/apt/apt.conf.d/90vps-cloudflared` | hook apt (`DPkg::Post-Invoke`): riavvia `vps-cloudflared` dopo ogni aggiornamento del pacchetto; tolto con la disattivazione |
| apt source di `cloudflared` (repository `pkg.cloudflare.com`, suite `any`) | installato con l'accesso SSH; origine aggiunta agli aggiornamenti automatici (`52vps-unattended`) |
| `/var/www/_maintenance/_maintenance.html` | pagina 503 dei siti disattivati |
| `/etc/systemd/system/vps-monitor.service` | `root:root` 644: `Type=oneshot`, `ExecStart=/opt/vps/bin/vps-monitor _run`, `TimeoutStartSec=55`, `Nice=5` |
| `/etc/systemd/system/vps-monitor.timer` | `root:root` 644: `OnCalendar=*:*:00`, `AccuracySec=5s`, `Persistent=false`; installato spento, lo abilita/ferma `vps-monitor config` |
| `/var/lib/vps-monitor/state.json` | `root:root` 600 (cartella 700): stato dei controlli, avvisi delle ultime 24 ore (al massimo 200), cursori |
| `/var/lib/vps-monitor/queue/` | `root:root` 700: messaggi Telegram non ancora consegnati (un file per messaggio, al massimo 500) |
| `/run/vps-monitor.lock` | lucchetto di un giro (`flock -n`: un giro ancora in corso fa saltare il successivo) |
| `/var/www/<sito>/` | `root:site_<slug>` 2750 (il sito non scrive nella radice); `logs/` `root:site_<slug>` 2750 con `access.log`/`error.log` di Nginx; `logs/php/` `site_<slug>` 2770 con `php-error.log`; `public/` e `tmp/` `site_<slug>` 2770 (admin nel gruppo, `www-data` in sola lettura via ACL); `db.env` `root:site_<slug>` 640. Radice, `logs/` e `db.env` sono di root perché Nginx (root) e `vps-site` seguirebbero un link messo lì dal sito |

## 3. `manifest.json`

```json
{
  "installer_version": "1.5.0",
  "installed_at": "2026-10-07T15:30:00+02:00",
  "hostname": "vps-01",
  "ipv4": "203.0.113.10",
  "ipv6": "2001:db8:100::1:2cf7",
  "admin_user": "manu",
  "ssh_port": 41822,
  "root_login": "no",
  "components": {
    "nginx": true, "php": "8.4", "mariadb": true, "redis": true,
    "certbot": true, "phpmyadmin": "5.2.3", "redis_acl": true
  },
  "cloudflare": { "enabled": true, "origin_locked": true, "zone": "miosito.it", "ips_updated_at": "2026-10-07T15:31:00+02:00" },
  "mail": { "configured": false, "alert_email": null },
  "panel": {
    "domain": "panel.miosito.it",
    "path": "/var/www/panel.miosito.it",
    "php_socket": "/run/php/php8.4-fpm-panel.sock",
    "pma_path": "/pma/",
    "version": "2.1.0",
    "deployed_at": "2026-10-11T18:00:00+02:00",
    "repo": "git@github.com:IImanuII/vps-panel.git"
  },
  "conventions": {
    "site_root": "/var/www/<dominio>",
    "site_db_prefix": "site_",
    "site_user_prefix": "site_"
  }
}
```

`components.redis_acl` è `true` quando Redis usa gli utenti ACL (`default` spento): `vps-site` crea siti WordPress solo se è vero.

`version`, `deployed_at`, `repo` li scrivono `vps-panel-install`/`vps-panel-update`; una riscrittura del manifest da parte dell'installer li conserva.

Il pannello **non** modifica il manifest direttamente: quando cambia lo stato (es. email configurata) lo aggiorna lo script wrapper corrispondente.

## 4. Script wrapper in `/opt/vps/bin`

Regole per tutti:
- eseguiti con `sudo` dall'utente `panel`, abilitati uno per uno in `/etc/sudoers.d/vps-panel`;
- **argomenti validati in modo rigido** (whitelist); niente shell libera, niente percorsi arbitrari;
- **segreti letti da stdin**, mai da argomenti;
- output JSON su stdout (`{"ok":true,...}` / `{"ok":false,"error":"..."}`), codice di uscita ≠ 0 in caso di errore;
- non stampano mai segreti.

Forniti dall'installer (v1):

| Script | Uso | Cosa fa |
|---|---|---|
| `vps-cf-token` | `set` (token da stdin) / `test` | sostituisce o verifica il token Cloudflare. `set` verifica che il token veda la zona del pannello e quelle di tutti i siti registrati prima di salvarlo (`{"ok":false,"error":"il token non vede le zone: ..."}`); `test` risponde `{"ok":true,"zones":N}`. Errori: `formato del token non valido`, `Cloudflare non è attivo su questa VPS`, `il token non ha accesso alla zona ZONA`, `il token salvato non ha accesso alla zona ZONA`, `il token non è valido o Cloudflare non risponde` |
| `vps-cf-purge` | `ZONA --all` / `ZONA` con indirizzi su stdin (1-30, https, host della zona) / `ZONA --host` con nomi su stdin (installer ≥ 1.11.1; 1-30, uno per riga, la zona o un suo sottodominio, maiuscole portate in minuscolo) | svuota la cache Cloudflare: `{"ok":true,"purged":"all"|N}`. `--host` svuota tutto ciò che è servito con quei nomi (purge per host, tutti i piani) senza toccare gli altri siti della zona; se Cloudflare lo rifiuta è un errore, mai un ripiego su `--all`. Dopo un ripristino `vps-backup` usa `--host` con il dominio del sito e, se ha il www, `www.<dominio>` (prima della 1.11.1 svuotava tutta la zona). Il pannello non tiene token Cloudflare. Errori: `zona non valida`, `Cloudflare non è attivo su questa VPS`, `zona non trovata: ZONA`, `Cloudflare non risponde`, `nessun indirizzo`, `troppi indirizzi: il limite è 30`, `indirizzo non valido: URL`, `nessun host`, `troppi host: il limite è 30`, `host non valido: HOST`, `Cloudflare ha rifiutato la richiesta: MSG` ||N}`. Il pannello non tiene token Cloudflare. Errori: `zona non valida`, `Cloudflare non è attivo su questa VPS`, `zona non trovata: ZONA`, `Cloudflare non risponde`, `nessun indirizzo`, `troppi indirizzi: il limite è 30`, `indirizzo non valido: URL`, `Cloudflare ha rifiutato la richiesta: MSG` |
| `vps-cf-ips-update` | — | scarica gli IP Cloudflare, rigenera `cloudflare-realip.conf` e regole UFW 80/443, `nginx -t` + reload. Anche da cron settimanale |
| `vps-smtp` | `show` / `set` (config JSON da stdin) / `test <email>` / `disable` | `show` (installer ≥ 1.8.0): `{ok, configured, host, port, user, from, alert_email}`, mai la password (campi `null` se non configurata). `set`: JSON `{host, port, user, pass, from, alert_email}`, scrive `msmtprc` e gli alias di `root`; `pass` vuota o assente = tiene la password salvata (≥ 1.8.0; senza configurazione: `password SMTP obbligatoria`). Porte 25/465/587/2525, utente senza spazi ≤ 254, password ≤ 256 caratteri senza controlli. `test`: manda una email di prova; se msmtp fallisce `invio non riuscito: <motivo>` con la riga utile dello stderr di msmtp (≥ 1.8.0). `disable`: toglie configurazione e alias |
| `vps-pma-pass` | `set` / `dbadmin` (password da stdin, 12-72 caratteri, una riga) | `set`: rigenera `.htpasswd-pma` (bcrypt). `dbadmin`: `ALTER USER 'panel_dbadmin'@'localhost'` come root dal socket (SQL su stdin, mai negli argomenti) e riscrive `DBADMIN_PASS=` in `<radice pannello>/config/.env` (radice dal manifest; file temporaneo + `mv`, stesso proprietario e permessi, le altre righe intatte, la riga è aggiunta se manca; lock `/run/vps-panel-update.lock`, attesa 30 s). Risposta `{"ok":true}`. `ALTER` fallito: `.env` non toccato; `.env` non scrivibile: la password MariaDB torna a quella letta prima. La password non può iniziare né finire con spazio o apice (il `.env` li taglierebbe). Plancia non legge `DBADMIN_*` (`Config::CHIAVI`): nessun reload di PHP-FPM. Errori: `password troppo lunga: massimo 72 caratteri`, `password non valida: ...`, `File .../.env mancante: password non cambiata`, `password di panel_dbadmin non cambiata`, `... non scrivibile: password di panel_dbadmin rimasta quella di prima` |
| `vps-pma-update` | `[--check]` | scarica l'ultima phpMyAdmin, verifica GPG + SHA256, sostituisce mantenendo `config.inc.php`; `{ok, updated, version, previous?}`, rifiuta se un altro aggiornamento è in corso. Con `--check` (installer ≥ 1.7.8; prima l'argomento era ignorato e lo script aggiornava) non tocca niente: `{ok, installed, latest, update_available}`, `latest` null se phpmyadmin.net non risponde |
| `vps-status` | — | stato servizi, versioni, disco, RAM, aggiornamenti disponibili (sostituisce gli script di health check) |

Forniti dall'installer v1.1, **eseguiti dall'amministratore** (non dal pannello, non in sudoers):

| Script | Uso | Cosa fa |
|---|---|---|
| `vps-panel-install` | interattivo | deploy key, token Telegram, checkout dell'ultimo tag `vX.Y.Z`, `APP_KEY` se manca, `schema.sql`, primo super_admin, `/etc/cron.d/vps-panel`, controllo `/health` |
| `vps-panel-update` | `[--ref vX.Y.Z]` | parte dalla versione del manifest (riprende un aggiornamento interrotto), dump del DB, checkout, `schema.sql` + `install/migrations/X.Y.Z.sql` letti dal tag e non dai file del pannello, `php -l`, reload PHP-FPM, `/health`; se fallisce torna alla versione di prima (codice e DB) |

Regole per il pannello: i rilasci sono tag annotati `vX.Y.Z`; le modifiche allo schema di
un'installazione esistente vanno in `install/migrations/X.Y.Z.sql`, idempotenti.
I file di sviluppo del repository (`.claude/`, `Documenti/`, `tests/`, `infra/`,
`PRODUCT.md`) non arrivano nella radice del pannello (sparse checkout, elenco
`PD_DEV_PATHS` in `lib/panel_deploy.sh`): il pannello non deve leggerli a runtime.

Forniti dall'installer v1.2 (eseguiti dal pannello, in sudoers):

| Comando | Sincrono | Risposta |
|---|---|---|
| `vps-site zones` | sì | `{"ok":true,"zones":["miosito.it",...]}`: zone attive visibili dal token |
| `vps-site list` | sì | `{"ok":true,"sites":[<registro>...]}` |
| `vps-site show <dominio>` | sì | `{"ok":true,"site":<registro>}` |
| `vps-site create <dominio> --type static\|php [--www] [--db]` | no | `{"ok":true,"state":"creating"}` |
| `vps-site create <dominio> --type wordpress [--www] --title T --admin-user U --admin-email E --login-path P [--cloudflare]` | no | `{"ok":true,"state":"creating"}` |
| `vps-site create <dominio> --from-backup NOME` | no | `{"ok":true,"state":"creating"}` (dettagli nella sezione `vps-backup`) |
| `vps-site wp-install <dominio> --title T --admin-user U --admin-email E --login-path P [--cloudflare]` | no | `{"ok":true,"state":"installing"}` |
| `vps-site disable <dominio>` / `enable <dominio>` | sì | `{"ok":true,"state":"disabled"\|"active"}` |
| `vps-site delete <dominio>` | no | `{"ok":true,"state":"deleting"}` |
| `vps-site db-create <dominio>` | sì | `{"ok":true}` |
| `vps-site db-password <dominio>` | sì | `{"ok":true}` |

Regole di `vps-site`:
- la password del database arriva **solo da stdin**, prima riga (16-128 caratteri stampabili, senza spazi né `'` `"` `\`), per `create --db`, `db-create` e `db-password`; il chiamante deve chiudere stdin;
- `create --type wordpress` ha sempre il database (niente `--db`) e legge **due righe** da stdin: password del database, poi password dell'amministratore di WordPress (stesse regole di `db-password`); `--title` 1-100 caratteri senza caratteri di controllo, `--admin-user` `^[a-z0-9_.-]{3,60}$` e non `admin`/`administrator`/`root`, `--admin-email` ≤ 100 caratteri, `--login-path` `^[a-z0-9-]{4,40}$` e non `wp-admin`/`wp-login`/`admin`/`login`/`dashboard` (`/wp-login.php` e `/wp-admin` danno 404, il login sta solo su quel percorso), `--cloudflare` installa anche il plugin Cloudflare;
- `wp-install` installa WordPress su un sito già esistente, con le stesse opzioni e **una riga** da stdin (password admin). È ammesso solo su un sito `php` in stato `active`, con database e con il segnaposto intatto (marcatore `<!-- vps-site:segnaposto -->` in `public/`): se ci sono file veri rifiuta prima di toccare qualunque cosa. Lo stato diventa `installing` e il lavoro è `job.op` `wpinstall`; durante l'installazione il sito serve la pagina di manutenzione 503 (chiude la finestra in cui qualcuno potrebbe prendersi l'installazione). Se fallisce, il sito torna PHP con il solo segnaposto e il database vuoto (eliminato e ricreato con la password di `db.env`); se l'annullamento è parziale finisce in `error` e il sito resta in 503 con `job.error` che elenca i resti;
- `db-password` su un sito WordPress aggiorna anche `wp-config.php`, altrimenti il sito perderebbe il database; `list` e `show` aggiungono a ogni sito `placeholder` (`true` se `public/` ha ancora solo il segnaposto) e, per WordPress, `wordpress` (`login_path`, `admin_user`, `cloudflare_plugin`, `installed_at`);
- Redis: un utente per sito WordPress (`site_<slug>`), con le sole chiavi che iniziano per `site_<slug>:` e senza comandi pericolosi o di amministrazione (regola `~site_<slug>:* &site_<slug>:* +@all -@dangerous -@admin +info -script|kill -script|flush -function`: niente `SCRIPT KILL`/`SCRIPT FLUSH` né `FUNCTION`, che agiscono su tutto Redis); la sua password sta in `wp-config.php`. L'utente `default` è spento; `vps-admin` (segreto in `/opt/vps/secrets/redis-admin`) serve solo a ricaricare le ACL, con la password in `REDISCLI_AUTH` e mai negli argomenti. `users.acl` si riscrive sempre con il lucchetto dei lavori di `vps-site` (anche l'installer lo prende, attesa massima 60 s) e il file temporaneo nasce in `/etc`, non nella cartella `redis:redis` 2770;
- cache Redis limitata: alla prima configurazione delle ACL, se `redis.conf` non ha già una riga `maxmemory` attiva, l'installer aggiunge `maxmemory 256mb` e `maxmemory-policy allkeys-lru` (un `maxmemory` scelto dall'amministratore resta com'è; se Redis non riparte `redis.conf` torna quello di prima, senza queste righe). `wp-config.php` ha `WP_REDIS_MAXTTL` 604800 (7 giorni): nessuna chiave della cache resta senza scadenza;
- i pulsanti del plugin Redis Object Cache in wp-admin ("Attiva"/"Svuota la cache") usano `FLUSHDB`, che l'utente del sito non ha: rispondono `NOPERM`. È normale: la cache la attiva `vps-site` (copia del drop-in), e lo svuotamento selettivo del solo prefisso del sito c'è grazie a `WP_REDIS_SELECTIVE_FLUSH` (ad es. `wp cache flush`);
- un sito WordPress disattivato (`disable`) risponde 503 ma il suo cron in `/etc/cron.d/vps-site-<slug>` continua a girare: gli eventi pianificati e gli aggiornamenti automatici di core e plugin vanno avanti anche mentre il sito è spento;
- `placeholder` in `list`/`show` si calcola solo per i siti `php` in stato `active` (gli unici su cui `wp-install` è ammesso); per tutti gli altri è sempre `false`. `index.html` lo legge l'utente del sito (al massimo 8 KiB, 5 s), mai root;
- `create` e `delete` rispondono subito e lavorano in background come unità systemd (`vps-site-<slug>-<op>`); un lavoro alla volta (lucchetto globale); l'avanzamento sta nel registro (`state`, `job.step`, `job.error`);
- le operazioni brevi (`disable`, `enable`, `db-*`) rispondono "riprova" se un lavoro è in corso; un breve lucchetto sul registro serializza i comandi concorrenti (attesa fino a 5 s);
- un lavoro interrotto da un riavvio: creazione -> `error` (si pulisce con `delete`); eliminazione ferma a `queued`/`archive` -> torna allo stato precedente, ferma a `remove` -> `error`;
- un'eliminazione che non riesce a togliere tutto (ad es. `userdel` rifiutato) non cancella il registro: il sito va in `error` con `job.error` che elenca i resti, e un nuovo `delete` riprova senza riarchiviare;
- `--www` vale solo per il dominio principale di una zona (`miosito.it`, non `blog.miosito.it`): il certificato gratuito di Cloudflare copre la zona e un solo livello di sottodomini, quindi `www.blog.miosito.it` non avrebbe HTTPS. La creazione si ferma al passo `dns`, prima di creare record;
- `_run` e `_prune` sono interni (systemd e cron) e sotto sudo vengono rifiutati;
- sotto sudo `vps-site` si rilancia subito in un'unità systemd temporanea (`systemd-run --wait --pipe --collect --quiet --service-type=exec --setenv=VPS_SITE_VIA_SYSTEMD=1 /opt/vps/bin/vps-site ...`): `php8.4-fpm.service` gira con `ProtectSystem=full` e `sudo` lanciato da PHP eredita il suo spazio dei mount, dove `/etc` è in sola lettura, quindi `disable`/`enable`/`db-*` non potrebbero scrivere vhost e configurazioni. stdin, stdout e codice d'uscita passano invariati; dentro l'unità `_run`/`_prune` restano rifiutati. Gli altri script che scrivono in `/etc` chiamati dal pannello (ad es. `vps-cf-ips-update`) hanno lo stesso limite e potranno servirsi dello stesso schema.

Forniti dall'installer v1.5 (eseguiti dal pannello, in sudoers): `vps-monitor`,
la sorveglianza della VPS con avvisi Telegram. Il giro (`_run`) lo lancia solo
`vps-monitor.timer` ogni minuto come root; sotto sudo `_run` risponde
`{"ok":false,"error":"comando interno"}`.

| Comando | stdin | Risposta |
|---|---|---|
| `vps-monitor status` | — | `{"ok":true,"enabled":bool,"telegram_configured":bool,"healthchecks":bool,"chat_id":"…","last_run":"ISO"\|null,"checks":[{"id","kind","label","state","since","code","time_ms"}],"alerts":[{"at","text"}],"urls":[{"url","keyword"}],"thresholds":{…},"queued":N}` |
| `vps-monitor config` | JSON della configurazione (≤ 64 KiB) | `{"ok":true}` / `{"ok":false,"error":"…"}` |
| `vps-monitor test` | — | invia "✅ <hostname>: messaggio di prova"; `{"ok":true}` o `{"ok":false,"error":"Telegram: <descrizione di Telegram>"}` (anche `Telegram non configurato`, `Telegram: Telegram non raggiungibile`) |

`status`:
- `checks`: un elemento per controllo, nell'ordine del giro. `kind` è `url` (id `health` per `/health` del pannello, `url:<indirizzo>` per gli altri), `service` (`service:<nome>`), `disk`, `mem`, `load`, `f2b`, `cert` (`cert:<dominio>`), `cf_token`; `state` `ok`/`warn`/`down`; `since` (ISO UTC, inizio del problema, `null` se ok); `code` e `time_ms` solo per gli indirizzi (`code` `null` se non c'è risposta HTTP);
- `alerts`: i messaggi delle ultime 24 ore (ISO UTC, testo completo con emoji e hostname), dal più vecchio; il riepilogo delle 9 non c'è;
- `last_run`: ora dell'ultimo giro (ISO UTC) o `null`; `queued`: messaggi in coda non ancora consegnati;
- `urls`, `thresholds` e `chat_id` (non è un segreto) dalla configurazione, per precompilare il modulo; **mai il token** (solo `telegram_configured`) né l'indirizzo di ping (solo `healthchecks`).

`config` (stesso formato di `/opt/vps/monitor/config.json`):

```json
{
  "enabled": true,
  "telegram": {"bot_token": "123456:ABC...", "chat_id": "123456789"},
  "healthchecks_url": "https://hc-ping.com/<uuid>",
  "urls": [{"url": "https://trip4free.org/", "keyword": "Trip4Free"}],
  "thresholds": {"fail_count": 2, "timeout_s": 10, "slow_s": 3, "slow_count": 5, "remind_min": 30,
    "disk_warn_pct": 85, "disk_crit_pct": 95, "mem_avail_pct": 10, "mem_minutes": 5,
    "load_factor": 2, "load_minutes": 10, "cert_days": 14, "f2b_bans": 20, "f2b_minutes": 10}
}
```

- `bot_token`, `telegram.chat_id` e `healthchecks_url` assenti = conserva quelli salvati (il pannello non deve rimandarli; la stringa vuota li cancella); `bot_token` vuoto = Telegram non configurato (in quel caso nessun messaggio viene accodato, gli avvisi restano solo in `status`). Gli altri campi assenti prendono i valori predefiniti (`enabled` falso, niente indirizzi, soglie qui sopra).
- Regole: `bot_token` `^[0-9]{5,15}:[A-Za-z0-9_-]{30,60}$`, `chat_id` `^-?[0-9]{1,20}$`, `healthchecks_url` vuoto o `https://hc-ping.com/[A-Za-z0-9_/-]{1,150}`, al massimo 20 `urls` (https, host minuscolo valido, niente porta, credenziali, spazi o caratteri di controllo, ≤ 512 byte), `keyword` ≤ 100 byte senza caratteri di controllo; soglie intere `fail_count` 1-10, `timeout_s` 2-30, `slow_s` 1-30, `slow_count` 1-30, `remind_min` 5-1440, `disk_warn_pct`/`disk_crit_pct` 50-99 con warn < crit, `mem_avail_pct` 1-50, `mem_minutes`/`load_minutes`/`f2b_minutes` 1-60, `load_factor` 1-10, `cert_days` 1-30, `f2b_bans` 1-1000. Un campo non valido rifiuta tutto e lascia la configurazione di prima.
- Dopo il salvataggio: `systemctl enable --now vps-monitor.timer` se `enabled`, altrimenti `disable --now`. Se il file è scritto ma il timer non parte/non si ferma: `{"ok":false,"saved":true,"error":"…"}`.

Un giro: indirizzi in parallelo (`/health` con `--resolve <dominio>:443:127.0.0.1`, atteso 200 e `OK`; gli altri ok se codice < 500, redirect non seguiti, e la parola attesa nel primo MiB), servizi del manifest con riavvio (al massimo 3 l'ora, poi "riavvii sospesi"), disco/RAM/carico, accessi SSH (`journalctl -u ssh`), Ban di fail2ban, ogni 6 ore certificati e `vps-cf-token test`, alle 9 (Europe/Rome) il riepilogo solo se c'è contenuto; poi stato salvato, ping a Healthchecks.io, invio della coda (dal più vecchio, al massimo 10 invii e 44 s). Messaggi in testo semplice: `<emoji> <hostname>: <testo>` (🔴 giù, 🟡 attenzione, 🟢 rientro, 🔐 SSH, 📋 riepilogo).

Fornito dall'installer v1.6, **eseguito dal pannello** con sudo (è in `/etc/sudoers.d/vps-panel`): `vps-files`, il file manager dei siti. Il chiamante non è fidato e i file sono del sito: root non apre mai nulla sotto `public/` o `logs/php/`, ogni accesso passa da `runuser -u site_<slug>` con `env -i`, `PATH` fisso e `umask 002` (file 664, cartelle 775), sotto `timeout`. Le sole letture di root sono le voci dirette di `logs/` (file regolari, non link). Il sito deve essere nel registro di `vps-site` con stato `active` o `disabled`.

| Comando (argomenti) | Risposta |
|---|---|
| `list DOM PERCORSO` (`""` = radice) | `{"ok":true,"path","writable":bool,"truncated":bool,"entries":[{"name","type":"file\|dir\|link\|other","size","mtime":"<sec>.<9 cifre>","perms","raw":bool}]}`; al massimo 10.000 voci; `raw:false` = nome non UTF-8, non indirizzabile |
| `stat DOM PERCORSO` | `{"ok":true,"type","size","mtime","text":bool}` (`text`: file regolare ≤ 2 MB, senza NUL nei primi 8 KB, UTF-8 valido) |
| `read DOM PERCORSO` | **byte grezzi** del file su stdout (solo file regolari) |
| `write DOM PERCORSO [--overwrite] [--if-mtime SEC.NSEC --if-size N]` (contenuto su stdin, ≤ 10 MB) | `{"ok":true,"mtime","size"}`; file nuovo senza `--overwrite`; con `--if-*` (insieme, implicano `--overwrite`) `{"ok":false,"error":"il file è cambiato","changed":true}` se data (ns) o dimensione sono diverse |
| `mkdir DOM PERCORSO` | `{"ok":true}` |
| `rename DOM DA NUOVONOME` | `{"ok":true}` |
| `move\|copy DOM DESTINAZIONE [--overwrite] -- PERCORSO...` | `{"ok":true}`; la copia è limitata a 200 MB |
| `delete DOM -- PERCORSO...` | `{"ok":true}` |
| `zip DOM DESTINAZIONE.zip -- PERCORSO...` | `{"ok":true}`; i nomi nell'archivio sono relativi a `public/`; collegamenti memorizzati come tali; sorgenti ≤ 200 MB |
| `unzip DOM ARCHIVIO DESTINAZIONE [--overwrite]` | `{"ok":true}` |
| `download-zip DOM PERCORSO` (cartella) | **zip su stdout**; il nome della cartella è in testa a ogni voce; tetto 200 MB |

Regole comuni:
- Percorsi relativi alla radice del sito; ammessi `public/…` (lettura e scrittura), `logs/<file>`, `logs/php/…` e `wp-config.php` (sola lettura); rifiutati assoluti, segmenti vuoti, `.` o `..`, slash finale, caratteri di controllo, byte non UTF-8, nome > 255 byte, percorso > 4096 byte, `tmp/` e il resto. La radice (`""`) vale solo per `list` e `stat`. Scrivono (write, mkdir, rename, move, copy, delete, zip, unzip) solo sotto `public/`, mai `public` stesso; destinazione di move/copy/unzip anche `public`.
- Argomenti: le opzioni (`--overwrite`, `--if-*`) vanno prima di `--`; dopo `--` tutto sono percorsi (anche con `-` iniziale), al massimo 500 per chiamata. Forma sbagliata = messaggio d'uso, uscita 1.
- Errori: `{"ok":false,"error":"…"}` su stdout, uscita 1.
- Conflitti: `write`, `move`, `copy` e `unzip` senza `--overwrite` non toccano nulla se anche un solo nome esiste; `mkdir`, `rename` e `zip` non hanno `--overwrite` e rifiutano sempre un nome esistente. In tutti i casi rispondono `{"ok":false,"error":"esiste già","conflicts":["public/x",…]}` (percorsi dalla radice del sito). Il pannello chiede e ripete con `--overwrite`. Con `unzip --overwrite`, un file al posto di una cartella (o un collegamento al posto di una cartella) non si sovrascrive: errore.
- Link simbolici: mai seguiti. `read`/`write` li rifiutano, `copy`/`move` li copiano come link, `zip` li memorizza come link, `unzip` rifiuta gli archivi che ne contengono, `delete` toglie il link e non la destinazione; un genitore che è un link è rifiutato.
- Limiti `unzip`: voce ≤ 10 MB, ≤ 10.000 voci, totale ≤ 200 MB, nessun nome assoluto, con `..` o `\`, nessun link o file speciale. Si controlla l'elenco (`zipinfo`) e poi **anche l'estrazione vera** (cartella di lavoro in `tmp/`, tetto per file con `ulimit -f`, sorveglianza sul totale, albero ricontrollato) prima di copiare in destinazione: un'intestazione che mente non basta. Errori: `archivio non valido`, `l'archivio ha più di 10.000 voci`, `l'archivio contiene un file oltre 10 MB`, `l'archivio supera i 200 MB estratti`, `l'archivio contiene collegamenti o file speciali`, `l'archivio contiene percorsi non ammessi (assoluti o con ..)`.
- Tempi: 120 s per write, zip, unzip, move, copy, delete, read e download-zip (il ponte del pannello deve avere almeno lo stesso timeout); scaduto = `operazione scaduta`, i temporanei vengono tolti.
- **Stream**: `read` e `download-zip` scrivono byte grezzi su stdout. Se l'uscita è ≠ 0 il chiamante **deve scartare** quanto ricevuto: dopo dati parziali può seguire un JSON di errore (`{"ok":false,…}`); un'uscita 0 è l'unica garanzia di un flusso completo.
- Registro: `/var/log/vps-tools.log`, una riga per operazione che modifica (`files <comando> <dominio> <al massimo 20 percorsi> totale=N`), mai i contenuti. Per il registro del pannello: `files.upload|write|mkdir|rename|move|copy|delete|zip|unzip`, dettagli con al massimo 20 percorsi più `totale`.
- Pacchetti `zip` e `unzip`: installati da `install.sh` e da `--tools-only` se mancano.

Fornito dall'installer v1.7, **eseguito dal pannello** con sudo (è in `/etc/sudoers.d/vps-panel`): `vps-backup`, le copie dei siti e del pannello su Google Drive e il ripristino. Solo per il super_admin. Dalla 1.7.0 `vps-site` ha anche `create DOMINIO --from-backup NOME` (vedi sopra).

Come per gli altri script: JSON su stdout, errori `{"ok":false,"error":"…"}` con uscita 1, stdin per i segreti, sotto sudo il comando si rilancia in un'unità systemd (`VPS_BACKUP_VIA_SYSTEMD`). `_run` (il giro, lanciato dal timer o da `run`) e `_restore` (il ripristino, lanciato da `restore`/`restore-local`) sono **interni** e sotto sudo rispondono `{"ok":false,"error":"comando interno"}`. Il token di Drive passa solo da stdin e non compare mai in argomenti, registro, `status` o risposte.

| Comando | stdin | Risposta |
|---|---|---|
| `vps-backup status` | — | vedi sotto |
| `vps-backup connect` | riga 1: token JSON di `rclone authorize "drive" …`; righe 2-3 facoltative (insieme): client id e client secret propri | `{"ok":true,"folder":"…"}` |
| `vps-backup auth-start` | facoltativo: riga 1 client id, riga 2 client secret (insieme, `[A-Za-z0-9._~-]{1,256}`), al massimo 1 KiB | `{"ok":true,"url":"https://accounts.google.com/…","expires":"ISO UTC"}` |
| `vps-backup auth-finish` | l'indirizzo incollato dall'utente, **una riga**, al massimo 4 KiB | come `connect`: `{"ok":true,"folder":"…"}` |
| `vps-backup auth-cancel` | — | `{"ok":true}` (anche se non c'era nulla) |
| `vps-backup disconnect` | — | `{"ok":true}`; toglie `rclone.conf`, imposta `enabled:false` (orario e cartella restano) e ferma il timer |
| `vps-backup config` | `{"enabled":bool,"time":"HH:MM","folder":"…"}` (`folder` facoltativo) | `{"ok":true}` |
| `vps-backup run` | — | `{"ok":true,"started":true}`: il giro parte come unità `vps-backup-run`; "backup in corso" se ce n'è già uno |
| `vps-backup list-local` | — | `{"ok":true,"items":[{"kind":"panel\|site\|restore","name":"cartella/file","domain":str\|null,"date":"AAAA-MM-GGTHH:MM:SS","size":int,"expires":"AAAA-MM-GG"\|null,"restorable":bool,"parts":"all\|db\|files"\|null}]}`, dalla più recente |
| `vps-backup read-local NOME` | — | **byte del file** su stdout |
| `vps-backup delete-local NOME` | — | `{"ok":true}` |
| `vps-backup list-remote` | — | `{"ok":true,"sites":[{"domain","present":bool,"copies":[{"name":"dominio/file","date","size"}]}],"panel":[{"name":"_pannello/file","date","size"}]}` |
| `vps-backup read-remote NOME` | — | **byte del file** scaricato da Drive, su stdout |
| `vps-backup restore DOMINIO dominio/file all\|db\|files` | — | `{"ok":true,"started":true}` |
| `vps-backup restore-local NOME all\|db\|files` | — | `{"ok":true,"started":true}` |

**Regole comuni**
- **Collegamento guidato** (`auth-start`, `auth-finish`, `auth-cancel`; è il flusso principale, `connect` col token resta l'alternativa): la VPS esegue `rclone authorize drive --auth-no-open-browser` in un'unità temporanea `vps-backup-auth` (`RuntimeMaxSec=960` (scadenza mostrata: 900 s), scope `drive.file`, client id/secret propri nell'ambiente dell'unità, mai negli argomenti) che ascolta solo su `127.0.0.1:53682`. `auth-start` (attende al massimo 20 s) risponde con l'indirizzo di Google da aprire (`url`, sempre `https://accounts.google.com/…`) e la scadenza (`expires`, 15 minuti); una nuova richiesta sostituisce la vecchia. L'utente accede e consente; il browser viene mandato a `http://127.0.0.1:53682/?state=…&code=…`, che sul PC **non si apre** ("impossibile raggiungere il sito"): è previsto. L'utente copia l'indirizzo dalla barra e lo incolla nel pannello, che lo passa su stdin a `auth-finish`. Questo accetta solo `http://127.0.0.1:53682/` o `http://localhost:53682/` (anche `/` omessa, spazi e `#…` ignorati) con `state` uguale a quello dell'autorizzazione aperta e `code` `[A-Za-z0-9/_.~-]{1,1024}` (anche con `%2F`); gli altri parametri (`scope`, `authuser`, …) si ignorano; l'indirizzo chiamato sulla VPS è ricostruito da `state` e `code`. Poi aspetta il token (al massimo 30 s) e lo passa a `connect` (stesse regole, stessa cartella e prova su Drive); in ogni caso, riuscito o no, ferma l'unità e cancella la cartella `/opt/vps/backup/auth/` (root 700, con il token e il client secret). Token e `code` non compaiono mai in argomenti, registro, journal o risposte. `auth-finish` prende il lock globale come `connect` (`backup in corso, riprova dopo`, **prima** di usare il `code`, quindi l'autorizzazione resta valida); `auth-start` e `auth-cancel` no. Errori leggibili (testo da mostrare così): `nessuna autorizzazione aperta: premi "Collega Google Drive" per cominciare`; `l'autorizzazione è scaduta (dura 15 minuti): ricomincia da "Collega Google Drive"`; `l'autorizzazione non è più attiva: ricomincia…` (unità finita o fermata); `Hai negato l'accesso a Google Drive: ricomincia da "Collega Google Drive" e premi Consenti` (`error=access_denied`, chiude l'autorizzazione); `non è l'indirizzo atteso: deve cominciare con http://127.0.0.1:53682/`; `l'indirizzo non appartiene a questa autorizzazione (state diverso): usa il link più recente`; `nell'indirizzo manca il code: copia l'indirizzo completo dalla barra del browser`. Gli errori di forma dell'indirizzo **non** chiudono l'autorizzazione: l'utente può incollare di nuovo. Altri errori che chiudono tutto: `la porta 53682 è occupata da un altro processo: collegamento annullato` (qualcuno, o un'altra unità, tiene la porta; prima di ogni chiamata locale lo script verifica che l'unico listener su 127.0.0.1:53682 sia il processo principale dell'unità e che sia rclone); `regola del firewall per la porta 53682 non attiva: esegui install.sh --tools-only` (sia `auth-start` sia `auth-finish` partono solo se la regola che riserva la porta a root è davvero in vigore, verificata con `iptables -C`/`ip6tables -C`: l'amministratore deve rilanciare `--tools-only`, che la reinstalla e ricarica ufw; con ufw spento resta rifiutato); `l'autorizzazione sta per scadere: ricomincia…` (meno di 30 s alla scadenza); `rclone non ha dato l'indirizzo di Google atteso (una versione di rclone diversa da quella del pacchetto Debian può causarlo): collegamento annullato` (l'indirizzo di Google restituito è controllato parametro per parametro: host `accounts.google.com`, percorso `/o/oauth2/auth`, `client_id` quello proprio o quello predefinito di rclone, `redirect_uri` `http://127.0.0.1:53682/`, solo lo scope `drive.file`, `state` nostro, nessun parametro in più).
- **Porta 53682 e sicurezza locale**: la porta di loopback è raggiungibile anche dagli utenti dei siti (PHP-FPM non ha hidepid). L'installer (e `--tools-only`) aggiunge perciò a `/etc/ufw/before.rules` e `before6.rules` (blocco `# vps-backup-auth BEGIN/END`, idempotente) la regola `-I ufw-before-output 1 -o lo -p tcp --dport 53682 -m owner ! --uid-owner 0 -j REJECT`: solo root può connettersi, quindi nessun altro può mandare a rclone uno `state` sbagliato (che lo ferma e libera la porta). Le due chiamate locali a rclone non usano curl: lo script apre la connessione TCP con il builtin di bash, verifica con `ss` che dall'altra parte del socket stabilito ci sia il processo principale dell'unità (e che sia rclone) e solo allora scrive la richiesta con `state`/`code` sulla stessa connessione. L'unità gira con `RuntimeMaxSec=960` (la scadenza mostrata resta a 900 s), `DynamicUser=yes`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `CapabilityBoundingSet=` vuoto, solo AF_INET/AF_INET6/AF_UNIX e `TimeoutStopSec=5`. **Il pannello non deve scrivere in nessun registro l'`url` di Google** (contiene lo `state` dell'autorizzazione) né le risposte di `auth-finish`; l'indirizzo incollato dall'utente (con il `code`) non va né registrato né conservato.
- **Tempi** (il pannello aspetta 125 s per `connect`/`auth-finish`/liste, 35 s per `status`): `connect` e la prova su Drive di `auth-finish` danno a ognuna delle 3 chiamate a rclone (`mkdir`, `rcat`, `deletefile`) 25 s (`tempo scaduto, Drive non risponde` e torna il collegamento di prima); `auth-finish` = al massimo 10 s di consegna del `code` + 30 s di attesa del token + 75 s di prove, ~115 s nel caso peggiore. `list-remote`: ogni chiamata a rclone ha 30 s e l'insieme 100 s; se una cartella non risponde o il tempo finisce, la risposta è **parziale**: `{"ok":true,"sites":[…],"panel":[…],"partial":true}` (il campo `partial` c'è solo in quel caso; il pannello deve dire che l'elenco è incompleto e far riprovare); se non risponde nemmeno l'elenco delle cartelle è un errore (`Google Drive non risponde: tempo scaduto`).
- `connect`: il token deve essere un solo oggetto JSON con `access_token` e `refresh_token`; client id e secret `[A-Za-z0-9._~-]{1,256}`, stdin al massimo 8 KiB. Scrive `/opt/vps/secrets/rclone.conf` (root 600, remote `gdrive`, scope `drive.file`), crea la cartella su Drive e vi scrive e cancella un file di prova; se qualcosa non va torna il collegamento di prima e l'errore è `Google Drive non ha accettato il collegamento: …` (testo di rclone ripulito dai token). `config` rifiuta un'ora non `HH:MM`, cartella fuori da `[A-Za-z0-9._-]{1,64}` (anche `.` e `..`), `enabled` non booleano e `enabled:true` a Drive scollegato. Scrive `config.json`, il drop-in `vps-backup.timer.d/ora.conf` (`OnCalendar=*-*-* HH:MM:00`), poi `daemon-reload` e `enable --now` o `disable --now` del timer; se il file è salvato ma systemd non obbedisce: `{"ok":false,"saved":true,"error":"…"}`. Predefiniti: `enabled` falso, ora 04:00, cartella `Plancia-<hostname>`.
- `connect`, `disconnect`, `config` e `delete-local` prendono il lock globale: mentre un giro o un ripristino è in corso rispondono `backup in corso, riprova dopo`.
- **Lock del sito**: finché un ripristino o la copia notturna di un sito è in corso, i comandi che lo modificano rispondono `ripristino in corso (o copia del sito in corso): riprova tra poco` (`vps-files` write, mkdir, rename, move, copy, delete, zip, unzip; `vps-site` wp-install, disable, enable, delete, db-create, db-password; un `_run` di eliminazione o installazione WordPress già in coda si ferma e torna allo stato di prima). Le letture non sono bloccate. Chi scrive tiene un lock condiviso per tutta la durata del comando, quindi un ripristino non parte mentre scrive (`ripristino in corso su questo sito` / `backup in corso`).
- **Nomi** (`NOME`): `list-local`/`read-local`/`delete-local`/`restore-local` usano `panel/FILE.sql.gz`, `sites/DOMINIO-AAAAMMGG-HHMM[SS].tar.gz|.sql.gz` o `restore/DOMINIO-AAAAMMGG-HHMM[SS].tar.gz`, esattamente come li restituisce `list-local`; `list-remote`/`read-remote`/`restore` usano `dominio/dominio-AAAAMMGG-HHMM.tar.gz` o `_pannello/pannello-AAAAMMGG-HHMM.sql.gz`. Niente `..`, niente `/` oltre al primo, niente collegamenti simbolici, file regolari.
- `list-local`: `date` è la data di modifica del file (ora locale della VPS, senza fuso). `expires` = modifica + 30 giorni (`site`), + 7 giorni (`restore`), `null` per il pannello (ultimi 5 dump). `restorable:true` solo per un `.tar.gz` il cui primo membro è `manifest.json` (formato 1.7.0): gli archivi vecchi (tar di tutta la cartella + `.sql.gz` a parte, due voci) sono `restorable:false`, si possono solo scaricare o eliminare. `parts` (solo se `restorable`, altrimenti `null`) dice cosa contiene la copia: `all` (sito intero, da cui si può anche ricreare il sito) oppure `db`/`files` (copie di sicurezza *parziali* di un ripristino `db`/`files`): il pannello deve offrire solo le modalità valide, `db` per `db`, `files` per `files`, tutte per `all`; `restore-local` rifiuta il resto ("la copia contiene solo il database/i file") prima di toccare il sito e `create --from-backup` rifiuta le copie parziali. `list-remote` non legge i manifest e non ha `parts` (le copie su Drive sono sempre `all`). `restore` (copie di sicurezza dei ripristini) e `site` si ripristinano e servono a ricreare un sito eliminato.
- `list-remote`: solo i nomi che crea il giro, dal più recente; una cartella ancora inesistente dà elenchi vuoti; Drive scollegato = errore `Google Drive non collegato…`; `present` dice se il dominio è ancora nel registro dei siti (altrimenti è un sito eliminato che ha ancora copie).
- **Stream**: `read-local` e `read-remote` scrivono byte grezzi; con uscita ≠ 0 il chiamante scarta quanto ricevuto (un JSON di errore può seguire dati parziali). `read-remote` scarica prima in `backups/tmp` (controlla spazio e dimensione) e poi manda su stdout.
- **Avvio di un ripristino** (`restore`, `restore-local`): controlla argomenti, che il sito sia nel registro in stato `active` o `disabled`, che Drive sia collegato (solo `restore`), che l'archivio locale esista e abbia il manifest, e che non ci sia un giro o un altro ripristino in corso (`backup in corso`) né un lavoro sul sito (`ripristino in corso su questo sito`). Poi lancia `_restore` come unità `vps-backup-restore-<slug>`: l'esito si legge da `status`. `all` richiede che archivio e sito coincidano sul database (altrimenti "ripristina solo i file"); `db` richiede il database in entrambi.

**`status`**

```json
{"ok":true,"connected":true,"folder":"Plancia-vps01","enabled":true,"time":"04:00",
 "job":null,
 "interrupted":false,"interrupted_job":null,
 "last_run":{"started":"ISO","finished":"ISO","ok":true,
   "sites":[{"domain","ok":bool,"reason":str|null,"file":str|null,"size":int,"deleted":int}],
   "panel":{"ok":bool,"error":str|null,"file":str|null,"size":int,"deleted":int},
   "purged":["dominio"],"alert":null|"sent"|"not_configured"|"failed: …"},
 "last_restore":{"domain","mode":"all|db|files","source":"local|remote","name","started","finished","ok":bool,
   "error":str|null,"safety":"dominio-AAAAMMGG-HHMMSS.tar.gz"|null,"backup_date":"ISO"|null,"alert":null|"sent"|"not_configured"|"failed: …"},
 "drive":{"used":int,"total":int}|null,
 "drive_checked_at":"ISO"|null,
 "auth":{"pending":bool,"expires":"ISO UTC"|null}}
```

- `job` (lavoro in corso, `null` se nessuno): giro `{"unit","op":"run","started","step":"start|site|upload|retention|panel|purge","domain":str|null}`; ripristino `{"unit","op":"restore","started","step":"start|download|verify|extract|dryrun|safety|files|database|cache","domain","safety":"…"|null}`. Un `job` rimasto in `state.json` senza che nessuno lavori (processo ucciso, riavvio) non è più `job`: `job:null`, `interrupted:true` e `interrupted_job` con quel lavoro. Si guarda il lock globale e le unità `vps-backup-run`, `vps-backup` e `vps-backup-restore-*`.
- **`job.safety` / `interrupted_job.safety` può nominare un file che non esiste ancora**: il nome viene scritto al passo `safety`, *prima* che la copia di sicurezza sia finita; se il processo muore durante la copia il file manca o è parziale. Il pannello deve dire "potrebbe non esistere" e controllare con `list-local` (cartella `restore/`). `last_restore.safety` invece è valorizzato solo se il file esiste davvero.
- `last_run.ok` è vero solo se tutti i siti e il pannello sono riusciti; durante un giro `last_run` resta quello del giro prima. Un giro con almeno un sito o il pannello falliti manda **un solo** messaggio Telegram (`💾 <hostname>: Backup: N siti non salvati` + una riga `dominio: motivo`, anche `pannello: motivo`), anche con la sorveglianza spenta; `alert` dice com'è andata. `drive` è `null` se Drive non è collegato o `rclone about` non risponde; `total` 0 = spazio illimitato. **Dalla 1.11.1 `drive` viene da una cache** (`/opt/vps/backup/drive.json`, root 600): `rclone about` si chiama al più ogni 15 minuti (ogni 2 se Drive non rispondeva), e la cache si toglie a collegamento (`connect`, `auth-finish`), scollegamento e fine di ogni giro. `drive_checked_at` (campo nuovo, 1.11.1) è quando `drive` è stato letto da Drive (ISO, ora del server), `null` se Drive non è collegato: il pannello può mostrarne l'età.
- **Giro notturno e lock globale**: il giro del timer (`vps-backup.service`) non salta la notte se un ripristino (o un altro giro) tiene il lock globale: aspetta fino a 1 ora (`BK_RUN_LOCK_WAIT`, entro `TimeoutStartSec=12h`). Se dopo l'attesa il lock è ancora occupato non fa il giro, ma scrive `last_run` con `ok:false`, `sites:[]`, `panel:{ok:false,error:"ripristino in corso",file:null}` (stessa forma di un giro fallito, `job` e `last_restore` restano) e manda il solito messaggio Telegram (`💾 <hostname>: Backup: pannello non salvato` + `pannello: ripristino in corso`); `alert` ne dice l'esito. Il giro a mano (`vps-backup run`, unità `vps-backup-run`) non aspetta mai: risponde `backup in corso`. Ogni scrittura di `state.json` (installer ≥ 1.11.1) avviene sotto un lock breve dedicato (`/run/vps-backup-state.lock`) e cambia solo i campi di chi scrive (`job` di chi tiene il lock globale, `last_run` e `known` del giro, `last_restore` del ripristino), rileggendo gli altri dal file: un giro saltato non perde il `job` del ripristino e il ripristino, finendo, non cancella il `last_run` del giro saltato. Il pannello legge `state.json` solo tramite `status` (file sostituito in modo atomico).
- `auth.pending` è vero se c'è un'autorizzazione guidata aperta (non scaduta e con l'unità `vps-backup-auth` attiva); `expires` è la scadenza. Il pannello può mostrare "in attesa dell'indirizzo" con il conto alla rovescia.
- `last_restore` resta fino al ripristino dopo. Ogni ripristino manda un messaggio Telegram (riuscito o no).
- `state.json` ha anche `known` (i domini già salvati da questa installazione): non è nella risposta, serve a non cancellare da Drive le copie di altri.

**Il giro** (`_run`, ogni notte alle 04:00 per impostazione predefinita, o `run`): un archivio per sito attivo o disattivato, uno per volta; lock globale `/run/vps-backup.lock` e, mentre un sito si archivia, `/run/vps-site.<slug>.lock`. Un sito che non si riesce a salvare (sito occupato, `spazio insufficiente`, archivio o caricamento non riusciti, Drive non risponde) non ferma gli altri. Su Drive: `<cartella>/<dominio>/<dominio>-AAAAMMGG-HHMM.tar.gz` e `<cartella>/_pannello/pannello-AAAAMMGG-HHMM.sql.gz`; si tengono le **ultime 3 copie riuscite** (mai la copia appena caricata e controllata), le eliminazioni sono definitive (`--drive-use-trash=false`). I siti che questa installazione aveva salvato e che non sono più nel registro perdono le copie su Drive 30 giorni dopo l'ultima. `backups/restore/` si pota a 7 giorni (nel giro e da `vps-site _prune`), `backups/sites/` a 30.

**Archivio di un sito** (`.tar.gz`, tutti file regolari): `manifest.json` (primo membro: `domain`, `type`, `www`, `db`, `slug`, `login_path` WordPress o `null`, `date` ISO, `installer_version`, `parts`, `sha256: {files, db}`), `files.tar.gz` (`public/` letto come utente del sito, link conservati come link; più `wp-config.php` letto da root; niente `logs/` né `tmp/`) e `db.sql.gz` se il sito ha un database. Prima di ripristinare, `bk_verify` rifiuta nomi assoluti o con `..`, file speciali, link che escono dal sito, checksum diversi.

**Ripristino** (`_restore`): scarico (se da Drive), controllo dell'archivio, dominio del manifest uguale a quello del sito, estrazione di `public/` come utente del sito in `tmp/.vpsbackup-x.*`, prova del dump in `<slug>__ripristino` con un utente temporaneo; solo dopo **copia di sicurezza** (`backups/restore/<dominio>-AAAAMMGG-HHMMSS.tar.gz`, 7 giorni, solo delle parti che si sovrascrivono), poi scambio dei file (il contenuto di `public/` passa da `tmp/.vpsbackup-old.*`, ACL di `www-data` riapplicate), poi il database, poi cache Redis e Cloudflare (dalla 1.11.1 solo i nomi del sito, `vps-cf-purge ZONA --host`, non tutta la zona). Se un passo fallisce si torna alla copia di sicurezza e il messaggio lo dice; se anche il ritorno fallisce l'errore e il messaggio Telegram dicono dov'è il contenuto di prima (`ATTENZIONE: …`). `wp-config.php` **non si ripristina mai**. Il dump si carica come utente del sito con `mariadb --sandbox --binary-mode --local-infile=0`, mai come root.

**Limiti noti**: durante il caricamento del database il sito è brevemente incoerente (nessuna pagina di manutenzione). Un processo ucciso a metà lascia avanzi in `tmp/` del sito (`.vpsbackup-old.*`, `.vpsbackup-x.*`, `.vpsbackup-c.*`) e la copia di sicurezza: gli avanzi più vecchi di 24 ore si tolgono all'inizio del ripristino/giro successivo; il sito interrotto non si ripara da solo. Il dump di un archivio manomesso, essendo caricato con le credenziali dell'utente del sito, potrebbe cambiare la password del database di quell'utente (`ALTER USER` su sé stesso): è un rischio accettato (richiede di poter scrivere su Drive) e `db.env`/`wp-config.php` non lo rilevano.

**Registro azioni del pannello**: `backup.connect|disconnect|config|run|restore|recreate|delete_local`, mai il token. Registro degli strumenti (`/var/log/vps-tools.log`): una riga per giro, ripristino e connessione, mai segreti.

`vps-site create DOMINIO --from-backup NOME` (sincrono fino all'avvio, poi lavoro in background `job.op = "create"`): `NOME` è `sites/FILE` o `restore/FILE` (come in `list-local`) oppure `remote:dominio/file` (come in `list-remote`). Tipo, `www`, database e `login_path` vengono dal manifest (non si danno `--type`, `--www`, `--db` né le opzioni di WordPress: errore). Il dominio deve essere quello del manifest e del nome del file. **stdin: una riga con la password del database nuovo, solo se la copia ha un database** (stesse regole di `db-password`). Il sito si crea come una creazione normale (DNS, utente, cartelle, pool, certificato, vhost, database); per WordPress niente download né `wp core install`: utente Redis nuovo e `wp-config.php` nuovo (credenziali nuove, chiavi nuove); poi parte `vps-backup _restore` in modalità `all` (`files` senza database). Il sito resta `creating` (`job.step` `restore`) finché il ripristino non finisce; poi `active` e `job.step` `done`. Se il ripristino fallisce il sito resta **`active` e vuoto**, con `job.step` `restore` e `job.error` che spiega perché ("sito creato ma vuoto, ripristino non riuscito: …"): si può riprovare dalla pagina Backup con `restore`/`restore-local`; se invece fallisce un passo di creazione si disfa tutto come in una creazione normale (`error`, si pulisce con `delete`). `list`/`show` mostrano `from_backup: {source:"local"|"remote", name, login_path, table_prefix}` (`table_prefix` è `null` se la copia non è WordPress o il manifest non lo ha) e, per WordPress, `wordpress` con `login_path` (da `manifest`), `admin_user: null`, `cloudflare_plugin: false`. L'eliminazione di un sito scrive l'archivio finale nello stesso formato (`backups/sites/<dominio>-AAAAMMGG-HHMMSS.tar.gz`, root 600): un disco quasi pieno ferma l'eliminazione ("spazio insufficiente… niente è stato cancellato"). Il prefisso delle tabelle WordPress viene dal manifest (`table_prefix`, scritto dall'archiviazione leggendo il `wp-config.php` vivo di root, validato `^[A-Za-z0-9_]{1,20}$`, predefinito `wp_`): mai dal `wp-config.php` dell'archivio né dal dump. Il lavoro gira nell'unità `vps-site-<slug>-create` e il ripristino ne è un processo figlio: il pannello **non deve fidarsi del nome dell'unità** per capire se un ripristino è in corso, ma di `state`, `job` e di `vps-backup status`. Durante il ripristino il lock globale dei lavori di `vps-site` è libero (gli altri lavori non aspettano); se un giro di backup, un ripristino o un'altra creazione da copia è in corso `create --from-backup` risponde subito `backup o ripristino in corso, riprova più tardi` (o `un'altra creazione da copia è in corso…`); il ripristino già in coda a una creazione aspetta comunque fino a 10 minuti che un giro finisca. Un sito PHP con database ricreato riceve la password nuova solo in `db.env`: le applicazioni che tengono la configurazione dentro `public/` (restituita dall'archivio) hanno ancora la vecchia e vanno aggiornate a mano. Se il ripristino fallisce non si installa il cron di WordPress: lo mette il primo ripristino di file riuscito.

Fornito dall'installer v1.9.0 (eseguito dal pannello, in sudoers):

| Comando | Risposta |
|---|---|
| `vps-f2b status` | `{"ok":true,"jails":[{"name","currently_failed","total_banned","banned":[{"ip","until"}]}]}`: le jail attive con gli IP bannati adesso; `until` è la fine del ban (`AAAA-MM-GG HH:MM:SS`, ora del server; `9999-12-31 23:59:59` = permanente) o `null`. Errore `fail2ban non risponde: è attivo?` |
| `vps-f2b unban IP` | `{"ok":true,"ip","unbanned":N}`: toglie l'IP da tutte le jail (`N` = in quante era). IPv4 o IPv6 singolo, niente reti; `indirizzo IP non valido` altrimenti |

**Cloudflare è obbligatorio quando la VPS è preparata per il pannello** (wizard, installer ≥ 1.10.0): il pannello e l'accesso SSH dipendono dalla zona e dal token.

Fornito dall'installer v1.10.0 (eseguito dal pannello, in sudoers; dalla 1.11.0 una persona = un utente Linux, con `add-user`/`remove-user`/`set-sudo`): `vps-ssh-tunnel`, accesso SSH dal browser con Cloudflare Tunnel + Access (un nome tipo `ssh-xxxxxx.<zona>`, login con codice via email, certificato SSH breve). I comandi che cambiano la macchina (`enable`, `add-user`, `remove-user`, `set-sudo`, `set-host`, `disable`) si rilanciano in un'unità systemd (`/etc/` è di sola lettura per PHP-FPM) e prendono un lock (`un'altra operazione sull'accesso SSH è in corso`). Dopo un errore in questi comandi quanto fatto è annullato, con due eccezioni dette nell'errore: `remove-user` può riuscire a eliminare l'utente e non riuscire a scrivere lo stato (poi `status` riporta `drift: users`), e `disable` non è annullabile ma si può ripetere (riparte da dove si era fermata).

| Comando | Risposta |
|---|---|
| `vps-ssh-tunnel status` | `{"ok":true,"cloudflare":bool,"zone","perms":{"tunnel","access","idp"},"zerotrust":bool,"otp":bool,"enabled":bool,"host":str\|null,"users":[{"email","user","sudo":bool}],"service":"active"\|"inactive"\|"missing","cloudflared_version":str\|null,"tunnel_status":str\|null,"drift":["dns"\|"app"\|"tunnel"\|"service"\|"users"]}`. `drift` contiene `users` se lo stato è della 1.10.0 (senza `users`, e allora `users` è `[]`) o se un utente dello stato non esiste più sulla VPS o non è più quello creato dall'accesso SSH: la pagina deve proporre solo Disattiva (poi si riattiva da capo). Con Cloudflare spento: `{"ok":true,"cloudflare":false}`. Cloudflare non risponde: `{"ok":false,"error"}` |
| `vps-ssh-tunnel random` | `{"ok":true,"label":"ssh-xxxxxx"}`: nome non indovinabile (il pannello lo chiama prima di `enable`) |
| `vps-ssh-tunnel check-host LABEL` | `{"ok":true,"host","free":bool,"reason":str\|null}`; `reason`: `usato da un sito`, `esiste già un record DNS`. Con etichetta non valida: `{"ok":true,"host":null,"free":false,"reason":"nome non valido"}` |
| `vps-ssh-tunnel enable` | stdin `{"label":"...","email":"a@x.it","sudo":true}` (**`label` obbligatorio**, mancante o vuoto = errore; `sudo` deve essere un booleano JSON) → `{"ok":true,"host"}`. Crea l'utente Linux dell'email |
| `vps-ssh-tunnel add-user` | stdin `{"email":"b@y.it","sudo":false}` → `{"ok":true,"user"}`. Rifiuta: 6ª persona (`massimo 5 persone`), nome già in elenco (`c'è già una persona con il nome utente b`), utente esistente non creato da noi, nome non valido. L'email entra nella policy Access per ultima |
| `vps-ssh-tunnel remove-user` | stdin `{"email":"b@y.it"}` → `{"ok":true,"user"}`. Rifiuta l'ultima persona (`l'ultima persona non si può eliminare: per togliere tutto usa Disattiva`). L'email esce dalla policy per prima; se questo fallisce non si tocca nient'altro |
| `vps-ssh-tunnel set-sudo` | stdin `{"email":"b@y.it","sudo":true}` → `{"ok":true,"user","sudo"}` |
| `vps-ssh-tunnel set-emails` | **non esiste più** (1.11.0): errore d'uso. Usare `add-user` / `remove-user` |
| `vps-ssh-tunnel set-host LABEL` | `{"ok":true,"from","host"}` |
| `vps-ssh-tunnel disable` | `{"ok":true}`: toglie anche tutti gli utenti dello stato (non quelli estranei) |

Utenti: ogni email autorizzata ha un utente Linux con il nome della parte prima della `@` (minuscola, `^[a-z_][a-z0-9_.-]{0,31}$`, non finisce con `.`), creato con `useradd -m -s /bin/bash -c vps-ssh-tunnel`, senza password né `authorized_keys`: si entra solo col certificato di Cloudflare. Lo strumento tocca solo utenti presenti in `users` **e** con GECOS `vps-ssh-tunnel`; un nome già usato da altri (`root`, `www-data`, l'utente dell'installazione) è rifiutato con `l'utente <nome> esiste già sulla VPS e non è stato creato dall'accesso SSH`. L'utente dell'installazione non cambia (chiave sulla porta SSH come prima). Il sudoers del pannello non cambia.

Altre regole: `vps-site create` rifiuta il dominio uguale all'host dell'accesso SSH (`nome usato dall'accesso SSH`); `vps-cf-token set`, con l'accesso attivo, rifiuta un token che non gestisce tunnel e app (o se lo stato è incompleto): `l'accesso SSH è attivo: il nuovo token deve poterlo gestire, oppure disattivalo prima`. Nessun comando mette segreti in output o nei log.

**Permessi del token** (oltre a quelli di prima): Zone › Zone › Read, Zone › DNS › Edit, Zone › Cache Purge › Purge, **Account › Cloudflare Tunnel › Edit**, **Account › Access: Apps and Policies › Edit**, **Account › Access: Organizations, Identity Providers, and Groups › Edit**. **Prerequisito manuale**: Zero Trust attivato sull'account Cloudflare (piano Free, va attivato a mano una volta); `status` lo riporta in `zerotrust`.

Previsti per il pannello (da scrivere con il pannello, stesse regole):

| Script | Cosa farà |
|---|---|
| `vps-cache` | attiva/disattiva/svuota cache FastCGI di un sito |
| `vps-service` | restart/reload di nginx, php-fpm, mariadb, redis (whitelist) |
| `vps-user` | cambio password utente admin, gestione chiavi SSH |

## 5. Database

| Utente | Dove sono le credenziali | Permessi |
|---|---|---|
| `root` | nessuna (`unix_socket`) | tutto, solo da root della macchina |
| `panel` | `config/.env` | tutto su DB `panel` |
| `panel_dbadmin` | `config/.env` | `ALL PRIVILEGES ON \`site\_%\`.*`, nessun permesso globale: lavora sui DB dei siti (anche da phpMyAdmin), non può creare o eliminare utenti |
| `pma` | `/opt/vps/phpmyadmin/config.inc.php` | `SELECT, INSERT, UPDATE, DELETE` solo su DB `phpmyadmin` |

Convenzione: DB e utenti dei siti hanno nome `site_<slug>` (es. `site_miosito_it`).

**Creazione di DB e utenti dei siti:** la fa lo script root `vps-site` (via `unix_socket`), non il pannello con `panel_dbadmin`. Un pannello compromesso quindi non può creare utenti DB né toccare `panel`, `pma` o `root`.

## 6. Da fare nel pannello (rimandato dall'installer)

- [x] **Email:** fatto (Plancia 2.8.0 + installer 1.8.0): pagina di configurazione SMTP (host, porta, utente, password, mittente, destinatario avvisi), pulsante "invia email di prova", link alle guide per **Gmail app password** e **Brevo** (con nota su SPF/DKIM per mittente sul proprio dominio). Usa `vps-smtp`.
- [x] **Cloudflare:** fatto (Plancia 2.4.0): cambio/verifica token, svuotamento cache. Usa `vps-cf-token`, `vps-cf-purge`, `vps-cf-ips-update`.
- [x] **phpMyAdmin:** fatto (Plancia 2.7.0 password, 2.7.8 versione e aggiornamento). Usa `vps-pma-update`, `vps-pma-pass`.
- [x] **Backup:** fatto, pagina Backup (Plancia 2.7.0): collegamento a Google Drive, pianificazione, stato e copie locali e su Drive, ripristino, siti eliminati ricreabili. Usa `vps-backup` e `vps-site create --from-backup` (installer 1.7.0).
- [ ] **Siti:** creazione statico / PHP fatta con `vps-site` (installer 1.2); WordPress fatto con `vps-site create --type wordpress` e `vps-site wp-install` (installer 1.3); resta la cache (`vps-cache`, 2c).
- [x] **Stato server:** fatto (Plancia 2.5.0): dashboard da `vps-status` e `vps-monitor status`, pagina Avvisi con `vps-monitor config`/`test`.
- [x] **Sicurezza:** fatto (Plancia 2.9.0 + installer 1.9.0): pagina Fail2ban, IP bannati e sblocco. Usa `vps-f2b`.
- [x] **Accesso SSH:** lato installer fatto (1.10.0, `vps-ssh-tunnel`); la pagina nel pannello è fatta (Plancia 2.10, persone con utente Linux dalla 2.11). Cloudflare Tunnel + Access, con guida nel pannello.
- [x] **Accesso SSH, utenti per email:** installer 1.11.0 (`add-user`, `remove-user`, `set-sudo`; `set-emails` tolto). Motivo: il terminale nel browser di Cloudflare entra da solo con il nome utente uguale alla parte dell'email prima della `@`, e il certificato vale solo per quel nome; mappare tutte le email sull'utente dell'installazione non funziona (dopo il tentativo fallito Cloudflare chiede nome utente e password). Quindi un utente Linux per ogni email, con `sudo` scelto per persona. Spec: `vps-panel/Documenti/PIANO/2026-10-27-vps-sp7b-utenti-ssh-design.md`; pagina nel pannello: Plancia 2.11.0.
- [x] **Pulizia log:** fatto lato installer: log dei siti in `vps-site-<slug>` (dalla 1.2), log di sistema e del pannello in `/etc/logrotate.d/vps` (1.9.0). Nel pannello la pagina Registri svuota i canali a mano.
