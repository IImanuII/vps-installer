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
  grep -q "define( 'WP_REDIS_MAXTTL', 604800 );" "$f"
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
  grep -qx "user site_blog_miosito_it on #$h ~site_blog_miosito_it:\* &site_blog_miosito_it:\* +@all -@dangerous -@admin +info -script|kill -script|flush -function" "$REDIS_ACL_FILE"
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

@test "utente Redis: le chiavi del prefisso si cancellano prima di aggiungerlo e quando si toglie" {
  # Un sito ricreato con lo stesso dominio ha lo stesso prefisso: senza svuotarlo
  # WordPress leggerebbe dalla cache le opzioni del sito eliminato (visto nell'E2E).
  site_reg_new blog.miosito.it wordpress no yes
  site_redis_user_add blog.miosito.it 'Password-redis-1234567890'
  ev="$(grep -n 'EVAL .*SCAN.*UNLINK.* 0 site_blog_miosito_it:\* auth=si' "$CALLS" | cut -d: -f1)"
  acl="$(grep -n 'ACL LOAD' "$CALLS" | cut -d: -f1)"
  [ -n "$ev" ] && [ -n "$acl" ] && [ "$ev" -lt "$acl" ]
  : >"$CALLS"
  site_redis_user_remove blog.miosito.it
  grep -q 'EVAL .* 0 site_blog_miosito_it:\* auth=si' "$CALLS"
}

@test "utente Redis: cache non svuotabile, l'utente non si aggiunge" {
  site_reg_new blog.miosito.it wordpress no yes
  cp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/prima"
  export STUB_RC_redis_cli=1 SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_redis_user_add blog.miosito.it 'Password-redis-1234567890'
  [ "$status" -eq 1 ]
  cmp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/prima"
  run grep -c 'ACL LOAD' "$CALLS"
  [ "$output" = 0 ]
}

@test "utente Redis: un sito PHP eliminato non tocca Redis" {
  site_reg_new blog.miosito.it php no yes
  : >"$CALLS"
  site_redis_user_remove blog.miosito.it
  run grep -c redis-cli "$CALLS"
  [ "$output" = 0 ]
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

@test "il vhost wordpress: SAMEORIGIN al posto di DENY, burst 60, regola per i file statici" {
  site_reg_new blog.miosito.it wordpress no yes
  site_vhost_add blog.miosito.it
  f="$NGINX_CONF_D/blog.miosito.it.conf"
  grep -qF 'add_header X-Frame-Options "SAMEORIGIN" always;' "$f"
  grep -qF 'add_header Strict-Transport-Security "max-age=63072000" always;' "$f"
  grep -qF 'add_header X-Content-Type-Options "nosniff" always;' "$f"
  grep -qF 'add_header Referrer-Policy "strict-origin-when-cross-origin" always;' "$f"
  run grep -c 'DENY\|security-headers.conf' "$f"
  [ "$output" = 0 ]
  grep -qF '    limit_req zone=req_limit_per_ip burst=60 nodelay;' "$f"
  grep -qF 'location ~* \.(?:css|js|mjs|map|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot)$' "$f"
  grep -qF 'limit_req zone=req_limit_per_ip burst=200 nodelay;' "$f"
  grep -qF 'expires 30d;' "$f"
}

@test "i vhost non wordpress restano con le intestazioni comuni e burst 20" {
  for t in php static; do
    site_reg_new "$t.miosito.it" "$t" no no
    site_vhost_add "$t.miosito.it"
    f="$NGINX_CONF_D/$t.miosito.it.conf"
    grep -qF 'include /etc/nginx/snippets/security-headers.conf;' "$f"
    grep -qF '    limit_req zone=req_limit_per_ip burst=20 nodelay;' "$f"
    run grep -c SAMEORIGIN "$f"
    [ "$output" = 0 ]
  done
}

@test "wp-config: password con apice rifiutata, nessun file scritto / file invariato" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_WWW/blog.miosito.it/public"
  f="$SITES_WWW/blog.miosito.it/wp-config.php"
  export SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run ! site_wp_config_write blog.miosito.it "Password'db-1234567890" 'Password-redis-1234567890'
  run ! site_wp_config_write blog.miosito.it 'Password-db-1234567890' "Password'redis-1234567890"
  [ ! -e "$f" ]
  site_wp_config_write blog.miosito.it 'Password-db-1234567890' 'Password-redis-1234567890'
  cp "$f" "$BATS_TEST_TMPDIR/prima"
  run ! site_wp_config_set_db_password blog.miosito.it "Nuova'pass-1234567890"
  cmp "$f" "$BATS_TEST_TMPDIR/prima"
}

