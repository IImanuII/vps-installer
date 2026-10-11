# vps-installer

Prepara una VPS **Debian 13** appena creata (pensato per OVH) con un solo comando:
utente amministratore, SSH sicuro, firewall, fail2ban, aggiornamenti automatici e,
a scelta, Nginx, PHP 8.4, MariaDB, Redis, Certbot, phpMyAdmin e il dominio del pannello.

## Uso

1. Crea la VPS con Debian 13 e genera la password dell'utente `debian` dal Manager OVH.
2. Collegati: `ssh debian@IP_DELLA_VPS`
3. Copia il comando dalla [pagina dell'ultima release](../../releases/latest) e incollalo.
   Il comando verifica l'hash dello script prima di eseguirlo.
4. Rispondi alle domande. Poi l'installazione procede da sola.
5. Alla fine apri una **seconda finestra** e accedi con il nuovo utente e la nuova porta,
   come indicato a schermo, poi scrivi `OK`.
6. Annota il riepilogo (credenziali mostrate una sola volta). La VPS si riavvia.

Serve la tua chiave SSH **pubblica** (es. contenuto di `~/.ssh/id_ed25519.pub`).
Se non ce l'hai: `ssh-keygen -t ed25519` sul tuo PC.

## Se qualcosa va storto

- **Connessione caduta:** ricollegati e lancia `sudo tmux attach -t vps-installer`.
- **Errore a metà:** correggi la causa (vedi `/var/log/vps-installer.log`) e rilancia
  `sudo bash install.sh`: riparte dallo step che era fallito, senza rifare le domande.
- **Ricominciare da capo:** `sudo bash install.sh --reset`.
- **Test SSH non confermato:** se entro 10 minuti non confermi il test SSH, la configurazione SSH precedente viene ripristinata automaticamente (un watchdog systemd lo fa anche se la sessione cade).
- **Bloccato fuori da SSH:** usa la console **KVM** dal Manager OVH.

## Dopo l'installazione

Restano solo i file descritti in [`docs/PANEL-HANDOFF.md`](docs/PANEL-HANDOFF.md),
il contratto con il pannello di gestione.

## Installare il pannello (Plancia)

Il pannello sta in un repository privato: serve una deploy key, che lo script crea e stampa.

```bash
sudo vps-panel-install     # la prima volta
sudo vps-panel-update      # poi, per ogni nuovo rilascio
```

Su una VPS installata con una versione precedente alla 1.1, prima:

```bash
curl -fsSLO https://github.com/IImanuII/vps-installer/releases/download/v1.2.0/install.sh
sudo bash install.sh --tools-only
```

`--tools-only` non fa domande e non usa tmux: va bene anche da remoto
(`ssh host 'sudo bash install.sh --tools-only'`). L'installazione completa invece
vuole un terminale.

## Sviluppo

- Test: `bash tests/run.sh` (da Windows: `wsl -d Debian -- bash tests/run.sh`).
- Release: aggiorna `VPS_INSTALLER_VERSION` in `lib/common.sh`, poi
  `git tag vX.Y.Z && git push --tags`. La GitHub Action pubblica `install.sh`,
  l'archivio e il comando con l'hash.
- Spec: [`docs/specs/2026-10-07-vps-installer-design.md`](docs/specs/2026-10-07-vps-installer-design.md)
- End-to-end del pannello (WSL, root): `sudo bash tests/e2e/panel-e2e.sh <percorso vps-panel>`.
- End-to-end dei siti (WSL, root): `sudo bash tests/e2e/site-e2e.sh`.
- Spec v1.1: [docs/specs/2026-10-11-vps-installer-v1.1-design.md](docs/specs/2026-10-11-vps-installer-v1.1-design.md)
