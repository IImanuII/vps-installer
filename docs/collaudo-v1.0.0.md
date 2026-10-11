# Collaudo v1.0.0 → v1.0.3

- **Data:** 2026-10-07/08
- **Macchina:** VPS OVH, Debian 13; pannello su `mami2.arcomy.com`, Cloudflare attivo.
- **Esito:** installazione completata con la v1.0.3; sul dominio del pannello la pagina segnaposto.
  Plancia non ancora installata (lo farà `vps-panel-install`, v1.1).

## Problemi trovati e correzioni

| Versione | Problema | Correzione |
|---|---|---|
| 1.0.1 | un record creato a mano come CNAME faceva fallire lo step 85 con l'errore Cloudflare 81054 | un CNAME esistente non si tocca (avviso nel log); un record dello stesso tipo con il contenuto giusto non si riscrive, uno diverso si aggiorna; se la lettura dei record fallisce è un errore |
| 1.0.2 | con `pipefail`, `sed` su una `config.inc.php` di phpMyAdmin non ancora esistente interrompeva lo step 90 a ogni prima installazione | la lettura restituisce vuoto se il file manca |
| 1.0.3 | i record DNS del pannello che puntavano altrove venivano sostituiti senza chiedere | la procedura guidata legge i record esistenti dopo aver validato il token e, per un CNAME o un A/AAAA con IP diverso, chiede se sostituirli (predefinito) o lasciarli; lo step 85 applica la scelta e il riepilogo finale avvisa se si è scelto di lasciarli; le risposte della 1.0.2 o precedenti mantengono il comportamento di prima |

## Da ricordare per il prossimo collaudo

- Controllare prima su Cloudflare i record del dominio del pannello.
- Dopo l'installer: `sudo vps-panel-install` (v1.1) e la checklist "Verifica manuale" di
  `vps-panel/Documenti/deploy/README.md`; esito in `docs/collaudo-v1.1.0.md`.
