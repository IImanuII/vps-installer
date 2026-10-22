# Collaudo v1.6.x (File manager)

- **Data:** 2026-10-22
- **Macchina:** VPS `vps-mami2`, installer 1.5.3 → 1.6.1, Plancia 2.5.0 → 2.6.0 → 2.6.1.
- **Esito:** file manager funzionante sul sito di prova `wp.arcomy.com`. Corretti durante il rilascio: `download-zip` con lo zip di Ubuntu (1.6.1), il blocco di Cloudflare sui link a `wp-config.php` (Plancia 2.6.1).

## Rilascio

| Versione | Cosa |
|---|---|
| 1.6.0 | solo tag: la CI di GitHub ha fermato la release. Lo `zip` di Ubuntu rifiuta l'uscita su pipe ("zip -0 not supported for I/O on pipes or devices"), quello di Debian no; in più un test usa `runuser` vero e in CI i test non girano come root |
| 1.6.1 | `download-zip` scrive l'archivio in `tmp/` del sito (`ulimit -f` appena sopra 200 MB), ne controlla la dimensione e poi lo manda su stdout; il test con `runuser` vero si salta se non si è root |
| Plancia 2.6.0 | pagina File (solo super_admin) |
| Plancia 2.6.1 | errori di invio Telegram con stato e descrizione nel registro, un nuovo tentativo sugli errori di rete, escape negli avvisi agli admin; percorso in base64url (`b`) nei link di modifica, download e anteprima |

## Aggiornamento

- `install.sh --tools-only` 1.6.1: uscita 0; manifest 1.6.1; `vps-files` in `/opt/vps/bin`, riga in `/etc/sudoers.d/vps-panel` (`visudo -c` ok); `zip`, `unzip`, `zipinfo` installati.
- Vhost del pannello: `--tools-only` ha aggiunto `fastcgi_read_timeout 150s;` dopo il `fastcgi_pass` del pool del pannello; `nginx -t` ok e reload.
- `vps-panel-update`: Plancia 2.5.0 → 2.6.0 → 2.6.1, ogni volta con dump del DB prima; `/health` 200.

## Prove

Sito di prova WordPress `wp.arcomy.com` creato da Plancia. Prove fatte dall'utente nel browser.

| Prova | Esito |
|---|---|
| Elenco di `public/`, navigazione nelle cartelle | ok |
| `logs/` | leggibile, in sola lettura (nessuna azione di modifica) |
| `wp-config.php` aperto e scaricato | con la 2.6.0 "Sorry, you have been blocked" di Cloudflare; con la 2.6.1 ok |
| Caricamento, sovrascrittura, editor, conflitto di salvataggio, cartelle (crea, rinomina, copia, sposta, elimina), zip ed estrazione, download e anteprima | ok, come riferito dall'utente |

## Osservazioni

| Dove | Osservazione | Seguito |
|---|---|---|
| Cloudflare | le regole WAF per WordPress bloccano qualsiasi indirizzo che contenga `wp-config.php`, anche come parametro di un'altra applicazione | link delle azioni in base64url (Plancia 2.6.1); i link delle cartelle restano in chiaro |
| Telegram | un codice 2FA non partito al primo invio (22:08:36), il "Reinvia" sì; il registro diceva solo "Errore invio messaggio" | dalla 2.6.1 il registro riporta stato HTTP e descrizione di Telegram, e un errore di rete si ritenta |
| CI | in WSL la suite gira come root, in GitHub come utente normale: i test che hanno bisogno di root vanno saltati se non lo si è | annotato |
| Download | un download interrotto a metà lascia un file troncato (uno zip troncato risulta corrotto) | noto, non urgente |
