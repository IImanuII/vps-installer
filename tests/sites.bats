bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
}

@test "site_slug: dominio corto e dominio lungo troncato con hash" {
  [ "$(site_slug blog.miosito.it)" = site_blog_miosito_it ]
  [ "$(site_slug un-sottodominio-molto-lungo.esempio.it)" = site_un_sottodominio_molto__0129 ]
  [ "$(site_slug un-sottodominio-molto-lungo.esempio.it | wc -c)" -eq 32 ]
}

@test "site_validate_new accetta un dominio nuovo" {
  run site_validate_new blog.miosito.it
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "site_validate_new rifiuta forme e nomi non ammessi" {
  for d in "Blog.miosito.it" "blog miosito.it" "blog;rm.it" "../etc" "a/b.it" "miosito" "" "_acme" "-x.miosito.it"; do
    run site_validate_new "$d"
    [ "$status" -eq 1 ]
    [[ "$output" == *"non valido"* ]]
  done
  run site_validate_new www.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"--www"* ]]
  run site_validate_new panel.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"pannello"* ]]
}

@test "site_validate_new rifiuta un sito esistente, una cartella estranea, uno slug già usato" {
  site_reg_new blog.miosito.it php no no
  run site_validate_new blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"esiste già"* ]]

  mkdir -p "$SITES_WWW/altro.miosito.it"
  run site_validate_new altro.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"cartella"* ]]

  # blog-miosito.it ha lo stesso slug di blog.miosito.it
  run site_validate_new blog-miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"site_blog_miosito_it"* ]]
}

@test "site_reg_new scrive un registro 640 in creazione, senza segreti" {
  site_reg_new blog.miosito.it php yes yes
  f="$(site_reg_path blog.miosito.it)"
  [ "$(stat -c %a "$f")" = 640 ]
  [ "$(stat -c %a "$SITES_DIR")" = 750 ]
  [ "$(jq -r .state "$f")" = creating ]
  [ "$(jq -r .slug "$f")" = site_blog_miosito_it ]
  [ "$(jq -r .www "$f")" = true ]
  [ "$(jq -r .db "$f")" = true ]
  [ "$(jq -r .job.step "$f")" = queued ]
  [ "$(jq -r '.dns_records | length' "$f")" = 0 ]
}

@test "site_job aggiorna passo ed errore; site_reg_update conserva il resto" {
  site_reg_new blog.miosito.it static no no
  site_job blog.miosito.it create cert "certificato rifiutato"
  [ "$(site_reg_get blog.miosito.it .job.step)" = cert ]
  [ "$(site_reg_get blog.miosito.it .job.error)" = "certificato rifiutato" ]
  jq -e '.job.ts > 0' "$(site_reg_path blog.miosito.it)"
  site_job blog.miosito.it create done
  [ "$(site_reg_get blog.miosito.it .job.error)" = null ]
  site_reg_update blog.miosito.it '.state = $s' --arg s active
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ "$(site_reg_get blog.miosito.it .type)" = static ]
}

@test "site_fail scrive il motivo in SITE_ERROR_FILE e restituisce 1" {
  SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_fail "qualcosa non va"
  [ "$status" -eq 1 ]
  [ "$(cat "$SITE_ERROR_FILE")" = "qualcosa non va" ]
}

@test "cf_list_zones elenca le zone visibili dal token" {
  export CF_ZONES="miosito.it altro.it" CF_API_TOKEN=x
  run cf_list_zones
  [ "$status" -eq 0 ]
  [ "$output" = $'miosito.it\naltro.it' ]
}

@test "site_dns_add crea A per dominio e www e annota gli id" {
  site_reg_new miosito.it static yes no
  export CF_API_TOKEN=x
  site_dns_add miosito.it
  [ "$(site_reg_get miosito.it .zone.name)" = miosito.it ]
  [ "$(site_reg_get miosito.it '.dns_records | length')" = 2 ]
  [ "$(site_reg_get miosito.it '.dns_records[1].name')" = www.miosito.it ]
  grep -q '"proxied":true' "$BATS_TEST_TMPDIR/cf.log"
  [ "$(grep -c '^POST ' "$BATS_TEST_TMPDIR/cf.log")" = 2 ]
}

