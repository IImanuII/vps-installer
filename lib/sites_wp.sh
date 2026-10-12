# shellcheck shell=bash
# WordPress sui siti di vps-site: validazione, segnaposto, wp-config.php,
# utente Redis per sito, cron, WP-CLI come utente del sito.

: "${REDIS_ACL_FILE:=/etc/redis/users.acl}"
: "${REDIS_ADMIN_SECRET:=$VPS_OPT/secrets/redis-admin}"
: "${WP_BIN:=/usr/local/bin/wp}"
: "${CRON_D:=/etc/cron.d}"

SITE_PLACEHOLDER_MARK='<!-- vps-site:segnaposto -->'

site_wp_valid_title() {
  local LC_ALL=C t="$1"
  ((${#t} >= 1 && ${#t} <= 100)) || return 1
  [[ "$t" != *[[:cntrl:]]* ]]
}

site_wp_valid_user() {
  local LC_ALL=C
  [[ "$1" =~ ^[a-z0-9_.-]{3,60}$ ]] && ! in_list "$1" admin administrator root
}

site_wp_valid_email() {
  local LC_ALL=C
  ((${#1} <= 100)) && [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

site_wp_valid_path() {
  local LC_ALL=C
  [[ "$1" =~ ^[a-z0-9-]{4,40}$ ]] && ! in_list "$1" wp-admin wp-login admin login dashboard
}

# site_placeholder_intact DOMINIO — public/ contiene solo il segnaposto di vps-site:
# WordPress si installa solo lì, mai sopra un sito con file veri.
site_placeholder_intact() {
  local pub
  pub="$(site_root "$1")/public"
  [[ -f "$pub/index.html" && ! -L "$pub/index.html" ]] || return 1
  [[ "$(find "$pub" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]] || return 1
  grep -qF "$SITE_PLACEHOLDER_MARK" "$pub/index.html"
}

# site_wp_config_write DOMINIO DB_PASSWORD REDIS_PASSWORD — wp-config.php nella
# radice (di root), fuori dalla webroot: il sito lo legge, non può riscriverlo.
# shellcheck disable=SC2034
site_wp_config_write() {
  local d="$1" i rc
  # Le password finiscono in stringhe PHP tra apici: qui si rifiuta ci� che le romperebbe.
  if ! site_valid_db_password "$2" || ! site_valid_db_password "$3"; then
    site_fail "password non valida per wp-config.php"
    return 1
  fi
  WP_DOMAIN="$d"
  WP_DB_NAME="$(site_reg_get "$d" .slug)"
  WP_DB_PASSWORD="$2"
  WP_REDIS_PASSWORD="$3"
  for i in 1 2 3 4 5 6 7 8; do
    printf -v "WP_KEY$i" '%s' "$(rand_secret 64)"
  done
  render_template "$VPS_TEMPLATES/wp-config.php.tmpl" "$(site_root "$d")/wp-config.php" 640 "root:$WP_DB_NAME" \
    WP_DOMAIN WP_DB_NAME WP_DB_PASSWORD WP_REDIS_PASSWORD WP_KEY1 WP_KEY2 WP_KEY3 WP_KEY4 WP_KEY5 WP_KEY6 WP_KEY7 WP_KEY8
  rc=$?
  # I segreti non devono restare nell'ambiente dei processi figli successivi.
  export -n WP_DB_PASSWORD WP_REDIS_PASSWORD WP_KEY1 WP_KEY2 WP_KEY3 WP_KEY4 WP_KEY5 WP_KEY6 WP_KEY7 WP_KEY8
  return "$rc"
}

# site_wp_config_set_db_password DOMINIO PASSWORD — solo la riga DB_PASSWORD;
# awk con la password nell'ambiente: & | / non hanno significati speciali.
site_wp_config_set_db_password() {
  local f slug out
  site_valid_db_password "$2" || { site_fail "password non valida per wp-config.php"; return 1; }
  f="$(site_root "$1")/wp-config.php"
  slug="$(site_reg_get "$1" .slug)"
  out="$(WP_NEW_PASS="$2" awk '
    index($0, "define( '\''DB_PASSWORD'\''") == 1 { found = 1; print "define( '\''DB_PASSWORD'\'', '\''" ENVIRON["WP_NEW_PASS"] "'\'' );"; next }
    { print }
    END { exit !found }' "$f")" || { site_fail "riga DB_PASSWORD non trovata in wp-config.php"; return 1; }
  printf '%s\n' "$out" | write_file "$f" 640 "root:$slug"
}

# site_redis_reload — ACL LOAD con l'utente di amministrazione; la password passa
# da REDISCLI_AUTH (l'ambiente), mai dagli argomenti visibili con ps.
site_redis_reload() {
  local pw
  pw="$(head -n 1 "$REDIS_ADMIN_SECRET" 2>/dev/null)" || return 1
  [[ -n "$pw" ]] || return 1
  REDISCLI_AUTH="$pw" redis-cli --user vps-admin ACL LOAD >>"$VPS_LOG" 2>&1
}

# site_redis_acl_replace DOMINIO [RIGA] — toglie la riga del sito e, se data, ne
# mette una nuova; se Redis rifiuta il file rimette quello di prima.
site_redis_acl_replace() {
  local slug bak new
  slug="$(site_reg_get "$1" .slug)"
  bak="$(mktemp)"
  cp -p "$REDIS_ACL_FILE" "$bak" || return 1
  new="$(
    grep -v "^user $slug " "$REDIS_ACL_FILE"
    [[ -z "${2:-}" ]] || printf '%s\n' "$2"
  )"
  printf '%s\n' "$new" | write_file "$REDIS_ACL_FILE" 640 root:redis || { rm -f "$bak"; return 1; }
  if site_redis_reload; then
    rm -f "$bak"
    return 0
  fi
  mv -f "$bak" "$REDIS_ACL_FILE"
  site_fail "Redis non ha accettato l'utente del sito (dettagli in $VPS_LOG)"
}

site_redis_user_add() {
  local slug h
  slug="$(site_reg_get "$1" .slug)"
  h="$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"
  site_redis_acl_replace "$1" "user $slug on #$h ~$slug:* &$slug:* +@all -@dangerous -@admin +info"
}

site_redis_user_remove() {
  grep -q "^user $(site_reg_get "$1" .slug) " "$REDIS_ACL_FILE" 2>/dev/null || return 0
  site_redis_acl_replace "$1"
}

site_wp_cron_file() {
  printf '%s/vps-site-%s' "$CRON_D" "$(site_reg_get "$1" .slug)"
}

# shellcheck disable=SC2034
site_wp_cron_add() {
  WP_DOMAIN="$1"
  WP_DB_NAME="$(site_reg_get "$1" .slug)"
  WP_ROOT="$(site_root "$1")"
  render_template "$VPS_TEMPLATES/cron-site-wp.tmpl" "$(site_wp_cron_file "$1")" 644 root:root \
    WP_DOMAIN WP_DB_NAME WP_ROOT WP_BIN
}

site_wp_cron_remove() {
  rm -f "$(site_wp_cron_file "$1")"
}

# site_wp DOMINIO ARG... — WP-CLI come utente del sito (WP-CLI rifiuta root, e
# così ogni file creato è del sito), cache e HOME in tmp/ del sito.
site_wp() {
  local d="$1" slug root
  shift
  slug="$(site_reg_get "$d" .slug)"
  root="$(site_root "$d")"
  # cwd = radice del sito: quella di chi chiama potrebbe non essere leggibile dal sito.
  (cd "$root" && runuser -u "$slug" -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$root/tmp" \
    WP_CLI_CACHE_DIR="$root/tmp/.wp-cli" "$WP_BIN" --path="$root/public" "$@")
}