@test "set_db_password: riga DB_PASSWORD mancante = errore e file intatto" {
  site_reg_new blog.miosito.it wordpress no yes
  f="$SITES_WWW/blog.miosito.it/wp-config.php"
  mkdir -p "$SITES_WWW/blog.miosito.it"
  printf '<?php\n// niente\n' >"$f"
  cp "$f" "$BATS_TEST_TMPDIR/prima"
  export SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run ! site_wp_config_set_db_password blog.miosito.it 'Nuova-password-1234567890'
  cmp "$f" "$BATS_TEST_TMPDIR/prima"
  [[ "$(cat "$SITE_ERROR_FILE")" == *DB_PASSWORD* ]]
}

@test "site_wp_config_write non lascia i segreti esportati" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_WWW/blog.miosito.it/public"
  site_wp_config_write blog.miosito.it 'Password-db-1234567890' 'Password-redis-1234567890'
  run bash -c 'echo "${WP_DB_PASSWORD:-}${WP_REDIS_PASSWORD:-}${WP_KEY1:-}"'
  [ -z "$output" ]
}

@test "site_placeholder_intact: index.html symlink rifiutato" {
  site_reg_new blog.miosito.it php no yes
  site_user_add blog.miosito.it
  pub="$SITES_WWW/blog.miosito.it/public"
  mv "$pub/index.html" "$BATS_TEST_TMPDIR/vero.html"
  ln -s "$BATS_TEST_TMPDIR/vero.html" "$pub/index.html"
  run ! site_placeholder_intact blog.miosito.it
}

@test "validatori WordPress: lunghezze in byte" {
  site_wp_valid_title "$(printf 'è%.0s' {1..34})"
  run ! site_wp_valid_title "$(printf 'è%.0s' {1..51})"
}

@test "utente Redis: togliere a.miosito.it lascia la riga di ab.miosito.it" {
  site_reg_new a.miosito.it wordpress no yes
  site_reg_new ab.miosito.it wordpress no yes
  site_redis_user_add a.miosito.it 'Password-redis-1234567890'
  site_redis_user_add ab.miosito.it 'Password-redis-1234567891'
  site_redis_user_remove a.miosito.it
  [ "$(grep -c '^user site_ab_miosito_it ' "$REDIS_ACL_FILE")" = 1 ]
  run grep -c '^user site_a_miosito_it ' "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
}

# Prepara i file di passaggio come li lascia `vps-site` (task 3).
wp_args() { # DOMINIO [cloudflare true|false]
  local slug; slug="$(site_slug "$1")"
  mkdir -p "$SITES_RUN"
  jq -n --arg cf "${2:-false}" '{title:"Il blog", admin_user:"gestore", admin_email:"io@miosito.it", login_path:"accesso-7k2f", cloudflare:($cf=="true")}' >"$SITES_RUN/$slug.wpargs"
  printf '%s' 'Password-admin-wp-12345' >"$SITES_RUN/$slug.wppass"
}