@test "site_dns_add con IPv6 crea anche AAAA" {
  jq '.ipv6 = "2001:db8::1"' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  site_reg_new blog.miosito.it static no no
  export CF_API_TOKEN=x
  site_dns_add blog.miosito.it
  grep -q '"type":"AAAA"' "$BATS_TEST_TMPDIR/cf.log"
  [ "$(site_reg_get blog.miosito.it '.dns_records | length')" = 2 ]
}

@test "site_dns_add riusa un record già giusto e non lo annota" {
  echo '{"success":true,"result":[{"id":"vecchio","type":"A","name":"blog.miosito.it","content":"203.0.113.10","proxied":true}]}' \
    >"$BATS_TEST_TMPDIR/cf-records-blog.miosito.it.json"
  site_reg_new blog.miosito.it static no no
  export CF_API_TOKEN=x
  site_dns_add blog.miosito.it
  run grep -c '^POST ' "$BATS_TEST_TMPDIR/cf.log"
  [ "$output" = 0 ]
  [ "$(site_reg_get blog.miosito.it '.dns_records | length')" = 0 ]
}

@test "site_dns_add: un record che punta altrove ferma tutto prima di creare" {
  echo '{"success":true,"result":[{"id":"c1","type":"CNAME","name":"www.miosito.it","content":"altrove.net"}]}' \
    >"$BATS_TEST_TMPDIR/cf-records-www.miosito.it.json"
  site_reg_new miosito.it static yes no
  export CF_API_TOKEN=x SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_dns_add miosito.it
  [ "$status" -eq 1 ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"punta altrove"* ]]
  run grep -c '^POST ' "$BATS_TEST_TMPDIR/cf.log"
  [ "$output" = 0 ]
}

@test "site_dns_add: zona non visibile dal token spiega i permessi" {
  site_reg_new blog.sconosciuto.it static no no
  export CF_API_TOKEN=x SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_dns_add blog.sconosciuto.it
  [ "$status" -eq 1 ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"Zone: Read"*"DNS: Edit"* ]]
}

@test "site_dns_remove toglie solo i record annotati" {
  site_reg_new miosito.it static yes no
  export CF_API_TOKEN=x
  site_dns_add miosito.it
  site_dns_remove miosito.it
  grep -q '^DELETE .*/zones/z-miosito.it/dns_records/rec1' "$BATS_TEST_TMPDIR/cf.log"
  grep -q '^DELETE .*/zones/z-miosito.it/dns_records/rec2' "$BATS_TEST_TMPDIR/cf.log"
  [ "$(site_reg_get miosito.it '.dns_records | length')" = 0 ]
}

@test "site_cert_issue chiede un certificato per tutti i nomi via DNS Cloudflare" {
  site_reg_new miosito.it static yes no
  site_cert_issue miosito.it
  grep -q -- '--cert-name miosito.it' "$CALLS"
  grep -q -- '--dns-cloudflare ' "$CALLS"
  grep -q -- '-d miosito.it -d www.miosito.it' "$CALLS"
}

@test "site_cert_issue: certbot che fallisce dà un motivo" {
  site_reg_new blog.miosito.it static no no
  export STUB_RC_certbot=1 SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_cert_issue blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"Let's Encrypt"* ]]
}

