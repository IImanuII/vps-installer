# Collaudo v1.12.2 e v1.12.3 (errori di Cloudflare distinti da "token senza accesso" e "zona non trovata")

- **Data:** 2026-11-23
- **Macchina:** VPS `vps-mami2`, installer 1.12.1 → 1.12.2 → 1.12.3 (`install.sh --tools-only`), Plancia 2.12.1 invariata.
- **Esito:** tutto funziona. Con la 1.12.3 è emersa la causa degli errori: Cloudflare rallentava per poco tempo le chiamate alla sua API (errore `971`).

## Perché

Il 23/11 il monitor ha mandato due avvisi, alle 04:59 e alle 10:59, con il testo "il token Cloudflare non funziona: il token salvato non ha accesso alla zona …". Il token però era valido: `vps-cf-token test` dava `{"ok":true,"zones":4}`, anche lanciato con `systemd-run` come fa il monitor. Più tardi `vps-cf-purge --host` è uscito due volte con "zona non trovata", e un minuto dopo è riuscito 4 volte su 4.

In tutti questi casi il codice trattava qualsiasi risposta senza id della zona come "zona non vista", e il monitor buttava via la risposta, quindi non c'era modo di vedere il motivo.

## Cosa cambia

| Versione | Modifica |
|---|---|
| 1.12.2 | `cf_find_zone`: 1 = zona non vista, 2 = errore di Cloudflare (rete, `success:false`, risposta non JSON), con il motivo in `CF_LAST_ERR` e in `vps-tools.log`. `vps-cf-token test` riprova una volta dopo 2 s. `vps-monitor` scrive "token Cloudflare non verificato: …" invece di "il token Cloudflare non funziona: …" e dà al controllo 20 s invece di 10 |
| 1.12.3 | Nuova `cf_zone_lookup`, usata da `cf_find_zone`, `cf_zone_id`, `vps-cf-purge` (riprova una volta) e accesso SSH. Se il corpo non è JSON, nel log va il suo inizio |

## Prove sulla VPS

| Prova | Esito |
|---|---|
| Riavvio (kernel 6.12.118 dagli aggiornamenti automatici) | servizi attivi, nessuna unit fallita, `reboot-required` sparito, siti 200 |
| `install.sh --tools-only` 1.12.2 e 1.12.3 | manifest aggiornato, `nginx -t` ok, servizi attivi |
| `vps-cf-token test` | `{"ok":true,"zones":4}` |
| `vps-cf-purge trip4free.org --host` (un sito) | `{"ok":true,"purged":1}`, il log indica l'host svuotato |
| Subito dopo l'installazione della 1.12.3 | `vps-cf-token test` ha incontrato il rallentamento: log `ricerca della zona … non riuscita: Cloudflare ha dato errore: 971 Please wait and consider throttling your request speed`, ripetuto anche nel secondo tentativo; risposta `{"ok":false,"error":"Cloudflare ha dato errore: 971 …"}`. Un minuto dopo tutto è tornato ok |
| Stesse chiamate in IPv4 e IPv6 | tutte 200 a rallentamento finito: non si può dire se dipenda dall'IPv6 |

## Suite

1168 test verdi, shellcheck ok, CI e release verdi per entrambi i tag. Test instabile già presente prima, non legato a queste modifiche: in `backup.bats`, "_restore: il job dice la copia di sicurezza dal passo safety in poi" a volte fallisce quando gira in parallelo con gli altri, da solo passa sempre.

## Aperto

- Non si sa chi fa scattare il rallentamento: dalla VPS partono poche chiamate. Il limite di Cloudflare vale per l'account, quindi pesano anche gli altri token dello stesso account.
- Un solo nuovo tentativo dopo 2 s può non bastare se il rallentamento dura di più. Ora però l'errore dice il motivo vero.
