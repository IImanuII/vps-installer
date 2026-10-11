# VPS Installer v1.1 — Installazione e aggiornamento di Plancia

- **Data:** 2026-10-11
- **Stato:** implementata (v1.1.0)
- **Versioni:** `vps-installer` 1.0.3 → **1.1.0**, Plancia (`vps-panel`) 2.0.0 → **2.1.0**
- **Contratto con il pannello:** [`../PANEL-HANDOFF.md`](../PANEL-HANDOFF.md) (aggiornato da questo lavoro)
- **Spec precedenti:** [`2026-10-07-vps-installer-design.md`](2026-10-07-vps-installer-design.md), `vps-panel/Documenti/PIANO/2026-10-07-vps-sp1-pulizia-design.md`

## 1. Obiettivo

Mettere in produzione Plancia (repository privato `IImanuII/vps-panel`) su una VPS preparata
dall'installer **con un comando**, e aggiornarla **con un altro**, al posto della procedura manuale di
`vps-panel/Documenti/deploy/README.md`.

**Successo significa:**
- su una VPS con installer v1.1, `sudo vps-panel-install` porta dalla pagina segnaposto al login con
  codice Telegram funzionante, senza passi manuali tranne aggiungere la deploy key su GitHub;
- `sudo vps-panel-update` porta all'ultimo rilascio senza toccare `config/.env`, `logs/`, `storage/`
  e i dati; se un passo fallisce, il pannello torna alla versione precedente, codice e database;
- rilanciare uno dei due script dopo un'interruzione non rompe niente.

**Stato della VPS reale (2026-10-11):** installer v1.0.3 completato, sul dominio del pannello c'è solo
la pagina segnaposto. Plancia non è mai stata messa in produzione: il primo deploy vero sarà questo.

**Fuori dallo scope:**
- pulsante "aggiorna" nel pannello (sotto-progetto Monitoraggio): `vps-panel-update` **non** entra nel
  sudoers di `panel` in questa versione;
- aggiornamento automatico pianificato;
- rilasci di Plancia su un repository diverso da `IImanuII/vps-panel`.

## 2. Decisioni prese

