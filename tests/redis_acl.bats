setup() {
  load test_helper
  setup_common
  export REDIS_CONF="$BATS_TEST_TMPDIR/redis.conf" REDIS_ACL_FILE="$BATS_TEST_TMPDIR/users.acl" REDIS_ADMIN_SECRET="$BATS_TEST_TMPDIR/secrets/redis-admin"
  export SITES_LOCK="$BATS_TEST_TMPDIR/vps-site.lock"
  echo "port 6379" >"$REDIS_CONF"
  jq -n '{components:{redis:true}}' >"$VPS_OPT/manifest.json"
  make_stub systemctl 'echo "systemctl $*" >>"$BATS_TEST_TMPDIR/calls"'
  make_stub redis-cli 'echo "redis-cli $* auth=${REDISCLI_AUTH:+set}" >>"$BATS_TEST_TMPDIR/calls"'
}

@test "redis_acl_setup: aclfile una sola volta, default spento, vps-admin, segreto 600" {
  redis_acl_setup
  redis_acl_setup
  [ "$(grep -c '^aclfile ' "$REDIS_CONF")" = 1 ]
  grep -qxF 'user default off' "$REDIS_ACL_FILE"
  h="$(head -n 1 "$REDIS_ADMIN_SECRET" | tr -d '\n' | sha256sum | cut -d' ' -f1)"
  grep -qxF "user vps-admin on #$h ~* &* +@all" "$REDIS_ACL_FILE"
  [ "$(stat -c %a "$REDIS_ADMIN_SECRET")" = 600 ]
}

@test "redis_acl_setup: riavvia solo la prima volta, poi ACL LOAD senza password negli argomenti" {
  redis_acl_setup
  [ "$(grep -c 'systemctl restart redis-server' "$BATS_TEST_TMPDIR/calls")" = 1 ]
  redis_acl_setup
  [ "$(grep -c 'systemctl restart redis-server' "$BATS_TEST_TMPDIR/calls")" = 1 ]
  grep -qx 'redis-cli --user vps-admin ACL LOAD auth=set' "$BATS_TEST_TMPDIR/calls"
}

@test "redis_acl_setup conserva gli utenti dei siti e non cambia il segreto" {
  redis_acl_setup
  before="$(cat "$REDIS_ADMIN_SECRET")"
  echo 'user site_x on #abc ~site_x:* &site_x:* +@all -@dangerous -@admin +info' >>"$REDIS_ACL_FILE"
  redis_acl_setup
  grep -q '^user site_x on #abc' "$REDIS_ACL_FILE"
  [ "$(cat "$REDIS_ADMIN_SECRET")" = "$before" ]
}

@test "redis_acl_setup segna redis_acl nel manifest" {
  redis_acl_setup
  [ "$(jq -r .components.redis_acl "$VPS_OPT/manifest.json")" = true ]
}

@test "riavvio che fallisce la prima volta: conf ripristinata, Redis riavviato, ritorno 1, manifest intatto" {
  make_stub systemctl 'echo "systemctl $*" >>"$BATS_TEST_TMPDIR/calls"
[ "$1" = restart ] || exit 0
n=$(grep -c "systemctl restart" "$BATS_TEST_TMPDIR/calls"); [ "$n" -ge 2 ]'
  run redis_acl_setup
  [ "$status" -eq 1 ]
  ! grep -q '^aclfile' "$REDIS_CONF"
  [ "$(cat "$REDIS_CONF")" = "port 6379" ]
  [ ! -e "$REDIS_ACL_FILE" ]
  [ "$(grep -c 'systemctl restart redis-server' "$BATS_TEST_TMPDIR/calls")" = 2 ]
  [ "$(jq -r '.components.redis_acl // "no"' "$VPS_OPT/manifest.json")" = no ]
}

@test "Redis fermo con aclfile già presente: si riavvia invece di ACL LOAD" {
  redis_acl_setup
  : >"$BATS_TEST_TMPDIR/calls"
  make_stub systemctl 'echo "systemctl $*" >>"$BATS_TEST_TMPDIR/calls"
[ "$1" != is-active ]'
  redis_acl_setup
  grep -q 'systemctl restart redis-server' "$BATS_TEST_TMPDIR/calls"
  ! grep -q 'redis-cli' "$BATS_TEST_TMPDIR/calls"
}

@test "ACL LOAD che fallisce: file ACL di prima ripristinato, ritorno 1" {
  redis_acl_setup
  echo 'user site_x on #abc ~site_x:* +@all' >>"$REDIS_ACL_FILE"
  cp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/acl.prima"
  make_stub redis-cli 'exit 1'
  run redis_acl_setup
  [ "$status" -eq 1 ]
  cmp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/acl.prima"
}

