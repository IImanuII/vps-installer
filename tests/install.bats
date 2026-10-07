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
