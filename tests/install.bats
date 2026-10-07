setup() {
  load test_helper
  export VPS_DEST="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$BATS_TEST_TMPDIR/pkg/vps-installer"
  echo 'echo ciao' >"$BATS_TEST_TMPDIR/pkg/vps-installer/run.sh"
  tar -czf "$BATS_TEST_TMPDIR/rel.tar.gz" -C "$BATS_TEST_TMPDIR/pkg" vps-installer
  source "$BATS_TEST_DIRNAME/../install.sh"
}

@test "fetch_release estrae un archivio locale" {
  fetch_release "$BATS_TEST_TMPDIR/rel.tar.gz"
  [ -f "$VPS_DEST/run.sh" ]
  [ "$(stat -c %a "$VPS_DEST")" = "700" ]
}

@test "fetch_release scarica e verifica l'hash" {
  mkdir -p "$BATS_TEST_TMPDIR/www/v9.9.9"
  cp "$BATS_TEST_TMPDIR/rel.tar.gz" "$BATS_TEST_TMPDIR/www/v9.9.9/vps-installer-v9.9.9.tar.gz"
  VPS_VERSION=v9.9.9
  TARBALL_SHA256="$(sha256sum "$BATS_TEST_TMPDIR/rel.tar.gz" | cut -d' ' -f1)"
  RELEASE_BASE_URL="file://$BATS_TEST_TMPDIR/www"
  fetch_release ""
  [ -f "$VPS_DEST/run.sh" ]
}

@test "fetch_release rifiuta un hash sbagliato" {
  mkdir -p "$BATS_TEST_TMPDIR/www/v9.9.9"
  cp "$BATS_TEST_TMPDIR/rel.tar.gz" "$BATS_TEST_TMPDIR/www/v9.9.9/vps-installer-v9.9.9.tar.gz"
  VPS_VERSION=v9.9.9
  TARBALL_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  RELEASE_BASE_URL="file://$BATS_TEST_TMPDIR/www"
  run fetch_release ""
  [ "$status" -ne 0 ]
  [ ! -f "$VPS_DEST/run.sh" ]
}

@test "senza release richiede --local" {
  TARBALL_SHA256=__TARBALL_SHA256__
  run fetch_release ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"--local"* ]]
}

local_id() {
  printf 'local:%s' "$(sha256sum "$BATS_TEST_TMPDIR/rel.tar.gz" | cut -d' ' -f1)"
}

@test "fetch_release scrive il marcatore .release" {
  fetch_release "$BATS_TEST_TMPDIR/rel.tar.gz"
  [ "$(cat "$VPS_DEST/.release")" = "$(local_id)" ]
}

@test "ensure_release: stessa release, riusa la cartella esistente" {
  mkdir -p "$VPS_DEST"
  echo vecchio >"$VPS_DEST/run.sh"
  local_id >"$VPS_DEST/.release"
  ensure_release "$BATS_TEST_TMPDIR/rel.tar.gz"
  [ "$(cat "$VPS_DEST/run.sh")" = vecchio ]
}

@test "ensure_release: release diversa, aggiorna e conserva i file di lavoro" {
  mkdir -p "$VPS_DEST"
  echo vecchio >"$VPS_DEST/run.sh"
  echo vecchio >"$VPS_DEST/lib-vecchia.sh"
  echo 'local:altro' >"$VPS_DEST/.release"
  echo 'ADMIN_USER=manu' >"$VPS_DEST/answers.env"
  printf '10-system\n20-user-ssh\n' >"$VPS_DEST/state"
  echo 'PMA_BASIC_PASS=x' >"$VPS_DEST/summary.env"
  echo 'Port 41822' >"$VPS_DEST/sshd-10-vps.conf"
  ensure_release "$BATS_TEST_TMPDIR/rel.tar.gz"
  [ "$(cat "$VPS_DEST/run.sh")" = "echo ciao" ]
  [ ! -e "$VPS_DEST/lib-vecchia.sh" ]
  [ "$(cat "$VPS_DEST/answers.env")" = 'ADMIN_USER=manu' ]
  [ "$(cat "$VPS_DEST/state")" = $'10-system\n20-user-ssh' ]
  [ "$(cat "$VPS_DEST/summary.env")" = 'PMA_BASIC_PASS=x' ]
  [ "$(cat "$VPS_DEST/sshd-10-vps.conf")" = 'Port 41822' ]
  [ "$(cat "$VPS_DEST/.release")" = "$(local_id)" ]
  [ "$(stat -c %a "$VPS_DEST")" = "700" ]
  run compgen -G "$VPS_DEST.*"
  [ "$status" -ne 0 ]
}

