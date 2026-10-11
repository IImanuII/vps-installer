#!/usr/bin/env bash
# vps-installer — bootstrap: scarica la release, la verifica e avvia l'installazione.
# Uso: sudo bash install.sh [--reset | --tools-only] [--local archivio.tar.gz]
# (set -Eeuo pipefail è in main: il file viene anche caricato dai test.)

VPS_VERSION="__VERSION__"
TARBALL_SHA256="__TARBALL_SHA256__"
REPO="__REPO__"
: "${VPS_DEST:=/root/vps-installer}"
: "${RELEASE_BASE_URL:=https://github.com/$REPO/releases/download}"

usage() {
  cat <<'EOF'
Uso: sudo bash install.sh [opzioni]
  --reset           ricomincia dalla procedura guidata
  --tools-only      aggiorna solo gli script di /opt/vps (VPS già installata)
  --local FILE      usa un archivio locale invece di scaricarlo
  -h, --help        mostra questo aiuto
Se la connessione cade: ricollegati e lancia  sudo tmux attach -t vps-installer
EOF
}

bootstrap_deps() {
  local try
  echo "Preparo gli strumenti di base..."
  for try in 1 2 3; do
    if apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null; then
      break
    fi
    if ((try == 3)); then
      echo "apt-get update non riuscito dopo 3 tentativi: controlla la rete e riprova." >&2
      return 1
    fi
    echo "apt-get update non riuscito, riprovo tra ${APT_RETRY_SLEEP:-10} secondi..." >&2
    sleep "${APT_RETRY_SLEEP:-10}"
  done
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q \
    tmux whiptail jq curl gettext-base openssl ca-certificates >/dev/null
}

# release_id ARCHIVIO_LOCALE — identifica la release da installare
# ("local:<sha256>" con --local, lo SHA256 della release, vuoto se ignota).
release_id() {
  if [[ -n "$1" ]]; then
    printf 'local:%s\n' "$(sha256sum "$1" | cut -d' ' -f1)"
  elif [[ "$TARBALL_SHA256" != __* ]]; then
    printf '%s\n' "$TARBALL_SHA256"
  fi
}

# fetch_release ARCHIVIO_LOCALE [DEST] — scarica/verifica ed estrae in DEST,
# scrivendo il marcatore .release.
fetch_release() {
  local tar="$1" dest="${2:-$VPS_DEST}" tmp="" id
  id="$(release_id "$tar")"
  if [[ -z "$tar" ]]; then
    if [[ "$TARBALL_SHA256" == __* ]]; then
      echo "Questo install.sh non proviene da una release: usa --local archivio.tar.gz" >&2
      return 1
    fi
    tmp="$(mktemp -d)"
    tar="$tmp/vps-installer.tar.gz"
    curl -fsSL --max-time 120 -o "$tar" "$RELEASE_BASE_URL/$VPS_VERSION/vps-installer-$VPS_VERSION.tar.gz" \
      || { rm -rf "$tmp"; echo "Download della release non riuscito." >&2; return 1; }
    if ! echo "$TARBALL_SHA256  $tar" | sha256sum -c - >/dev/null 2>&1; then
      rm -rf "$tmp"
      echo "Hash dell'archivio non valido: interrompo." >&2
      return 1
    fi
  fi
  install -d -m 700 "$dest"
  tar -xzf "$tar" -C "$dest" --strip-components=1 --no-same-owner || { rm -rf "$tmp"; return 1; }
  printf '%s\n' "$id" >"$dest/.release"
  if [[ -n "$tmp" ]]; then
    rm -rf "$tmp"
  fi
}

# File di lavoro da conservare quando si sostituisce una release vecchia.
RUNTIME_FILES=(answers.env state summary.env sshd-10-vps.conf)

