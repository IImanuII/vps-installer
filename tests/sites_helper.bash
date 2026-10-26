# shellcheck shell=bash
# Ambiente finto per lib/sites.sh e tools/vps-site: cartelle in BATS_TEST_TMPDIR,
# manifest con pannello e Cloudflare, stub dei comandi di sistema e dell'API Cloudflare.

sites_test_setup() {
  export SITES_DIR="$BATS_TEST_TMPDIR/sites" SITES_WWW="$BATS_TEST_TMPDIR/www"
  export SITES_BACKUPS="$BATS_TEST_TMPDIR/backups" SITES_LOCK="$BATS_TEST_TMPDIR/vps-site.lock"
  export SITES_RUN="$BATS_TEST_TMPDIR/run" NGINX_CONF_D="$BATS_TEST_TMPDIR/conf.d"
  export PHP_POOL_D="$BATS_TEST_TMPDIR/pool.d" LOGROTATE_D="$BATS_TEST_TMPDIR/logrotate.d"
  export VPS_SITE_SELF="$REPO_ROOT/tools/vps-site" VPS_LIB="$REPO_ROOT/lib"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  # lock dei siti di vps-backup: /run non è scrivibile senza root (CI)
  export BK_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$SITES_WWW" "$NGINX_CONF_D" "$PHP_POOL_D" "$LOGROTATE_D" "$VPS_OPT/secrets" "$BK_LOCK_DIR"
  printf 'dns_cloudflare_api_token = %s\n' "$(printf 'a%.0s' {1..40})" >"$VPS_OPT/secrets/cloudflare.ini"
  jq -n '{installer_version:"1.2.0", admin_user:"manu", ipv4:"203.0.113.10", ipv6:null,
    cloudflare:{enabled:true, zone:"miosito.it"}, components:{redis:true, redis_acl:true},
    panel:{domain:"panel.miosito.it", path:"/var/www/panel.miosito.it"}}' >"$VPS_OPT/manifest.json"

  # Comandi di sistema: annotano la chiamata in $CALLS; STUB_RC_<nome> ne sceglie
  # il codice d'uscita (nome con i caratteri non alfanumerici diventati _).
  local c body
  # shellcheck disable=SC2016
  body='n="$(basename "$0")"; echo "$n $*" >>"$CALLS"; v="STUB_RC_$(printf %s "$n" | tr -c "a-zA-Z0-9" _)"; exit "${!v:-0}"'
  for c in groupadd useradd userdel groupdel gpasswd setfacl nginx "php-fpm$PHP_VERSION" systemctl certbot systemd-run visudo pkill; do
    make_stub "$c" "$body"
  done
  # pgrep: di norma nessun processo rimasto (1); STUB_RC_pgrep=0 simula processi vivi.
  # shellcheck disable=SC2016
  make_stub pgrep 'echo "pgrep $*" >>"$CALLS"; exit "${STUB_RC_pgrep:-1}"'
  # shellcheck disable=SC2016
  make_stub mariadb 'echo "mariadb $*" >>"$CALLS"; cat >>"$BATS_TEST_TMPDIR/mariadb.sql"; exit "${STUB_RC_mariadb:-0}"'
  # shellcheck disable=SC2016
  make_stub mariadb-dump 'echo "-- dump $*"; exit "${STUB_RC_mariadb_dump:-0}"'

  # API Cloudflare finta. Zone in CF_ZONES (spazi); record esistenti di un nome in
  # $BATS_TEST_TMPDIR/cf-records-<nome>.json; ogni chiamata in cf.log.
  # shellcheck disable=SC2016
  make_stub curl 'T="$BATS_TEST_TMPDIR"; m=GET; url=""; data=""
while (($#)); do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -H | --max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$m $url $data" >>"$T/cf.log"
zones="${CF_ZONES:-miosito.it}"
case "$m $url" in
  "GET "*"/zones?status=active"*)
    printf "%s\n" $zones | jq -R . | jq -sc "{success: true, result: map({name: .}), result_info: {total_pages: 1}}" ;;
  "GET "*"/zones?name="*)
    n="${url#*name=}"; n="${n%%&*}"
    if printf "%s\n" $zones | grep -qxF "$n"; then echo "{\"success\":true,\"result\":[{\"id\":\"z-$n\"}]}"
    else echo "{\"success\":true,\"result\":[]}"; fi ;;
  "GET "*"/dns_records?name="*)
    n="${url#*name=}"; f="$T/cf-records-$n.json"
    if [[ -f "$f" ]]; then cat "$f"; else echo "{\"success\":true,\"result\":[]}"; fi ;;
  "POST "*)
    c=$(( $(cat "$T/cf.n" 2>/dev/null || echo 0) + 1 )); echo "$c" >"$T/cf.n"
    echo "{\"success\":${CF_POST_OK:-true},\"result\":{\"id\":\"rec$c\"}}" ;;
  "DELETE "*) echo "{\"success\":true,\"result\":{}}" ;;
