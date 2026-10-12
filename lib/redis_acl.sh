# shellcheck shell=bash
# Redis con utenti ACL: default spento, vps-admin per ACL LOAD, un utente per sito WordPress.

: "${REDIS_CONF:=/etc/redis/redis.conf}"
: "${REDIS_ACL_FILE:=/etc/redis/users.acl}"
: "${REDIS_ADMIN_SECRET:=$VPS_OPT/secrets/redis-admin}"

# redis_acl_setup — idempotente. Le righe `user site_*` (una per sito WordPress,
# scritte da vps-site) si conservano a ogni rigenerazione del file. Il riavvio
# serve solo la prima volta (aclfile non si carica a caldo); poi basta ACL LOAD.
redis_acl_setup() {
  local pw h sites="" first=0
  install -d -m 700 "$(dirname "$REDIS_ADMIN_SECRET")"
  if [[ ! -s "$REDIS_ADMIN_SECRET" ]]; then
    rand_secret 48 | write_file "$REDIS_ADMIN_SECRET" 600 root:root
  fi
  pw="$(head -n 1 "$REDIS_ADMIN_SECRET")"
  h="$(printf '%s' "$pw" | sha256sum | cut -d' ' -f1)"
  [[ -f "$REDIS_ACL_FILE" ]] && sites="$(grep '^user site_' "$REDIS_ACL_FILE" || true)"
  {
    printf 'user default off\n'
    printf 'user vps-admin on #%s ~* &* +@all\n' "$h"
    [[ -z "$sites" ]] || printf '%s\n' "$sites"
  } | write_file "$REDIS_ACL_FILE" 640 root:redis
  if ! grep -qx "aclfile $REDIS_ACL_FILE" "$REDIS_CONF"; then
    printf '\n# vps-installer: utenti ACL (default spento, uno per sito WordPress)\naclfile %s\n' "$REDIS_ACL_FILE" >>"$REDIS_CONF"
    first=1
  fi
  if ((first)); then
    systemctl restart redis-server || die "Redis non riparte con le ACL"
  else
    REDISCLI_AUTH="$pw" redis-cli --user vps-admin ACL LOAD >>"$VPS_LOG" 2>&1 || die "Redis non ha ricaricato le ACL"
  fi
  manifest_set '.components.redis_acl = true'
}
