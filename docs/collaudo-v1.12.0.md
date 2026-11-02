# Collaudo v1.12.0 (Regole Nginx a mano)

- **Data:** 2026-11-02
- **Macchina:** VPS `vps-mami2`, installer 1.11.1 → 1.12.0, Plancia 2.11.1 → 2.12.0 (`install.sh --tools-only`, poi `vps-panel-update`).
- **Esito:** tutto funziona su VPS vera, con Nginx, certificati, Cloudflare e Drive veri. Siti di prova `prova8.arcomy.com` (regole a mano) e `prova9.arcomy.com` (standard), eliminati a fine prova.

## Aggiornamento

Nessuna migrazione, nessun sito sulla VPS. Dopo l'aggiornamento: `nginx -t` ok, servizi attivi, `/health` 200.

## Prove da riga di comando

| Prova | Esito |
|---|---|
| `create --custom-rules` | sito attivo, 200; cartella `vps-custom` 750 root, file 644; `www-data` respinto |
| Regola a mano in `.conf` | servita da `prova8`, 404 su `prova9`; `access_log` scrive attraverso il file a mano |
| File a mano rotto, `disable` di un altro sito | rifiutato: `Nginx rifiuta la configurazione per un errore in un altro file, non in prova9.arcomy.com: [emerg] unknown directive "direttiva_rotta" in /etc/nginx/vps-custom/prova8.arcomy.com.conf:23`; l'altro sito resta attivo |
| File rotto e servizio | Nginx continua a servire con la configurazione caricata |
| `vps-monitor` | `nginx_conf` da `ok` a `down` al giro dopo, di nuovo `ok` dopo la riparazione |
| `rules off` con file rotto | `nginx -t` torna valido, il file resta; `rules on` lo riusa dopo la correzione |
| `disable` / `enable` con regole a mano | manutenzione 503 senza include; alla riattivazione le regole tornano |
| Giro di backup | copia su Drive di entrambi i siti |
| Eliminazione | tolti vhost, file delle regole e cron; copia finale conservata in `sites/` |
| `create --from-backup` da Drive, `.conf` 248 KB, `.http.conf` 179 KB | sha256 uguali all'originale; `custom_rules` falso, `custom_restored` vero; nessun include e nessun cron attivo; `.cron-da-rivedere` 600 col cron; `last_restore.custom_restored` vero |
| `restore ... files` sul sito ricreato | file delle regole e registro intatti, `last_restore.custom_restored` falso |
| `rules on` con i file della copia | regola servita, sha uguale, `custom_restored` tolto, `cron_review` ancora riportato finché il file esiste |
| Pulizia finale | nessun residuo in `vps-custom`, `cron.d`, `conf.d`, `/var/www`, certificati; `nginx -t` ok |

## Prove nel browser (Plancia 2.12.0)

| Prova | Esito |
|---|---|
| Casella in "Nuovo sito" | visibile con PHP; con Statico e WordPress nascosta, disattivata e tolta la spunta, riga di spiegazione nascosta; col ritorno a PHP riattivata, senza spunta |
| Riga del sito ricreato | avviso con "Togli l'avviso" e relativa conferma |
| Finestra "Regole a mano" dopo una ricreazione | avviso rosso sui file da copia, percorsi, comando di prova, cron del sito, percorso di `.cron-da-rivedere`, `attiva=1`, conferma con l'avviso root |
| Finestra di eliminazione | nota su file delle regole e cron |
| Console | nessun errore |

Dal browser non è stato salvato nulla: i bottoni delle azioni e le finestre di conferma non sono stati premuti.

## Non provato

- **"Togli l'avviso" e "Attiva" premuti dal browser:** il controller e `vps-site` sono provati dai test e da riga di comando, il clic con la conferma no.
- **Avviso Telegram del monitor:** lo stato `down` e `ok` è verificato, la consegna del messaggio va confermata da chi lo riceve.
- **Esecuzione del cron spostato:** il file è stato messo a posto come dice l'aiuto, ma non si è atteso l'orario.
- **Copia di un sito con database:** i siti di prova non avevano database.

## Difetti trovati

- **Finestra "Regole a mano":** la riga d'esempio del cron è lunga, esce dal riquadro e fa comparire una barra di scorrimento orizzontale. Solo estetico.

## Limiti noti

- Con due siti rotti insieme `rules off` e `disable` non riparano: serve correggere il file via SSH. Il messaggio indica il file giusto.
- "Togli l'avviso" azzera `custom_restored`: un'attivazione successiva non ripete l'avviso sui file da copia.
- `known` in `state.json` conserva i domini dei siti di prova: la pulizia del giro non trova più cartelle su Drive e non fa nulla.

## Rilascio

| Versione | Cosa |
|---|---|
| 1.12.0 | `create --custom-rules`, `rules D on\|off`, file in `/etc/nginx/vps-custom/`, regole e cron nelle copie, ricreazione con file non attivi, errori di `nginx -t` che nominano il file, controllo `nginx_conf` nel monitor |
| Plancia 2.12.0 | pagina Siti: casella, etichetta, finestra d'aiuto, conferme, avviso dopo una ricreazione |
