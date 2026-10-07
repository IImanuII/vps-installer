setup() {
  load test_helper
  setup_common
  make_stub df 'printf "Avail\n  40G\n"'
  make_stub getent 'echo "151.101.2.132 deb.debian.org"'
}

@test "os_codename legge os-release" {
  printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run os_codename
  [ "$output" = "trixie" ]
}

@test "preflight segnala Debian non supportata" {
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run preflight_errors
  [[ "$output" == *"Debian 13"* ]]
}

@test "preflight non segnala il sistema se è trixie" {
  printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run preflight_errors
  [[ "$output" != *"Debian 13"* ]]
}

@test "preflight segnala disco pieno e DNS rotto" {
  make_stub df 'printf "Avail\n   2G\n"'
  make_stub getent 'exit 2'
  printf 'VERSION_CODENAME=trixie\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run preflight_errors
  [[ "$output" == *"Spazio disco"* ]]
  [[ "$output" == *"DNS"* ]]
}
