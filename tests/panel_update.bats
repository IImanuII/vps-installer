setup() {
  load test_helper
  load panel_helper
  setup_common
  pd_test_setup
  T="$REPO_ROOT/tools/vps-panel-update"
}

tag_now() { git --git-dir="$PD_GIT_DIR" describe --tags --exact-match; }

@test "aggiorna all'ultimo rilascio con migrazione e manifest" {
  pd_test_installed v1.0.0
  run bash "$T"
  [ "$status" -eq 0 ]
  [ "$(tag_now)" = v1.1.0 ]
  grep -qx -- '-- schema' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -qx -- '-- migrazione 1.1.0' "$BATS_TEST_TMPDIR/mariadb.sql"
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.1.0 ]
  [ "$(find "$PD_BACKUPS" -name 'v1.0.0-*.sql.gz' | wc -l)" -eq 1 ]
  [[ "$output" == *"v1.0.0 → v1.1.0"* ]]
}

@test "già aggiornata: uscita 0, niente dump" {
  pd_test_installed v1.1.0
  run bash "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Già aggiornata"* ]]
  [ ! -d "$PD_BACKUPS" ]
}

@test "non installata: rimanda a vps-panel-install" {
  run bash "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vps-panel-install"* ]]
}

@test "git dir non sicura: rifiuta" {
  pd_test_installed v1.0.0
  chmod 777 "$PD_GIT_DIR"
  VPS_NO_CHOWN="" run bash "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non sicuro"* ]]
}

@test "/health rotto: torna alla versione di prima, codice e database" {
  pd_test_installed v1.0.0
  CURL_RC=22 run bash "$T"
  [ "$status" -eq 1 ]
  [ "$(tag_now)" = v1.0.0 ]
  grep -q 'DROP DATABASE IF EXISTS `panel`' "$BATS_TEST_TMPDIR/mariadb.args"
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.0.0 ]
  [[ "$output" == *"/health"* ]]
  [[ "$output" == *".sql.gz"* ]]
}

@test "php -l fallito: rollback" {
  pd_test_installed v1.0.0
  PHP_LINT_RC=255 run bash "$T"
  [ "$status" -eq 1 ]
  [ "$(tag_now)" = v1.0.0 ]
}

@test "ritorno indietro impossibile (database giù): uscita 2 col percorso del dump" {
  pd_test_installed v1.0.0
  MARIADB_RC=1 run bash "$T"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$PD_BACKUPS/v1.0.0-"* ]]
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.0.0 ]
}

@test "dump fallito: nessuna modifica" {
  pd_test_installed v1.0.0
  make_stub mariadb-dump 'exit 1'
  run bash "$T"
  [ "$status" -eq 1 ]
  [ "$(tag_now)" = v1.0.0 ]
}

@test "--ref: formato e esistenza" {
  pd_test_installed v1.0.0
  run bash "$T" --ref v1.1
  [ "$status" -eq 1 ]
  run bash "$T" --ref v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"non esiste"* ]]
  run bash "$T" --ref
  [ "$status" -eq 1 ]
}

@test "--ref a una versione più vecchia: solo codice, avviso, niente migrazioni" {
  pd_test_installed v1.1.0
  run bash "$T" --ref v1.0.0
  [ "$status" -eq 0 ]
  [ "$(tag_now)" = v1.0.0 ]
  [[ "$output" == *"ATTENZIONE"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/mariadb.sql" ]
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.0.0 ]
}

@test "un secondo aggiornamento in corso: esce subito" {
  pd_test_installed v1.0.0
  exec 8>"$PD_LOCK"
  flock 8
  run bash "$T"
  exec 8>&-
  [ "$status" -eq 1 ]
  [[ "$output" == *"in corso"* ]]
  [ "$(tag_now)" = v1.0.0 ]
  [ ! -d "$PD_BACKUPS" ]
}

@test "checkout attuale non su un rilascio: rifiuta" {
  pd_test_installed v1.0.0
  # Un commit senza tag: HEAD su v1.1.0 o su main (= v1.1.0) avrebbe comunque un tag esatto.
  echo x >"$PD_WORK/extra"
  git -C "$PD_WORK" add -A && git -C "$PD_WORK" commit -qm extra && git -C "$PD_WORK" push -q "$PANEL_REPO" main
  pd_git fetch -q origin
  pd_git checkout -q origin/main
  run bash "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non è un rilascio"* ]]
}