@test "site_user_add: utente di sistema, admin nel gruppo, cartelle, ACL, segnaposto" {
  site_reg_new blog.miosito.it php no no
  site_user_add blog.miosito.it
  r="$SITES_WWW/blog.miosito.it"
  grep -q '^groupadd --system site_blog_miosito_it' "$CALLS"
  grep -q "^useradd --system --gid site_blog_miosito_it --home-dir $r --no-create-home --shell /usr/sbin/nologin site_blog_miosito_it" "$CALLS"
  grep -q '^gpasswd -a manu site_blog_miosito_it' "$CALLS"
  [ "$(stat -c %a "$r")" = 2750 ]
  [ "$(stat -c %a "$r/logs")" = 2750 ]
  [ "$(stat -c %a "$r/public")" = 2770 ]
  [ "$(stat -c %a "$r/tmp")" = 2770 ]
  grep -q "^setfacl -m u:www-data:x $r\$" "$CALLS"
  grep -q "^setfacl -m u:www-data:rX -m d:u:www-data:rX $r/public" "$CALLS"
  grep -q "^setfacl -m d:g::rwX $r/public $r/tmp" "$CALLS"
  grep -q '<h1>blog.miosito.it</h1>' "$r/public/index.html"
}

@test "site_user_remove toglie utente, gruppo e radice; rifiuta uno slug estraneo" {
  site_reg_new blog.miosito.it php no no
  site_user_add blog.miosito.it
  make_stub id 'exit 0'
  make_stub getent 'exit 0'
  hash -r  # bash ricorda il percorso di id/getent già usati: senza, lo stub non vale
  site_user_remove blog.miosito.it
  grep -q '^userdel site_blog_miosito_it' "$CALLS"
  grep -q '^groupdel site_blog_miosito_it' "$CALLS"
  [ ! -e "$SITES_WWW/blog.miosito.it" ]

  site_reg_new altro.miosito.it php no no
  site_reg_update altro.miosito.it '.slug = "root"'
  run site_user_remove altro.miosito.it
  [ "$status" -eq 1 ]
}

@test "site_pool_add scrive il pool del sito e ricarica PHP-FPM" {
  site_reg_new blog.miosito.it php no no
  site_pool_add blog.miosito.it
  f="$PHP_POOL_D/site_blog_miosito_it.conf"
  grep -qx '\[site_blog_miosito_it\]' "$f"
  grep -qx "listen = /run/php/php$PHP_VERSION-fpm-site_blog_miosito_it.sock" "$f"
  grep -qx "php_admin_value\[open_basedir\] = $SITES_WWW/blog.miosito.it/" "$f"
  grep -q "^systemctl reload php$PHP_VERSION-fpm" "$CALLS"
}

@test "site_pool_add: configurazione rifiutata da php-fpm -t non resta" {
  site_reg_new blog.miosito.it php no no
  export "STUB_RC_php_fpm${PHP_VERSION//./_}=1" SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_pool_add blog.miosito.it
  [ "$status" -eq 1 ]
  [ ! -e "$PHP_POOL_D/site_blog_miosito_it.conf" ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"PHP-FPM"* ]]
}

@test "site_logrotate_add: settimanale, 8 copie, ruotato da root" {
  site_reg_new blog.miosito.it php no no
  site_logrotate_add blog.miosito.it
  f="$LOGROTATE_D/vps-site-site_blog_miosito_it"
  grep -q "^$SITES_WWW/blog.miosito.it/logs/\*.log {" "$f"
  grep -qx '    rotate 8' "$f"
  # Niente "su": nginx (root) crea i log di proprietà di root e il sito non potrebbe troncarli.
  run grep -c '^ *su ' "$f"
  [ "$output" = 0 ]
  site_logrotate_remove blog.miosito.it
  [ ! -e "$f" ]
}

@test "site_vhost_add php con www: redirect, pool del sito, variabili di Nginx intatte" {
  site_reg_new miosito.it php yes no
  site_vhost_add miosito.it
  f="$NGINX_CONF_D/miosito.it.conf"
  grep -q 'server_name miosito.it www.miosito.it;' "$f"
  grep -q 'server_name www.miosito.it;' "$f"
  grep -q 'return 301 https://miosito.it$request_uri;' "$f"
  grep -q "fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm-site_miosito_it.sock;" "$f"
  grep -q 'try_files $uri $uri/ /index.php?$query_string;' "$f"
  grep -q "root $SITES_WWW/miosito.it/public;" "$f"
  grep -q '^nginx -t' "$CALLS"
  grep -q '^systemctl reload nginx' "$CALLS"
}

