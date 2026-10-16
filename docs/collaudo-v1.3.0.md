# Collaudo v1.3.0

- **Data:** 2026-10-16
- **Macchina:** VPS `vps-mami2`, installer 1.2.1 → 1.3.0, Plancia 2.2.1 → 2.3.0.
- **Esito:** WordPress dal pannello funzionante (creazione, login nascosto, Redis, eliminazione). Nessun bug bloccante; un ritocco di usabilità sul nome utente da fare nel pannello.

## Aggiornamento

- `install.sh --tools-only` (v1.3.0) via SSH senza terminale: uscita 0.
- WP-CLI 2.12.0 in `/usr/local/bin/wp` (SHA-512 verificato).
- Redis 8.0.2 riavviato con le ACL: `aclfile /etc/redis/users.acl` (`root:redis` 640), utente `default` spento (`PING` senza credenziali → `NOAUTH`), `vps-admin` con segreto in `/opt/vps/secrets/redis-admin` (`root` 600), `maxmemory 256mb` con `allkeys-lru`. Prima dell'aggiornamento nessun client usava Redis (sessioni PHP su file, Plancia senza Redis).
- Manifest: `installer_version` 1.3.0, `components.redis_acl` true.
- `vps-panel-update`: Plancia 2.2.1 → 2.3.0 con dump del DB prima; `/health` 200; `vps-site list` come `panel` anche dentro lo spazio dei mount di PHP-FPM.

## Prova dal pannello (`wp.arcomy.com`, WordPress, plugin Cloudflare)

| Passo | Esito |
|---|---|
| Creazione | ok dopo aver corretto il nome utente (vedi sotto); credenziali mostrate una volta |
| Stato | `active`, job `done`; 503 di manutenzione durante l'installazione |
| Permessi | radice e `logs/` `root:<sito>` 2750, `wp-config.php` `root:<sito>` 640 fuori da `public/`, `public/` e `logs/php` del sito 2770 |
| Plugin | wps-hide-login, redis-cache, cloudflare attivi, aggiornamenti automatici accesi; drop-in `object-cache.php` valido |
| Redis | `wp redis status`: connesso, drop-in valido; un utente `site_wp_arcomy_com` nel file ACL |
| Cron | file in `/etc/cron.d/` presente |
| Permalink | `/%postname%/` |
| HTTP | `/` 200 (anche dall'esterno, via Cloudflare), `/wp-login.php` 404, `/xmlrpc.php` 403; login dal percorso nascosto ok |
| Password nel log | nessuna `--admin_password` in chiaro in `/var/log/vps-tools.log` |
| Elimina | ok: archivio `.tar.gz` (79 MB) + `.sql.gz` in `/opt/vps/backups/sites/`; utente, gruppo, DB, utente DB, pool, vhost, cron, utente Redis, chiavi Redis del sito, certificato e cartella tolti |

## Osservazioni

| Dove | Osservazione | Seguito |
|---|---|---|
| Plancia | `Manu_2288` rifiutato: il nome utente WordPress ammette solo minuscole, ma il messaggio non lo rende evidente e WordPress accetterebbe le maiuscole | convertire in minuscolo nel pannello (come il percorso di login) o ammettere le maiuscole, in un rilascio successivo |
| Cloudflare | il token di sistema vede solo `arcomy.com`: per altri domini serve un token con permessi su tutte le zone | sotto-progetto "Domini" |
