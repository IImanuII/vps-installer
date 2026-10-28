bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
}

@test "site_vhost_add php senza regole a mano: cornice di prima" {
  site_reg_new miosito.it php no no
  site_vhost_add miosito.it
  f="$NGINX_CONF_D/miosito.it.conf"
  grep -q "access_log $SITES_WWW/miosito.it/logs/access.log main;" "$f"
  run grep -c vps-custom "$f"
  [ "$output" = 0 ]
}

@test "site_vhost_add php con regole a mano: include, access_log nel file del sito" {
  site_reg_new miosito.it php no no
  site_reg_update miosito.it '.custom_rules = true'
  site_vhost_add miosito.it
  f="$NGINX_CONF_D/miosito.it.conf"
  grep -qx "    include $NGINX_CUSTOM_D/miosito.it.conf;" "$f"
  [ "$(grep -n "include $NGINX_CUSTOM_D/miosito.it.http.conf;" "$f" | cut -d: -f1)" -lt "$(grep -n '^server {' "$f" | head -1 | cut -d: -f1)" ]
  run grep -c access_log "$f"
  [ "$output" = 0 ]
  grep -q 'error_log ' "$f"
  run grep -c fastcgi_pass "$f"
  [ "$output" = 0 ]
  c="$NGINX_CUSTOM_D/miosito.it.conf"
  [ "$(grep -v '^\s*#' "$c" | grep -v '^\s*$' | head -1)" = "access_log $SITES_WWW/miosito.it/logs/access.log main;" ]
  grep -q "fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm-site_miosito_it.sock;" "$c"
  grep -q 'try_files $uri $uri/ /index.php?$query_string;' "$c"
  [ "$(stat -c %a "$c")" = 644 ]
  [ "$(stat -c %a "$NGINX_CUSTOM_D")" = 755 ]
  [ "$(grep -v '^\s*#' "$NGINX_CUSTOM_D/miosito.it.http.conf" | grep -cv '^\s*$')" = 0 ]
}

@test "site_custom_files_add non riscrive file esistenti" {
  site_reg_new miosito.it php no no
  site_reg_update miosito.it '.custom_rules = true'
  mkdir -p "$NGINX_CUSTOM_D"
  printf '# mio\n' >"$NGINX_CUSTOM_D/miosito.it.conf"
  site_vhost_add miosito.it
  site_vhost_add miosito.it
  [ "$(cat "$NGINX_CUSTOM_D/miosito.it.conf")" = "# mio" ]
  [ -f "$NGINX_CUSTOM_D/miosito.it.http.conf" ]
}

@test "maintenance con regole a mano: nessun include, access_log nella cornice" {
  site_reg_new miosito.it php no no
  site_reg_update miosito.it '.custom_rules = true'
  site_vhost_add miosito.it maintenance
  f="$NGINX_CONF_D/miosito.it.conf"
  run grep -c vps-custom "$f"
  [ "$output" = 0 ]
  grep -q "access_log $SITES_WWW/miosito.it/logs/access.log main;" "$f"
}

@test "regole a mano ignorate su static e wordpress" {
  for t in static wordpress; do
    site_reg_new "$t.miosito.it" "$t" no no
    site_reg_update "$t.miosito.it" '.custom_rules = true'
    site_vhost_add "$t.miosito.it"
    run grep -c vps-custom "$NGINX_CONF_D/$t.miosito.it.conf"
    [ "$output" = 0 ]
  done
  [ ! -e "$NGINX_CUSTOM_D" ]
}

@test "nginx -t fallito con regole a mano: vhost di prima, file a mano intatti" {
  site_reg_new miosito.it php no no
  site_vhost_add miosito.it
  cp "$NGINX_CONF_D/miosito.it.conf" "$BATS_TEST_TMPDIR/prima"
  site_reg_update miosito.it '.custom_rules = true'
  mkdir -p "$NGINX_CUSTOM_D"
  printf '# mio\n' >"$NGINX_CUSTOM_D/miosito.it.conf"
  export STUB_RC_nginx=1 SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_vhost_add miosito.it
  [ "$status" -eq 1 ]
  cmp "$NGINX_CONF_D/miosito.it.conf" "$BATS_TEST_TMPDIR/prima"
  [ "$(cat "$NGINX_CUSTOM_D/miosito.it.conf")" = "# mio" ]
}