@test "site_vhost_add statico senza www: niente PHP, niente blocco www" {
  site_reg_new blog.miosito.it static no no
  site_vhost_add blog.miosito.it
  f="$NGINX_CONF_D/blog.miosito.it.conf"
  run grep -c fastcgi_pass "$f"
  [ "$output" = 0 ]
  run grep -c 'server_name www.' "$f"
  [ "$output" = 0 ]
  grep -q 'try_files $uri $uri/ =404;' "$f"
}

@test "site_vhost_add maintenance: 503 con la pagina di manutenzione" {
  site_reg_new blog.miosito.it php no no
  site_vhost_add blog.miosito.it maintenance
  f="$NGINX_CONF_D/blog.miosito.it.conf"
  grep -q 'return 503;' "$f"
  grep -q 'root /var/www/_maintenance;' "$f"
  grep -q 'Retry-After 3600' "$f"
  run grep -c fastcgi_pass "$f"
  [ "$output" = 0 ]
}

@test "site_vhost_add: nginx -t fallito rimette il file di prima, o nessuno" {
  site_reg_new blog.miosito.it php no no
  site_vhost_add blog.miosito.it
  cp "$NGINX_CONF_D/blog.miosito.it.conf" "$BATS_TEST_TMPDIR/prima"
  export STUB_RC_nginx=1 SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_vhost_add blog.miosito.it maintenance
  [ "$status" -eq 1 ]
  cmp "$NGINX_CONF_D/blog.miosito.it.conf" "$BATS_TEST_TMPDIR/prima"
  [[ "$(cat "$SITE_ERROR_FILE")" == *"Nginx"* ]]

  site_reg_new altro.miosito.it php no no
  run site_vhost_add altro.miosito.it
  [ "$status" -eq 1 ]
  [ ! -e "$NGINX_CONF_D/altro.miosito.it.conf" ]
}

@test "site_valid_db_password" {
  site_valid_db_password 'Abcdefghijklmnop'
  site_valid_db_password 'a_B-c9.:!@#%^*+=~xyz'
  run ! site_valid_db_password 'corta'
  run ! site_valid_db_password 'con uno spazio dentro'
  run ! site_valid_db_password "con'apostrofo12345"
  run ! site_valid_db_password 'con"virgolette12345'
  run ! site_valid_db_password 'con\barra123456789'
  run ! site_valid_db_password "$(printf 'x%.0s' {1..129})"
}

@test "site_db_sql: grant sul solo database del sito, underscore protetti" {
  run site_db_sql site_blog_miosito_it 'Password-di-prova-123'
  [[ "$output" == *'CREATE DATABASE IF NOT EXISTS `site_blog_miosito_it`'* ]]
  [[ "$output" == *'ON `site\_blog\_miosito\_it`.* TO '"'site_blog_miosito_it'@'localhost'"* ]]
}

@test "site_db_add crea DB e db.env 640; site_db_password cambia solo DB_PASS" {
  site_reg_new blog.miosito.it php no yes
  mkdir -p "$SITES_WWW/blog.miosito.it"
  site_db_add blog.miosito.it 'Password-di-prova-123'
  f="$SITES_WWW/blog.miosito.it/db.env"
  [ "$(stat -c %a "$f")" = 640 ]
  grep -qx 'DB_NAME=site_blog_miosito_it' "$f"
  grep -qx 'DB_PASS=Password-di-prova-123' "$f"
  grep -q 'CREATE DATABASE' "$BATS_TEST_TMPDIR/mariadb.sql"

  site_db_password blog.miosito.it 'Nuova-password-456789'
  grep -qx 'DB_PASS=Nuova-password-456789' "$f"
  grep -qx 'DB_USER=site_blog_miosito_it' "$f"
  grep -q "ALTER USER 'site_blog_miosito_it'@'localhost'" "$BATS_TEST_TMPDIR/mariadb.sql"
}

