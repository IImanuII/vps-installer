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
  if [[ -e "$(site_root "$d")" ]]; then
    echo "la cartella $(site_root "$d") esiste già e non è un sito di vps-site"
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

# site_dns_remove DOMINIO — toglie i record annotati; uno che non c'è più non è un errore.
site_dns_remove() {
  local d="$1" zid id
  zid="$(site_reg_get "$d" '.zone.id // empty')"
  [[ -n "$zid" ]] || return 0
  while read -r id; do
    [[ -n "$id" ]] || continue
    cf_delete_record "$zid" "$id" || log "ATTENZIONE: record $id di $d non eliminato da Cloudflare: toglilo a mano"
  done < <(site_reg_get "$d" '.dns_records[].id')
  site_reg_update "$d" '.dns_records = []'
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
  install -d -m 2750 "$root" "$root/logs" || return 1
  install -d -m 2770 "$root/public" "$root/tmp" || return 1
  own "$slug:$slug" "$root" "$root/logs" "$root/public" "$root/tmp" || return 1
  setfacl -m u:www-data:x "$root" || return 1
  setfacl -m u:www-data:rX -m d:u:www-data:rX "$root/public" || return 1
  # I file creati da PHP restano modificabili dall'admin e viceversa.
  setfacl -m d:g::rwX "$root/public" "$root/tmp" || return 1
  # shellcheck disable=SC2016
  SITE_DOMAIN="$d" envsubst '${SITE_DOMAIN}' <"$VPS_TEMPLATES/site-placeholder.html.tmpl" \
    | write_file "$root/public/index.html" 664 "$slug:$slug"
}

# site_user_remove DOMINIO — utente, gruppo e radice; ciò che manca già si salta.
site_user_remove() {
  local d="$1" slug root
  slug="$(site_reg_get "$d" .slug)"
  root="$(site_root "$d")"
  # Mai un rm -rf su un percorso che non sia la radice di un sito di vps-site.
  [[ -n "$d" && "$slug" == site_* && "$root" == "$SITES_WWW/$d" ]] || return 1
  if id -u "$slug" >/dev/null 2>&1; then
    userdel "$slug" >>"$VPS_LOG" 2>&1 || return 1
  fi
  if getent group "$slug" >/dev/null 2>&1; then
    groupdel "$slug" >>"$VPS_LOG" 2>&1 || return 1
  fi
  rm -rf --one-file-system -- "$root"
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
  rm -f "$f"
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
  rm -f "$f"
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

site_db_add() {
  local d="$1" slug
  slug="$(site_reg_get "$d" .slug)"
  site_db_sql "$slug" "$2" | mariadb >>"$VPS_LOG" 2>&1 \
    || { site_fail "il database $slug non è stato creato (dettagli in $VPS_LOG)"; return 1; }
  printf 'DB_HOST=localhost\nDB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\n' "$slug" "$slug" "$2" \
    | write_file "$(site_root "$d")/db.env" 640 "$slug:$slug"
}

site_db_password() {
  local d="$1" slug
  slug="$(site_reg_get "$d" .slug)"
  printf "ALTER USER '%s'@'localhost' IDENTIFIED BY %s;\n" "$slug" "$(sql_quote "$2")" | mariadb >>"$VPS_LOG" 2>&1 \
    || { site_fail "la password del database non è stata cambiata (dettagli in $VPS_LOG)"; return 1; }
  printf 'DB_PASS=%s\n' "$2" | env_merge "$(site_root "$d")/db.env" 640 "$slug:$slug"
}

site_db_remove() {
  local slug
  slug="$(site_reg_get "$1" .slug)"
  printf "DROP DATABASE IF EXISTS \`%s\`;\nDROP USER IF EXISTS '%s'@'localhost';\n" "$slug" "$slug" \
    | mariadb >>"$VPS_LOG" 2>&1 || log "ATTENZIONE: database o utente $slug non eliminati"
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
    nginx) site_vhost_add "$2" normal ;;
    db)
      if [[ -z "$3" ]]; then
        site_fail "password del database mancante"
        return 1
      fi
      site_db_add "$2" "$3"
      ;;
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
  [[ "$type" != php ]] || steps+=(php)
  steps+=(cert nginx)
  [[ "$(site_reg_get "$d" .db)" != true ]] || steps+=(db)
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
  site_reg_update "$d" '.state = "active"'
  site_job "$d" create "done"
}

# site_archive DOMINIO — file e dump del sito in SITES_BACKUPS (root 600). Se
# qualcosa non va non resta un archivio a metà e si restituisce errore.
site_archive() {
  local d="$1" slug base ok=1
  slug="$(site_reg_get "$d" .slug)"
  base="$SITES_BACKUPS/$d-$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$SITES_BACKUPS" || return 1
  (
    umask 077
    tar -czf "$base.tar.gz" -C "$SITES_WWW" "$d"
  ) >>"$VPS_LOG" 2>&1 || ok=0
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
  (site_vhost_remove "$d")
  (site_pool_remove "$d")
  (site_cert_remove "$d")
  (site_logrotate_remove "$d")
  (site_db_remove "$d")
  (site_user_remove "$d") || log "ATTENZIONE: utente o cartella di $d non rimossi"
  (site_dns_remove "$d")
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
  else
    site_reg_update "$1" '.state = (.prev_state // "active")'
  fi
  site_job "$1" "$2" "$(site_reg_get "$1" .job.step)" "$3"
}

# site_run OP DOMINIO — il lavoro in background (unità systemd), uno alla volta
# su tutta la macchina: gli altri aspettano il lucchetto fino a 10 minuti.
site_run() {
  local op="$1" d="$2" rc=0
  if ! valid_domain "$d" || ! site_reg_exists "$d"; then
    log "vps-site _run: sito sconosciuto: $d"
    return 1
  fi
  [[ "$op" == create || "$op" == delete ]] || return 1
  install -d -m 700 "$SITES_RUN"
  SITE_ERROR_FILE="$SITES_RUN/$(site_reg_get "$d" .slug).err"
  rm -f "$SITE_ERROR_FILE"
  exec 9>"$SITES_LOCK"
  if ! flock -w "${SITES_LOCK_WAIT:-600}" 9; then
    exec 9>&-
    site_abort "$d" "$op" "la coda dei lavori è ferma da troppo tempo: riprova"
    return 1
  fi
  if ! site_cf_token; then
    exec 9>&-
    site_abort "$d" "$op" "token Cloudflare mancante in $VPS_OPT/secrets/cloudflare.ini"
    return 1
  fi
  if [[ "$op" == create ]]; then
    site_job_create "$d" || rc=1
  else
    site_job_delete "$d" || rc=1
  fi
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
# del registro e l'avvio dell'unità passa qualche istante.
site_refresh() {
  local d="$1" state op ts slug
  state="$(site_reg_get "$d" .state)"
  [[ "$state" == creating || "$state" == deleting ]] || return 0
  ts="$(site_reg_get "$d" '.job.ts // 0')"
  (($(date +%s) - ts > 60)) || return 0
  op="$(site_reg_get "$d" .job.op)"
  slug="$(site_reg_get "$d" .slug)"
  if systemctl is-active --quiet "vps-site-$slug-$op.service"; then
    return 0
  fi
  if [[ "$state" == creating ]]; then
    site_abort "$d" create "operazione interrotta: elimina il sito per pulire i resti"
  else
    site_abort "$d" delete "eliminazione interrotta: riprova"
  fi
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
  jq -s 'sort_by(.domain)' "${files[@]}"
}
