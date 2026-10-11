setup() {
  load test_helper
  load panel_helper
  setup_common
  pd_test_setup
}

@test "known_hosts di GitHub: le tre impronte pubblicate" {
  run ssh-keygen -lf "$REPO_ROOT/templates/github-known-hosts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"* ]]
  [[ "$output" == *"SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"* ]]
  [[ "$output" == *"SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"* ]]
}

@test "pd_load legge dominio e radice dal manifest" {
  pd_load
  [ "$PANEL_DOMAIN" = panel.test ]
  [ "$PANEL_ROOT" = "$P" ]
  [ "$PD_ENV" = "$P/config/.env" ]
}

@test "pd_load senza pannello nel manifest" {
  jq -n '{installer_version:"1.1.0", panel:null}' >"$VPS_OPT/manifest.json"
  run pd_load
  [ "$status" -eq 1 ]
  [[ "$output" == *"non ha un pannello"* ]]
}

@test "pd_key_ensure crea la chiave una volta sola, 600" {
  pd_key_ensure
  [ "$(stat -c %a "$PD_KEY")" = 600 ]
  first="$(cat "$PD_KEY.pub")"
  pd_key_ensure
  [ "$(cat "$PD_KEY.pub")" = "$first" ]
}

@test "pd_latest_tag: ordine di versione, tag non conformi ignorati" {
  pd_test_tag v1.9.0
  pd_test_tag v1.10.0
  pd_test_tag v3.0
  pd_test_tag v3.0.0-rc1
  pd_test_tag latest
  pd_load
  pd_git init -q -b main
  pd_git remote add origin "$PANEL_REPO"
  pd_git fetch -q --tags origin
  [ "$(pd_latest_tag)" = v1.10.0 ]
}

@test "pd_latest_tag senza tag non stampa niente e non fallisce" {
  pd_load
  pd_git init -q -b main
  run pd_latest_tag
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pd_ver_gt" {
  pd_ver_gt 1.10.0 1.9.0
  ! pd_ver_gt 1.9.0 1.10.0
  ! pd_ver_gt 1.0.0 1.0.0
}

@test "pd_checkout porta al tag e non tocca config, logs, storage" {
  echo riga >"$P/logs/app.log"
  pd_test_installed v1.0.0
  [ "$(pd_current_tag)" = v1.0.0 ]
  [ ! -f "$P/install/migrations/1.1.0.sql" ]
  pd_checkout v1.1.0
  [ "$(pd_current_tag)" = v1.1.0 ]
  [ -f "$P/install/migrations/1.1.0.sql" ]
  grep -qx 'DB_PASS=segreto' "$P/config/.env"
  grep -qx riga "$P/logs/app.log"
}

@test "pd_env_merge aggiunge APP_KEY una volta e il token" {
  pd_load
  pd_env_merge "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  key="$(env_get "$PD_ENV" APP_KEY)"
  [ "$(printf '%s' "$key" | base64 -d | wc -c)" -eq 32 ]
  pd_env_merge ""
  [ "$(env_get "$PD_ENV" APP_KEY)" = "$key" ]
  [ "$(grep -c '^APP_KEY=' "$PD_ENV")" -eq 1 ]
  [ "$(env_get "$PD_ENV" TELEGRAM_BOT_TOKEN)" = "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]
  grep -qx 'DB_PASS=segreto' "$PD_ENV"
}

@test "pd_db_name rifiuta nomi non validi" {
  pd_load
  [ "$(pd_db_name)" = panel ]
  printf 'DB_NAME=pan;el\n' >"$PD_ENV"
  run pd_db_name
  [ "$status" -eq 1 ]
}
