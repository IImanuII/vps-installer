# shellcheck shell=bash
# Repository finto di Plancia, radice del pannello finta e stub dei comandi
# esterni, per panel_deploy.bats e per i test dei due script.

pd_test_setup() {
  export PANEL_REPO="$BATS_TEST_TMPDIR/repo.git"
  export PD_TEST=1 PD_AS_PANEL=0 PD_SKIP_TELEGRAM_CHECK=1
  export PD_HEALTH_URL=http://127.0.0.1:9/health PD_CURL_RESOLVE="" PD_HEALTH_SLEEP=0
  export PD_BACKUPS="$BATS_TEST_TMPDIR/backups" PD_CRON="$BATS_TEST_TMPDIR/cron-vps-panel"
  export PD_LOCK="$BATS_TEST_TMPDIR/update.lock" PD_KEY="$VPS_OPT/secrets/panel-deploy-key" PD_GIT_DIR="$BATS_TEST_TMPDIR/panel.git"
  export PD_PHP="$BATS_TEST_TMPDIR/bin/php" VPS_LIB="$REPO_ROOT/lib"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  P="$BATS_TEST_TMPDIR/panel"
  mkdir -p "$P/config" "$P/public" "$P/logs" "$P/storage"
  printf 'DB_HOST=localhost\nDB_NAME=panel\nDB_USER=panel\nDB_PASS=segreto\n' >"$P/config/.env"
  echo segnaposto >"$P/public/index.html"
  jq -n --arg p "$P" '{installer_version:"1.1.0", panel:{domain:"panel.test", path:$p}}' >"$VPS_OPT/manifest.json"

  local w="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$PANEL_REPO"
  git init -q -b main "$w"
  mkdir -p "$w/install/migrations" "$w/public" "$w/app/cli"
  echo '-- schema' >"$w/install/schema.sql"
  echo '<?php echo "OK";' >"$w/public/index.php"
  echo '<?php' >"$w/app/cli/create-admin.php"
  git -C "$w" add -A && git -C "$w" commit -qm v1.0.0 && git -C "$w" tag v1.0.0
  echo '-- migrazione 1.1.0' >"$w/install/migrations/1.1.0.sql"
  git -C "$w" add -A && git -C "$w" commit -qm v1.1.0 && git -C "$w" tag v1.1.0
  git -C "$w" push -q "$PANEL_REPO" main --tags
  PD_WORK="$w"

  make_stub mariadb 'printf "%s\n" "$*" >>"$BATS_TEST_TMPDIR/mariadb.args"
case " $* " in
  *" -e "*) printf "%s\n" "${MARIADB_OUT:-0}" ;;
  *) cat >>"$BATS_TEST_TMPDIR/mariadb.sql" ;;
esac
exit "${MARIADB_RC:-0}"'
  make_stub mariadb-dump 'echo "-- dump $*"'
  make_stub curl 'echo x >>"$BATS_TEST_TMPDIR/curl.calls"; echo "${CURL_OUT:-OK}"; exit "${CURL_RC:-0}"'
  make_stub systemctl 'printf "%s\n" "$*" >>"$BATS_TEST_TMPDIR/systemctl.args"'
  make_stub php 'T="$BATS_TEST_TMPDIR"
if [[ "$1" == -l ]]; then exit "${PHP_LINT_RC:-0}"; fi
if [[ " $* " == *" --dry-run "* ]]; then
  n=$(( $(cat "$T/dry.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$T/dry.n"
  cat >/dev/null
  (( n > ${PHP_DRY_FAILS:-0} )) || { echo "Errore: dati non validi" >&2; exit 1; }
  exit 0
fi
printf "%s\n" "$*" >>"$T/php.args"; cat >>"$T/php.stdin"; exit "${PHP_RC:-0}"'
}

# pd_test_installed TAG — la radice come la lascia un'installazione riuscita a TAG.
pd_test_installed() {
  pd_load
  pd_repo_init
  pd_git fetch -q --tags origin
  pd_checkout "$1"
  manifest_set '.panel.version = $v' --arg v "${1#v}"
  rm -f "$BATS_TEST_TMPDIR/mariadb.sql" "$BATS_TEST_TMPDIR/mariadb.args"
}

# pd_test_tag TAG [FILE CONTENUTO] — aggiunge un rilascio al repository finto.
pd_test_tag() {
  if (($# == 3)); then
    mkdir -p "$(dirname "$PD_WORK/$2")"
    printf '%s\n' "$3" >"$PD_WORK/$2"
  else
    echo "$1" >>"$PD_WORK/CHANGES"
  fi
  git -C "$PD_WORK" add -A && git -C "$PD_WORK" commit -qm "$1" && git -C "$PD_WORK" tag "$1"
  git -C "$PD_WORK" push -q "$PANEL_REPO" main --tags
}
