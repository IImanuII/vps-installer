# shellcheck shell=bash
# Supporto per gli script wrapper /opt/vps/bin/vps-*: output JSON su stdout.

json_ok() {
  if (($#)); then
    jq -nc "$@"
  else
    printf '{"ok":true}\n'
  fi
}

json_err() {
  jq -nc --arg e "$1" '{ok: false, error: $e}'
  exit 1
}

tool_init() {
  set -Eeuo pipefail
  trap 'rc=$?; if [[ $BASHPID == "$$" ]]; then log "ERRORE: ${BASH_COMMAND}"; json_err "errore interno (dettagli in $VPS_LOG)"; fi; exit "$rc"' ERR
  die() {
    # shellcheck disable=SC2317
    log "ERRORE: $*"
    # shellcheck disable=SC2317
    json_err "$*"
  }
}

read_stdin_limited() {
  head -c "${1:-4096}"
}
