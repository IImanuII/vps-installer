setup() {
  load test_helper
}

@test "install.sh contiene i segnaposto della release" {
  grep -q '^VPS_VERSION="__VERSION__"$' "$BATS_TEST_DIRNAME/../install.sh"
  grep -q '^TARBALL_SHA256="__TARBALL_SHA256__"$' "$BATS_TEST_DIRNAME/../install.sh"
  grep -q '^REPO="__REPO__"$' "$BATS_TEST_DIRNAME/../install.sh"
}

@test "il workflow controlla che il tag corrisponda alla versione" {
  grep -q 'VPS_INSTALLER_VERSION' "$BATS_TEST_DIRNAME/../.github/workflows/release.yml"
}

@test "l'archivio di release esclude test e documentazione" {
  grep -qxF '/tests export-ignore' "$BATS_TEST_DIRNAME/../.gitattributes"
  grep -qxF '/docs export-ignore' "$BATS_TEST_DIRNAME/../.gitattributes"
}
