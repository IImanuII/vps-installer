# shellcheck shell=bash
# Verifica che l'utente admin sia davvero entrato con la nuova configurazione.

admin_logged_in() {
  loginctl list-sessions --no-legend 2>/dev/null \
    | awk -v u="$1" '$3 == u { f = 1 } END { exit !f }'
}
