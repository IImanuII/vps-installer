# shellcheck shell=bash
# Redis con utenti ACL: default spento, vps-admin per ACL LOAD, un utente per sito WordPress.

: "${REDIS_CONF:=/etc/redis/redis.conf}"
: "${REDIS_ACL_FILE:=/etc/redis/users.acl}"
: "${REDIS_ADMIN_SECRET:=$VPS_OPT/secrets/redis-admin}"

# redis_acl_setup — idempotente. Le righe `user site_*` (una per sito WordPress,
# scritte da vps-site) si conservano a ogni rigenerazione del file. Il riavvio
# serve solo la prima volta (aclfile non si carica a caldo); poi basta ACL LOAD.
# Non abortisce mai l'installer: se qualcosa non va ripristina i file di prima,
# rimette in piedi Redis e ritorna 1 (components.redis_acl resta non impostato).
redis_acl_setup() {
  local pw h sites="" first=0 conf_bak acl_bak="" had_acl=0
  # Una configurazione ACL o una password già presenti non sono nostre: mescolarle
  # con le nostre cambierebbe chi può collegarsi, quindi ci si ferma senza toccare nulla.
  if grep -E '^[[:space:]]*(aclfile|user|requirepass)[[:space:]]' "$REDIS_CONF" 2>/dev/null \
    | grep -vqxF "aclfile $REDIS_ACL_FILE"; then
    log "ATTENZIONE: $REDIS_CONF ha già aclfile/user/requirepass non nostri: Redis non configurato con le ACL"
    return 1
  fi
  install -d -m 700 "$(dirname "$REDIS_ADMIN_SECRET")"
  if [[ ! -s "$REDIS_ADMIN_SECRET" ]]; then
    rand_secret 48 | write_file "$REDIS_ADMIN_SECRET" 600 root:root
  fi
  pw="$(head -n 1 "$REDIS_ADMIN_SECRET")"
  h="$(printf '%s' "$pw" | sha256sum | cut -d' ' -f1)"
  conf_bak="$(mktemp)"
  cp -p "$REDIS_CONF" "$conf_bak"
  if [[ -f "$REDIS_ACL_FILE" ]]; then
    had_acl=1
    acl_bak="$(mktemp)"
    cp -p "$REDIS_ACL_FILE" "$acl_bak"
    sites="$(grep '^user site_' "$REDIS_ACL_FILE" || true)"
  fi
  {
    printf 'user default off\n'
    printf 'user vps-admin on #%s ~* &* +@all\n' "$h"
    [[ -z "$sites" ]] || printf '%s\n' "$sites"
  } | write_file "$REDIS_ACL_FILE" 640 root:redis
  if ! grep -qxF "aclfile $REDIS_ACL_FILE" "$REDIS_CONF"; then
    printf '\n# vps-installer: utenti ACL (default spento, uno per sito WordPress)\naclfile %s\n' "$REDIS_ACL_FILE" >>"$REDIS_CONF"
    first=1
    log "Redis: l'utente default è spento: i client senza credenziali non si collegano più"
  fi
  if ((first)) || ! systemctl is-active --quiet redis-server; then
    if ! systemctl restart redis-server >>"$VPS_LOG" 2>&1; then
      log "ATTENZIONE: Redis non riparte con le ACL (dettagli in $VPS_LOG): ripristino la configurazione di prima"
      redis_acl_restore "$conf_bak" "$acl_bak" "$had_acl"
      return 1
    fi
  elif ! REDISCLI_AUTH="$pw" redis-cli --user vps-admin ACL LOAD >>"$VPS_LOG" 2>&1; then
    log "ATTENZIONE: Redis non ha ricaricato le ACL (dettagli in $VPS_LOG): ripristino i file di prima"
    redis_acl_restore "$conf_bak" "$acl_bak" "$had_acl"
    return 1
  fi
  rm -f "$conf_bak" "$acl_bak"
  manifest_set '.components.redis_acl = true'
}

# redis_acl_restore CONF_BAK ACL_BAK HAD_ACL — rimette i file di prima e riavvia Redis.
redis_acl_restore() {
  mv -f "$1" "$REDIS_CONF"
  if (($3)); then
    mv -f "$2" "$REDIS_ACL_FILE"
  else
    rm -f "$REDIS_ACL_FILE" "$2"
  fi
  systemctl restart redis-server >>"$VPS_LOG" 2>&1 || log "ATTENZIONE: Redis non riparte nemmeno con la configurazione di prima"
}
