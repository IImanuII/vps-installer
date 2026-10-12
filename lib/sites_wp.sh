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
  # Le password finiscono in stringhe PHP tra apici: qui si rifiuta ciò che le romperebbe.
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

# site_redis_purge DOMINIO — cancella le chiavi del prefisso del sito. Un sito
# ricreato con lo stesso dominio ha lo stesso prefisso: senza questo WordPress
# leggerebbe dalla cache le opzioni (e gli utenti) del sito eliminato.
# Lo script Lua gira dentro Redis: i nomi delle chiavi (spazi, apici, a capo)
# non passano mai da una shell. Il prefisso è [a-z0-9_]: nessun jolly del glob.
site_redis_purge() {
  local slug pw
  slug="$(site_reg_get "$1" .slug)"
  pw="$(head -n 1 "$REDIS_ADMIN_SECRET" 2>/dev/null)" || return 1
  [[ -n "$pw" ]] || return 1
  REDISCLI_AUTH="$pw" redis-cli --no-auth-warning --user vps-admin EVAL \
    "local c, n = '0', 0 repeat local r = redis.call('SCAN', c, 'MATCH', ARGV[1], 'COUNT', 1000) c = r[1] for _, k in ipairs(r[2]) do redis.call('UNLINK', k) n = n + 1 end until c == '0' return n" \
    0 "$slug:*" >>"$VPS_LOG" 2>&1
}

site_redis_user_add() {
  local slug h
  slug="$(site_reg_get "$1" .slug)"
  h="$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"
  site_redis_purge "$1" || { site_fail "cache Redis di un sito precedente non svuotata (dettagli in $VPS_LOG)"; return 1; }
  site_redis_acl_replace "$1" "user $slug on #$h ~$slug:* &$slug:* +@all -@dangerous -@admin +info"
}

