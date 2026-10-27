# Collaudo v1.7.x (Backup e phpMyAdmin) e dintorni (1.8, 1.9)

- **Data:** 2026-10-25 → 2026-10-27
- **Macchina:** VPS `vps-mami2`, installer 1.6.1 → 1.7.x → 1.9.0, Plancia 2.6.x → 2.7.x → 2.9.0.
- **Esito:** backup su Google Drive, ripristino per parti e ricreazione dei siti funzionanti sul
  sito di prova `bkp.arcomy.com`; giro manuale, da timer e notturno riusciti. Corretti durante il
  collaudo: lock in `/run` in CI (1.7.1), cartelle `/backup` create per errore (1.7.2), diagnosi del
  collegamento a Drive (1.7.3-1.7.4), 403 sulle immagini caricate (1.7.5), svuotamento di Cloudflare
  dopo un ripristino (1.7.6), 429 e pagina bianca al primo accesso a phpMyAdmin (1.7.7).

## Rilascio

| Versione | Cosa |
|---|---|
| 1.7.0 | solo tag: in CI i test non girano come root e il lock dei siti stava in `/run` |
| 1.7.1 | lock dei test nella cartella temporanea del test |
| 1.7.2 | `run.sh` carica `lib/*.sh` in ordine alfabetico: `backup.sh` prima di `common.sh` lasciava `VPS_OPT` vuoto e creava `/backup`; default in `backup.sh`, cartelle sbagliate tolte dalla VPS |
| 1.7.3, 1.7.4 | collegamento a Drive: prova con `-vv`, riga `Error NNN:` nel messaggio, "tempo scaduto" leggibile |
| 1.7.5 | ACL di `www-data` sulla default di `tmp/` dei siti (un'immagine caricata nasce in `tmp/` e non ereditava la lettura: 403) e passata sui siti esistenti con `--tools-only` |
| 1.7.6 | svuotamento della cache Cloudflare dopo un ripristino: `.zone` del registro è un oggetto, non un nome |
| 1.7.7 | `location /pma/` con `burst=200`: ereditava il `burst=20` del pannello e phpMyAdmin al primo accesso riceveva decine di 429 |
| 1.7.8 | `vps-pma-update --check` e lucchetto contro due aggiornamenti insieme |
| 1.8.0 | `vps-smtp show`, password conservata se vuota, motivo di msmtp nella prova |
| 1.9.0 | `vps-f2b` (ban e sblocco) e `/etc/logrotate.d/vps` (log di sistema e del pannello) |
| Plancia 2.7.0-2.7.8 | pagina Backup (2.7.2 riorganizzata, 2.7.5 conferme con popup, 2.7.6 VPS sopra Drive), `[hidden]` contro `.d-flex` (2.7.1), virgolette rovinate nei registri (2.7.7), versione e aggiornamento di phpMyAdmin (2.7.8) |
| Plancia 2.8.0 | pagina Email |
| Plancia 2.9.0 | pagina Fail2ban |

## Prove

Sito di prova WordPress `bkp.arcomy.com`, creato dall'utente. Prove fatte dall'utente nel browser,
stato verificato via SSH.

| Prova | Esito |
|---|---|
| Collegamento a Google Drive | col client OAuth condiviso di rclone: quota esaurita (`Error 403: Quota exceeded … Requests per minute`); con un client Google dell'utente (app desktop, pubblicata): ok, cartella `Plancia-vps-mami2`, scope `drive.file` |
| Giro manuale | ok |
| Giro da timer (orario spostato a 19:34 per la prova) | ok; poi rimesso alle 04:00 |
| Giro notturno del 27/10 alle 04:00 | ok (solo il dump del pannello: nessun sito in quel momento) |
| Ripristino da Drive: tutto, solo database | ok |
| Ripristino da copia sulla VPS: solo file | ok, con copia di sicurezza `parts:files` |
| Scarico di una copia dalla VPS e da Drive | ok |
| Eliminazione del sito → ricreazione dall'archivio sulla VPS | ok |
| Eliminazione del sito → ricreazione da Drive | ok |
| Immagine caricata in WordPress | 403 prima della 1.7.5, poi ok |
| phpMyAdmin: cambio delle due password | ok |
| phpMyAdmin: primo accesso | pagina bianca e "Codice errore: 429" prima della 1.7.7, poi ok |
| phpMyAdmin: Controlla versione | ok (5.2.3 installata e ultima) |
| Email con Brevo: configurazione e prova | ok |
| Fail2ban: pagina | ok (jail `sshd`, nessun ban) |

## Osservazioni

| Dove | Osservazione | Seguito |
|---|---|---|
| Drive | il client OAuth predefinito di rclone è condiviso e spesso a quota esaurita | la pagina Backup dovrebbe consigliare un client proprio (da fare) |
| Pagina Backup | l'elenco di Drive arriva dopo e spostava la tabella mentre si cliccava: un ripristino "solo file" partito come "tutto" | Plancia 2.7.6: VPS sopra, Drive in fondo |
| Cloudflare | lo svuotamento dopo un ripristino vale per l'intera zona, non per il solo sottodominio | debito |
| `vps-backup status` | chiama `rclone about` a ogni aggiornamento della pagina | debito |
| Giro saltato dopo l'attesa di 1 h | scrive `state.json` senza lock | debito |
| `vps-tools.log` | conteggi di chiavi Redis stampati come numeri sciolti | debito |
| Suite in background | un test di `vps-site` legge la password da stdin: lanciata senza `</dev/null` resta appesa | lanciare la suite sempre con `</dev/null` (come in CI) |
| Chiave SMTP | incollata in chat dall'utente | consigliato di rigenerarla in Brevo |