@test "creazione WordPress: tutti i passi, credenziali solo su stdin, file di passaggio cancellati" {
  site_reg_new blog.miosito.it wordpress no yes
  printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass" 2>/dev/null || { mkdir -p "$SITES_RUN"; printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass"; }
  wp_args blog.miosito.it
  site_run create blog.miosito.it
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ "$(site_reg_get blog.miosito.it .wordpress.login_path)" = accesso-7k2f ]
  [ "$(site_reg_get blog.miosito.it .wordpress.admin_user)" = gestore ]
  grep -q 'wp --path=.* core download --locale=it_IT' "$CALLS"
  grep -q 'wp --path=.* core install --url=https://blog.miosito.it --title=Il blog --admin_user=gestore --admin_email=io@miosito.it --skip-email --locale=it_IT --prompt=admin_password' "$CALLS"
  grep -q 'Password-admin-wp-12345' "$BATS_TEST_TMPDIR/wp.stdin"
  run grep -c 'Password-admin-wp-12345\|Password-db-1234567890' "$CALLS"
  [ "$output" = 0 ]
  # WP-CLI con --prompt ristampa la password: nel registro arriva nascosta.
  run grep -c 'Password-admin-wp-12345\|Password-db-1234567890' "$VPS_LOG"
  [ "$output" = 0 ]
  grep -qF -- '--admin_password=<password nascosta>' "$VPS_LOG"
  grep -q 'wp --path=.* plugin install wps-hide-login redis-cache --activate' "$CALLS"
  grep -q 'wp --path=.* option update whl_page accesso-7k2f' "$CALLS"
  # permalink belli: senza, /wp-login.php finisce sulla home con 200 invece di 404
  grep -q 'wp --path=.* rewrite structure /%postname%/' "$CALLS"
  # drop-in copiato a mano: `wp redis enable` fa FLUSHDB, vietato all'utente ACL del sito
  run grep -c 'redis enable' "$CALLS"
  [ "$output" = 0 ]
  grep -q 'drop-in' "$SITES_WWW/blog.miosito.it/public/wp-content/object-cache.php"
  grep -q 'wp --path=.* redis status' "$CALLS"
  grep -q 'wp --path=.* plugin auto-updates enable --all' "$CALLS"
  run grep -c 'plugin install cloudflare' "$CALLS"
  [ "$output" = 0 ]
  [ -f "$SITES_WWW/blog.miosito.it/wp-config.php" ]
  [ -f "$CRON_D/vps-site-site_blog_miosito_it" ]
  grep -q '^user site_blog_miosito_it ' "$REDIS_ACL_FILE"
  grep -q 'location = /xmlrpc.php' "$NGINX_CONF_D/blog.miosito.it.conf"
  [ -z "$(ls "$SITES_RUN")" ]
}

@test "creazione WordPress con il plugin Cloudflare" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_RUN"; printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass"
  wp_args blog.miosito.it true
  site_run create blog.miosito.it
  grep -q 'wp --path=.* plugin install cloudflare --activate' "$CALLS"
  [ "$(site_reg_get blog.miosito.it .wordpress.cloudflare_plugin)" = true ]
}

@test "creazione WordPress: download fallito, si annulla tutto (anche Redis, cron, wp-config)" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_RUN"; printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass"
  wp_args blog.miosito.it
  export WP_FAIL_ON="core download"
  run site_run create blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = wp ]
  [ ! -e "$SITES_WWW/blog.miosito.it" ]
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it" ]
  [ -z "$(ls "$SITES_RUN" | grep -v '\.err$')" ]
}

# Un sito PHP attivo con DB e segnaposto, come lo lascia la 2a.
php_site() {
  site_reg_new blog.miosito.it php no yes
  mkdir -p "$SITES_RUN"; printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass"
  site_run create blog.miosito.it
}

@test "wp-install su un sito PHP vuoto: diventa WordPress" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  site_run wpinstall blog.miosito.it
  [ "$(site_reg_get blog.miosito.it .type)" = wordpress ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  grep -q "define( 'DB_PASSWORD', 'Password-db-1234567890' );" "$SITES_WWW/blog.miosito.it/wp-config.php"
  grep -q 'location = /xmlrpc.php' "$NGINX_CONF_D/blog.miosito.it.conf"
  run grep -c 'return 503' "$NGINX_CONF_D/blog.miosito.it.conf"
  [ "$output" = 0 ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = done ]
  [ -z "$(ls "$SITES_RUN")" ]
}

@test "wp-install fallito: il sito torna PHP con il segnaposto e il DB senza tabelle" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  : >"$BATS_TEST_TMPDIR/mariadb.sql"
  export WP_FAIL_ON="plugin install"
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .type)" = php ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *plugin* ]]
  site_placeholder_intact blog.miosito.it
  [ ! -e "$SITES_WWW/blog.miosito.it/wp-config.php" ]
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it" ]
  grep -qF 'DROP DATABASE IF EXISTS `site_blog_miosito_it`;' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -qF 'CREATE DATABASE IF NOT EXISTS `site_blog_miosito_it`' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -q 'Password-db-1234567890' "$BATS_TEST_TMPDIR/mariadb.sql"
  run grep -c 'information_schema' "$BATS_TEST_TMPDIR/mariadb.sql"
  [ "$output" = 0 ]
  run grep -c 'location = /xmlrpc.php' "$NGINX_CONF_D/blog.miosito.it.conf"
  [ "$output" = 0 ]
}