@test "site_db_add: MariaDB che fallisce dà un motivo e non scrive db.env" {
  site_reg_new blog.miosito.it php no yes
  mkdir -p "$SITES_WWW/blog.miosito.it"
  export STUB_RC_mariadb=1 SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_db_add blog.miosito.it 'Password-di-prova-123'
  [ "$status" -eq 1 ]
  [ ! -e "$SITES_WWW/blog.miosito.it/db.env" ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"database"* ]]
}

# Prepara un sito in creazione come lo lascia `vps-site create`.
nuovo() { # DOMINIO TIPO WWW DB [PASSWORD]
  site_reg_new "$1" "$2" "$3" "$4"
  if [[ -n "${5:-}" ]]; then
    mkdir -p "$SITES_RUN"
    printf '%s' "$5" >"$SITES_RUN/$(site_slug "$1").pass"
  fi
}

@test "site_run create: tutti i passi, sito attivo, password letta e cancellata" {
  nuovo blog.miosito.it php no yes 'Password-di-prova-123'
  site_run create blog.miosito.it
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = done ]
  [ "$(site_reg_get blog.miosito.it .job.error)" = null ]
  [ -f "$NGINX_CONF_D/blog.miosito.it.conf" ]
  [ -f "$PHP_POOL_D/site_blog_miosito_it.conf" ]
  [ -f "$LOGROTATE_D/vps-site-site_blog_miosito_it" ]
  grep -qx 'DB_PASS=Password-di-prova-123' "$SITES_WWW/blog.miosito.it/db.env"
  [ ! -e "$SITES_RUN/site_blog_miosito_it.pass" ]
}

@test "site_run create: certbot fallisce, si disfa tutto e resta l'errore" {
  nuovo miosito.it php yes no
  export STUB_RC_certbot=1
  run site_run create miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get miosito.it .state)" = error ]
  [ "$(site_reg_get miosito.it .job.step)" = cert ]
  [[ "$(site_reg_get miosito.it .job.error)" == *"Let's Encrypt"* ]]
  [ ! -e "$NGINX_CONF_D/miosito.it.conf" ]
  [ ! -e "$PHP_POOL_D/site_miosito_it.conf" ]
  [ ! -e "$SITES_WWW/miosito.it" ]
  grep -q '^DELETE .*/dns_records/rec1' "$BATS_TEST_TMPDIR/cf.log"
  grep -q '^DELETE .*/dns_records/rec2' "$BATS_TEST_TMPDIR/cf.log"
  grep -q '^certbot delete -n --cert-name miosito.it' "$CALLS"
}

@test "site_run create: nginx -t fallisce, nessun vhost resta" {
  nuovo blog.miosito.it static no no
  export STUB_RC_nginx=1
  run site_run create blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = nginx ]
  [ ! -e "$NGINX_CONF_D/blog.miosito.it.conf" ]
}

@test "site_run delete: archivio, rimozione completa, registro cancellato" {
  nuovo blog.miosito.it php no yes 'Password-di-prova-123'
  site_run create blog.miosito.it
  echo ciao >"$SITES_WWW/blog.miosito.it/public/ciao.txt"
  site_reg_update blog.miosito.it '.prev_state = .state | .state = "deleting"'
  site_run delete blog.miosito.it
  run ! site_reg_exists blog.miosito.it
  [ ! -e "$SITES_WWW/blog.miosito.it" ]
  [ ! -e "$NGINX_CONF_D/blog.miosito.it.conf" ]
  [ ! -e "$PHP_POOL_D/site_blog_miosito_it.conf" ]
  tgz="$(ls "$SITES_BACKUPS"/blog.miosito.it-*.tar.gz)"
  [ "$(stat -c %a "$tgz")" = 600 ]
  tar -tzf "$tgz" | grep -q 'blog.miosito.it/public/ciao.txt'
  ls "$SITES_BACKUPS"/blog.miosito.it-*.sql.gz
  grep -q 'DROP DATABASE IF EXISTS `site_blog_miosito_it`' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -q '^DELETE .*/dns_records/rec1' "$BATS_TEST_TMPDIR/cf.log"
}