site_redis_user_remove() {
  local has_user=0
  grep -q "^user $(site_reg_get "$1" .slug) " "$REDIS_ACL_FILE" 2>/dev/null && has_user=1
  # Le chiavi si tolgono anche se la riga ACL non c'è più (un WordPress a metà
  # potrebbe averne lasciate); i siti PHP e statici non hanno mai usato Redis.
  # Se non riesce, ci riprova la prossima creazione con lo stesso dominio.
  if ((has_user)) || [[ "$(site_reg_get "$1" .type)" == wordpress ]]; then
    site_redis_purge "$1" || log "ATTENZIONE: chiavi Redis di $1 non cancellate"
  fi
  ((has_user)) || return 0
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

# site_wp_args_clean DOMINIO — cancella i file di passaggio di WordPress (la
# password admin non deve sopravvivere a un lavoro finito, fallito o mai partito).
site_wp_args_clean() {
  local slug
  slug="$(site_reg_get "$1" .slug)"
  rm -f "$SITES_RUN/$slug.wpargs" "$SITES_RUN/$slug.wppass"
}

# site_wp_args_read DOMINIO — WP_TITLE, WP_ADMIN_USER, WP_ADMIN_EMAIL, WP_LOGIN_PATH,
# WP_CLOUDFLARE e WP_ADMIN_PASS dai file di passaggio, che poi cancella.
# Variabili della shell, non esportate: la password admin arriva a WP-CLI solo su stdin.
site_wp_args_read() {
  local slug f
  slug="$(site_reg_get "$1" .slug)"
  f="$SITES_RUN/$slug.wpargs"
  WP_TITLE="" WP_ADMIN_USER="" WP_ADMIN_EMAIL="" WP_LOGIN_PATH="" WP_CLOUDFLARE=false WP_ADMIN_PASS=""
  if [[ -f "$f" ]]; then
    WP_TITLE="$(jq -r '.title // ""' "$f")"
    WP_ADMIN_USER="$(jq -r '.admin_user // ""' "$f")"
    WP_ADMIN_EMAIL="$(jq -r '.admin_email // ""' "$f")"
    WP_LOGIN_PATH="$(jq -r '.login_path // ""' "$f")"
    WP_CLOUDFLARE="$(jq -r 'if .cloudflare == true then "true" else "false" end' "$f")"
  fi
  WP_ADMIN_PASS="$(cat "$SITES_RUN/$slug.wppass" 2>/dev/null || true)"
  site_wp_args_clean "$1"
  site_wp_valid_title "$WP_TITLE" && site_wp_valid_user "$WP_ADMIN_USER" && site_wp_valid_email "$WP_ADMIN_EMAIL" \
    && site_wp_valid_path "$WP_LOGIN_PATH" && site_valid_db_password "$WP_ADMIN_PASS"
}

# site_wp_install_files DOMINIO DB_PASSWORD — passo "wp": WordPress in public/,
# wp-config.php, utente Redis, installazione con la password admin su stdin.
site_wp_install_files() {
  local d="$1" root redis_pw
  root="$(site_root "$d")"
  # Seconda difesa (la prima è in site_job_wpinstall): con file veri in public/
  # si esce con 2, prima di toccare qualunque cosa, e chi chiama non disfa nulla.
  site_placeholder_intact "$d" || { site_fail "public/ non è vuota: WordPress si installa solo su un sito appena creato"; return 2; }
  # Fino alla fine di core install setup-config.php e install.php sarebbero di
  # chiunque arrivi per primo: intanto il sito risponde 503.
  site_vhost_add "$d" maintenance || return 1
  rm -f "$root/public/index.html"
  site_wp "$d" core download --locale=it_IT >>"$VPS_LOG" 2>&1 \
    || { site_fail "download di WordPress non riuscito (dettagli in $VPS_LOG)"; return 1; }
  redis_pw="$(rand_secret 48)"
  site_wp_config_write "$d" "$2" "$redis_pw" || return 1
  site_redis_user_add "$d" "$redis_pw" || return 1
  printf '%s\n' "$WP_ADMIN_PASS" | site_wp "$d" core install --url="https://$d" --title="$WP_TITLE" \
    --admin_user="$WP_ADMIN_USER" --admin_email="$WP_ADMIN_EMAIL" --skip-email --locale=it_IT \
    --prompt=admin_password >>"$VPS_LOG" 2>&1 \
    || { site_fail "installazione di WordPress non riuscita (dettagli in $VPS_LOG)"; return 1; }
}

# site_wp_redis_dropin DOMINIO — attiva la cache Redis copiando il drop-in del
# plugin. `wp redis enable` non si può usare: dopo la copia lancia FLUSHDB, che
# l'utente ACL del sito non ha (giustamente: svuoterebbe le chiavi di tutti i
# siti), e fallisce. La copia la fa l'utente del sito: wp-content/ è sua.
site_wp_redis_dropin() {
  local d="$1" root slug out
  root="$(site_root "$d")"
  slug="$(site_reg_get "$d" .slug)"
  (cd "$root" && runuser -u "$slug" -- cp -- "$root/public/wp-content/plugins/redis-cache/includes/object-cache.php" \
    "$root/public/wp-content/object-cache.php") >>"$VPS_LOG" 2>&1 \
    || { site_fail "cache Redis non attivata: drop-in non copiato (dettagli in $VPS_LOG)"; return 1; }
  # Il drop-in non dà errori se Redis rifiuta le credenziali (ripiega sul DB):
  # si controlla che il sito si colleghi davvero.
  out="$(site_wp "$d" redis status 2>&1)" || true
  printf '%s\n' "$out" >>"$VPS_LOG"
  [[ "$out" == *"Status: Connected"* ]] || { site_fail "cache Redis non collegata (dettagli in $VPS_LOG)"; return 1; }
}

# site_wp_plugins DOMINIO — passo "plugins": plugin, aggiornamenti automatici,
# registro, vhost wordpress, cron.
site_wp_plugins() {
  local d="$1"
  site_wp "$d" plugin install wps-hide-login redis-cache --activate >>"$VPS_LOG" 2>&1 \
    || { site_fail "installazione dei plugin non riuscita (dettagli in $VPS_LOG)"; return 1; }
  site_wp "$d" option update whl_page "$WP_LOGIN_PATH" >>"$VPS_LOG" 2>&1 || { site_fail "percorso di login non impostato"; return 1; }
  # Permalink "belli": con quelli semplici (il default senza Apache) WPS Hide
  # Login non riesce a dare 404 su /wp-login.php e /wp-admin, che finiscono
  # sulla home con 200 (visto nell'E2E). Nginx li serve già con try_files.
  site_wp "$d" rewrite structure '/%postname%/' >>"$VPS_LOG" 2>&1 || { site_fail "permalink non impostati"; return 1; }
  site_wp_redis_dropin "$d" || return 1
  if [[ "$WP_CLOUDFLARE" == true ]]; then
    site_wp "$d" plugin install cloudflare --activate >>"$VPS_LOG" 2>&1 \
      || { site_fail "installazione del plugin Cloudflare non riuscita"; return 1; }
  fi
  site_wp "$d" plugin auto-updates enable --all >>"$VPS_LOG" 2>&1 || { site_fail "aggiornamenti automatici dei plugin non attivati"; return 1; }
  site_reg_update "$d" '.type = "wordpress" | .wordpress = {login_path: $p, admin_user: $u, cloudflare_plugin: ($cf == "true"), installed_at: $at}' \
    --arg p "$WP_LOGIN_PATH" --arg u "$WP_ADMIN_USER" --arg cf "$WP_CLOUDFLARE" --arg at "$(date -Iseconds)" || return 1
  site_vhost_add "$d" normal || return 1
  site_wp_cron_add "$d"
}

# site_wp_undo DOMINIO — toglie WordPress da un sito PHP (wp-install fallito):
# public/ torna con il solo segnaposto, il DB vuoto, vhost PHP. Prova tutto e
# restituisce 1 se qualcosa non è andato.
site_wp_undo() {
  local d="$1" root slug dbpass rc=0
  root="$(site_root "$d")"
  slug="$(site_reg_get "$d" .slug)"
  site_wp_cron_remove "$d" || rc=1
  site_redis_user_remove "$d" || { log "ATTENZIONE: utente Redis di $d non rimosso"; rc=1; }
  # Prima i file di WordPress, poi wp-config.php: un WordPress rimasto a metà
  # senza wp-config offrirebbe setup-config.php a chiunque.
  # find -delete non segue i collegamenti simbolici: sicuro anche in una cartella del sito.
  if ! find "$root/public" -mindepth 1 -delete; then
    # File di WordPress ancora lì: DB e vhost restano come sono e il sito
    # risponde 503, altrimenti install.php sarebbe aperto a chiunque.
    log "ATTENZIONE: file di WordPress di $d non tolti tutti"
    site_vhost_add "$d" maintenance || log "ATTENZIONE: vhost di manutenzione di $d non scritto"
    return 1
  fi
  rm -f "$root/wp-config.php" || rc=1
  # Il segnaposto lo scrive l'utente del sito, non root: public/ è sua e il pool
  # PHP è vivo, un file temporaneo di root lì dentro potrebbe essere scambiato
  # con un collegamento prima di chmod/chown.
  # shellcheck disable=SC2016
  SITE_DOMAIN="$d" envsubst '${SITE_DOMAIN}' <"$VPS_TEMPLATES/site-placeholder.html.tmpl" \
    | (cd "$root" && runuser -u "$slug" -- sh -c 'umask 002 && cat >"$1"' sh "$root/public/index.html") \
    || { log "ATTENZIONE: segnaposto di $d non ripristinato"; rc=1; }
  # DB vuoto: si ricrea da capo con la stessa password e gli stessi permessi.
  # Niente nomi letti dal DB: le tabelle le può creare il sito, e un nome con
  # un apice inverso diventerebbe SQL eseguito da root.
  dbpass="$(env_get "$root/db.env" DB_PASS)"
  if [[ -z "$dbpass" ]] || ! {
    printf 'DROP DATABASE IF EXISTS `%s`;\n' "$slug"
    site_db_sql "$slug" "$dbpass"
  } | mariadb >>"$VPS_LOG" 2>&1; then
    log "ATTENZIONE: database di $d non svuotato"
    rc=1
  fi
  site_reg_update "$d" '.type = "php" | del(.wordpress)' || rc=1
  # Il vhost PHP solo se tutto il resto è tornato com'era; altrimenti 503 (il
  # passo plugins potrebbe aver già messo il vhost wordpress).
  if ((rc == 0)); then
    site_vhost_add "$d" normal || { log "ATTENZIONE: vhost PHP di $d non ripristinato"; rc=1; }
  else
    site_vhost_add "$d" maintenance || log "ATTENZIONE: vhost di manutenzione di $d non scritto"
  fi
  return "$rc"
}

# site_job_wpinstall DOMINIO — lavoro "wpinstall": WordPress su un sito PHP con
# DB appena creato. Se un passo fallisce il sito torna PHP con il segnaposto;
# se nemmeno questo riesce va in errore (da eliminare).
site_job_wpinstall() {
  local d="$1" dbpass="" msg step rc
  if [[ "$(site_reg_get "$d" .db)" == true ]]; then
    dbpass="$(env_get "$(site_root "$d")/db.env" DB_PASS)"
  fi
  # I file di passaggio si leggono (e cancellano) comunque, anche se poi si rifiuta.
  if ! site_wp_args_read "$d" || [[ -z "$dbpass" ]]; then
    site_reg_update "$d" '.state = "active"'
    if [[ -z "$dbpass" ]]; then
      site_job "$d" wpinstall queued "WordPress richiede un sito con database"
    else
      site_job "$d" wpinstall queued "dati di WordPress mancanti o non validi"
    fi
    return 1
  fi
  # Un public/ con file propri non si tocca: si rifiuta prima di ogni passo.
  if ! site_placeholder_intact "$d"; then
    site_reg_update "$d" '.state = "active"'
    site_job "$d" wpinstall wp "public/ non è vuota: WordPress si installa solo su un sito appena creato"
    return 1
  fi
  for step in wp plugins; do
    rc=0
    case "$step" in
      wp) site_step "$d" wpinstall wp site_wp_install_files "$d" "$dbpass" ;;
      plugins) site_step "$d" wpinstall plugins site_wp_plugins "$d" ;;
    esac || rc=$?
    ((rc)) || continue
    msg="$(site_error_text "$step")"
    # rc 2: il passo wp ha trovato file veri in public/ prima di toccare nulla.
    if ((rc != 2)) && ! (site_wp_undo "$d"); then
      site_reg_update "$d" '.state = "error"'
      site_job "$d" wpinstall "$step" "$msg; installazione WordPress non annullata del tutto: elimina il sito (dettagli in $VPS_LOG)"
      return 1
    fi
    site_reg_update "$d" '.state = "active" | .type = "php"'
    site_job "$d" wpinstall "$step" "$msg"
    return 1
  done
  site_reg_update "$d" \
    '.state = "active" | .job = {op: "wpinstall", step: "done", error: null, updated_at: $at, ts: ($ts | tonumber)}' \
    --arg at "$(date -Iseconds)" --arg ts "$(date +%s)"
}
