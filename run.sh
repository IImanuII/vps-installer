#!/usr/bin/env bash
# Esegue la procedura guidata (se serve) e poi gli step, con ripresa.

if [[ -z "${VPS_ROOT:-}" ]]; then
  VPS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
export VPS_ROOT
VPS_RUN_SH="$(readlink -f "${BASH_SOURCE[0]}")"
export VPS_TEMPLATES="${VPS_TEMPLATES:-$VPS_ROOT/templates}"
for _lib in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"/lib/*.sh; do
  source "$_lib"
done

run_steps() {
  local f name rc
  for f in "$VPS_ROOT"/steps/[0-9][0-9]-*.sh; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .sh)"
    if state_done "$name"; then
      log "Step $name già completato, salto."
      continue
    fi
    log "=== Step $name ==="
    # Processo bash separato: ogni step ha le sue funzioni, un errore non segna
    # lo stato e `set -e` resta attivo anche se run_steps è chiamata in un
    # contesto che lo disabilita (if, ||, bats `run`).
    rc=0
    bash -c '
      source "$1"
      if [[ -f "$VPS_ANSWERS" ]]; then answers_load; fi
      set -Eeuo pipefail
      step_enabled() { return 0; }
      source "$2"
      if step_enabled; then
        step_main
      else
        log "Step $3 non richiesto, salto."
      fi
    ' _ "$VPS_RUN_SH" "$f" "$name" || rc=$?
    ((rc == 0)) || return "$rc"
    state_mark "$name"
  done
}

main() {
  enable_error_trap
  ((EUID == 0)) || die "Esegui come root: sudo bash $0"
  touch "$VPS_LOG"
  chmod 600 "$VPS_LOG"
  if [[ "${1:-}" == "--reset" ]]; then
    rm -f "$VPS_ANSWERS" "$VPS_STATE" "$VPS_ROOT/summary.env"
  fi
  if [[ ! -f "$VPS_ANSWERS" ]]; then
    bash "$VPS_ROOT/wizard.sh" || die "Procedura guidata annullata."
  else
    log "Risposte già presenti: riprendo dall'ultimo step non completato."
  fi
  answers_load
  run_steps
  log "Installazione terminata."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
