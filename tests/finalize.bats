setup() {
  load test_helper
  setup_common
  source "$REPO_ROOT/steps/99-finalize.sh"
  ADMIN_USER=manu SSH_PORT=41822 PANEL_ENABLED=yes PANEL_DOMAIN=panel.miosito.it PANEL_ROOT=/var/www/panel.miosito.it
  WANT_PMA=yes MAIL_ENABLED=no CF_ENABLED=yes
  server_ipv4() { echo 203.0.113.10; }
}

@test "il riepilogo contiene accesso SSH, pannello e credenziali phpMyAdmin" {
  summary_set PMA_BASIC_PASS 'Pma-Segreta-1'
  summary_set PANEL_DBADMIN_PASS 'Db-Segreta-1'
  run finalize_summary_text
  [[ "$output" == *"ssh -p 41822 manu@203.0.113.10"* ]]
  [[ "$output" == *"https://panel.miosito.it/pma/"* ]]
  [[ "$output" == *"manu / Pma-Segreta-1"* ]]
  [[ "$output" == *"panel_dbadmin / Db-Segreta-1"* ]]
  [[ "$output" == *"Full (strict)"* ]]
}

@test "il riepilogo non inventa password già esistenti" {
  run finalize_summary_text
  [[ "$output" == *"(invariata)"* ]]
}

@test "il riepilogo non finisce nel log" {
  summary_set PMA_BASIC_PASS 'Pma-Segreta-1'
  finalize_summary_text >/dev/null
  ! grep -q 'Pma-Segreta-1' "$VPS_LOG" 2>/dev/null
}