@test "configurazione estranea in redis.conf: niente cambiato, ritorno 1" {
  local riga
  for riga in "aclfile /altro/file.acl" "user pippo on >x ~* +@all" "requirepass segreto" "  requirepass segreto"; do
    printf 'port 6379\n%s\n' "$riga" >"$REDIS_CONF"
    cp "$REDIS_CONF" "$BATS_TEST_TMPDIR/conf.prima"
    run redis_acl_setup
    [ "$status" -eq 1 ]
    cmp "$REDIS_CONF" "$BATS_TEST_TMPDIR/conf.prima"
    [ ! -e "$REDIS_ACL_FILE" ]
    [ ! -e "$REDIS_ADMIN_SECRET" ]
  done
}

@test "la nostra riga aclfile e i commenti non sono configurazione estranea" {
  printf 'port 6379\n# requirepass x\naclfile %s\n' "$REDIS_ACL_FILE" >"$REDIS_CONF"
  run redis_acl_setup
  [ "$status" -eq 0 ]
}

@test "prima volta: maxmemory 256mb con allkeys-lru, una sola volta" {
  printf 'port 6379\n# maxmemory <bytes>\n' >"$REDIS_CONF"
  redis_acl_setup
  redis_acl_setup
  [ "$(grep -cx 'maxmemory 256mb' "$REDIS_CONF")" = 1 ]
  [ "$(grep -cx 'maxmemory-policy allkeys-lru' "$REDIS_CONF")" = 1 ]
}

@test "un maxmemory già scelto resta com'è" {
  printf 'port 6379\nmaxmemory 1gb\n' >"$REDIS_CONF"
  redis_acl_setup
  grep -qx 'maxmemory 1gb' "$REDIS_CONF"
  ! grep -q '256mb\|maxmemory-policy' "$REDIS_CONF"
}

@test "riavvio fallito: il ripristino toglie anche maxmemory" {
  make_stub systemctl 'echo "systemctl $*" >>"$BATS_TEST_TMPDIR/calls"
[ "$1" = restart ] || exit 0
n=$(grep -c "systemctl restart" "$BATS_TEST_TMPDIR/calls"); [ "$n" -ge 2 ]'
  run redis_acl_setup
  [ "$status" -eq 1 ]
  ! grep -q maxmemory "$REDIS_CONF"
}

@test "lucchetto dei lavori occupato: niente toccato, ritorno 1 con un messaggio" {
  export REDIS_ACL_LOCK_WAIT=1
  exec 7>"$SITES_LOCK"
  flock -n 7
  run redis_acl_setup
  exec 7>&-
  [ "$status" -eq 1 ]
  [[ "$output" == *"vps-site"* ]] || grep -q 'vps-site' "$VPS_LOG"
  [ "$(cat "$REDIS_CONF")" = "port 6379" ]
  [ ! -e "$REDIS_ACL_FILE" ]
}

@test "il lucchetto si libera dopo redis_acl_setup" {
  redis_acl_setup
  flock -n "$SITES_LOCK" true
}

@test "copia di sicurezza non riuscita: niente toccato, nessun resto, ritorno 1" {
  redis_acl_setup
  : >"$BATS_TEST_TMPDIR/calls"
  cp "$REDIS_CONF" "$BATS_TEST_TMPDIR/conf.prima"
  cp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/acl.prima"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  local quale
  for quale in redis.conf users.acl; do
    # shellcheck disable=SC2016
    make_stub cp "[[ \"\$*\" == *$quale* ]] && exit 1; exec /bin/cp \"\$@\""
    hash -r
    run redis_acl_setup
    [ "$status" -eq 1 ]
    cmp "$REDIS_CONF" "$BATS_TEST_TMPDIR/conf.prima"
    cmp "$REDIS_ACL_FILE" "$BATS_TEST_TMPDIR/acl.prima"
    [ -z "$(ls -A "$TMPDIR")" ]
  done
  ! grep -q 'systemctl restart\|redis-cli' "$BATS_TEST_TMPDIR/calls"
}

@test "file ACL: il temporaneo nasce nella cartella sopra, di root" {
  mkdir -p "$BATS_TEST_TMPDIR/redis"
  export REDIS_ACL_FILE="$BATS_TEST_TMPDIR/redis/users.acl"
  # shellcheck disable=SC2016
  make_stub mktemp 'echo "mktemp $*" >>"$BATS_TEST_TMPDIR/calls"; exec /usr/bin/mktemp "$@"'
  redis_acl_setup
  grep -qxF "mktemp $BATS_TEST_TMPDIR/.vps-acl.XXXXXX" "$BATS_TEST_TMPDIR/calls"
  [ "$(stat -c %a "$REDIS_ACL_FILE")" = 640 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 2 -name '.vps-acl.*')" ]
}
