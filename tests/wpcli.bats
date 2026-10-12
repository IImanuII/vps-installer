setup() {
  load test_helper
  setup_common
  export WP_BIN="$BATS_TEST_TMPDIR/wp" WPCLI_API="file://$BATS_TEST_TMPDIR/api/latest"
  mkdir -p "$BATS_TEST_TMPDIR/api/dl"
  echo '#!/usr/bin/env php' >"$BATS_TEST_TMPDIR/api/dl/wp-cli-2.12.0.phar"
  sha512sum "$BATS_TEST_TMPDIR/api/dl/wp-cli-2.12.0.phar" | cut -d' ' -f1 >"$BATS_TEST_TMPDIR/api/dl/wp-cli-2.12.0.phar.sha512"
  jq -n --arg u "file://$BATS_TEST_TMPDIR/api/dl" '{tag_name:"v2.12.0", assets:[{name:"wp-cli-2.12.0.phar", browser_download_url:($u+"/wp-cli-2.12.0.phar")},{name:"wp-cli-2.12.0.phar.sha512", browser_download_url:($u+"/wp-cli-2.12.0.phar.sha512")}]}' >"$BATS_TEST_TMPDIR/api/latest"
}

@test "wpcli_install scarica, verifica e installa 755" {
  wpcli_install
  [ "$(stat -c %a "$WP_BIN")" = 755 ]
  grep -q 'env php' "$WP_BIN"
}

@test "wpcli_install rifiuta un hash sbagliato e lascia il WP-CLI precedente" {
  echo vecchio >"$WP_BIN"
  echo 0000 >"$BATS_TEST_TMPDIR/api/dl/wp-cli-2.12.0.phar.sha512"
  run wpcli_install
  [ "$status" -ne 0 ]
  [ "$(cat "$WP_BIN")" = vecchio ]
  [ ! -e "$WP_BIN.new" ]
}

@test "wpcli_install fallisce se la release non ha i file attesi" {
  echo '{"tag_name":"v1","assets":[]}' >"$BATS_TEST_TMPDIR/api/latest"
  run wpcli_install
  [ "$status" -ne 0 ]
  [ ! -e "$WP_BIN" ]
}
