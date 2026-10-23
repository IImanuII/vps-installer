bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load panel_helper
  setup_common
  pd_test_setup
  T="$REPO_ROOT/tools/vps-panel-install"
  TOKEN="123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}

answers() { printf '%s\n' "$TOKEN" manu 123456789 'Una-Password-12!' 'Una-Password-12!'; }

@test "installa l'ultimo rilascio dall'inizio alla fine" {
  run bash -c "$(declare -f answers); TOKEN='$TOKEN'; answers | bash '$T'"
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$PD_GIT_DIR" describe --tags --exact-match)" = v1.1.0 ]
  [ ! -e "$P/.git" ]
  [ ! -f "$P/public/index.html" ]
  [ -n "$(env_get "$P/config/.env" APP_KEY)" ]
  [ "$(env_get "$P/config/.env" TELEGRAM_BOT_TOKEN)" = "$TOKEN" ]
  grep -qx -- '-- schema' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -q -- '--username=manu --telegram-id=123456789' "$BATS_TEST_TMPDIR/php.args"
  grep -qx 'Una-Password-12!' "$BATS_TEST_TMPDIR/php.stdin"
  [ -f "$PD_CRON" ]
  grep -q 'reload php8.4-fpm' "$BATS_TEST_TMPDIR/systemctl.args"
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.1.0 ]
  [[ "$output" == *"https://panel.test/login"* ]]
  ! grep -q 'Una-Password-12!' "$VPS_LOG"
  ! grep -q AAAAAAAAAAAA "$VPS_LOG"
}

@test "password con spazi in testa e in coda: arriva a create-admin com'è" {
  run bash -c "printf '%s\n' '$TOKEN ' manu 123456789 '  Una-Password-12! ' '  Una-Password-12! ' | bash '$T'"
  [ "$status" -eq 0 ]
  grep -qx '  Una-Password-12! ' "$BATS_TEST_TMPDIR/php.stdin"
}

@test "rifiuta se Plancia è già installata" {
  manifest_set '.panel.version = "1.0.0"'
  run bash "$T" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"vps-panel-update"* ]]
}

@test "rilancio dopo un'interruzione: niente seconda APP_KEY, niente secondo super_admin, token non richiesto" {
  printf 'APP_KEY=chiave-esistente\nTELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >>"$P/config/.env"
  pd_key_ensure
  key="$(cat "$PD_KEY.pub")"
  MARIADB_OUT=1 run bash "$T" </dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -c '^APP_KEY=' "$P/config/.env")" -eq 1 ]
  grep -qx 'APP_KEY=chiave-esistente' "$P/config/.env"
  [ "$(cat "$PD_KEY.pub")" = "$key" ]
  [ ! -f "$BATS_TEST_TMPDIR/php.args" ]
}

@test "dati del super_admin non validi: li richiede" {
  run bash -c "printf '%s\n' '$TOKEN' a 1 'x' 'x' manu 123456789 'Una-Password-12!' 'Una-Password-12!' | PHP_DRY_FAILS=1 bash '$T'"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/dry.n")" -eq 2 ]
  grep -q -- '--username=manu' "$BATS_TEST_TMPDIR/php.args"
}

@test "password ripetuta diversa: la richiede" {
  run bash -c "printf '%s\n' '$TOKEN' manu 123456789 'Una-Password-12!' 'Altra-Password-12!' manu 123456789 'Una-Password-12!' 'Una-Password-12!' | bash '$T'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"non coincidono"* ]]
}

@test "input finito a metà: esce con 1 e non resta in attesa" {
  run timeout 20 bash -c "printf '%s\n' '$TOKEN' manu | bash '$T'"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.panel.version // empty' "$VPS_OPT/manifest.json")" = "" ]
}

@test "token Telegram non valido tre volte: esce senza toccare il codice" {
  run bash -c "printf 'corto\ncorto\ncorto\n' | bash '$T'"
  [ "$status" -eq 1 ]
  [ ! -d "$PD_GIT_DIR" ]
}

@test "repository senza rilasci: errore chiaro" {
  git init -q --bare "$BATS_TEST_TMPDIR/vuoto.git"
  run bash -c "$(declare -f answers); TOKEN='$TOKEN'; answers | PANEL_REPO='$BATS_TEST_TMPDIR/vuoto.git' bash '$T'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Nessun rilascio"* ]]
}

@test "/health che non risponde: uscita 1 e manifest senza versione" {
  run bash -c "$(declare -f answers); TOKEN='$TOKEN'; answers | CURL_RC=7 bash '$T'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"/health"* ]]
  [ "$(jq -r '.panel.version // empty' "$VPS_OPT/manifest.json")" = "" ]
}

@test "sotto sudo l'ambiente del chiamante non conta" {
  grep -q 'unset PANEL_REPO' "$T"
  grep -q 'PD_GIT_DIR' "$T"
}
