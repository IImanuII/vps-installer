# Collaudo v1.1.0 → v1.1.1

- **Data:** 2026-10-11
- **Macchina:** VPS OVH `vps-mami2`, Debian 13, installata con la v1.0.2; pannello su
  `mami2.arcomy.com`.
- **Esito:** `install.sh --tools-only` (v1.1.0) e `sudo vps-panel-install` lanciati
  dall'amministratore; Plancia v2.1.0 installata, login con codice Telegram riuscito.

## Controlli dopo l'installazione

- Manifest: `installer_version` 1.1.0, `panel.version` 2.1.0, `deployed_at`, `repo`.
- `vps-panel-install` / `vps-panel-update` in `/opt/vps/bin`, link in `/usr/local/sbin`.
- Git dir `/opt/vps/panel.git` (root, 700) sul tag `v2.1.0`; nessun `.git` nella radice.
- Radice tutta di `panel`; `config/.env` con `APP_KEY` una sola volta; `logs/` nella radice.
- Database: 11 tabelle. Cron `/etc/cron.d/vps-panel` (manutenzione alle 3:00 come `panel`).
- HTTP: `/login` 200 (locale e pubblico), `/` → `/login`; `.env`, `app/`, `config/`,
  `storage/`, `install/`, `logs/` non raggiungibili (docroot `public/`).
- `sudo vps-panel-update`: "Già aggiornata (v2.1.0)", uscita 0.
- Rilancio dopo errore: il primo `vps-panel-install` è finito per deploy key non ancora
  aggiunta; il secondo ha riusato la chiave ed è andato a buon fine.

## Problemi trovati e correzioni (v1.1.1)

| Problema | Correzione |
|---|---|
| `install.sh --tools-only` lanciato senza terminale (es. `ssh host 'sudo bash install.sh --tools-only'`) falliva con `open terminal failed: not a terminal`: partiva sempre dentro tmux | `--tools-only` non usa tmux e non chiede Invio; l'installazione completa senza terminale esce subito con un messaggio chiaro |
| In `vps-panel-install` gli Invio premuti più volte di fila consumavano tutti e 5 i tentativi della deploy key in 3 secondi | prima di ogni richiesta si scartano i tasti premuti in anticipo (solo da terminale) |
| Nella radice di produzione arrivavano i file di sviluppo di Plancia (`.claude/`, `Documenti/`, `tests/`, `infra/`, `PRODUCT.md`); non raggiungibili dal web ma inutili | sparse checkout: esclusi a ogni checkout e tolti anche da una radice già installata |
