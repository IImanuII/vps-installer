# shellcheck shell=bash
# Siti gestiti da vps-site: nomi, registro, passi di creazione ed eliminazione.
# Il registro (/opt/vps/sites/<dominio>.json) è la fonte di verità: il pannello
# lo legge con `sudo vps-site list` e non ne tiene copia.

: "${SITES_DIR:=$VPS_OPT/sites}"
: "${SITES_WWW:=/var/www}"
: "${SITES_BACKUPS:=$VPS_OPT/backups/sites}"
: "${SITES_LOCK:=/run/vps-site.lock}"
: "${SITES_RUN:=/run/vps-site}"
: "${NGINX_CONF_D:=/etc/nginx/conf.d}"
: "${PHP_POOL_D:=/etc/php/$PHP_VERSION/fpm/pool.d}"
: "${LOGROTATE_D:=/etc/logrotate.d}"
: "${VPS_SITE_SELF:=$VPS_OPT/bin/vps-site}"

# site_slug DOMINIO — nome di utente, gruppo, database e utente DB del sito.
# Linux accetta al massimo 32 caratteri: oltre, si tronca e si aggiunge un pezzo
# di hash del dominio, così due domini lunghi simili non si scontrano.
site_slug() {
  local s="site_${1//[.-]/_}" h
  if ((${#s} > 32)); then
    h="$(printf '%s' "$1" | sha256sum | cut -c1-4)"
    s="${s:0:27}_$h"
  fi
  printf '%s' "$s"
}

site_root() {
  printf '%s/%s' "$SITES_WWW" "$1"
}

site_reg_path() {
  printf '%s/%s.json' "$SITES_DIR" "$1"
}

site_reg_exists() {
  [[ -f "$(site_reg_path "$1")" ]]
}

# site_reg_get DOMINIO FILTRO — un campo del registro (jq -r).
site_reg_get() {
  jq -r "$2" "$(site_reg_path "$1")"
}

# site_reg_write DOMINIO — registro da stdin, sostituzione atomica; root:panel 640.
site_reg_write() {
  install -d -m 750 "$SITES_DIR"
  own "root:$(manifest_group)" "$SITES_DIR"
  write_file "$(site_reg_path "$1")" 640 "root:$(manifest_group)"
}

# site_reg_update DOMINIO FILTRO [ARGOMENTI_JQ...]
site_reg_update() {
  local d="$1" filter="$2" json
  shift 2
  json="$(jq "$@" "$filter" "$(site_reg_path "$d")")" || return 1
  printf '%s\n' "$json" | site_reg_write "$d"
}

# site_reg_new DOMINIO TIPO WWW DB — registro di un sito appena chiesto (WWW e DB: yes|no).
site_reg_new() {
  jq -n --arg d "$1" --arg slug "$(site_slug "$1")" --arg t "$2" --arg www "$3" --arg db "$4" \
    --arg at "$(date -Iseconds)" --arg ts "$(date +%s)" '
    {domain: $d, slug: $slug, type: $t, www: ($www == "yes"), db: ($db == "yes"),
     state: "creating", zone: null, dns_records: [],
     job: {op: "create", step: "queued", error: null, updated_at: $at, ts: ($ts | tonumber)},
     created_at: $at}' | site_reg_write "$1"
}

# site_job DOMINIO OP PASSO [ERRORE] — avanzamento del lavoro, letto dal pannello.
site_job() {
  site_reg_update "$1" \
    '.job = {op: $op, step: $step, error: (if $err == "" then null else $err end), updated_at: $at, ts: ($ts | tonumber)}' \
    --arg op "$2" --arg step "$3" --arg err "${4:-}" --arg at "$(date -Iseconds)" --arg ts "$(date +%s)"
}

# site_fail MESSAGGIO — il motivo dell'errore per il pannello (finisce in job.error).
site_fail() {
  log "vps-site: $*"
  if [[ -n "${SITE_ERROR_FILE:-}" ]]; then
    printf '%s\n' "$*" >"$SITE_ERROR_FILE"
  fi
  return 1
}

# site_validate_new DOMINIO — 0 se il dominio può diventare un sito nuovo,
# altrimenti stampa il motivo e restituisce 1. I nomi riservati (_acme,
# _maintenance) non passano già da valid_domain.
site_validate_new() {
  local d="$1" panel slug f
  if ! valid_domain "$d"; then
    echo "dominio non valido: $d"
    return 1
  fi
  if [[ "$d" == www.* ]]; then
    echo "indica il dominio senza www: il www si aggiunge con --www"
    return 1
  fi
  panel="$(jq -r '.panel.domain // empty' "$(manifest_path)")"
  if [[ -n "$panel" && "$d" == "$panel" ]]; then
    echo "$d è il dominio del pannello"
    return 1
  fi
  if site_reg_exists "$d"; then
    echo "il sito $d esiste già"
    return 1
  fi
  # Anche un collegamento simbolico rotto conta: install -d lo seguirebbe.
  if [[ -e "$(site_root "$d")" || -L "$(site_root "$d")" ]]; then
    echo "la cartella $(site_root "$d") esiste già e non è un sito di vps-site"
    return 1
  fi
  # Un vhost con lo stesso nome lo sovrascriveremmo, e all'eliminazione sparirebbe.
  if [[ -e "$NGINX_CONF_D/$d.conf" || -L "$NGINX_CONF_D/$d.conf" ]]; then
    echo "esiste già una configurazione Nginx per $d ($NGINX_CONF_D/$d.conf)"
    return 1
  fi
  slug="$(site_slug "$d")"
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(jq -r .slug "$f")" == "$slug" ]]; then
      echo "il nome $slug è già usato da $(jq -r .domain "$f")"
      return 1
    fi
  done
  if getent passwd "$slug" >/dev/null 2>&1 || getent group "$slug" >/dev/null 2>&1; then
    echo "l'utente o il gruppo $slug esiste già sul sistema"
    return 1
  fi
}

# site_cf_token — il token di sistema (lo stesso di certbot) per cf_api.
site_cf_token() {
  CF_API_TOKEN="$(cf_token_from_ini)"
  export CF_API_TOKEN
  [[ -n "$CF_API_TOKEN" ]]
}

# site_names DOMINIO — i nomi serviti: il dominio e, se richiesto, www.
site_names() {
  printf '%s\n' "$1"
  if [[ "$(site_reg_get "$1" .www)" == true ]]; then
    printf 'www.%s\n' "$1"
  fi
}

# site_dns_add DOMINIO — record A (e AAAA con IPv6) proxati verso la VPS per ogni
# nome. Prima si controllano tutti i nomi, poi si crea: con un conflitto non si
# crea niente. Un record già giusto si riusa e non si annota, quindi
# all'eliminazione resta dov'è.
site_dns_add() {
  local d="$1" zone zid zname v4 v6 n recs conflicts type ip id t
  local todo=()
  zone="$(cf_find_zone "$d")" \
    || { site_fail "la zona di $d non è su Cloudflare o il token non la vede: serve un token con Zone: Read e DNS: Edit su tutte le zone"; return 1; }
  read -r zid zname <<<"$zone"
  # Il certificato gratuito di Cloudflare copre la zona e un solo livello di
  # sottodomini (*.zona): www.blog.zona non avrebbe HTTPS sul bordo di Cloudflare.
  if [[ "$(site_reg_get "$d" .www)" == true && "$d" != "$zname" ]]; then
    site_fail "il www si aggiunge solo al dominio principale della zona ($zname): Cloudflare non ha un certificato per www.$d"
    return 1
  fi
  site_reg_update "$d" '.zone = {id: $id, name: $name}' --arg id "$zid" --arg name "$zname" || return 1
  v4="$(jq -r '.ipv4 // empty' "$(manifest_path)")"
  v6="$(jq -r '.ipv6 // empty' "$(manifest_path)")"
  while read -r n; do
    recs="$(cf_list_records "$zid" "$n")" || { site_fail "Cloudflare non risponde (record di $n)"; return 1; }
    conflicts="$(cf_dns_conflicts "$recs" "$v4" "$v6")"
    if [[ -n "$conflicts" ]]; then
      site_fail "il record ${conflicts%%$'\n'*} punta altrove: toglilo da Cloudflare o scegli un altro nome"
      return 1
    fi
    # Un record giusto ma col proxy spento non va: l'origine accetta solo il
    # traffico che arriva da Cloudflare, quindi il sito non risponderebbe.
    conflicts="$(jq -r --arg v4 "$v4" --arg v6 "$v6" '
      .result[]
      | select(((.type == "A" and .content == $v4) or (.type == "AAAA" and .content == $v6))
          and .proxied != true)
      | "\(.type) \(.name)"' <<<"$recs")"
    if [[ -n "$conflicts" ]]; then
      site_fail "il record ${conflicts%%$'\n'*} non passa da Cloudflare (proxy spento): attivalo o toglilo"
      return 1
    fi
    for type in A AAAA; do
      ip="$v4"
      [[ "$type" == A ]] || ip="$v6"
      [[ -n "$ip" ]] || continue
      if jq -e --arg t "$type" --arg c "$ip" 'any(.result[]; .type == $t and .content == $c)' >/dev/null <<<"$recs"; then
        continue
      fi
      todo+=("$type $n $ip")
    done
  done < <(site_names "$d")
  for t in "${todo[@]}"; do
    read -r type n ip <<<"$t"
    id="$(cf_create_record "$zid" "$type" "$n" "$ip")" || { site_fail "Cloudflare non ha creato il record $type di $n"; return 1; }
    site_reg_update "$d" '.dns_records += [{id: $id, name: $n, type: $t}]' --arg id "$id" --arg n "$n" --arg t "$type" || return 1
  done
}

# site_dns_remove DOMINIO — toglie i record annotati; uno che non c'è più non è
# un errore. Restituisce 1 se Cloudflare ne ha rifiutato qualcuno.
site_dns_remove() {
  local d="$1" zid id n recs left_json
  local left=()
  zid="$(site_reg_get "$d" '.zone.id // empty')"
  [[ -n "$zid" ]] || return 0
  while read -r id n; do
    [[ -n "$id" ]] || continue
    cf_delete_record "$zid" "$id" && continue
    # Un record già tolto a mano fa fallire la DELETE: se non compare più tra
    # quelli del nome, è come tolto.
    if recs="$(cf_list_records "$zid" "$n")" \
      && ! jq -e --arg i "$id" 'any(.result[]; .id == $i)' >/dev/null <<<"$recs"; then
      continue
    fi
    log "ATTENZIONE: record $id ($n) di $d non eliminato da Cloudflare"
    left+=("$id")
  done < <(site_reg_get "$d" '.dns_records[] | "\(.id) \(.name)"')
  # Restano annotati solo i record non tolti: un nuovo tentativo riprova quelli.
  left_json="$(printf '%s\n' "${left[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"
  site_reg_update "$d" '.dns_records |= map(select(.id as $i | $left | any(. == $i)))' \
    --argjson left "$left_json" || return 1
  ((${#left[@]} == 0))
}

# site_cert_issue DOMINIO — certificato Let's Encrypt via DNS Cloudflare per tutti i nomi.
site_cert_issue() {
  local n args=(certonly -n --agree-tos --register-unsafely-without-email --keep-until-expiring
    --cert-name "$1" --dns-cloudflare --dns-cloudflare-credentials "$VPS_OPT/secrets/cloudflare.ini"
    --dns-cloudflare-propagation-seconds 30)
  while read -r n; do
    args+=(-d "$n")
  done < <(site_names "$1")
  certbot "${args[@]}" >>"$VPS_LOG" 2>&1 \
    || site_fail "Let's Encrypt non ha rilasciato il certificato (dettagli in $VPS_LOG)"
}

site_cert_remove() {
  certbot delete -n --cert-name "$1" >>"$VPS_LOG" 2>&1 || true
}

# site_user_add DOMINIO — utente e gruppo del sito, cartelle e ACL.
# L'admin entra nel gruppo (scrive via SFTP con il proprio utente); www-data no:
# attraversa la radice e legge solo public/, grazie alle ACL.
site_user_add() {
  local d="$1" slug root admin
  slug="$(site_reg_get "$d" .slug)"
  root="$(site_root "$d")"
  getent group "$slug" >/dev/null 2>&1 || groupadd --system "$slug" || return 1
  id -u "$slug" >/dev/null 2>&1 \
    || useradd --system --gid "$slug" --home-dir "$root" --no-create-home --shell /usr/sbin/nologin "$slug" \
    || return 1
  admin="$(jq -r '.admin_user // empty' "$(manifest_path)")"
  if [[ -n "$admin" ]]; then
    gpasswd -a "$admin" "$slug" >/dev/null || return 1
  fi
  # La radice e logs/ sono di root (gruppo del sito, sola lettura): il sito non
  # può metterci collegamenti simbolici. Nginx (root) apre access.log ed
  # error.log seguendo i link a ogni reload, e vps-site scrive db.env qui:
  # in cartelle del sito un link verso /etc diventerebbe una scrittura come root.
  # Il sito scrive solo in public/, tmp/ e logs/php/ (il log di PHP).
  install -d -m 2750 "$root" "$root/logs" || return 1
  own "root:$slug" "$root" "$root/logs" || return 1
  install -d -m 2770 "$root/logs/php" "$root/public" "$root/tmp" || return 1
  own "$slug:$slug" "$root/logs/php" "$root/public" "$root/tmp" || return 1
  setfacl -m u:www-data:x "$root" || return 1
  setfacl -m u:www-data:rX -m d:u:www-data:rX "$root/public" || return 1
  # I file creati da PHP restano modificabili dall'admin e viceversa.
  setfacl -m d:g::rwX "$root/public" "$root/tmp" || return 1
  # shellcheck disable=SC2016
  SITE_DOMAIN="$d" envsubst '${SITE_DOMAIN}' <"$VPS_TEMPLATES/site-placeholder.html.tmpl" \
    | write_file "$root/public/index.html" 664 "$slug:$slug"
}

# site_user_remove DOMINIO — utente, gruppo e radice; ciò che manca già si salta.
# Restituisce 1 se qualcosa resta, ma prova comunque a togliere tutto.
site_user_remove() {
  local d="$1" slug root rc=0
  slug="$(site_reg_get "$d" .slug)"
  root="$(site_root "$d")"
  # Mai un rm -rf su un percorso che non sia la radice di un sito di vps-site.
  [[ -n "$d" && "$slug" == site_* && "$root" == "$SITES_WWW/$d" ]] || return 1
  if id -u "$slug" >/dev/null 2>&1; then
    # Subito dopo il reload (asincrono) di PHP-FPM i processi del pool possono
    # girare ancora come utente del sito, e userdel si rifiuterebbe.
    pkill -u "$slug" >/dev/null 2>&1 || true
    for _ in {1..50}; do
      pgrep -u "$slug" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if ! userdel "$slug" >>"$VPS_LOG" 2>&1; then
      userdel -f "$slug" >>"$VPS_LOG" 2>&1 || rc=1
    fi
  fi
  if getent group "$slug" >/dev/null 2>&1; then
    groupdel "$slug" >>"$VPS_LOG" 2>&1 || rc=1
  fi
  rm -rf --one-file-system -- "$root" || rc=1
  return "$rc"
}

site_pool_file() {
  printf '%s/%s.conf' "$PHP_POOL_D" "$(site_reg_get "$1" .slug)"
}

# site_pool_add DOMINIO — pool PHP-FPM del sito (utente del sito, open_basedir sulla radice).
site_pool_add() {
  local d="$1" f
  f="$(site_pool_file "$d")"
  SITE_DOMAIN="$d" SITE_SLUG="$(site_reg_get "$d" .slug)" SITE_ROOT="$(site_root "$d")" \
    render_template "$VPS_TEMPLATES/php-pool-site.conf.tmpl" "$f" 644 root:root \
    SITE_DOMAIN SITE_SLUG SITE_ROOT PHP_VERSION || return 1
  if ! "php-fpm$PHP_VERSION" -t >>"$VPS_LOG" 2>&1; then
    rm -f "$f"
    site_fail "configurazione PHP-FPM del sito non valida (dettagli in $VPS_LOG)"
    return 1
  fi
  systemctl reload "php$PHP_VERSION-fpm" || site_fail "PHP-FPM non si è ricaricato"
}

site_pool_remove() {
  local f
  f="$(site_pool_file "$1")"
  [[ -f "$f" ]] || return 0
  rm -f "$f" || return 1
  systemctl reload "php$PHP_VERSION-fpm" || log "ATTENZIONE: PHP-FPM non ricaricato dopo la rimozione del pool di $1"
}

site_logrotate_add() {
  local slug
  slug="$(site_reg_get "$1" .slug)"
  SITE_SLUG="$slug" SITE_ROOT="$(site_root "$1")" \
    render_template "$VPS_TEMPLATES/logrotate-site.tmpl" "$LOGROTATE_D/vps-site-$slug" 644 root:root SITE_SLUG SITE_ROOT
}

site_logrotate_remove() {
  rm -f "$LOGROTATE_D/vps-site-$(site_reg_get "$1" .slug)"
}

# site_tmpl_text FILE VAR... — il testo di un template con le sole variabili elencate.
site_tmpl_text() {
  local src="$1" v fmt=""
  shift
  for v in "$@"; do
    export "${v?}"
    fmt+="\${$v} "
  done
  envsubst "$fmt" <"$src"
}

# site_vhost_add DOMINIO [normal|maintenance] — scrive il vhost e ricarica Nginx.
# Se nginx -t lo rifiuta rimette il file di prima (o nessuno): un vhost rotto
# bloccherebbe i reload di tutti i siti e del pannello.
# Le variabili SITE_* le legge render_template (envsubst), non lo vede shellcheck.
# shellcheck disable=SC2034
site_vhost_add() {
  local d="$1" mode="${2:-normal}" f bak="" variant
  f="$NGINX_CONF_D/$d.conf"
  SITE_DOMAIN="$d"
  SITE_SLUG="$(site_reg_get "$d" .slug)"
  SITE_ROOT="$(site_root "$d")"
  SITE_NAMES="$d"
  SITE_WWW_BLOCK=""
  if [[ "$mode" == maintenance ]]; then
    variant=maintenance
  else
    variant="$(site_reg_get "$d" .type)"
  fi
  SITE_BODY="$(site_tmpl_text "$VPS_TEMPLATES/nginx-site-$variant.inc.tmpl" SITE_DOMAIN SITE_SLUG PHP_VERSION)"
  if [[ "$(site_reg_get "$d" .www)" == true ]]; then
    SITE_NAMES="$d www.$d"
    SITE_WWW_BLOCK="$(site_tmpl_text "$VPS_TEMPLATES/nginx-site-www.inc.tmpl" SITE_DOMAIN)"
  fi
  if [[ -f "$f" ]]; then
    bak="$(mktemp)"
    cp -p "$f" "$bak"
  fi
  render_template "$VPS_TEMPLATES/nginx-site.conf.tmpl" "$f" 644 root:root \
    SITE_DOMAIN SITE_NAMES SITE_ROOT SITE_BODY SITE_WWW_BLOCK || return 1
  if nginx -t >>"$VPS_LOG" 2>&1; then
    rm -f "$bak"
    systemctl reload nginx || site_fail "Nginx non si è ricaricato"
    return
  fi
  if [[ -n "$bak" ]]; then
    mv -f "$bak" "$f"
  else
    rm -f "$f"
  fi
  site_fail "la configurazione Nginx di $d non è valida (dettagli in $VPS_LOG)"
}

site_vhost_remove() {
  local f="$NGINX_CONF_D/$1.conf"
  [[ -f "$f" ]] || return 0
  rm -f "$f" || return 1
  if ! { nginx -t >>"$VPS_LOG" 2>&1 && systemctl reload nginx; }; then
    log "ATTENZIONE: Nginx non ricaricato dopo la rimozione del vhost di $1"
  fi
}

# site_valid_db_password PASSWORD — 16-128 caratteri ASCII stampabili, senza
# spazi né ' " \ (la genera il pannello; il controllo è una difesa in più).
site_valid_db_password() {
  local p="$1"
  ((${#p} >= 16 && ${#p} <= 128)) || return 1
  LC_ALL=C
  [[ "$p" =~ ^[[:graph:]]+$ ]] || return 1
  [[ "$p" != *[\'\"\\]* ]]
}

# site_db_sql SLUG PASSWORD — database e utente del sito. Nel GRANT gli _ vanno
# protetti: altrimenti sono caratteri jolly e il permesso varrebbe anche per
# altri nomi simili.
site_db_sql() {
  local esc="${1//_/\\_}"
  printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$1"
  sql_user_grant "$1" "$2" "ALL PRIVILEGES" "\`$esc\`.*"
}

# db.env è root:<sito> 640 nella radice, che è di root: PHP e l'admin (gruppo)
# lo leggono, ma il sito non può sostituirlo con un link che vps-site seguirebbe.
site_db_add() {
  local d="$1" slug
  slug="$(site_reg_get "$d" .slug)"
  site_db_sql "$slug" "$2" | mariadb >>"$VPS_LOG" 2>&1 \
    || { site_fail "il database $slug non è stato creato (dettagli in $VPS_LOG)"; return 1; }
  printf 'DB_HOST=localhost\nDB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\n' "$slug" "$slug" "$2" \
    | write_file "$(site_root "$d")/db.env" 640 "root:$slug"
}

site_db_alter_password() {
  printf "ALTER USER '%s'@'localhost' IDENTIFIED BY %s;\n" "$1" "$(sql_quote "$2")" | mariadb >>"$VPS_LOG" 2>&1
}

# site_db_password DOMINIO PASSWORD — su un sito WordPress anche wp-config.php:
# DB e wp-config devono cambiare insieme, altrimenti il sito non si connette più.
site_db_password() {
  local d="$1" slug old
  slug="$(site_reg_get "$d" .slug)"
  old="$(env_get "$(site_root "$d")/db.env" DB_PASS)"
  site_db_alter_password "$slug" "$2" \
    || { site_fail "la password del database non è stata cambiata (dettagli in $VPS_LOG)"; return 1; }
  if [[ "$(site_reg_get "$d" .type)" == wordpress ]] && ! site_wp_config_set_db_password "$d" "$2"; then
    # wp-config.php non aggiornato: si rimette nel DB la password di prima
    # (db.env non è ancora cambiato), così il sito continua a funzionare.
    if [[ -z "$old" ]] || ! site_db_alter_password "$slug" "$old"; then
      log "ATTENZIONE: password del database di $d cambiata ma wp-config.php non aggiornato"
    fi
    return 1
  fi
  if ! printf 'DB_PASS=%s\n' "$2" | env_merge "$(site_root "$d")/db.env" 640 "root:$slug"; then
    site_fail "password del database cambiata, ma db.env non aggiornato (dettagli in $VPS_LOG)"
    return 1
  fi
}

site_db_remove() {
  local slug
  slug="$(site_reg_get "$1" .slug)"
  printf "DROP DATABASE IF EXISTS \`%s\`;\nDROP USER IF EXISTS '%s'@'localhost';\n" "$slug" "$slug" \
    | mariadb >>"$VPS_LOG" 2>&1 || { log "ATTENZIONE: database o utente $slug non eliminati"; return 1; }
}

# site_step DOMINIO OP PASSO FUNZIONE [ARG...] — registra il passo e lo esegue in
# una subshell: un die dentro una funzione di libreria ferma il passo, non il
# lavoro, che così può ancora disfare quanto fatto.
site_step() {
  local d="$1" op="$2" step="$3"
  shift 3
  site_job "$d" "$op" "$step" || return 1
  (
    set -o pipefail
    "$@"
  )
}

# site_error_text PASSO — il motivo scritto da site_fail, o uno generico.
site_error_text() {
  local m=""
  if [[ -n "${SITE_ERROR_FILE:-}" && -f "$SITE_ERROR_FILE" ]]; then
    m="$(head -n 1 "$SITE_ERROR_FILE")"
  fi
  printf '%s' "${m:-passo \"$1\" non riuscito (dettagli in $VPS_LOG)}"
}

site_create_step() {
  case "$1" in
    dns) site_dns_add "$2" ;;
    user) site_user_add "$2" ;;
    php) site_pool_add "$2" ;;
    cert) site_cert_issue "$2" ;;
    nginx)
      # WordPress non ancora installato: 503 finché il passo plugins non mette
      # il vhost vero (setup-config.php non deve essere di chi arriva per primo).
      if [[ "$(site_reg_get "$2" .type)" == wordpress ]]; then
        site_vhost_add "$2" maintenance
      else
        site_vhost_add "$2" normal
      fi
      ;;
    db)
      if [[ -z "$3" ]]; then
        site_fail "password del database mancante"
        return 1
      fi
      site_db_add "$2" "$3"
      ;;
    wp) site_wp_install_files "$2" "$3" ;;
    plugins) site_wp_plugins "$2" ;;
    *) return 1 ;;
  esac
}

# site_undo_create DOMINIO PASSO... — disfa i passi tentati, dall'ultimo al primo.
# Ogni rimozione tollera ciò che non c'è.
site_undo_create() {
  local d="$1" i
  shift
  for ((i = $#; i >= 1; i--)); do
    case "${!i}" in
      # I file di WordPress e wp-config.php spariscono con la radice (passo user);
      # restano fuori solo cron e utente Redis. Chi ha tentato plugins ha
      # tentato anche wp: basta il caso wp.
      wp)
        (site_wp_cron_remove "$d")
        (site_redis_user_remove "$d") || log "ATTENZIONE: utente Redis di $d non rimosso"
        ;;
      db) (site_db_remove "$d") ;;
      nginx) (site_vhost_remove "$d") ;;
      cert) (site_cert_remove "$d") ;;
      php) (site_pool_remove "$d") ;;
      user) (site_user_remove "$d") || log "ATTENZIONE: utente o cartella di $d non rimossi" ;;
      dns) (site_dns_remove "$d") ;;
    esac
  done
}

