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
