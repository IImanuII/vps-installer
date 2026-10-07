#!/usr/bin/env bash
# Esegue la procedura guidata (se serve) e poi gli step, con ripresa.

if [[ -z "${VPS_ROOT:-}" ]]; then
  VPS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
export VPS_ROOT
export VPS_TEMPLATES="${VPS_TEMPLATES:-$VPS_ROOT/templates}"
for _lib in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"/lib/*.sh; do
  source "$_lib"
done

run_steps() {
  local f name
  for f in "$VPS_ROOT"/steps/[0-9][0-9]-*.sh; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .sh)"
    if state_done "$name"; then
      log "Step $name già completato, salto."
      continue
    fi
    log "=== Step $name ==="
    # Subshell: ogni step ha le sue funzioni e un errore non segna lo stato.
    (
      set -Eeuo pipefail
      step_enabled() { return 0; }
      source "$f"
      if step_enabled; then
        step_main
      else
        log "Step $name non richiesto, salto."
      fi
    ) || return $?
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
