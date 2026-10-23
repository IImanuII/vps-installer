bats_require_minimum_version 1.5.0

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
  run ! pd_ver_gt 1.9.0 1.10.0
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

# Rilascio v1.2.0 con i file di sviluppo che stanno nel repository di Plancia.
dev_release() {
  local f
  for f in .claude/CLAUDE.md Documenti/note.md tests/t.php infra/nginx.conf PRODUCT.md app/cli/nuovo.php; do
    mkdir -p "$PD_WORK/$(dirname "$f")"
    echo x >"$PD_WORK/$f"
  done
  git -C "$PD_WORK" add -A && git -C "$PD_WORK" commit -qm v1.2.0 && git -C "$PD_WORK" tag v1.2.0
  git -C "$PD_WORK" push -q "$PANEL_REPO" main --tags
}

@test "pd_checkout: i file di sviluppo non arrivano nella radice" {
  dev_release
  pd_test_installed v1.2.0
  [ -f "$P/app/cli/nuovo.php" ]
  [ -f "$P/install/schema.sql" ]
  for f in .claude Documenti tests infra PRODUCT.md; do
    [ ! -e "$P/$f" ]
  done
  [ -z "$(pd_git status --porcelain --untracked-files=no)" ]
  [ "$(pd_current_tag)" = v1.2.0 ]
}