@test "ensure_release: marcatore mancante, release considerata vecchia" {
  mkdir -p "$VPS_DEST"
  echo vecchio >"$VPS_DEST/run.sh"
  echo 'ADMIN_USER=manu' >"$VPS_DEST/answers.env"
  ensure_release "$BATS_TEST_TMPDIR/rel.tar.gz"
  [ "$(cat "$VPS_DEST/run.sh")" = "echo ciao" ]
  [ "$(cat "$VPS_DEST/answers.env")" = 'ADMIN_USER=manu' ]
}

@test "ensure_release: senza release né --local riusa quello che c'è" {
  TARBALL_SHA256=__TARBALL_SHA256__
  mkdir -p "$VPS_DEST"
  echo vecchio >"$VPS_DEST/run.sh"
  ensure_release ""
  [ "$(cat "$VPS_DEST/run.sh")" = vecchio ]
}

@test "ensure_release: release scaricata con hash diverso dal marcatore" {
  mkdir -p "$BATS_TEST_TMPDIR/www/v9.9.9" "$VPS_DEST"
  cp "$BATS_TEST_TMPDIR/rel.tar.gz" "$BATS_TEST_TMPDIR/www/v9.9.9/vps-installer-v9.9.9.tar.gz"
  VPS_VERSION=v9.9.9
  TARBALL_SHA256="$(sha256sum "$BATS_TEST_TMPDIR/rel.tar.gz" | cut -d' ' -f1)"
  RELEASE_BASE_URL="file://$BATS_TEST_TMPDIR/www"
  echo vecchio >"$VPS_DEST/run.sh"
  echo 0000 >"$VPS_DEST/.release"
  ensure_release ""
  [ "$(cat "$VPS_DEST/run.sh")" = "echo ciao" ]
  [ "$(cat "$VPS_DEST/.release")" = "$TARBALL_SHA256" ]
}

@test "ensure_release: download fallito, la cartella esistente resta intatta" {
  mkdir -p "$VPS_DEST"
  VPS_VERSION=v9.9.9
  TARBALL_SHA256=1111111111111111111111111111111111111111111111111111111111111111
  RELEASE_BASE_URL="file://$BATS_TEST_TMPDIR/nessuno"
  echo vecchio >"$VPS_DEST/run.sh"
  echo 0000 >"$VPS_DEST/.release"
  run ensure_release ""
  [ "$status" -ne 0 ]
  [ "$(cat "$VPS_DEST/run.sh")" = vecchio ]
  run compgen -G "$VPS_DEST.*"
  [ "$status" -ne 0 ]
}

@test "bootstrap_deps riprova apt-get update e usa il timeout del lock" {
  export APT_RETRY_SLEEP=0 CALLS="$BATS_TEST_TMPDIR/apt.calls"
  make_stub apt-get 'echo "$*" >>"$CALLS"; if [[ "$*" == *update* ]] && (( $(grep -c update "$CALLS") < 3 )); then exit 100; fi; exit 0'
  run bootstrap_deps
  [ "$status" -eq 0 ]
  [ "$(grep -c update "$CALLS")" -eq 3 ]
  [ "$(grep -c 'DPkg::Lock::Timeout=300' "$CALLS")" -eq 4 ]
  grep -q 'install -y -q tmux' "$CALLS"
}

@test "bootstrap_deps fallisce dopo 3 tentativi di update" {
  export APT_RETRY_SLEEP=0 CALLS="$BATS_TEST_TMPDIR/apt.calls"
  make_stub apt-get 'echo "$*" >>"$CALLS"; exit 100'
  run bootstrap_deps
  [ "$status" -ne 0 ]
  [ "$(grep -c update "$CALLS")" -eq 3 ]
  run grep -q install "$CALLS"
  [ "$status" -ne 0 ]
}
