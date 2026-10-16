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
| `/opt/vps/backups/sites/` | `root:root` 700 / file 600 | archivi dei siti eliminati (file + dump), cancellati dopo 30 giorni |
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
| `vps-cf-purge` | `ZONA --all` / `ZONA` con indirizzi su stdin (1-30, https, host della zona) | svuota la cache Cloudflare: `{"ok":true,"purged":"all"\|N}`. Il pannello non tiene token Cloudflare. Errori: `zona non valida`, `Cloudflare non è attivo su questa VPS`, `zona non trovata: ZONA`, `Cloudflare non risponde`, `nessun indirizzo`, `troppi indirizzi: il limite è 30`, `indirizzo non valido: URL`, `Cloudflare ha rifiutato la richiesta: MSG` |
| `vps-cf-ips-update` | — | scarica gli IP Cloudflare, rigenera `cloudflare-realip.conf` e regole UFW 80/443, `nginx -t` + reload. Anche da cron settimanale |
| `vps-smtp` | `set` (config JSON da stdin) / `test <email>` / `disable` | scrive `msmtprc`, manda email di prova, aggiorna il manifest |
| `vps-pma-pass` | `set` (password da stdin) | rigenera `.htpasswd-pma` (bcrypt) |
| `vps-pma-update` | — | scarica l'ultima phpMyAdmin, verifica GPG + SHA256, sostituisce mantenendo `config.inc.php` |
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
| `vps-monitor status` | — | `{"ok":true,"enabled":bool,"telegram_configured":bool,"healthchecks":bool,"last_run":"ISO"\|null,"checks":[{"id","kind","label","state","since","code","time_ms"}],"alerts":[{"at","text"}],"urls":[{"url","keyword"}],"thresholds":{…},"queued":N}` |
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

Previsti per il pannello (da scrivere con il pannello, stesse regole):

| Script | Cosa farà |
|---|---|
| `vps-cache` | attiva/disattiva/svuota cache FastCGI di un sito |
| `vps-service` | restart/reload di nginx, php-fpm, mariadb, redis (whitelist) |
| `vps-backup` | configurazione rclone ed esecuzione backup |
| `vps-f2b` | elenco/sblocco IP bannati |
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

- [ ] **Email:** pagina di configurazione SMTP (host, porta, utente, password, mittente, destinatario avvisi), pulsante "invia email di prova", link alle guide per **Gmail app password** e **Brevo** (con nota su SPF/DKIM per mittente sul proprio dominio). Usa `vps-smtp`.
- [x] **Cloudflare:** fatto (Plancia 2.4.0): cambio/verifica token, svuotamento cache. Usa `vps-cf-token`, `vps-cf-purge`, `vps-cf-ips-update`.
- [ ] **phpMyAdmin:** versione installata vs ultima, aggiornamento, cambio password basic auth. Usa `vps-pma-update`, `vps-pma-pass`.
- [ ] **Backup rclone:** configurazione OAuth Google Drive, pianificazione, retention, stato ultimo backup. Usa `vps-backup`.
- [ ] **Siti:** creazione statico / PHP fatta con `vps-site` (installer 1.2); WordPress fatto con `vps-site create --type wordpress` e `vps-site wp-install` (installer 1.3); resta la cache (`vps-cache`, 2c).
- [x] **Stato server:** fatto (Plancia 2.5.0): dashboard da `vps-status` e `vps-monitor status`, pagina Avvisi con `vps-monitor config`/`test`.
- [ ] **Sicurezza:** IP bannati da fail2ban, sblocco. Usa `vps-f2b`.
- [ ] **Pulizia log:** rotazione/pulizia dei log Nginx dei siti (era in `da fare.txt`).
