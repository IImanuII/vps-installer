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
  mkdir -p "$SITES_WWW" "$NGINX_CONF_D" "$PHP_POOL_D" "$LOGROTATE_D" "$VPS_OPT/secrets"
  printf 'dns_cloudflare_api_token = %s\n' "$(printf 'a%.0s' {1..40})" >"$VPS_OPT/secrets/cloudflare.ini"
  jq -n '{installer_version:"1.2.0", admin_user:"manu", ipv4:"203.0.113.10", ipv6:null,
    cloudflare:{enabled:true, zone:"miosito.it"},
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
  # shellcheck disable=SC2016
  make_stub wp 'echo "wp $*" >>"$CALLS"; if [[ "$*" == *--prompt=* ]]; then cat >>"$BATS_TEST_TMPDIR/wp.stdin"; fi
if [[ -n "${WP_FAIL_ON:-}" && "$*" == *"$WP_FAIL_ON"* ]]; then exit 1; fi
if [[ "$*" == *"core download"* ]]; then p="${*##*--path=}"; p="${p%% *}"; mkdir -p "$p/wp-content"; echo "<?php" >"$p/index.php"; fi
exit 0'
}