@test "wp-install su public/ non intatta: rifiutato senza toccare niente" {
  php_site
  echo x >"$SITES_WWW/blog.miosito.it/public/mio.html"
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ -f "$SITES_WWW/blog.miosito.it/public/mio.html" ]
  [ "$(site_reg_get blog.miosito.it .type)" = php ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"non è vuota"* ]]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ -z "$(ls "$SITES_RUN")" ]
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
  run grep -c 'return 503' "$NGINX_CONF_D/blog.miosito.it.conf"
  [ "$output" = 0 ]
  run grep -c 'core download' "$CALLS"
  [ "$output" = 0 ]
}

@test "eliminazione di un sito WordPress toglie anche utente Redis e cron" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_RUN"; printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass"
  wp_args blog.miosito.it
  site_run create blog.miosito.it
  # prima dell'eliminazione utente Redis e cron ci sono davvero
  grep -q '^user site_blog_miosito_it ' "$REDIS_ACL_FILE"
  [ -f "$CRON_D/vps-site-site_blog_miosito_it" ]
  site_reg_update blog.miosito.it '.prev_state = .state | .state = "deleting"'
  site_run delete blog.miosito.it
  run site_reg_exists blog.miosito.it
  [ "$status" -eq 1 ]
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it" ]
}

@test "site_refresh: wpinstall interrotto diventa errore" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing" | .job.op = "wpinstall" | .job.ts = 1'
  export STUB_RC_systemctl=3
  site_refresh blog.miosito.it
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"installazione WordPress interrotta"* ]]
}

@test "nuova password DB su un sito WordPress aggiorna anche wp-config.php" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_WWW/blog.miosito.it/public"
  site_wp_config_write blog.miosito.it 'Password-db-1234567890' 'Password-redis-1234567890'
  printf 'DB_PASS=Password-db-1234567890\n' >"$SITES_WWW/blog.miosito.it/db.env"
  site_db_password blog.miosito.it 'Nuova-password-db-0987654321'
  grep -q "define( 'DB_PASSWORD', 'Nuova-password-db-0987654321' );" "$SITES_WWW/blog.miosito.it/wp-config.php"
}

@test "nuova password DB: wp-config.php senza la riga, DB rimesso com'era e db.env intatto" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_WWW/blog.miosito.it/public"
  printf '<?php\n// niente\n' >"$SITES_WWW/blog.miosito.it/wp-config.php"
  printf 'DB_PASS=Password-db-1234567890\n' >"$SITES_WWW/blog.miosito.it/db.env"
  export SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_db_password blog.miosito.it 'Nuova-password-db-0987654321'
  [ "$status" -eq 1 ]
  grep -qx 'DB_PASS=Password-db-1234567890' "$SITES_WWW/blog.miosito.it/db.env"
  [ "$(grep -c 'ALTER USER' "$BATS_TEST_TMPDIR/mariadb.sql")" = 2 ]
  tail -n 1 "$BATS_TEST_TMPDIR/mariadb.sql" | grep -q "Password-db-1234567890"
}

@test "wp-install su un sito senza database: rifiutato, file di passaggio cancellati" {
  site_reg_new blog.miosito.it php no no
  site_run create blog.miosito.it
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ "$(site_reg_get blog.miosito.it .type)" = php ]
  [ -z "$(ls "$SITES_RUN")" ]
  run grep -c 'core download' "$CALLS"
  [ "$output" = 0 ]
}

@test "site_abort di wpinstall: sito di nuovo attivo, file di passaggio cancellati" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  export SITES_LOCK_WAIT=0
  exec 7>"$SITES_LOCK"; flock -n 7
  run site_run wpinstall blog.miosito.it
  exec 7>&-
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ -z "$(ls "$SITES_RUN")" ]
}