site_job_create() {
  local d="$1" slug type pass="" step msg
  local steps=(dns user) tried=()
  slug="$(site_reg_get "$d" .slug)"
  type="$(site_reg_get "$d" .type)"
  if [[ "$(site_reg_get "$d" .db)" == true ]]; then
    pass="$(cat "$SITES_RUN/$slug.pass" 2>/dev/null || true)"
    rm -f "$SITES_RUN/$slug.pass"
  fi
  if [[ "$type" == wordpress ]]; then
    # Letti (e cancellati) subito: la password admin non resta in /run se il
    # lavoro si ferma prima. WordPress senza database non esiste.
    if ! site_wp_args_read "$d" || [[ "$(site_reg_get "$d" .db)" != true ]]; then
      site_reg_update "$d" '.state = "error"'
      site_job "$d" create wp "dati di WordPress mancanti o non validi"
      return 1
    fi
  fi
  if [[ "$(site_reg_get "$d" .db)" == true && -z "$pass" ]]; then
    site_reg_update "$d" '.state = "error"'
    site_job "$d" create db "password del database mancante"
    return 1
  fi
  [[ "$type" != php && "$type" != wordpress ]] || steps+=(php)
  steps+=(cert nginx)
  [[ "$(site_reg_get "$d" .db)" != true ]] || steps+=(db)
  [[ "$type" != wordpress ]] || steps+=(wp plugins)
  for step in "${steps[@]}"; do
    tried+=("$step")
    if ! site_step "$d" create "$step" site_create_step "$step" "$d" "$pass"; then
      msg="$(site_error_text "$step")"
      site_undo_create "$d" "${tried[@]}"
      site_reg_update "$d" '.state = "error"'
      site_job "$d" create "$step" "$msg"
      return 1
    fi
  done
  (site_logrotate_add "$d") || log "ATTENZIONE: rotazione dei log di $d non configurata"
  # Stato e lavoro in una sola scrittura: il pannello non deve mai vedere un
  # sito attivo con il lavoro ancora a metà.
  site_reg_update "$d" \
    '.state = "active" | .job = {op: "create", step: "done", error: null, updated_at: $at, ts: ($ts | tonumber)}' \
    --arg at "$(date -Iseconds)" --arg ts "$(date +%s)"
}

