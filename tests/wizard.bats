setup() {
  load test_helper
  setup_common
}

@test "wizard.sh si carica senza eseguire main" {
  run bash -c "source '$REPO_ROOT/wizard.sh'; declare -F ask_input wizard_cloudflare wizard_summary >/dev/null"
  [ "$status" -eq 0 ]
}

@test "wizard_defaults azzera tutte le risposte" {
  source "$REPO_ROOT/wizard.sh"
  ADMIN_USER=vecchio
  wizard_defaults
  [ "$ADMIN_USER" = "" ]
  [ "$WANT_NGINX" = no ]
  [ "$CF_ENABLED" = no ]
}
