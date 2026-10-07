#!/usr/bin/env bash
# vps-installer — bootstrap: scarica la release, la verifica e avvia l'installazione.
# Uso: sudo bash install.sh [--reset] [--local archivio.tar.gz]
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
  --local FILE      usa un archivio locale invece di scaricarlo
  -h, --help        mostra questo aiuto
Se la connessione cade: ricollegati e lancia  sudo tmux attach -t vps-installer
EOF
}

bootstrap_deps() {
  echo "Preparo gli strumenti di base..."
  apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    tmux whiptail jq curl gettext-base openssl ca-certificates >/dev/null
}

fetch_release() {
  local tar="$1" tmp=""
  if [[ -z "$tar" ]]; then
    if [[ "$TARBALL_SHA256" == __* ]]; then
      echo "Questo install.sh non proviene da una release: usa --local archivio.tar.gz" >&2
      return 1
    fi
    tmp="$(mktemp -d)"
    tar="$tmp/vps-installer.tar.gz"
    curl -fsSL --max-time 120 -o "$tar" "$RELEASE_BASE_URL/$VPS_VERSION/vps-installer-$VPS_VERSION.tar.gz"
    if ! echo "$TARBALL_SHA256  $tar" | sha256sum -c - >/dev/null 2>&1; then
      rm -rf "$tmp"
      echo "Hash dell'archivio non valido: interrompo." >&2
      return 1
    fi
  fi
  install -d -m 700 "$VPS_DEST"
  tar -xzf "$tar" -C "$VPS_DEST" --strip-components=1 --no-same-owner
  if [[ -n "$tmp" ]]; then
    rm -rf "$tmp"
  fi
}

main() {
  set -Eeuo pipefail
  local self orig_args=("$@") local_tar="" run_args=()
  self="$(readlink -f "$0")"
  while (($#)); do
    case "$1" in
      --local) local_tar="${2:?manca il file}"; local_tar="$(readlink -f "$local_tar")"; shift 2 ;;
      --reset) run_args+=(--reset); shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Opzione sconosciuta: $1" >&2; usage; exit 1 ;;
    esac
  done
  if ((EUID != 0)); then
    echo "Esegui con: sudo bash $self" >&2
    exit 1
  fi
  if [[ -z "${TMUX:-}" ]]; then
    bootstrap_deps
    echo "Avvio dentro tmux. Se la connessione cade: sudo tmux attach -t vps-installer"
    sleep 2
    exec tmux new-session -A -s vps-installer bash "$self" "${orig_args[@]}"
  fi
  if [[ ! -f "$VPS_DEST/run.sh" ]]; then
    fetch_release "$local_tar"
  fi
  export VPS_BOOTSTRAP="$self"
  bash "$VPS_DEST/run.sh" "${run_args[@]}" || {
    echo
    echo "Installazione interrotta. Dettagli: /var/log/vps-installer.log"
    echo "Per riprendere: sudo bash $self"
    echo "ATTENZIONE: $VPS_DEST/answers.env contiene segreti finché l'installazione non termina."
    read -r -p "Premi Invio per chiudere." _ || true
    exit 1
  }
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
