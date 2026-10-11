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

### File di sistema (posizioni obbligate)

| Percorso | Note |
|---|---|
| `/etc/nginx/nginx.conf` | template installer |
| `/etc/nginx/conf.d/<pannello>.conf` | vhost pannello |
| `/etc/nginx/snippets/ssl-params.conf` | TLS Mozilla intermediate |
| `/etc/nginx/snippets/security-headers.conf` | header di sicurezza |
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

## 3. `manifest.json`

```json
{
  "installer_version": "1.1.0",
  "installed_at": "2026-10-07T15:30:00+02:00",
  "hostname": "vps-01",
  "ipv4": "203.0.113.10",
  "ipv6": "2001:db8:100::1:2cf7",
  "admin_user": "manu",
  "ssh_port": 41822,
  "root_login": "no",
  "components": {
    "nginx": true, "php": "8.4", "mariadb": true, "redis": true,
    "certbot": true, "phpmyadmin": "5.2.3"
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
| `vps-cf-token` | `set` (token da stdin) / `test` | sostituisce o verifica il token Cloudflare (verifica che il token acceda alla zona prima di salvarlo) |
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

Previsti per il pannello (da scrivere con il pannello, stesse regole):

| Script | Cosa farà |
|---|---|
| `vps-site` | `create` / `delete` / `enable` / `disable` sito: utente `site_*`, cartella, pool PHP, vhost, certificato, DNS Cloudflare |
| `vps-site-wp` | installazione WordPress su un sito esistente |
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
- [ ] **Cloudflare:** cambio/verifica token, stato ultimo aggiornamento IP. Usa `vps-cf-token`, `vps-cf-ips-update`.
- [ ] **phpMyAdmin:** versione installata vs ultima, aggiornamento, cambio password basic auth. Usa `vps-pma-update`, `vps-pma-pass`.
- [ ] **Backup rclone:** configurazione OAuth Google Drive, pianificazione, retention, stato ultimo backup. Usa `vps-backup`.
- [ ] **Siti:** creazione statico / PHP / WordPress, rimozione, SSL, cache. Usa `vps-site`, `vps-site-wp`, `vps-cache`.
- [ ] **Stato server:** dashboard da `vps-status`.
- [ ] **Sicurezza:** IP bannati da fail2ban, sblocco. Usa `vps-f2b`.
- [ ] **Pulizia log:** rotazione/pulizia dei log Nginx dei siti (era in `da fare.txt`).
