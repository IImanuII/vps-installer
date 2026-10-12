bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
}

@test "validazione WordPress: titolo, utente, email, percorso" {
  site_wp_valid_title "Il mio blog"
  run ! site_wp_valid_title ""
  run ! site_wp_valid_title "$(printf 'x%.0s' {1..101})"
  run ! site_wp_valid_title $'due\nrighe'
  site_wp_valid_user gestore
  run ! site_wp_valid_user admin
  run ! site_wp_valid_user root
  run ! site_wp_valid_user "Ab"
  run ! site_wp_valid_user "a b"
  site_wp_valid_email "io@miosito.it"
  run ! site_wp_valid_email "io@miosito"
  run ! site_wp_valid_email "io miosito.it"
  site_wp_valid_path accesso-7k2f
  run ! site_wp_valid_path wp-admin
  run ! site_wp_valid_path login
  run ! site_wp_valid_path "acc"
  run ! site_wp_valid_path "Accesso"
}

@test "site_placeholder_intact: solo il segnaposto con il marcatore" {
  site_reg_new blog.miosito.it php no yes
  site_user_add blog.miosito.it
  site_placeholder_intact blog.miosito.it
  echo x >"$SITES_WWW/blog.miosito.it/public/altro.html"
  run ! site_placeholder_intact blog.miosito.it
  rm "$SITES_WWW/blog.miosito.it/public/altro.html"
  echo '<h1>mio</h1>' >"$SITES_WWW/blog.miosito.it/public/index.html"
  run ! site_placeholder_intact blog.miosito.it
}

@test "site_wp_config_write: fuori dalla webroot, 640, chiavi diverse, variabili PHP intatte" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_WWW/blog.miosito.it/public"
  site_wp_config_write blog.miosito.it 'Password-db-1234567890' 'Password-redis-1234567890'
  f="$SITES_WWW/blog.miosito.it/wp-config.php"
  [ "$(stat -c %a "$f")" = 640 ]
  grep -q "define( 'DB_PASSWORD', 'Password-db-1234567890' );" "$f"
  grep -q "define( 'WP_REDIS_USERNAME', 'site_blog_miosito_it' );" "$f"
  grep -q "define( 'WP_REDIS_PREFIX', 'site_blog_miosito_it:' );" "$f"
  grep -q "define( 'WP_HOME', 'https://blog.miosito.it' );" "$f"
  grep -q '\$table_prefix = '"'"'wp_'"'"';' "$f"
  grep -q "\$_SERVER\['HTTPS'\] = 'on';" "$f"
  [ "$(grep -c "_KEY',\|_SALT'," "$f")" = 8 ]
  [ "$(grep -o "_\(KEY\|SALT\)', *'[^']*'" "$f" | sort -u | wc -l)" = 8 ]
  run ! grep -q '\${' "$f"
}

@test "site_wp_config_set_db_password cambia solo la riga della password" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_WWW/blog.miosito.it/public"
  site_wp_config_write blog.miosito.it 'Password-db-1234567890' 'Password-redis-1234567890'
  before="$(grep -v DB_PASSWORD "$SITES_WWW/blog.miosito.it/wp-config.php")"
  site_wp_config_set_db_password blog.miosito.it 'Nuova&pass|word/12345'
  grep -q "define( 'DB_PASSWORD', 'Nuova&pass|word/12345' );" "$SITES_WWW/blog.miosito.it/wp-config.php"
  [ "$(grep -v DB_PASSWORD "$SITES_WWW/blog.miosito.it/wp-config.php")" = "$before" ]
}

@test "utente Redis: riga ACL aggiunta e tolta in modo atomico, ACL LOAD con la password nell'ambiente" {
  site_reg_new blog.miosito.it wordpress no yes
  site_redis_user_add blog.miosito.it 'Password-redis-1234567890'
  h="$(printf %s 'Password-redis-1234567890' | sha256sum | cut -d' ' -f1)"
  grep -qx "user site_blog_miosito_it on #$h ~site_blog_miosito_it:\* &site_blog_miosito_it:\* +@all -@dangerous -@admin +info" "$REDIS_ACL_FILE"
  grep -qx 'user default off' "$REDIS_ACL_FILE"
  grep -q '^redis-cli --user vps-admin ACL LOAD auth=si' "$CALLS"
  run grep -c 'Password-redis' "$CALLS"
  [ "$output" = 0 ]
  site_redis_user_add blog.miosito.it 'Altra-password-redis-123456'
  [ "$(grep -c '^user site_blog_miosito_it ' "$REDIS_ACL_FILE")" = 1 ]
  site_redis_user_remove blog.miosito.it
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
  grep -qx 'user default off' "$REDIS_ACL_FILE"
}

@test "utente Redis: ACL LOAD che fallisce rimette il file di prima" {
  site_reg_new blog.miosito.it wordpress no yes
  cp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/prima"
  export STUB_RC_redis_cli=1 SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_redis_user_add blog.miosito.it 'Password-redis-1234567890'
  [ "$status" -eq 1 ]
  cmp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/prima"
  [[ "$(cat "$SITE_ERROR_FILE")" == *Redis* ]]
}

@test "cron di WordPress come utente del sito" {
  site_reg_new blog.miosito.it wordpress no yes
  site_wp_cron_add blog.miosito.it
  f="$CRON_D/vps-site-site_blog_miosito_it"
  grep -q "^\*/5 \* \* \* \* site_blog_miosito_it $WP_BIN --path=$SITES_WWW/blog.miosito.it/public cron event run --due-now --quiet" "$f"
  site_wp_cron_remove blog.miosito.it
  [ ! -e "$f" ]
}

@test "site_wp esegue WP-CLI come utente del sito con cache in tmp/" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_WWW/blog.miosito.it/tmp"
  site_wp blog.miosito.it option get siteurl
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
  grep -q "^wp --path=$SITES_WWW/blog.miosito.it/public option get siteurl" "$CALLS"
}

@test "il vhost wordpress blocca xmlrpc e PHP negli upload" {
  site_reg_new blog.miosito.it wordpress no yes
  site_vhost_add blog.miosito.it
  f="$NGINX_CONF_D/blog.miosito.it.conf"
  grep -q 'location = /xmlrpc.php' "$f"
  grep -qF 'location ~* /(?:uploads|files)/.*\.php$' "$f"
  grep -q 'try_files $uri $uri/ /index.php?$args;' "$f"
  grep -q "fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm-site_blog_miosito_it.sock;" "$f"
}
