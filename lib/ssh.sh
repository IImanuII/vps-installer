# shellcheck shell=bash
# Verifica che l'utente admin sia davvero entrato con la nuova configurazione.

admin_logged_in() {
  loginctl list-sessions --no-legend 2>/dev/null \
    | awk -v u="$1" '$3 == u { f = 1 } END { exit !f }'
}

# Elenca gli ID delle sessioni di classe "user" dell'utente $1 (esclude le sessioni "manager").
admin_session_ids() {
  local id cls name
  while read -r id _ name _; do
    [[ "$name" == "$1" ]] || continue
    cls="$(loginctl show-session "$id" -p Class --value 2>/dev/null)" || continue
    [[ "$cls" == user ]] && echo "$id"
  done < <(loginctl list-sessions --no-legend 2>/dev/null)
  return 0
}

# 0 se esiste una sessione "user" di $1 con ID non presente in $2 (elenco di ID, uno per riga).
admin_new_session() {
  local id
  while read -r id; do
    [[ -n "$id" ]] || continue
    grep -qxF -- "$id" <<<"$2" || return 0
  done < <(admin_session_ids "$1")
  return 1
}
