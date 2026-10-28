# Collaudo v1.10.x–1.11.0 (Accesso SSH dal browser)

- **Data:** 2026-10-27 / 2026-10-28
- **Macchina:** VPS `vps-mami2`, installer 1.9.0 → 1.10.0 → 1.11.0, Plancia 2.9.0 → 2.10.0 → 2.10.2 → 2.11.0.
- **Esito:** accesso SSH dal browser via Cloudflare Tunnel + Access funzionante, con un utente Linux per ogni email autorizzata. Il primo collaudo (1.10.0) ha mostrato che Cloudflare entra con l'utente = parte dell'email prima della `@`, non mappabile su `iimanuii`: da qui la 1.11.0.

## Rilascio

| Versione | Cosa |
|---|---|
| 1.10.0 | `vps-ssh-tunnel`: tunnel, app Access di tipo SSH con CA, `cloudflared`, drop-in `sshd` con rollback; permessi SSH nel controllo del token |
| Plancia 2.10.0 | pagina Sicurezza → Accesso SSH (attiva, cambia, disattiva) |
| Plancia 2.10.1 | guida Cloudflare con i permessi del token |
| Plancia 2.10.2 | `<!--email_off-->` nei layout: l'Email Obfuscation di Cloudflare riscriveva le email e la CSP bloccava il suo script |
| 1.11.0 | permessi del token letti su risorse singole (gli elenchi di Cloudflare rispondono 200 vuoto senza permesso: falso "ok"); un utente Linux per email (max 5), `add-user`, `remove-user`, `set-sudo`; `AllowUsers` nel drop-in si somma a quello di `10-vps.conf`, `Match User … AuthorizedKeysFile none` per gli utenti nuovi |
| Plancia 2.11.0 | righe con email, casella sudo, cestino con conferma, "+" |

## Prove

Prove fatte dall'utente nel browser; verifiche di Claude sulla VPS (journal, `sshd -T`, `/etc/sudoers.d`, `/home`).

| Prova | Esito |
|---|---|
| Attiva con la prima email (personale) e sudo | utente `manuele2288` (UID 1002) creato il 27/10 23:24 |
| Accesso dal terminale nel browser | `Accepted publickey for manuele2288 … ECDSA-CERT … ID <email>`; `sudo` ok |
| "+" con una seconda email (`info@…`) senza sudo | utente `info` (UID 1003) creato; accesso con certificato ok; `sudo` → "user NOT in sudoers" |
| Casella sudo accesa per `info` | `set-sudo` alle 10:04:10, nuovo accesso e `sudo` ok |
| Cestino su `info` | `userdel` di utente e gruppo, nessun file residuo con UID/GID 1003 |
| Disattiva | `vps-cloudflared` fermato, `manuele2288` eliminato, drop-in e file sudo rimossi; `/home` ha solo `iimanuii` |
| Stato finale | `sshd -t` ok; `AllowUsers iimanuii`, chiave normale per `iimanuii`; `vps-ssh-tunnel status`: `enabled:false`, `users:[]`, `drift:[]` |

## Osservazioni

| Dove | Osservazione | Seguito |
|---|---|---|
| Cloudflare | l'utente con cui Cloudflare entra è il prefisso dell'email, non configurabile | un utente Linux per email (1.11.0) |
| Cloudflare | gli endpoint di elenco rispondono 200 con lista vuota anche senza permesso | permessi letti su risorse singole (1.11.0) |
| Cloudflare | Email Obfuscation rompe le email nelle pagine del pannello | `<!--email_off-->` (Plancia 2.10.2) |
| `cloudflared` | dopo Disattiva il pacchetto resta installato (2026.10.5), il servizio è rimosso | voluto: riattivare è più veloce |
