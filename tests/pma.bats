setup() {
  load test_helper
  setup_common
  export PMA_DIR="$VPS_OPT/phpmyadmin"
}

@test "pma_latest_version legge version.json" {
  make_stub curl 'echo "{\"version\": \"5.2.3\", \"date\": \"2025-10-01\"}"'
  run pma_latest_version
  [ "$output" = "5.2.3" ]
}

@test "pma_latest_version rifiuta risposte strane" {
  make_stub curl 'echo "<html>manutenzione</html>"'
  run pma_latest_version
  [ "$status" -ne 0 ]
}

@test "pma_installed_version legge la versione installata" {
  mkdir -p "$PMA_DIR/libraries/classes"
  printf "<?php\nfinal class Version\n{\n    public const VERSION = '5.2.3' . VERSION_SUFFIX;\n}\n" >"$PMA_DIR/libraries/classes/Version.php"
  run pma_installed_version
  [ "$output" = "5.2.3" ]
}

@test "pma_installed_version vuoto se non installato" {
  run pma_installed_version
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pma_controlpass_from_config" {
  mkdir -p "$PMA_DIR"
  printf "<?php\n\$cfg['Servers'][\$i]['controlpass'] = 'Abc123xyz';\n" >"$PMA_DIR/config.inc.php"
  run pma_controlpass_from_config
  [ "$output" = "Abc123xyz" ]
}

@test "pma_install_tree conserva la configurazione e toglie setup" {
  mkdir -p "$PMA_DIR" "$VPS_OPT/new/setup" "$VPS_OPT/new/libraries"
  echo vecchia >"$PMA_DIR/config.inc.php"
  echo nuovo >"$VPS_OPT/new/index.php"
  pma_install_tree "$VPS_OPT/new"
  [ "$(cat "$PMA_DIR/config.inc.php")" = vecchia ]
  [ "$(cat "$PMA_DIR/index.php")" = nuovo ]
  [ ! -d "$PMA_DIR/setup" ]
  [ ! -d "$PMA_DIR.old" ]
  [ "$(stat -c %a "$PMA_DIR/index.php")" = "640" ]
}

@test "pma_verify_sig accetta solo il firmatario atteso e file integri" {
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'PMA Test <pma@example.com>' ed25519 sign never
  local fpr
  fpr="$(gpg --batch --with-colons --list-keys pma@example.com | awk -F: '$1=="fpr"{print $10; exit}')"
  gpg --batch --export pma@example.com >"$BATS_TEST_TMPDIR/keyring"
  echo contenuto >"$BATS_TEST_TMPDIR/pma.tar.xz"
  gpg --batch --quiet --armor --detach-sign -o "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/pma.tar.xz"
  PMA_SIGNER_FPRS=("$fpr")
  pma_verify_sig "$BATS_TEST_TMPDIR/pma.tar.xz" "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/keyring"
  PMA_SIGNER_FPRS=(0000000000000000000000000000000000000000)
  run pma_verify_sig "$BATS_TEST_TMPDIR/pma.tar.xz" "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/keyring"
  [ "$status" -ne 0 ]
  PMA_SIGNER_FPRS=("$fpr")
  echo manomesso >>"$BATS_TEST_TMPDIR/pma.tar.xz"
  run pma_verify_sig "$BATS_TEST_TMPDIR/pma.tar.xz" "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/keyring"
  [ "$status" -ne 0 ]
}
