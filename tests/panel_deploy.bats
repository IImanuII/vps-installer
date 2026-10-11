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
  pd_repo_init
  pd_git fetch -q --tags origin
  [ "$(pd_latest_tag)" = v1.10.0 ]
}

@test "pd_latest_tag senza tag non stampa niente e non fallisce" {
  pd_load
  pd_repo_init
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

@test "la git dir sta fuori dalla radice: nessun .git nella radice" {
  pd_test_installed v1.0.0
  [ ! -e "$P/.git" ]
  [ -d "$PD_GIT_DIR" ]
  [ "$(pd_current_tag)" = v1.0.0 ]
}

@test "pd_repo_init è idempotente e origin è PANEL_REPO" {
  pd_load
  pd_repo_init
  pd_repo_init
  [ "$(pd_git remote get-url origin)" = "$PANEL_REPO" ]
  [ "$(pd_git remote | wc -l)" -eq 1 ]
  [ "$(pd_git config core.bare)" = false ]
  PANEL_REPO=/altro/repo pd_repo_init
  [ "$(pd_git remote get-url origin)" = /altro/repo ]
}

@test "pd_repo_ok: falso per cartella mancante e per link simbolico" {
  pd_load
  ! pd_repo_ok
  pd_repo_init
  pd_repo_ok
  mv "$PD_GIT_DIR" "$BATS_TEST_TMPDIR/vera.git"
  ln -s "$BATS_TEST_TMPDIR/vera.git" "$PD_GIT_DIR"
  ! pd_repo_ok
}

@test "pd_checkout non segue link simbolici nel work tree" {
  pd_test_installed v1.0.0
  ln -s /etc/passwd "$P/trappola"
  pd_checkout v1.1.0
  [ -L "$P/trappola" ]
  # il blocco chown è -R -P -h sull'intera radice, senza giro per percorso (nei test è saltato: VPS_NO_CHOWN=1)
  grep -q 'chown -R -P -h' "$REPO_ROOT/lib/panel_deploy.sh"
  ! grep -q 'ls-files' "$REPO_ROOT/lib/panel_deploy.sh"
}

@test "pd_key_ensure: cartella 700, rigenera .pub mancante" {
  pd_key_ensure
  [ "$(stat -c %a "$(dirname "$PD_KEY")")" = 700 ]
  first="$(cut -d' ' -f1,2 "$PD_KEY.pub")"
  rm "$PD_KEY.pub"
  pd_key_ensure
  [ "$(cut -d' ' -f1,2 "$PD_KEY.pub")" = "$first" ]
}

@test "pd_env_merge: se openssl fallisce niente APP_KEY vuoto" {
  make_stub openssl 'exit 1'
  pd_load
  run pd_env_merge ""
  [ "$status" -ne 0 ]
  ! grep -q '^APP_KEY=' "$PD_ENV"
}
