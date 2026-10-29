# shellcheck shell=bash
# Regole Nginx a mano dei siti PHP: i due file del sito in /etc/nginx/vps-custom/
# (<dominio>.conf dentro il server 443, <dominio>.http.conf a livello http) e il
# loro legame col vhost generato da site_vhost_add. Solo funzioni e default.

: "${NGINX_CUSTOM_D:=/etc/nginx/vps-custom}"
: "${CRON_D:=/etc/cron.d}"

site_custom_conf() {
  printf '%s/%s.conf' "$NGINX_CUSTOM_D" "$1"
}

site_custom_http() {
  printf '%s/%s.http.conf' "$NGINX_CUSTOM_D" "$1"
}

# I cron tolti per un cambio di regole restano qui da rivedere, accanto ai file.
site_custom_review() {
  printf '%s/%s.cron-da-rivedere' "$NGINX_CUSTOM_D" "$1"
}

# Prefisso dei file cron del sito in cron.d (uno per cron, vedi sites_wp.sh).
site_custom_cron_prefix() {
  printf '%s/vps-site-%s-' "$CRON_D" "$(site_reg_get "$1" .slug)"
}

# site_custom_active DOMINIO — 0 se il sito usa le regole a mano. Valgono solo per i
# siti PHP: static e WordPress hanno un vhost fisso e il flag, se c'è, si ignora.
site_custom_active() {
  [[ "$(site_reg_get "$1" .type)" == php && "$(site_reg_get "$1" .custom_rules)" == true ]]
}

# site_custom_files_add DOMINIO — crea la cartella e, solo se mancano, i due file dai
# template. Un file che c'è è del gestore del sito (anche un link spezzato): non si
# riscrive mai. Ogni errore finisce nel registro e in un solo messaggio per il pannello.
# Le variabili SITE_* le legge site_tmpl_text (envsubst), non lo vede shellcheck.
# shellcheck disable=SC2034
site_custom_files_add() {
  local d="$1"
  SITE_DOMAIN="$d"
  SITE_ROOT="$(site_root "$d")"
  SITE_SLUG="$(site_reg_get "$d" .slug)"
  if ! _site_custom_files_write "$d" >>"$VPS_LOG" 2>&1; then
    site_fail "file delle regole a mano di $d non scritti (dettagli in $VPS_LOG)"
    return 1
  fi
}

_site_custom_files_write() {
  local d="$1" f
  install -d -m 755 "$NGINX_CUSTOM_D" || return 1
  f="$(site_custom_conf "$d")"
  if [[ ! -e "$f" && ! -L "$f" ]]; then
    site_tmpl_text "$VPS_TEMPLATES/nginx-site-custom.conf.tmpl" SITE_DOMAIN SITE_ROOT SITE_SLUG PHP_VERSION |
      write_file "$f" 644 root:root || return 1
  fi
  f="$(site_custom_http "$d")"
  if [[ ! -e "$f" && ! -L "$f" ]]; then
    site_tmpl_text "$VPS_TEMPLATES/nginx-site-custom.http.conf.tmpl" SITE_DOMAIN |
      write_file "$f" 644 root:root || return 1
  fi
}

# site_custom_set DOMINIO on|off — accende o spegne le regole a mano. Salva il registro
# di prima: se Nginx rifiuta il vhost nuovo si torna lì (il vhost lo rimette già
# site_vhost_add). I file restano sempre, anche con off. Entrambi tolgono custom_restored,
# anche off su un sito che le aveva già spente: è il modo per chiudere l'avviso di
# ricreazione a chi non vuole le regole. Con il sito disattivato il vhost di
# manutenzione non si tocca: gli include tornano con enable.
site_custom_set() {
  local d="$1" mode="$2" prev
  prev="$(cat "$(site_reg_path "$d")")" || return 1
  if [[ "$mode" == on ]]; then
    site_custom_files_add "$d" || return 1
    site_reg_update "$d" '.custom_rules = true | del(.custom_restored)' || return 1
  else
    site_reg_update "$d" '.custom_rules = false | del(.custom_restored)' || return 1
  fi
  if [[ "$(site_reg_get "$d" .state)" == active ]] && ! site_vhost_add "$d" normal; then
    printf '%s\n' "$prev" | site_reg_write "$d"
    return 1
  fi
}

# site_custom_remove DOMINIO — all'eliminazione toglie i file delle regole a mano, il
# file dei cron da rivedere e i cron fatti a mano (vps-site-<slug>-*). Il cron di
# WordPress (vps-site-<slug>, senza trattino finale) lo toglie site_wp_cron_remove.
# Lo slug finisce in un glob di find: se non ha la forma attesa non si tocca niente,
# così un registro rovinato non può portarsi via i file di altri siti. Il trattino
# dopo lo slug evita che site_blog_x prenda anche i file di site_blog_x_y.
# Da chiamare solo dopo aver tolto il vhost: finché lo include, Nginx ha bisogno
# dei file. Rc 1 se qualcosa resta.
site_custom_remove() {
  local d="$1" slug
  slug="$(site_reg_get "$d" .slug)"
  if [[ ! "$slug" =~ ^site_[a-z0-9_]+$ ]]; then
    log "ATTENZIONE: slug di $d non valido, regole a mano e cron non toccati"
    return 1
  fi
  rm -f "$(site_custom_conf "$d")" "$(site_custom_http "$d")" "$(site_custom_review "$d")" || return 1
  find "$CRON_D" -maxdepth 1 -type f -name "vps-site-$slug-*" -delete || return 1
  [[ ! -e "$(site_custom_conf "$d")" && ! -L "$(site_custom_conf "$d")" &&
    ! -e "$(site_custom_http "$d")" && ! -L "$(site_custom_http "$d")" &&
    ! -e "$(site_custom_review "$d")" && ! -L "$(site_custom_review "$d")" ]] || return 1
  [[ -z "$(find "$CRON_D" -maxdepth 1 -name "vps-site-$slug-*" -print -quit)" ]]
}
