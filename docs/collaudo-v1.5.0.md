# Collaudo v1.5.x (Monitoraggio)

- **Data:** 2026-10-19
- **Macchina:** VPS `vps-mami2`, installer 1.4.1 → 1.5.3, Plancia 2.4.0 → 2.5.0.
- **Esito:** monitoraggio funzionante: avvisi Telegram, riavvio automatico dei servizi, sorveglianza degli indirizzi, Healthchecks.io per la VPS spenta. Corretti durante il rilascio: test non deterministici (1.5.1), `open_basedir` del pannello (1.5.2), aggiornamenti automatici di Nginx (1.5.3).

## Rilascio

| Versione | Cosa |
|---|---|
| 1.5.0 | solo tag: la CI di GitHub ha fermato la release (due test di `monitor.bats` dipendenti dalla data e dalle scritture parallele) |
| 1.5.1 | `status` usa l'orologio dei giri anche nei test; curl finto con un file per chiamata |
| 1.5.2 | `/opt/vps/bin/` nell'`open_basedir` del pool del pannello: la dashboard non poteva leggere l'elenco degli script (warning in `php-error.log`); `--tools-only` aggiorna i pool esistenti con `php-fpm -t` e reload |
| 1.5.3 | `unattended-upgrades` aggiorna anche Nginx di nginx.org (`origin=nginx`); `--tools-only` aggiorna la configurazione |

## Aggiornamento

- `install.sh --tools-only`: uscita 0 a ogni versione; manifest 1.5.3; unità `vps-monitor.service`/`.timer` installate, timer spento finché la configurazione non è attiva; sudoers con `vps-monitor`.
- `vps-panel-update`: Plancia 2.4.0 → 2.5.0 con dump del DB prima; `/health` 200 e nessun file di sessione creato per la richiesta.
- `vps-monitor status` anche dallo spazio dei mount di PHP-FPM.
- Nginx 1.30.5 → 1.30.6 a mano, poi incluso negli aggiornamenti automatici (`unattended-upgrade --dry-run` mostra `origin=nginx,codename=trixie`).

## Prove

| Prova | Esito |
|---|---|
| Attivazione da Plancia → Avvisi, destinatario "Invia a me" | timer attivo, giro ogni minuto, `config.json` e `state.json` `root:root` 600, token assente dal log |
| Messaggio di prova | ricevuto su Telegram |
| Healthchecks.io | ping a ogni giro; timer fermato 7 minuti → avviso di Healthchecks.io, poi rientro |
| Redis fermato | al giro dopo riavviato, "🟡 redis-server era fermo, riavviato" |
| Accesso SSH | "🔐 accesso SSH di iimanuii da … (publickey)" per ogni accesso |
| Indirizzo inesistente | "🔴 … è giù da 1 min (errore di connessione)" dopo 2 controlli falliti |
| Dashboard | stato della macchina, sorveglianza, elenco degli script (dopo la 1.5.2) |
| Disco oltre soglia | non provato: disco all'8%, soglia minima ammessa 50%; coperto dai test bats |

## Osservazioni

| Dove | Osservazione | Seguito |
|---|---|---|
| Sorveglianza | `https://trip4free.org/` risponde 403 a curl (protezione anti-bot di Cloudflare): conta come raggiungibile (< 500), un guasto vero (5xx, 52x) viene comunque segnalato; la parola attesa non sarebbe verificabile | regola Cloudflare che lascia passare l'IP della VPS, se serve la parola attesa |
| Dashboard | due controlli si chiamano entrambi "fail2ban" (servizio e numero di ban) | etichetta più chiara in un rilascio successivo |
| SSH | ogni accesso di manutenzione produce un avviso | atteso |