# Sostituisce lo stub di wp: a "core download" copia il vhost servito in quel momento.
wp_spia_vhost() {
  mv "$BATS_TEST_TMPDIR/bin/wp" "$BATS_TEST_TMPDIR/bin/wp.orig"
  # shellcheck disable=SC2016
  make_stub wp 'if [[ "$*" == *"core download"* ]]; then cp "$NGINX_CONF_D/blog.miosito.it.conf" "$BATS_TEST_TMPDIR/vhost-durante"; fi
exec "$BATS_TEST_TMPDIR/bin/wp.orig" "$@"'
}

@test "creazione WordPress: durante l'installazione il sito risponde 503, poi il vhost vero" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_RUN"; printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass"
  wp_args blog.miosito.it
  wp_spia_vhost
  site_run create blog.miosito.it
  grep -q 'return 503' "$BATS_TEST_TMPDIR/vhost-durante"
  run grep -c 'xmlrpc' "$BATS_TEST_TMPDIR/vhost-durante"
  [ "$output" = 0 ]
  grep -q 'location = /xmlrpc.php' "$NGINX_CONF_D/blog.miosito.it.conf"
  run grep -c 'return 503' "$NGINX_CONF_D/blog.miosito.it.conf"
  [ "$output" = 0 ]
}

@test "wp-install: durante l'installazione il sito risponde 503" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  wp_spia_vhost
  site_run wpinstall blog.miosito.it
  grep -q 'return 503' "$BATS_TEST_TMPDIR/vhost-durante"
  run grep -c 'return 503' "$NGINX_CONF_D/blog.miosito.it.conf"
  [ "$output" = 0 ]
}

@test "creazione WordPress: plugin falliti dopo l'utente Redis, Redis tolto e niente cron" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$SITES_RUN"; printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_blog_miosito_it.pass"
  wp_args blog.miosito.it
  export WP_FAIL_ON="plugin install"
  run site_run create blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = plugins ]
  # l'utente Redis era stato aggiunto (primo ACL LOAD) e poi tolto (secondo)
  [ "$(grep -c 'ACL LOAD' "$CALLS")" = 2 ]
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it" ]
  [ ! -e "$SITES_WWW/blog.miosito.it" ]
  [ -z "$(ls "$SITES_RUN")" ]
}

@test "wp-install: Redis non collegato dopo il drop-in, passo plugins fallito e annullato" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  export WP_REDIS_STATUS="Not connected"
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = plugins ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"Redis non collegata"* ]]
  [ "$(site_reg_get blog.miosito.it .type)" = php ]
  [ ! -e "$SITES_WWW/blog.miosito.it/public/wp-content" ]
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
}

@test "wp-install fallito a core install: annullato del tutto" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  export WP_FAIL_ON="core install"
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ "$(site_reg_get blog.miosito.it .type)" = php ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = wp ]
  [ "$(grep -c 'ACL LOAD' "$CALLS")" = 2 ]
  run grep -c site_blog_miosito_it "$REDIS_ACL_FILE"
  [ "$output" = 0 ]
  site_placeholder_intact blog.miosito.it
  [ ! -e "$SITES_WWW/blog.miosito.it/wp-config.php" ]
  run grep -c 'return 503' "$NGINX_CONF_D/blog.miosito.it.conf"
  [ "$output" = 0 ]
  [ -z "$(ls "$SITES_RUN")" ]
}

@test "wp-install: annullamento non riuscito, il sito va in errore" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  export WP_FAIL_ON="plugin install" STUB_RC_mariadb=1
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"non annullata del tutto"* ]]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *plugin* ]]
}

@test "site_run fuori posto: i file di passaggio non restano in /run" {
  php_site
  wp_args blog.miosito.it
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ -z "$(ls "$SITES_RUN")" ]
  wp_args altro.miosito.it
  printf '%s' 'Password-db-1234567890' >"$SITES_RUN/site_altro_miosito_it.pass"
  run site_run create altro.miosito.it
  [ "$status" -eq 1 ]
  [ -z "$(ls "$SITES_RUN")" ]
}

@test "wp-install: file di WordPress non tolti, DB intatto e il sito resta in 503" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  : >"$BATS_TEST_TMPDIR/mariadb.sql"
  # find -delete fallisce; le altre ricerche (controllo del segnaposto) funzionano
  # shellcheck disable=SC2016
  make_stub find 'if [[ " $* " == *" -delete "* ]]; then exit 1; fi; exec /usr/bin/find "$@"'
  export WP_FAIL_ON="plugin install"
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"non annullata del tutto"* ]]
  grep -q 'return 503' "$NGINX_CONF_D/blog.miosito.it.conf"
  run grep -c 'DROP DATABASE' "$BATS_TEST_TMPDIR/mariadb.sql"
  [ "$output" = 0 ]
  [ -f "$SITES_WWW/blog.miosito.it/wp-config.php" ]
}

