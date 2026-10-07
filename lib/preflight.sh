# shellcheck shell=bash
# Controlli iniziali prima della procedura guidata.

os_codename() {
  (
    source "${OS_RELEASE_FILE:-/etc/os-release}"
    printf '%s' "${VERSION_CODENAME:-}"
  )
}

preflight_errors() {
  local avail
  if [[ "$(os_codename)" != "trixie" ]]; then
    echo "Sistema non supportato: serve Debian 13 (trixie)."
  fi
  if ((EUID != 0)); then
    echo "Servono i privilegi di root (lancia con sudo)."
  fi
  avail="$(df --output=avail -BG / | tail -n 1 | tr -dc '0-9')"
  if ((${avail:-0} < 5)); then
    echo "Spazio disco insufficiente: ${avail:-0}G liberi, ne servono almeno 5."
  fi
  if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "Rete o DNS non funzionanti: deb.debian.org non risolve."
  fi
}
