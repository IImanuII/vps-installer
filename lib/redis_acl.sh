# shellcheck shell=bash
# Redis con utenti ACL: default spento, vps-admin per ACL LOAD, un utente per sito WordPress.

: "${REDIS_CONF:=/etc/redis/redis.conf}"
: "${REDIS_ACL_FILE:=/etc/redis/users.acl}"
: "${REDIS_ADMIN_SECRET:=$VPS_OPT/secrets/redis-admin}"
: "${SITES_LOCK:=/run/vps-site.lock}"

# redis_acl_write MODE OWNER — il file ACL da stdin, sostituito in modo atomico.
# /etc/redis è redis:redis 2770: un file temporaneo creato lì dentro potrebbe
# essere toccato dall'utente redis prima di chmod/chown. Si crea nella cartella
# sopra (di root, stesso filesystem: mv resta atomico) e si sposta solo alla fine.
redis_acl_write() {
  local tmp
  tmp="$(mktemp "$(dirname "$(dirname "$REDIS_ACL_FILE")")/.vps-acl.XXXXXX")" || return 1
  if ! { cat >"$tmp" && chmod "$1" "$tmp" && own "$2" "$tmp" && mv -f "$tmp" "$REDIS_ACL_FILE"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# redis_acl_setup — idempotente. Le righe `user site_*` (una per sito WordPress,
# scritte da vps-site) si conservano a ogni rigenerazione del file. Il riavvio
# serve solo la prima volta (aclfile non si carica a caldo); poi basta ACL LOAD.
# Non abortisce mai l'installer: se qualcosa non va ripristina i file di prima,
# rimette in piedi Redis e ritorna 1 (components.redis_acl resta non impostato).
redis_acl_setup() {
  local rc=0
  # Una configurazione ACL o una password già presenti non sono nostre: mescolarle
  # con le nostre cambierebbe chi può collegarsi, quindi ci si ferma senza toccare nulla.
  if grep -E '^[[:space:]]*(aclfile|user|requirepass)[[:space:]]' "$REDIS_CONF" 2>/dev/null \
    | grep -vqxF "aclfile $REDIS_ACL_FILE"; then
    log "ATTENZIONE: $REDIS_CONF ha già aclfile/user/requirepass non nostri: Redis non configurato con le ACL"
    return 1
  fi
  # Il lucchetto dei lavori di vps-site: un lavoro in corso riscrive anche lui
  # users.acl (utente del sito) e una delle due modifiche andrebbe persa.
  exec 6>"$SITES_LOCK" || { log "ATTENZIONE: lucchetto $SITES_LOCK non aperto: Redis non configurato con le ACL"; return 1; }
  if ! flock -w "${REDIS_ACL_LOCK_WAIT:-60}" 6; then
    exec 6>&-
    log "ATTENZIONE: un lavoro di vps-site è in corso da troppo tempo: Redis non configurato con le ACL (rilancia l'installer)"
    return 1
  fi
  redis_acl_setup_locked || rc=1
  exec 6>&-
  return "$rc"
}

redis_acl_setup_locked() {
  local pw h sites="" first=0 conf_bak acl_bak="" had_acl=0
  install -d -m 700 "$(dirname "$REDIS_ADMIN_SECRET")"
  if [[ ! -s "$REDIS_ADMIN_SECRET" ]]; then
    rand_secret 48 | write_file "$REDIS_ADMIN_SECRET" 600 root:root
  fi
  pw="$(head -n 1 "$REDIS_ADMIN_SECRET")"
  h="$(printf '%s' "$pw" | sha256sum | cut -d' ' -f1)"
  # Senza copie complete non si tocca nulla: non ci sarebbe come tornare indietro.
  conf_bak="$(mktemp)" || { log "ATTENZIONE: copia di $REDIS_CONF non riuscita: Redis non configurato con le ACL"; return 1; }
  if ! cp -p "$REDIS_CONF" "$conf_bak"; then
    rm -f "$conf_bak"
    log "ATTENZIONE: copia di $REDIS_CONF non riuscita: Redis non configurato con le ACL"
    return 1
  fi
  if [[ -f "$REDIS_ACL_FILE" ]]; then
    had_acl=1
    if ! acl_bak="$(mktemp)" || ! cp -p "$REDIS_ACL_FILE" "$acl_bak"; then
      rm -f "$conf_bak" "$acl_bak"
      log "ATTENZIONE: copia di $REDIS_ACL_FILE non riuscita: Redis non configurato con le ACL"
      return 1
    fi
    sites="$(grep '^user site_' "$REDIS_ACL_FILE" || true)"
  fi
  if ! {
    printf 'user default off\n'
    printf 'user vps-admin on #%s ~* &* +@all\n' "$h"
    [[ -z "$sites" ]] || printf '%s\n' "$sites"
  } | redis_acl_write 640 root:redis; then
    log "ATTENZIONE: $REDIS_ACL_FILE non scritto: Redis non configurato con le ACL"
    rm -f "$conf_bak" "$acl_bak"
    return 1
  fi
  if ! grep -qxF "aclfile $REDIS_ACL_FILE" "$REDIS_CONF"; then
    printf '\n# vps-installer: utenti ACL (default spento, uno per sito WordPress)\naclfile %s\n' "$REDIS_ACL_FILE" >>"$REDIS_CONF"
    # Cache limitata: di serie Redis non ha limite (maxmemory 0) e con noeviction,
    # pieno, rifiuta le scritture. Un maxmemory già scelto dall'amministratore resta.
    if ! grep -qE '^[[:space:]]*maxmemory[[:space:]]' "$REDIS_CONF"; then
      printf '# vps-installer: cache dei siti limitata, si scartano le chiavi meno usate\nmaxmemory 256mb\nmaxmemory-policy allkeys-lru\n' >>"$REDIS_CONF"
      log "Redis: maxmemory 256mb con allkeys-lru (si può cambiare in $REDIS_CONF)"
    fi
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
