setup() {
  load test_helper
  setup_common
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Test Repo <repo@example.com>' ed25519 sign never
  gpg --batch --armor --export repo@example.com >"$BATS_TEST_TMPDIR/key.asc"
  FPR="$(gpg --batch --with-colons --list-keys repo@example.com | awk -F: '$1=="fpr"{print $10; exit}')"
}

@test "gpg_primary_fprs restituisce il fingerprint" {
  run gpg_primary_fprs "$BATS_TEST_TMPDIR/key.asc"
  [ "$output" = "$FPR" ]
}

@test "gpg_keyring_install accetta una chiave attesa e la converte in binario" {
  gpg_keyring_install "$BATS_TEST_TMPDIR/key.asc" "$BATS_TEST_TMPDIR/repo.gpg" AAAA "$FPR"
  [ -f "$BATS_TEST_TMPDIR/repo.gpg" ]
  ! grep -q 'BEGIN PGP' "$BATS_TEST_TMPDIR/repo.gpg"
  run gpg_primary_fprs "$BATS_TEST_TMPDIR/repo.gpg"
  [ "$output" = "$FPR" ]
}

@test "gpg_keyring_install rifiuta una chiave inattesa" {
  run gpg_keyring_install "$BATS_TEST_TMPDIR/key.asc" "$BATS_TEST_TMPDIR/repo.gpg" 0000000000000000000000000000000000000000
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/repo.gpg" ]
}

@test "gpg_keyring_install rifiuta un file che non è una chiave" {
  echo "<html>errore</html>" >"$BATS_TEST_TMPDIR/bad.asc"
  run gpg_keyring_install "$BATS_TEST_TMPDIR/bad.asc" "$BATS_TEST_TMPDIR/repo.gpg" "$FPR"
  [ "$status" -eq 1 ]
}