esac'
  export REDIS_ACL_FILE="$BATS_TEST_TMPDIR/users.acl" REDIS_ADMIN_SECRET="$VPS_OPT/secrets/redis-admin"
  export CRON_D="$BATS_TEST_TMPDIR/cron.d" WP_BIN="$BATS_TEST_TMPDIR/bin/wp"
  mkdir -p "$CRON_D"
  printf 'user default off\n' >"$REDIS_ACL_FILE"
  printf 'segreto-admin-redis-0123456789\n' >"$REDIS_ADMIN_SECRET"
  # redis-cli: annota argomenti e se la password è arrivata dall'ambiente (mai negli argomenti).
  # shellcheck disable=SC2016
  make_stub redis-cli 'echo "redis-cli $* auth=${REDISCLI_AUTH:+si}" >>"$CALLS"; exit "${STUB_RC_redis_cli:-0}"'
  # runuser -u UTENTE -- [env -i VAR=... ] COMANDO...: annota l'utente ed esegue il
  # comando saltando `env -i` e le sue assegnazioni (cancellerebbero CALLS e
  # BATS_TEST_TMPDIR, che servono allo stub di wp).
  # shellcheck disable=SC2016
  make_stub runuser 'echo "runuser $1 $2" >>"$CALLS"; shift 3
if [[ "$1" == env ]]; then shift; while [[ "$1" == -i || "$1" == *=* ]]; do shift; done; fi
exec "$@"'
  # wp (WP-CLI): annota la chiamata; legge stdin solo con --prompt (altrimenti
  # potrebbe bloccarsi su uno stdin mai chiuso); WP_FAIL_ON="core download" fa fallire quel comando.
  # Con --prompt ristampa il valore letto, come fa WP-CLI vero (--admin_password=...).
  # shellcheck disable=SC2016
  make_stub wp 'echo "wp $*" >>"$CALLS"; if [[ "$*" == *--prompt=* ]]; then in="$(cat)"; printf "%s\n" "$in" >>"$BATS_TEST_TMPDIR/wp.stdin"; echo "wp core install --admin_password=$in"; fi
if [[ -n "${WP_FAIL_ON:-}" && "$*" == *"$WP_FAIL_ON"* ]]; then exit 1; fi
p="${*##*--path=}"; p="${p%% *}"
if [[ "$*" == *"core download"* ]]; then mkdir -p "$p/wp-content"; echo "<?php" >"$p/index.php"; fi
if [[ "$*" == *"plugin install"*redis-cache* ]]; then mkdir -p "$p/wp-content/plugins/redis-cache/includes"; echo "<?php // drop-in" >"$p/wp-content/plugins/redis-cache/includes/object-cache.php"; fi
if [[ "$*" == *"redis status"* ]]; then echo "Status: ${WP_REDIS_STATUS:-Connected}"; fi
exit 0'
}

# fb_archive DOMINIO TIPO WWW(yes|no) DB(yes|no) [LOGIN] — archivia un sito finto in
# $BK_BACKUPS/sites (formato nuovo) e poi lo fa sparire (registro e cartella): è il caso
# di un sito eliminato. Lascia il nome della copia, come lo vuole list-local, in $FB_ARC.
fb_archive() {
  local d="$1" t="$2" www="$3" db="$4" login="${5:-}" root
  root="$SITES_WWW/$d"
  site_reg_new "$d" "$t" "$www" "$db"
  site_reg_update "$d" '.state = "active"'
  if [[ -n "$login" ]]; then
    site_reg_update "$d" '.wordpress = {login_path: $l, admin_user: "gestore"}' --arg l "$login"
  fi
  mkdir -p "$root/public/wp-content" "$root/logs" "$root/tmp" "$BK_BACKUPS/sites"
  echo "contenuto di $d" >"$root/public/index.php"
  printf '<?php // wp-config vecchio\n$table_prefix = '"'%s'"';\n' "${FB_PREFIX:-wp_}" >"$root/wp-config.php"
  FB_ARC="sites/$d-20261001-040000.tar.gz"
  bk_archive "$d" "$BK_BACKUPS/$FB_ARC" "${FB_PARTS:-all}" || return 1
  rm -f "$(site_reg_path "$d")"
  rm -rf "$root"
}

# fb_backup_stub [RC] — finto vps-backup per VPS_BACKUP_SELF: annota gli argomenti in
# $BATS_TEST_TMPDIR/fb.calls (e lo stato del sito in quel momento) ed esce con RC.
fb_backup_stub() {
  # shellcheck disable=SC2016
  make_stub vps-backup-fb 'T="$BATS_TEST_TMPDIR"; echo "$*" >>"$T/fb.calls"
state="$(jq -r .state "$SITES_DIR/$3.json" 2>/dev/null)"; echo "$state" >>"$T/fb.state"
# il lock globale dei lavori di vps-site non deve essere tenuto durante il ripristino
if flock -n "$SITES_LOCK" true; then echo libero >>"$T/fb.joblock"; else echo preso >>"$T/fb.joblock"; fi
rc="${FB_STUB_RC:-0}"
if [[ "$rc" == 0 ]]; then echo "{\"ok\":true,\"finished\":true,\"restore_ok\":true}"; else echo "{\"ok\":false,\"error\":\"${FB_STUB_ERR:-ripristino fallito}\"}"; fi
exit "$rc"'
  export VPS_BACKUP_SELF="$BATS_TEST_TMPDIR/bin/vps-backup-fb"
}