# site_archive DOMINIO — file e dump del sito in SITES_BACKUPS (root 600). Se
# qualcosa non va non resta un archivio a metà e si restituisce errore.
site_archive() {
  local d="$1" slug base ok=1 rc=0
  slug="$(site_reg_get "$d" .slug)"
  base="$SITES_BACKUPS/$d-$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$SITES_BACKUPS" || return 1
  # tar esce 1 se un file cambia mentre lo legge (i log di un sito vivo
  # crescono): l'archivio è buono. Solo 2 o più è un errore vero.
  (
    umask 077
    tar --warning=no-file-changed -czf "$base.tar.gz" -C "$SITES_WWW" "$d"
  ) >>"$VPS_LOG" 2>&1 || rc=$?
  ((rc <= 1)) || ok=0
  if ((ok)) && [[ "$(site_reg_get "$d" .db)" == true ]]; then
    (
      umask 077
      set -o pipefail
      mariadb-dump --single-transaction "$slug" | gzip >"$base.sql.gz"
    ) 2>>"$VPS_LOG" || ok=0
  fi
  if ((ok)); then
    return 0
  fi
  rm -f "$base.tar.gz" "$base.sql.gz"
  site_fail "archivio di $d non riuscito: niente è stato cancellato (dettagli in $VPS_LOG)"
}

