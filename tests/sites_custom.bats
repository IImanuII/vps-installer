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
  [ "$(stat -c %a "$NGINX_CUSTOM_D")" = 750 ]
  [ "$(grep -v '^\s*#' "$NGINX_CUSTOM_D/miosito.it.http.conf" | grep -cv '^\s*$')" = 0 ]
}

@test "site_custom_files_add: la cartella diventa 750 anche se esisteva con 755" {
  site_reg_new miosito.it php no no
  site_reg_update miosito.it '.custom_rules = true'
  mkdir -p "$NGINX_CUSTOM_D"
  chmod 755 "$NGINX_CUSTOM_D"
  site_vhost_add miosito.it
  [ "$(stat -c %a "$NGINX_CUSTOM_D")" = 750 ]
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

@test "cartella delle regole non creabile: errore chiaro, vhost di prima" {
  site_reg_new miosito.it php no no
  site_vhost_add miosito.it
  cp "$NGINX_CONF_D/miosito.it.conf" "$BATS_TEST_TMPDIR/prima"
  site_reg_update miosito.it '.custom_rules = true'
  printf 'file\n' >"$NGINX_CUSTOM_D"
  export SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_vhost_add miosito.it
  [ "$status" -eq 1 ]
  [[ "$(cat "$SITE_ERROR_FILE")" == "file delle regole a mano di miosito.it non scritti (dettagli in $VPS_LOG)" ]]
  cmp "$NGINX_CONF_D/miosito.it.conf" "$BATS_TEST_TMPDIR/prima"
}

@test "site_custom_files_add non tocca un link spezzato al posto del file" {
  site_reg_new miosito.it php no no
  site_reg_update miosito.it '.custom_rules = true'
  mkdir -p "$NGINX_CUSTOM_D"
  ln -s /non/esiste "$NGINX_CUSTOM_D/miosito.it.conf"
  ln -s /non/esiste "$NGINX_CUSTOM_D/miosito.it.http.conf"
  site_vhost_add miosito.it
  [ "$(readlink "$NGINX_CUSTOM_D/miosito.it.conf")" = /non/esiste ]
  [ "$(readlink "$NGINX_CUSTOM_D/miosito.it.http.conf")" = /non/esiste ]
}

@test "site_run delete: via file delle regole, .cron-da-rivedere e cron del sito" {
  site_reg_new blog.miosito.it php no no
  site_run create blog.miosito.it
  mkdir -p "$NGINX_CUSTOM_D"
  for f in blog.miosito.it.conf blog.miosito.it.http.conf blog.miosito.it.cron-da-rivedere; do
    echo x >"$NGINX_CUSTOM_D/$f"
  done
  echo x >"$CRON_D/vps-site-site_blog_miosito_it-backup"
  site_reg_update blog.miosito.it '.prev_state = .state | .state = "deleting"'
  site_run delete blog.miosito.it
  run ! site_reg_exists blog.miosito.it
  [ -z "$(ls -A "$NGINX_CUSTOM_D")" ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it-backup" ]
}

@test "site_custom_remove: solo i file del sito, mai quelli di uno slug simile" {
  site_reg_new blog.miosito.it php no no
  mkdir -p "$NGINX_CUSTOM_D" "$CRON_D"
  for f in vps-site-site_blog_miosito_it-cron vps-site-site_blog_miosito_it-backup \
    vps-site-site_blog_miosito_it_x-cron vps-site-site_blog_miosito_itx vps-site-site_blog_miosito_it; do
    echo x >"$CRON_D/$f"
  done
  echo x >"$NGINX_CUSTOM_D/blog.miosito.it.conf"
  echo x >"$NGINX_CUSTOM_D/altro.it.conf"
  echo x >"$NGINX_CUSTOM_D/altro.it.http.conf"
  site_custom_remove blog.miosito.it
  [ ! -e "$NGINX_CUSTOM_D/blog.miosito.it.conf" ]
  [ -f "$NGINX_CUSTOM_D/altro.it.conf" ]
  [ -f "$NGINX_CUSTOM_D/altro.it.http.conf" ]
  # restano il cron di WordPress e quelli di slug più lunghi; via i due del sito
  [ -f "$CRON_D/vps-site-site_blog_miosito_it" ]
  [ -f "$CRON_D/vps-site-site_blog_miosito_it_x-cron" ]
  [ -f "$CRON_D/vps-site-site_blog_miosito_itx" ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it-cron" ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it-backup" ]
}

@test "site_custom_remove: slug estraneo rifiutato" {
  site_reg_new blog.miosito.it php no no
  site_reg_update blog.miosito.it '.slug = "x*"'
  mkdir -p "$NGINX_CUSTOM_D" "$CRON_D"
  echo x >"$NGINX_CUSTOM_D/blog.miosito.it.conf"
  echo x >"$CRON_D/vps-site-x-cron"
  run site_custom_remove blog.miosito.it
  [ "$status" -eq 1 ]
  [ -f "$NGINX_CUSTOM_D/blog.miosito.it.conf" ]
  [ -f "$CRON_D/vps-site-x-cron" ]
}

@test "site_run delete: vhost non tolto, file delle regole lasciati e sito in errore" {
  site_reg_new blog.miosito.it php no no
  site_run create blog.miosito.it
  mkdir -p "$NGINX_CUSTOM_D"
  echo x >"$NGINX_CUSTOM_D/blog.miosito.it.conf"
  site_vhost_remove() { return 1; }
  site_reg_update blog.miosito.it '.prev_state = .state | .state = "deleting"'
  run site_run delete blog.miosito.it
  [ "$status" -eq 1 ]
  [ -f "$NGINX_CUSTOM_D/blog.miosito.it.conf" ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"regole Nginx a mano"* ]]
}
