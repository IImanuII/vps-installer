# Collaudo v1.4.0

- **Data:** 2026-10-16
- **Macchina:** VPS `vps-mami2`, installer 1.3.0 → 1.4.0, Plancia 2.3.0 → 2.4.0.
- **Esito:** Cloudflare multi-zona funzionante dal pannello (purge di un dominio, sostituzione del token di sistema). Nessun bug trovato.

## Prima del rilascio

- Token di sistema nuovo `VPS mami2 sistema` (Zone > Zone > Read, Zone > DNS > Edit, Zone > Cache Purge > Purge, All zones) installato con `vps-cf-token set` da SSH: `{"ok":true}`, 9 zone attive visibili; vecchio token (solo `arcomy.com`) revocato.
- Al momento dell'aggiornamento il token vedeva 4 zone (`arcomy.com`, `trip4free.org`, `viaggiarealverde.it`, `viralteam.it`): risposta diretta dell'API di Cloudflare, cambiamento lato account/token, non del codice.

## Aggiornamento

- `install.sh --tools-only` (v1.4.0) via SSH senza terminale: uscita 0; `vps-cf-purge` in `/opt/vps/bin`, sudoers del pannello con `vps-cf-purge`, manifest 1.4.0, nessun servizio riavviato.
- `vps-panel-update`: Plancia 2.3.0 → 2.4.0 con dump del DB prima; migrazione 2.4.0 applicata (nessuna impostazione `cloudflare_*` rimasta nel database del pannello); `/health` 200.
- `vps-cf-token test` anche dallo spazio dei mount di PHP-FPM: `{"ok":true,"zones":4}`.

## Prova dal pannello

| Passo | Esito |
|---|---|
| Stato del token | "Valido: vede 4 zone" |
| Svuota tutta la cache di `arcomy.com` | ok (log `vps-cf-purge: arcomy.com svuotata (all)`, registro azioni `cloudflare.purged`) |
| Svuota un indirizzo di `arcomy.com` | ok (`(1)`) |
| Indirizzo di un'altra zona | rifiutato dal pannello, nessuna chiamata allo script |
| Password sbagliata nella sostituzione | rifiutata (`cloudflare.token_password_failed`, tentativo 1), nessuna chiamata a `set` |
| Sostituzione del token | ok: `cloudflare.ini` riscritto (`root:root` 600) dal pannello sotto `ProtectSystem=full` di PHP-FPM, senza rilancio via systemd; log `token di sistema sostituito`, registro `cloudflare.token_replaced` senza dettagli |
| Token nei log | assente da `/var/log/vps-tools.log` |
| Favicon | visibile nelle schede del pannello |
| Rinnovo certificati con il token nuovo | `certbot renew --dry-run`: simulazione riuscita per `mami2.arcomy.com` |

## Osservazioni

| Dove | Osservazione | Seguito |
|---|---|---|
| Installer | `vps-cf-token test` interroga l'elenco delle zone due volte: un errore momentaneo della seconda chiamata darebbe "vede 0 zone" | ritocco in un rilascio successivo |
| Collaudo | nessun sito registrato sulla VPS: il rifiuto di un token che non vede la zona di un sito è provato solo dai test | — |