# site_job_delete DOMINIO — archivio (salvo un sito in errore: c'è solo da
# pulire), poi rimozione di tutto, record DNS creati compresi.
site_job_delete() {
  local d="$1" prev msg
  prev="$(site_reg_get "$d" '.prev_state // "active"')"
  if [[ "$prev" != error ]]; then
    if ! site_step "$d" delete archive site_archive "$d"; then
      msg="$(site_error_text archive)"
      site_reg_update "$d" '.state = $s' --arg s "$prev"
      site_job "$d" delete archive "$msg"
      return 1
    fi
  fi
  site_job "$d" delete remove
  # Si prova a togliere tutto; se qualcosa resta il registro non si cancella:
  # il sito va in errore con l'elenco dei resti, e Elimina riprova (saltando
  # l'archivio, perché lo stato di partenza è errore). Ogni rimozione tollera
  # ciò che non c'è più, quindi riprovare è sicuro.
  local left=()
  (site_vhost_remove "$d") || left+=("configurazione Nginx")
  (site_pool_remove "$d") || left+=("pool PHP-FPM")
  (site_cert_remove "$d")
  (site_logrotate_remove "$d") || left+=("rotazione dei log")
  (site_wp_cron_remove "$d") || left+=("cron di WordPress")
  (site_redis_user_remove "$d") || left+=("utente Redis")
  (site_db_remove "$d") || left+=("database")
  (site_user_remove "$d") || left+=("utente o cartella $(site_root "$d")")
  (site_dns_remove "$d") || left+=("record DNS su Cloudflare")
  if ((${#left[@]})); then
    msg="eliminazione incompleta, restano: $(printf '%s, ' "${left[@]}")"
    msg="${msg%, }: elimina di nuovo per riprovare (dettagli in $VPS_LOG)"
    log "vps-site: $msg"
    site_reg_update "$d" '.state = "error"'
    site_job "$d" delete remove "$msg"
    return 1
  fi
  rm -f "$(site_reg_path "$d")"
  log "vps-site: $d eliminato"
}

site_prune() {
  [[ -d "$SITES_BACKUPS" ]] || return 0
  find "$SITES_BACKUPS" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.sql.gz' \) -mtime +30 -delete
}

# site_abort DOMINIO OP MESSAGGIO — un lavoro che non può nemmeno partire.
site_abort() {
  if [[ "$2" == create ]]; then
    site_reg_update "$1" '.state = "error"'
    # le password non devono sopravvivere a un lavoro che non è partito
    rm -f "$SITES_RUN/$(site_reg_get "$1" .slug).pass"
    site_wp_args_clean "$1"
  elif [[ "$2" == wpinstall ]]; then
    # il sito PHP non è stato toccato: resta attivo com'era
    site_reg_update "$1" '.state = "active"'
    site_wp_args_clean "$1"
  else
    site_reg_update "$1" '.state = (.prev_state // "active")'
  fi
  site_job "$1" "$2" "$(site_reg_get "$1" .job.step)" "$3"
}

# site_run OP DOMINIO — il lavoro in background (unità systemd), uno alla volta
# su tutta la macchina: gli altri aspettano il lucchetto fino a 10 minuti.
# site_run_files_clean OP DOMINIO — i file di passaggio di un lavoro che non
# partirà: password e dati non restano in /run. Il nome viene da site_slug
# perché il registro potrebbe non esserci.
site_run_files_clean() {
  local slug
  valid_domain "$2" || return 0
  slug="$(site_slug "$2")"
  case "$1" in
    create) rm -f "$SITES_RUN/$slug.pass" "$SITES_RUN/$slug.wpargs" "$SITES_RUN/$slug.wppass" ;;
    wpinstall) rm -f "$SITES_RUN/$slug.wpargs" "$SITES_RUN/$slug.wppass" ;;
  esac
}

site_run() {
  local op="$1" d="$2" rc=0 state
  if ! valid_domain "$d" || ! site_reg_exists "$d"; then
    log "vps-site _run: sito sconosciuto: $d"
    site_run_files_clean "$op" "$d"
    return 1
  fi
  [[ "$op" == create || "$op" == delete || "$op" == wpinstall ]] || return 1
  install -d -m 700 "$SITES_RUN"
  SITE_ERROR_FILE="$SITES_RUN/$(site_reg_get "$d" .slug).err"
  rm -f "$SITE_ERROR_FILE"
  exec 9>"$SITES_LOCK"
  if ! flock -w "${SITES_LOCK_WAIT:-600}" 9; then
    exec 9>&-
    site_abort "$d" "$op" "la coda dei lavori è ferma da troppo tempo: riprova"
    return 1
  fi
  # Un doppione o un _run fuori posto non deve disfare un sito che funziona.
  state="$(site_reg_get "$d" .state)"
  if [[ "$op" == create && "$state" != creating ]] || [[ "$op" == delete && "$state" != deleting ]] \
    || [[ "$op" == wpinstall && "$state" != installing ]]; then
    exec 9>&-
    log "vps-site _run: $d è in stato $state, $op ignorato"
    site_run_files_clean "$op" "$d"
    return 1
  fi
  # wpinstall non parla con Cloudflare: il token serve solo a creare ed eliminare.
  if [[ "$op" != wpinstall ]] && ! site_cf_token; then
    exec 9>&-
    site_abort "$d" "$op" "token Cloudflare mancante in $VPS_OPT/secrets/cloudflare.ini"
    return 1
  fi
  case "$op" in
    create) site_job_create "$d" || rc=1 ;;
    wpinstall) site_job_wpinstall "$d" || rc=1 ;;
    *) site_job_delete "$d" || rc=1 ;;
  esac
  rm -f "$SITE_ERROR_FILE"
  # Libera il lucchetto: in un processo a sé si chiude da solo, ma chi chiama
  # site_run da una shell che resta viva (i test) non deve bloccare il lavoro dopo.
  exec 9>&-
  return "$rc"
}

