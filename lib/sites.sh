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
