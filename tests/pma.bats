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

# Prepara fixture in $FIX: archivio tar.xz, .sha256, .asc e keyring per la versione 9.9.9.
make_pma_fixtures() {
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'PMA Test <pma@example.com>' ed25519 sign never
  PMA_FPR="$(gpg --batch --with-colons --list-keys pma@example.com | awk -F: '$1=="fpr"{print $10; exit}')"
  FIX="$BATS_TEST_TMPDIR/fix"
  W="$BATS_TEST_TMPDIR/work"
  mkdir -p "$FIX" "$W" "$BATS_TEST_TMPDIR/src/phpMyAdmin-9.9.9-all-languages"
  echo nuovo >"$BATS_TEST_TMPDIR/src/phpMyAdmin-9.9.9-all-languages/index.php"
  tar -cJf "$FIX/phpMyAdmin-9.9.9-all-languages.tar.xz" -C "$BATS_TEST_TMPDIR/src" phpMyAdmin-9.9.9-all-languages
  (cd "$FIX" && sha256sum phpMyAdmin-9.9.9-all-languages.tar.xz >phpMyAdmin-9.9.9-all-languages.tar.xz.sha256)
  gpg --batch --quiet --armor --detach-sign -o "$FIX/phpMyAdmin-9.9.9-all-languages.tar.xz.asc" "$FIX/phpMyAdmin-9.9.9-all-languages.tar.xz"
  gpg --batch --export pma@example.com >"$FIX/phpmyadmin.keyring"
  export FIX
  make_stub curl 'out=; url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
cp "$FIX/$(basename "$url")" "$out"'
}

@test "pma_fetch estrae un archivio integro e firmato dal firmatario atteso" {
  make_pma_fixtures
  PMA_SIGNER_FPRS=("$PMA_FPR")
  run pma_fetch 9.9.9 "$W"
  [ "$status" -eq 0 ]
  [ -f "$W/phpMyAdmin-9.9.9-all-languages/index.php" ]
}

@test "pma_fetch rifiuta un archivio manomesso o con sha256 sbagliato" {
  make_pma_fixtures
  PMA_SIGNER_FPRS=("$PMA_FPR")
  echo manomesso >>"$FIX/phpMyAdmin-9.9.9-all-languages.tar.xz"
  run pma_fetch 9.9.9 "$W"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHA256"* ]]
  [ ! -e "$W/phpMyAdmin-9.9.9-all-languages" ]
}

@test "pma_fetch rifiuta una firma di un firmatario non fidato anche con sha256 valido" {
  make_pma_fixtures
  PMA_SIGNER_FPRS=(0000000000000000000000000000000000000000)
  run pma_fetch 9.9.9 "$W"
  [ "$status" -ne 0 ]
  [[ "$output" == *"firma GPG"* ]]
  [ ! -e "$W/phpMyAdmin-9.9.9-all-languages" ]
}

@test "pma_install_tree ripristina PMA_DIR.old se PMA_DIR manca" {
  mkdir -p "$PMA_DIR.old" "$VPS_OPT/new"
  echo vecchia >"$PMA_DIR.old/config.inc.php"
  echo nuovo >"$VPS_OPT/new/index.php"
  pma_install_tree "$VPS_OPT/new"
  [ "$(cat "$PMA_DIR/config.inc.php")" = vecchia ]
  [ "$(cat "$PMA_DIR/index.php")" = nuovo ]
  [ ! -d "$PMA_DIR.old" ]
}

pma_web_env() {
  source "$REPO_ROOT/steps/90-phpmyadmin.sh"
  export HTPASSWD_PMA="$BATS_TEST_TMPDIR/htpasswd" NGINX_SNIPPETS="$BATS_TEST_TMPDIR/snippets"
  mkdir -p "$NGINX_SNIPPETS/panel.d"
  ADMIN_USER=manu
  make_stub htpasswd 'printf "%s:%s\n" "$5" "$(cat)" >"$4"'
  make_stub nginx 'exit 0'
  make_stub systemctl 'exit 0'
}

@test "pma_web_access: senza password nel riepilogo ne genera una e sovrascrive l'htpasswd" {
  pma_web_env
  echo 'manu:vecchia-sconosciuta' >"$HTPASSWD_PMA"
  pma_web_access
  local pass
  pass="$(summary_get PMA_BASIC_PASS)"
  [ "${#pass}" -eq 20 ]
  [ "$(cat "$HTPASSWD_PMA")" = "manu:$pass" ]
  [ -f "$NGINX_SNIPPETS/panel.d/pma.conf" ]
}

@test "pma_web_access: riusa la password già nel riepilogo" {
  pma_web_env
  summary_set PMA_BASIC_PASS 'Gia-Salvata-123'
  pma_web_access
  [ "$(cat "$HTPASSWD_PMA")" = "manu:Gia-Salvata-123" ]
  [ "$(grep -c PMA_BASIC_PASS "$VPS_ROOT/summary.env")" -eq 1 ]
}

@test "pma_web_access: se htpasswd fallisce la password è già nel riepilogo" {
  pma_web_env
  make_stub htpasswd 'exit 1'
  # Come nello step reale: set -e attivo.
  run bash -c 'set -Eeuo pipefail
    for f in "$REPO_ROOT"/lib/*.sh; do source "$f"; done
    source "$REPO_ROOT/steps/90-phpmyadmin.sh"
    ADMIN_USER=manu pma_web_access'
  [ "$status" -ne 0 ]
  [ ! -f "$NGINX_SNIPPETS/panel.d/pma.conf" ]
  [ -n "$(summary_get PMA_BASIC_PASS)" ]
}

@test "pma_update_to rimuove la cartella di lavoro anche se il download fallisce" {
  make_stub curl 'exit 22'
  run pma_update_to 9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"aggiornamento non riuscito"* ]]
  run compgen -G "$VPS_OPT/.pma.*"
  [ "$status" -ne 0 ]
  [ ! -e "$PMA_DIR" ]
}

@test "pma_update_to installa e rimuove la cartella di lavoro" {
  make_pma_fixtures
  PMA_SIGNER_FPRS=("$PMA_FPR")
  manifest_group() { id -gn; }
  pma_update_to 9.9.9
  [ "$(cat "$PMA_DIR/index.php")" = nuovo ]
  run compgen -G "$VPS_OPT/.pma.*"
  [ "$status" -ne 0 ]
}

@test "pma_controlpass_from_config senza config non fallisce in modalità rigida" {
  run bash -c "set -Eeuo pipefail; export VPS_OPT='$VPS_OPT' VPS_LOG='$VPS_LOG' PMA_DIR='$BATS_TEST_TMPDIR/nessuno'; for f in '$REPO_ROOT'/lib/*.sh; do source \"\$f\"; done; p=\"\$(pma_controlpass_from_config)\"; echo \"[\$p]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