@test "pd_checkout toglie i file di sviluppo da una radice installata senza filtro" {
  dev_release
  pd_load
  pd_repo_init
  pd_git fetch -q --tags origin
  pd_git checkout -q -f v1.2.0
  [ -f "$P/Documenti/note.md" ]
  pd_checkout v1.2.0
  for f in .claude Documenti tests infra PRODUCT.md; do
    [ ! -e "$P/$f" ]
  done
  [ -f "$P/app/cli/nuovo.php" ]
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
  printf 'DB_NAME=mysql\n' >"$PD_ENV"
  [ "$(pd_db_name)" = panel ]
  jq '.panel.db = "pan;el"' "$VPS_OPT/manifest.json" >"$VPS_OPT/m.tmp" && mv "$VPS_OPT/m.tmp" "$VPS_OPT/manifest.json"
  run pd_db_name
  [ "$status" -eq 1 ]
  jq '.panel.db = "mysql"' "$VPS_OPT/manifest.json" >"$VPS_OPT/m.tmp" && mv "$VPS_OPT/m.tmp" "$VPS_OPT/manifest.json"
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
  run ! pd_repo_ok
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

@test "pd_schema legge schema.sql dal tag, non dalla radice del pannello" {
  pd_test_installed v1.0.0
  echo '-- manomesso' >"$P/install/schema.sql"
  pd_schema v1.0.0
  grep -qx -- '-- schema' "$BATS_TEST_TMPDIR/mariadb.sql"
  run ! grep -q manomesso "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -qx panel "$BATS_TEST_TMPDIR/mariadb.args"
}

@test "pd_schema fallisce se il tag non esiste" {
  pd_test_installed v1.0.0
  run pd_schema v9.9.9
  [ "$status" -eq 1 ]
}

@test "pd_migrations: solo l'intervallo (DA, A], in ordine di versione" {
  printf -- '-- migrazione 1.2.0\n' >"$PD_WORK/install/migrations/1.2.0.sql"
  printf -- '-- migrazione 1.0.0\n' >"$PD_WORK/install/migrations/1.0.0.sql"
  printf 'non sql\n' >"$PD_WORK/install/migrations/note.txt"
  pd_test_tag v1.10.0 install/migrations/1.10.0.sql '-- migrazione 1.10.0'
  pd_test_tag v1.11.0
  pd_test_installed v1.11.0
  pd_migrations v1.0.0 v1.10.0
  run cat "$BATS_TEST_TMPDIR/mariadb.sql"
  [ "${lines[0]}" = "-- migrazione 1.1.0" ]
  [ "${lines[1]}" = "-- migrazione 1.2.0" ]
  [ "${lines[2]}" = "-- migrazione 1.10.0" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "pd_migrations ignora i file manomessi nella radice del pannello" {
  pd_test_installed v1.1.0
  mkdir -p "$P/install/migrations"
  echo '-- falsa 1.5.0' >"$P/install/migrations/1.5.0.sql"
  echo '-- manomessa 1.1.0' >"$P/install/migrations/1.1.0.sql"
  pd_migrations v1.0.0 v1.1.0
  grep -qx -- '-- migrazione 1.1.0' "$BATS_TEST_TMPDIR/mariadb.sql"
  ! grep -q -e falsa -e manomessa "$BATS_TEST_TMPDIR/mariadb.sql"
}

@test "pd_migrations si ferma alla prima che fallisce" {
  pd_test_installed v1.1.0
  MARIADB_RC=1 run pd_migrations v1.0.0 v1.1.0
  [ "$status" -eq 1 ]
}

@test "pd_dump scrive un gzip 600 e tiene gli ultimi 5" {
  pd_test_installed v1.0.0
  mkdir -p "$PD_BACKUPS"
  for i in 1 2 3 4 5 6; do
    : >"$PD_BACKUPS/vecchio-$i.sql.gz"
    touch -d "2020-01-0$i" "$PD_BACKUPS/vecchio-$i.sql.gz"
  done
  f="$(pd_dump v1.0.0)"
  [ -f "$f" ]
  [[ "$(basename "$f")" == v1.0.0-*.sql.gz ]]
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(stat -c %a "$PD_BACKUPS")" = 700 ]
  gunzip -c "$f" | grep -q -- '-- dump'
  [ "$(find "$PD_BACKUPS" -name '*.sql.gz' | wc -l)" -eq 5 ]
  [ ! -f "$PD_BACKUPS/vecchio-1.sql.gz" ]
  [ ! -f "$PD_BACKUPS/vecchio-2.sql.gz" ]
}

@test "pd_dump: due dump nello stesso secondo non si sovrascrivono" {
  pd_test_installed v1.0.0
  make_stub date 'echo 20261011-120000'
  a="$(pd_dump v1.0.0)"
  b="$(pd_dump v1.0.0)"
  [ "$a" != "$b" ]
  [ -f "$a" ] && [ -f "$b" ]
  [[ "$(basename "$a")" == v1.0.0-20261011-120000-*.sql.gz ]]
  [ "$(stat -c %a "$b")" = 600 ]
}

@test "pd_restore: dump corrotto, nessun DROP del database" {
  pd_test_installed v1.0.0
  echo 'non sono un gzip' >"$BATS_TEST_TMPDIR/rotto.sql.gz"
  run pd_restore "$BATS_TEST_TMPDIR/rotto.sql.gz"
  [ "$status" -eq 1 ]
  run grep -q 'DROP DATABASE' "$BATS_TEST_TMPDIR/mariadb.args"
  [ "$status" -ne 0 ]
}

@test "pd_restore ricrea il database e carica il dump" {
  pd_test_installed v1.0.0
  printf -- '-- contenuto\n' | gzip >"$BATS_TEST_TMPDIR/d.sql.gz"
  pd_restore "$BATS_TEST_TMPDIR/d.sql.gz"
  grep -q 'DROP DATABASE IF EXISTS `panel`' "$BATS_TEST_TMPDIR/mariadb.args"
  grep -qx -- '-- contenuto' "$BATS_TEST_TMPDIR/mariadb.sql"
}

@test "pd_health: OK passa, altrimenti tre tentativi e fallisce" {
  pd_load
  pd_health
  rm -f "$BATS_TEST_TMPDIR/curl.calls"
  CURL_RC=22 run pd_health
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/curl.calls")" -eq 3 ]
  CURL_OUT=NO run pd_health
  [ "$status" -eq 1 ]
}

@test "pd_php_lint fallisce se un file non compila" {
  pd_test_installed v1.0.0
  pd_php_lint
  PHP_LINT_RC=255 run pd_php_lint
  [ "$status" -ne 0 ]
}

@test "pd_super_admin_exists: sì, no, prefisso non valido" {
  pd_load
  MARIADB_OUT=1 pd_super_admin_exists
  MARIADB_OUT=0 run pd_super_admin_exists
  [ "$status" -eq 1 ]
  grep -q 'vp_users' "$BATS_TEST_TMPDIR/mariadb.args"
  printf 'DB_PREFIX=x`;\n' >>"$PD_ENV"
  run pd_super_admin_exists
  [ "$status" -eq 2 ]
}

@test "pd_telegram_ok rifiuta un formato sbagliato senza chiamare Telegram" {
  PD_SKIP_TELEGRAM_CHECK=0 run pd_telegram_ok "corto"
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/curl.calls" ]
}

@test "pd_telegram_ok: il token non finisce negli argomenti di curl" {
  make_stub curl 'printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/curl.argv"; cat >"$BATS_TEST_TMPDIR/curl.stdin"; echo "{\"ok\":true}"'
  PD_SKIP_TELEGRAM_CHECK=0 pd_telegram_ok "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  run ! grep -q AAAAAAAA "$BATS_TEST_TMPDIR/curl.argv"
  grep -q 'bot123456:AAAAAAAA' "$BATS_TEST_TMPDIR/curl.stdin"
}

@test "pd_cron_install e pd_manifest" {
  pd_load
  pd_cron_install
  grep -q "^0 3 \* \* \* panel /usr/bin/php $P/app/cron/maintenance.php" "$PD_CRON"
  [ "$(stat -c %a "$PD_CRON")" = 644 ]
  pd_manifest v2.1.0
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 2.1.0 ]
  [ "$(jq -r .panel.repo "$VPS_OPT/manifest.json")" = "$PANEL_REPO" ]
  [ "$(jq -r .panel.deployed_at "$VPS_OPT/manifest.json")" != null ]
  [ "$(jq -r .panel.domain "$VPS_OPT/manifest.json")" = panel.test ]
}