@test "site_run delete: archivio non riuscito, niente cancellato e stato di prima" {
  nuovo blog.miosito.it static no no
  site_run create blog.miosito.it
  site_reg_update blog.miosito.it '.state = "disabled"'
  site_reg_update blog.miosito.it '.prev_state = .state | .state = "deleting"'
  make_stub tar 'exit 2'
  run site_run delete blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = disabled ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"niente è stato cancellato"* ]]
  [ -d "$SITES_WWW/blog.miosito.it/public" ]
  [ -f "$NGINX_CONF_D/blog.miosito.it.conf" ]
  run ls "$SITES_BACKUPS"
  [ -z "$output" ]
}

@test "site_run delete di un sito in errore salta l'archivio" {
  nuovo blog.miosito.it static no no
  export STUB_RC_certbot=1
  site_run create blog.miosito.it || true
  unset STUB_RC_certbot
  site_reg_update blog.miosito.it '.prev_state = .state | .state = "deleting"'
  site_run delete blog.miosito.it
  run ! site_reg_exists blog.miosito.it
  [ ! -e "$SITES_BACKUPS" ] || [ -z "$(ls "$SITES_BACKUPS")" ]
}

@test "site_run: lucchetto occupato oltre l'attesa, il lavoro finisce in errore" {
  nuovo blog.miosito.it static no no
  export SITES_LOCK_WAIT=1
  flock "$SITES_LOCK" sleep 5 >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  run site_run create blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"coda"* ]]
  kill "$pid" 2>/dev/null || true
}

@test "site_refresh: creazione interrotta diventa errore, eliminazione interrotta torna com'era" {
  nuovo blog.miosito.it static no no
  site_reg_update blog.miosito.it '.job.ts = 1'
  export STUB_RC_systemctl=3
  site_refresh blog.miosito.it
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"interrotta"* ]]

  nuovo altro.miosito.it static no no
  site_reg_update altro.miosito.it '.state = "active" | .prev_state = .state | .state = "deleting" | .job.op = "delete" | .job.ts = 1'
  site_refresh altro.miosito.it
  [ "$(site_reg_get altro.miosito.it .state)" = active ]
  [[ "$(site_reg_get altro.miosito.it .job.error)" == *"riprova"* ]]
}

@test "site_refresh non tocca un lavoro appena partito o ancora vivo" {
  nuovo blog.miosito.it static no no
  export STUB_RC_systemctl=3
  site_refresh blog.miosito.it
  [ "$(site_reg_get blog.miosito.it .state)" = creating ]
  site_reg_update blog.miosito.it '.job.ts = 1'
  export STUB_RC_systemctl=0
  site_refresh blog.miosito.it
  [ "$(site_reg_get blog.miosito.it .state)" = creating ]
}

@test "site_list_json: array ordinato, vuoto senza siti" {
  [ "$(site_list_json)" = "[]" ]
  site_reg_new zeta.miosito.it static no no
  site_reg_new alfa.miosito.it static no no
  [ "$(site_list_json | jq -r '.[0].domain')" = alfa.miosito.it ]
  [ "$(site_list_json | jq length)" = 2 ]
}

@test "site_prune cancella solo gli archivi oltre 30 giorni" {
  mkdir -p "$SITES_BACKUPS"
  touch -d '40 days ago' "$SITES_BACKUPS/vecchio.miosito.it-20260101-000000.tar.gz"
  touch "$SITES_BACKUPS/nuovo.miosito.it-20261011-000000.tar.gz"
  site_prune
  [ ! -e "$SITES_BACKUPS/vecchio.miosito.it-20260101-000000.tar.gz" ]
  [ -e "$SITES_BACKUPS/nuovo.miosito.it-20261011-000000.tar.gz" ]
}