@test "wp-install: annullamento a metà (DB non ricreato), il vhost resta in 503" {
  php_site
  site_reg_update blog.miosito.it '.state = "installing"'
  wp_args blog.miosito.it
  export WP_FAIL_ON="plugin install" STUB_RC_mariadb=1
  run site_run wpinstall blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  grep -q 'return 503' "$NGINX_CONF_D/blog.miosito.it.conf"
}

@test "site_placeholder_intact: index.html che punta a una FIFO non blocca" {
  site_reg_new blog.miosito.it php no yes
  site_user_add blog.miosito.it
  pub="$SITES_WWW/blog.miosito.it/public"
  rm "$pub/index.html"
  mkfifo "$BATS_TEST_TMPDIR/fifo"
  ln -s "$BATS_TEST_TMPDIR/fifo" "$pub/index.html"
  SECONDS=0
  run ! site_placeholder_intact blog.miosito.it
  rm "$pub/index.html"
  mkfifo "$pub/index.html"
  run ! site_placeholder_intact blog.miosito.it
  ((SECONDS < 3))
}

@test "site_placeholder_intact: una lettura che si blocca (scambio con una FIFO) finisce entro 5 s" {
  site_reg_new blog.miosito.it php no yes
  site_user_add blog.miosito.it
  # L'utente del sito che legge resta appeso: timeout lo ferma.
  make_stub runuser 'exec sleep 60'
  SECONDS=0
  run ! site_placeholder_intact blog.miosito.it
  ((SECONDS < 10))
}

@test "site_placeholder_intact: il marcatore lo legge l'utente del sito, al massimo 8 KiB" {
  site_reg_new blog.miosito.it php no yes
  site_user_add blog.miosito.it
  pub="$SITES_WWW/blog.miosito.it/public"
  : >"$CALLS"
  site_placeholder_intact blog.miosito.it
  grep -qx 'runuser -u site_blog_miosito_it' "$CALLS"
  # Marcatore oltre i primi 8 KiB: non letto.
  { head -c 9000 /dev/zero | tr '\0' x; cat "$pub/index.html"; } >"$BATS_TEST_TMPDIR/grande.html"
  cp "$BATS_TEST_TMPDIR/grande.html" "$pub/index.html"
  run ! site_placeholder_intact blog.miosito.it
}

@test "site_placeholder_intact: con molti file find si ferma al primo" {
  site_reg_new blog.miosito.it php no yes
  site_user_add blog.miosito.it
  pub="$SITES_WWW/blog.miosito.it/public"
  for i in $(seq 1 300); do : >"$pub/f$i.html"; done
  # shellcheck disable=SC2016
  make_stub find 'echo "find $*" >>"$CALLS"; exec /usr/bin/find "$@"'
  : >"$CALLS"
  run ! site_placeholder_intact blog.miosito.it
  grep -q -- '-print -quit' "$CALLS"
  ! grep -q '^runuser' "$CALLS"
}

@test "utente Redis: il file temporaneo nasce fuori dalla cartella di Redis" {
  site_reg_new blog.miosito.it wordpress no yes
  mkdir -p "$BATS_TEST_TMPDIR/redis"
  export REDIS_ACL_FILE="$BATS_TEST_TMPDIR/redis/users.acl"
  printf 'user default off\n' >"$REDIS_ACL_FILE"
  # shellcheck disable=SC2016
  make_stub mktemp 'echo "mktemp $*" >>"$CALLS"; exec /usr/bin/mktemp "$@"'
  site_redis_user_add blog.miosito.it 'Password-redis-1234567890'
  grep -qxF "mktemp $BATS_TEST_TMPDIR/.vps-acl.XXXXXX" "$CALLS"
  grep -q '^user site_blog_miosito_it ' "$REDIS_ACL_FILE"
  [ "$(stat -c %a "$REDIS_ACL_FILE")" = 640 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/redis" -maxdepth 1 -name '.vps-acl.*')" ]
}