| # | Decisione | Alternativa scartata |
|---|---|---|
| D1 | `vps-panel-install` è un **comando separato**, lanciato a mano dopo l'installer | domanda dentro la procedura guidata: l'installer pubblico resta generico |
| D2 | I log del pannello vanno in **`<radice>/logs/`** (come già crea l'installer, accanto a `php-error.log`) | installer adeguato a `storage/logs/` |
| D3 | `update` va all'**ultimo tag `vX.Y.Z`**; `--ref vX.Y.Z` per una versione precisa | punta di `master` |
| D4 | **Git in place** nella radice del pannello | cartelle `releases/` + symlink `current` (vhost, pool e contratto da cambiare) |
| D5 | **Migrazioni automatiche** `install/migrations/X.Y.Z.sql`, con dump del DB prima e ripristino se l'update fallisce | `ALTER TABLE` a mano dal CHANGELOG |
| D6 | Deploy key **di root** (`/opt/vps/secrets/`): `panel` non può usarla | chiave leggibile da `panel` |

## 3. Componenti

### 3.1 `vps-installer`

| File | Ruolo |
|---|---|
| `tools/vps-panel-install` | installazione interattiva (sez. 4) |
| `tools/vps-panel-update` | aggiornamento con rollback (sez. 5) |
| `lib/panel_deploy.sh` | funzioni comuni ai due script (elenco sotto) |
| `templates/github-known-hosts` | chiavi host pubbliche di `github.com` (ed25519, ecdsa, rsa), fissate: nessun "fidati al primo collegamento" |
| `templates/cron-vps-panel` | `/etc/cron.d/vps-panel`: `0 3 * * * panel /usr/bin/php <radice>/app/cron/maintenance.php` |
| `install.sh --tools-only` | aggiorna una VPS già installata alla nuova release senza la procedura guidata (sez. 6) |
| `lib/manifest.sh` | `manifest_write` conserva i campi `panel.version`, `panel.deployed_at`, `panel.repo` già presenti |
| `docs/PANEL-HANDOFF.md` | aggiornato (sez. 7) |
| `docs/collaudo-v1.0.0.md` | resoconto del collaudo della v1.0.x sulla VPS reale: bug trovati e correzioni 1.0.1–1.0.3 (CNAME Cloudflare, `config.inc.php` di phpMyAdmin mancante, record DNS in conflitto) |
| `README.md` | sezione "Installare il pannello" |
| `lib/common.sh` | `VPS_INSTALLER_VERSION="1.1.0"` |

**Funzioni di `lib/panel_deploy.sh`** (ognuna testabile da sola):

| Funzione | Cosa fa |
|---|---|
| `pd_git ARGS…` | `git` come root nella radice del pannello, con `GIT_SSH_COMMAND` sulla deploy key e sui known_hosts fissati, `-c safe.directory=<radice>` |
| `pd_key_ensure` | genera `/opt/vps/secrets/panel-deploy-key` (ed25519, nessuna passphrase, `root` 600) se manca |
| `pd_latest_tag` | ultimo tag che rispetta `^v[0-9]+\.[0-9]+\.[0-9]+$`, ordinato con `sort -V` |
| `pd_current_tag` | tag del checkout attuale (`git describe --tags --exact-match`), vuoto se nessuno |
| `pd_checkout TAG` | `checkout -f TAG` + `chown -R panel:panel` sui file tracciati e su `.git` (non su `config/`, `logs/`, `storage/`) |
| `pd_env_merge` | aggiunge al `.env` le chiavi del pannello **solo se mancano** (`env_get`/`env_merge`) |
| `pd_schema` | `install/schema.sql` nel DB del pannello via `unix_socket` (`mariadb <DB_NAME>`) |
| `pd_migrations DA A` | applica in ordine `install/migrations/X.Y.Z.sql` con `DA < X.Y.Z ≤ A` |
| `pd_dump` / `pd_restore FILE` | `mariadb-dump --single-transaction` gzip in `/opt/vps/backups/panel/<tag>-<data>.sql.gz` (`root` 600, cartella 700, si tengono gli ultimi 5) / ripristino |
| `pd_reload_php` | `systemctl reload php8.4-fpm` (svuota opcache) |
| `pd_health` | `curl -sk --resolve <dominio>:443:127.0.0.1 https://<dominio>/health`, deve dare 200 `OK`; 3 tentativi a 2 s |
| `pd_manifest TAG` | `panel.version` (senza `v`), `panel.deployed_at`, `panel.repo` nel manifest |

Costanti: `PANEL_REPO=git@github.com:IImanuII/vps-panel.git`. Come negli altri script, sotto `sudo`
l'ambiente del chiamante viene ignorato (variabili riportate ai valori fissi); fuori da `sudo` (solo test)
`PANEL_REPO`, i percorsi e i comandi sono sovrascrivibili.

### 3.2 `vps-panel` (Plancia 2.1.0)

| Cosa | Dettaglio |
|---|---|
| `LOGS_PATH` | nuova costante = `<radice>/logs`; `Log.php` scrive lì al posto di `STORAGE_PATH/logs` |
| Registri | la pagina mostra anche `php-error.log` (registro PHP-FPM del pool `panel`), con la stessa lettura e la stessa pulizia degli altri |
| Repository | via `storage/logs/`; `logs/.gitkeep` tracciato, contenuto di `logs/` ignorato; `storage/locks/` resta |
| `create-admin.php --dry-run` | valida username, id Telegram e password (stdin) con le stesse regole, **senza scrivere**; codici di uscita invariati (0 ok, 1 dati non validi, 2 errore) |
| `install/migrations/` | cartella con `README.md`: nome `X.Y.Z.sql` = versione che la introduce, contenuto **idempotente**, mai dati di esempio |
| Test | `LOGS_PATH`; Registri con `php-error.log`; `--dry-run` non scrive; `APP_VERSION` uguale all'ultima voce del CHANGELOG; nomi dei file in `install/migrations/` validi |
| Documenti | `Documenti/deploy/README.md` riscritto attorno ai due script (la procedura manuale resta in appendice); `.claude/CLAUDE.md` senza la sezione "Da allineare con installer v1.1"; CHANGELOG 2.1.0 |
| Rilascio | tag annotato **`v2.1.0`** spinto su GitHub: è la versione che `install` mette sulla VPS |

## 4. `sudo vps-panel-install`

Interattivo, testo per un umano (non JSON: lo lancia l'amministratore, non il pannello). Ogni passo è
idempotente: se interrotto, si rilancia e riprende.

1. **Controlli:** root; manifest con `panel.domain` e `panel.path`; radice esistente; `git`, `curl`,
   `mariadb`, `php8.4` presenti. Se il manifest ha già `panel.version` → errore *"Plancia è già
   installata (vX): usa vps-panel-update"*, uscita 1.
2. **Deploy key:** `pd_key_ensure`; stampa la chiave pubblica e il link
   `https://github.com/IImanuII/vps-panel/settings/keys/new` (titolo suggerito: hostname, **senza**
   accesso in scrittura). *"Premi Invio quando l'hai aggiunta"* → `git ls-remote`. Fallito: lo ridice e
   riprova, al massimo 5 volte, poi uscita 1 (rilanciando riparte da qui, la chiave resta la stessa).
3. **Token Telegram** (solo se il `.env` non ha già `TELEGRAM_BOT_TOKEN`): letto nascosto, formato
   `^[0-9]{5,15}:[A-Za-z0-9_-]{30,60}$`, verificato con `getMe` (il token passa a `curl` via file di
   configurazione su stdin, mai come argomento). Fallito: lo richiede, al massimo 3 volte.
4. **Codice:** se manca `.git`, `git init -b main` + remote; `fetch --tags`; `pd_checkout
   $(pd_latest_tag)`; nessun tag → uscita 1. Toglie il segnaposto `public/index.html`.
5. **`.env`:** `pd_env_merge` con `TELEGRAM_BOT_TOKEN` e `APP_KEY` (32 byte casuali in base64,
   **solo se manca**: cambiarla renderebbe illeggibili i segreti cifrati).
6. **Database:** `pd_schema`.
7. **Primo super_admin** (solo se nel DB non ne esiste nessuno, tabella `<DB_PREFIX>users`, prefisso
   dal `.env`, default `vp_`): chiede username, id Telegram e password (nascosta, due volte), li valida
   con `create-admin.php --dry-run` e li ripete finché sono validi; poi `create-admin.php` come utente
   `panel`, password su stdin.
8. **Chiusura:** `/etc/cron.d/vps-panel`; `pd_reload_php`; `pd_health`; `pd_manifest`; riepilogo con
   l'URL di login e la versione.

Se `pd_health` fallisce l'installazione esce con 1 e il messaggio indica `logs/` e
`/var/log/vps-tools.log`: non c'è una versione precedente a cui tornare.

## 5. `sudo vps-panel-update [--ref vX.Y.Z]`

1. Lock (`flock` su `/run/vps-panel-update.lock`): un secondo update concorrente esce subito con 1.
2. Richiede Plancia installata (`panel.version` nel manifest e `.git` presente).
3. `fetch --tags`. Bersaglio = `--ref` (deve rispettare il formato ed esistere) oppure `pd_latest_tag`.
   Bersaglio uguale all'attuale → *"Già aggiornata (vX)"*, uscita 0.
4. `pd_dump`.
5. `pd_checkout BERSAGLIO`.
6. `pd_schema`, poi `pd_migrations ATTUALE BERSAGLIO` (solo se il bersaglio è più nuovo).
7. `php -l` su ogni `.php` di `app/` e `public/`; `pd_reload_php`; `pd_health`.
8. **Fallimento in 5–7:** `pd_checkout ATTUALE`; `pd_restore` se il passo 6 era iniziato;
   `pd_reload_php`; messaggio con il passo fallito e il dump usato; uscita 1. Se fallisce anche il
   ritorno indietro: messaggio esplicito con il percorso del dump, uscita 2.
9. `pd_manifest BERSAGLIO`; riepilogo *"vA → vB"*.

**Bersaglio più vecchio** (`--ref` a una versione precedente): cambia solo il codice, niente
migrazioni, e lo scrive in un avviso (lo schema resta quello più nuovo).

## 6. Aggiornare l'installer su una VPS esistente

La VPS reale ha la v1.0.3 e la cartella dell'installer è stata cancellata alla fine. Per avere i nuovi
script:

```
curl -fsSLO https://github.com/IImanuII/vps-installer/releases/download/v1.1.0/install.sh
sudo bash install.sh --tools-only
```

`--tools-only` scarica e verifica la release come sempre, poi **senza procedura guidata** ricopia
`/opt/vps/{bin,lib,templates}`, aggiorna `installer_version` nel manifest (conservando il resto) e si
ferma. Rifiuta se il manifest non esiste (macchina mai installata). Su una VPS nuova la v1.1 installa
gli script direttamente.

## 7. `PANEL-HANDOFF.md`

- § 2: `logs/` contiene i log applicativi **e** `php-error.log`; `.git` nella radice; nuove righe
  `/opt/vps/secrets/panel-deploy-key`, `/opt/vps/backups/panel/`, `/etc/cron.d/vps-panel`.
- § 3: campi `panel.version`, `panel.deployed_at`, `panel.repo`.
- § 4: `vps-panel-install` e `vps-panel-update` (eseguiti dall'amministratore, non dal pannello).
- Regola nuova: le migrazioni del pannello stanno in `install/migrations/X.Y.Z.sql`, idempotenti.

## 8. Sicurezza

- Deploy key **di sola lettura**, valida solo per `vps-panel`, leggibile solo da root.
- known_hosts di GitHub fissati nel template; `StrictHostKeyChecking=yes`.
- Token Telegram e password: solo stdin o pipe, mai argomenti, mai variabili esportate, mai nei log.
- Dump del DB: `root` 600 in una cartella `root` 700.
- `git` lavora come root ma i file restano di `panel`; `config/.env` mai toccato se non per aggiungere
  chiavi mancanti.

## 9. Test

**`vps-installer` (bats, come gli altri):**
- `panel_deploy.bats`: ogni funzione con stub di `git`, `mariadb`, `mariadb-dump`, `curl`, `php`,
  `systemctl`: ultimo tag con `sort -V` (`v2.10.0` > `v2.9.0`, tag non conformi ignorati); `.env`
  idempotente (`APP_KEY` presente non cambia); migrazioni nell'intervallo giusto e in ordine; dump con
  rotazione a 5.
- `panel_install.bats` / `panel_update.bats`: rifiuto se già installata / non installata; "già
  aggiornata"; rollback (codice + dump) quando falliscono `php -l`, la migrazione o `/health`; uscita 2
  se fallisce il ritorno indietro; `--ref` non valido rifiutato; downgrade senza migrazioni.
- `install.bats`: `--tools-only` ricopia gli script e conserva il manifest.
- shellcheck su tutto.

**End-to-end in WSL:** un repository git locale con due tag (`v0.0.1`, `v0.0.2` con una migrazione)
al posto di GitHub, MariaDB vera, `/health` servito da `php -S`: install → update → update verso un tag
con `/health` rotto → verifica del rollback di codice e DB.

**`vps-panel`:** test della sez. 3.2 + suite completa in WSL.

**Collaudo reale** (lo fa l'utente): sulla VPS, `install.sh --tools-only` → `vps-panel-install` →
login Telegram → checklist "Verifica manuale" del README di deploy. Esito annotato in
`docs/collaudo-v1.1.0.md`.

## 10. Ordine di lavoro

1. Plancia 2.1.0 (log, `--dry-run`, migrazioni, documenti, tag `v2.1.0`).
2. `lib/panel_deploy.sh` con i test.
3. `vps-panel-install`, `vps-panel-update`, template, `--tools-only`, manifest.
4. End-to-end in WSL.
5. Documenti (`PANEL-HANDOFF`, README, `collaudo-v1.0.0.md`), release v1.1.0.

## Modifiche in implementazione

Rispetto al testo sopra, per sicurezza e robustezza:

- **Repository git fuori dalla radice del pannello:** la git dir è `/opt/vps/panel.git` (`root:root` 700),
  non `/var/www/<pannello>/.git`. Con un `.git` di proprietà di `panel`, un pannello compromesso potrebbe
  piazzare hook o `core.fsmonitor`/`core.sshCommand` e far eseguire codice come root al successivo
  aggiornamento. Non esiste alcun `.git` nella radice del pannello.
- **SQL dagli oggetti git del tag:** `schema.sql` e le migrazioni si leggono con `git show TAG:...` dal
  repository di root, non dai file della radice (scrivibili dal pannello).
- **Proprietà dei file:** dopo il checkout, `chown -R -P -h panel:panel` sulla radice del pannello
  (non segue i link simbolici).
- **Versione di partenza dal manifest:** `vps-panel-update` parte dalla versione scritta nel manifest,
  quindi un aggiornamento interrotto (codice già al bersaglio, manifest vecchio) si ripara rilanciandolo.
- **Template cron:** si chiama `templates/cron-vps-panel.tmpl` (i template con `${VAR}` richiedono
  l'estensione `.tmpl`).