# site_refresh DOMINIO — un lavoro in corso la cui unità systemd non c'è più
# (riavvio, processo ucciso). Una creazione diventa errore, così il pannello
# offre Elimina; un'eliminazione torna allo stato di prima, perché l'archivio
# potrebbe non esserci ancora. Il primo minuto non si guarda: tra la scrittura
# del registro e l'avvio dell'unità passa qualche istante. Un'installazione di
# WordPress interrotta diventa errore: il sito è a metà tra PHP e WordPress.
site_refresh() {
  local d="$1" rc=0
  in_list "$(site_reg_get "$d" .state)" creating deleting installing || return 0
  # Se il lucchetto globale è occupato un lavoro è in corso o in coda: non si
  # tocca nulla. Evita di scambiare per morto un lavoro che sta finendo.
  exec 8>"$SITES_LOCK" || return 0
  if flock -n 8; then
    site_refresh_locked "$d" || rc=$?
  fi
  exec 8>&-
  return "$rc"
}

site_refresh_locked() {
  local d="$1" state op ts slug step
  state="$(site_reg_get "$d" .state)"
  in_list "$state" creating deleting installing || return 0
  ts="$(site_reg_get "$d" '.job.ts // 0')"
  (($(date +%s) - ts > 60)) || return 0
  op="$(site_reg_get "$d" .job.op)"
  slug="$(site_reg_get "$d" .slug)"
  step="$(site_reg_get "$d" .job.step)"
  if systemctl is-active --quiet "vps-site-$slug-$op.service"; then
    return 0
  fi
  if [[ "$state" == creating ]]; then
    site_abort "$d" create "operazione interrotta: elimina il sito per pulire i resti"
  elif [[ "$state" == installing ]]; then
    site_wp_args_clean "$d"
    site_reg_update "$d" '.state = "error"'
    site_job "$d" wpinstall "$step" "installazione WordPress interrotta: elimina il sito e ricrealo"
  elif [[ "$step" == remove ]]; then
    # l'archivio c'è già e la rimozione è a metà: tornare indietro porterebbe
    # a riarchiviare una cartella che non esiste più. Errore: riprovare salta l'archivio.
    site_reg_update "$d" '.state = "error"'
    site_job "$d" delete remove "eliminazione interrotta: elimina di nuovo per pulire i resti"
  else
    site_abort "$d" delete "eliminazione interrotta: riprova"
  fi
}

# site_reg_json_full FILE — il registro con `placeholder`: true se public/ ha ancora
# solo il segnaposto (il pannello decide da lì se offrire "installa WordPress").
site_reg_json_full() {
  local d p=false
  d="$(jq -r '.domain // empty' "$1")"
  if [[ -n "$d" ]] && site_placeholder_intact "$d"; then p=true; fi
  jq --argjson p "$p" '. + {placeholder: $p}' "$1"
}

site_list_json() {
  local f files=()
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if ((${#files[@]} == 0)); then
    echo '[]'
    return
  fi
  for f in "${files[@]}"; do
    site_refresh "$(basename "$f" .json)"
  done
  # un lavoro può aver cancellato un registro nel frattempo
  files=()
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if ((${#files[@]} == 0)); then
    echo '[]'
    return
  fi
  for f in "${files[@]}"; do
    site_reg_json_full "$f"
  done | jq -s 'sort_by(.domain)'
}