# ensure_release ARCHIVIO_LOCALE — estrae la release in VPS_DEST; se c'è già una
# release diversa (o senza marcatore) la sostituisce conservando i file di lavoro.
ensure_release() {
  local tar="$1" want have="" new old f
  if [[ ! -f "$VPS_DEST/run.sh" ]]; then
    fetch_release "$tar"
    return
  fi
  want="$(release_id "$tar")"
  if [[ -f "$VPS_DEST/.release" ]]; then
    have="$(<"$VPS_DEST/.release")"
  fi
  if [[ -z "$want" || "$want" == "$have" ]]; then
    return 0
  fi
  echo "Trovata una versione diversa dell'installer in $VPS_DEST: la aggiorno."
  new="$(mktemp -d "$VPS_DEST.new.XXXXXX")"
  if ! fetch_release "$tar" "$new"; then
    rm -rf "$new"
    return 1
  fi
  for f in "${RUNTIME_FILES[@]}"; do
    if [[ -e "$VPS_DEST/$f" ]]; then
      cp -p "$VPS_DEST/$f" "$new/$f"
    fi
  done
  old="$VPS_DEST.old.$$"
  rm -rf "$old"
  mv "$VPS_DEST" "$old"
  mv "$new" "$VPS_DEST"
  rm -rf "$old"
}

# start_mode TOOLS_ONLY — come partire fuori da tmux: "tmux" per l'installazione
# completa (sopravvive a una connessione caduta), "direct" per --tools-only (pochi
# secondi, nessuna domanda: funziona anche con ssh host 'sudo bash install.sh
# --tools-only'), "noterm" se l'installazione completa non ha un terminale.
start_mode() {
  if (($1)); then
    echo direct
  elif [[ -t 0 && -t 1 ]]; then
    echo tmux
  else
    echo noterm
  fi
}

# run_failed TOOLS_ONLY SELF — messaggio quando run.sh fallisce; l'installazione
# completa poi attende Invio (la finestra tmux si chiude appena lo script termina).
run_failed() {
  echo
  if (($1)); then
    echo "Aggiornamento degli script (--tools-only) non riuscito. Dettagli: /var/log/vps-installer.log"
  else
    echo "Installazione interrotta. Dettagli: /var/log/vps-installer.log"
    echo "Per riprendere: sudo bash $2"
    echo "ATTENZIONE: $VPS_DEST/answers.env contiene segreti finché l'installazione non termina."
    read -r -p "Premi Invio per chiudere." _ || true
  fi
}

# tools_only_done — dopo --tools-only la cartella dell'installer non serve più,
# a meno che contenga un'installazione completa non terminata (da riprendere).
# Niente "Premi Invio": --tools-only non gira in tmux.
tools_only_done() {
  if [[ -f "$VPS_DEST/answers.env" ]] \
    || { [[ -f "$VPS_DEST/state" ]] && ! grep -qxF 99-finalize "$VPS_DEST/state"; }; then
    echo "Lascio $VPS_DEST: contiene un'installazione completa non terminata (riprendila con sudo bash install.sh)."
  else
    rm -rf "$VPS_DEST"
  fi
  echo "Script di /opt/vps aggiornati. Per il pannello: sudo vps-panel-install (prima volta) o sudo vps-panel-update."
}

main() {
  set -Eeuo pipefail
  local self orig_args=("$@") local_tar="" run_args=() tools_only=0
  self="$(readlink -f "$0")"
  while (($#)); do
    case "$1" in
      --local) local_tar="${2:?manca il file}"; local_tar="$(readlink -f "$local_tar")"; shift 2 ;;
      --reset) run_args+=(--reset); shift ;;
      --tools-only) run_args+=(--tools-only); tools_only=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Opzione sconosciuta: $1" >&2; usage; exit 1 ;;
    esac
  done
  if ((tools_only)) && [[ " ${run_args[*]} " == *" --reset "* ]]; then
    echo "--reset e --tools-only non si usano insieme." >&2
    usage
    exit 1
  fi
  if ((EUID != 0)); then
    echo "Esegui con: sudo bash $self" >&2
    exit 1
  fi
  if [[ -z "${TMUX:-}" ]]; then
    case "$(start_mode "$tools_only")" in
      noterm)
        echo "L'installazione fa domande e vuole un terminale: collegati con ssh e rilancia sudo bash $self" >&2
        exit 1
        ;;
      tmux)
        bootstrap_deps
        echo "Avvio dentro tmux. Se la connessione cade: sudo tmux attach -t vps-installer"
        sleep 2
        exec tmux new-session -A -s vps-installer bash "$self" "${orig_args[@]}"
        ;;
      direct) bootstrap_deps ;;
    esac
  fi
  ensure_release "$local_tar"
  export VPS_BOOTSTRAP="$self"
  bash "$VPS_DEST/run.sh" "${run_args[@]}" || {
    run_failed "$tools_only" "$self"
    exit 1
  }
  if ((tools_only)); then
    tools_only_done
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
