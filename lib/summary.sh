# shellcheck shell=bash
# Dati da mostrare una sola volta nel riepilogo finale (cancellati con l'installer).

summary_file() {
  printf '%s' "${VPS_SUMMARY:-$VPS_ROOT/summary.env}"
}

summary_set() {
  local f
  f="$(summary_file)"
  if [[ ! -f "$f" ]]; then
    : | write_file "$f" 600 "$(id -un):$(id -gn)"
  fi
  printf '%s=%q\n' "$1" "$2" >>"$f"
}

summary_load() {
  local f
  f="$(summary_file)"
  if [[ -f "$f" ]]; then
    source "$f"
  fi
}

# summary_get CHIAVE — valore salvato nel riepilogo (vuoto se assente).
summary_get() {
  (
    unset "$1"
    summary_load
    printf '%s' "${!1:-}"
  )
}
