# Collaudo v1.2.0 → v1.2.1

- **Data:** 2026-10-12
- **Macchina:** VPS `vps-mami2`, installer 1.1.1 → 1.2.0, Plancia 2.1.0 → 2.2.0.
- **Esito:** siti base funzionanti dal pannello; un limite di Cloudflare sul `www` dei sottodomini corretto nella 1.2.1.

## Aggiornamento

- `install.sh --tools-only` (v1.2.0) lanciato via SSH senza terminale: uscita 0 (conferma la correzione della 1.1.1).
- sudoers con `vps-site`, cron con `vps-site _prune`, pacchetto `acl`, `/opt/vps/sites` `root:panel` 750, pagina di manutenzione presente.
- `vps-panel-update`: Plancia 2.1.0 → 2.2.0 con dump del DB prima; `/health` 200.
- `vps-site list` e `zones` come utente `panel`, anche dentro lo spazio dei mount di PHP-FPM (rilancio via systemd): risposte corrette. Il token Cloudflare vede una sola zona (`arcomy.com`).

## Prova dal pannello (`prova.arcomy.com`, PHP con database e www)

| Passo | Esito |
|---|---|
| Creazione con database | ok; password mostrata una volta |
| Pagina in HTTPS | ok su `prova.arcomy.com`; `www.prova.arcomy.com` → `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` (vedi sotto) |
| Disattiva / Riattiva | ok (scrittura del vhost da PHP-FPM tramite il rilancio systemd) |
| Nuova password database | ok |
| Elimina | ok: archivio `.tar.gz` + `.sql.gz` in `/opt/vps/backups/sites/`; utente, gruppo, DB, utente DB, certificato, pool, logrotate, cartella e record DNS tolti |

## Problemi trovati e correzioni

| Versione | Problema | Correzione |
|---|---|---|
| 1.2.1 / Plancia 2.2.1 | Il certificato gratuito di Cloudflare copre la zona e un solo livello di sottodomini: con `--www` su un sottodominio, `www.prova.arcomy.com` non ha HTTPS | `vps-site` rifiuta `--www` se il dominio non è la radice della zona (passo `dns`, prima di creare record); nel pannello la casella www è attiva solo con il nome vuoto |
| Plancia 2.2.1 | "Crea anche un database" selezionabile anche con il tipo statico (il server lo rifiutava) | casella disattivata se il tipo è statico |
| Plancia 2.2.1 | I radio del pannello disegnati come caselle quadrate | stile radio (cerchio e pallino) in `components.css` |
