# shellcheck shell=bash
# Installazione e aggiornamento di Plancia (vps-panel-install, vps-panel-update).
# Git lavora come root con una deploy key di sola lettura che l'utente panel non
# può leggere. La git dir sta FUORI dalla radice del pannello (PD_GIT_DIR,
# root:root 700): il work tree è di panel, quindi hook e config di una .git
# dentro la radice sarebbero codice di panel eseguito da root.
# Ogni funzione può essere chiamata in un `if`: dove errexit non vale, ogni
# comando che può fallire ha il suo `|| return 1`.

: "${PANEL_REPO:=git@github.com:IImanuII/vps-panel.git}"
: "${PD_REPO_WEB:=https://github.com/IImanuII/vps-panel}"
: "${PD_KEY:=$VPS_OPT/secrets/panel-deploy-key}"
: "${PD_GIT_DIR:=$VPS_OPT/panel.git}"
: "${PD_KNOWN_HOSTS:=$VPS_TEMPLATES/github-known-hosts}"
: "${PD_BACKUPS:=$VPS_OPT/backups/panel}"
: "${PD_CRON:=/etc/cron.d/vps-panel}"
: "${PD_LOCK:=/run/vps-panel-update.lock}"
: "${PD_PHP:=php}"

# pd_load — dominio e radice del pannello dal manifest.
pd_load() {
  local m
  m="$(manifest_path)"
  [[ -f "$m" ]] || die "Manifest $m mancante: la VPS non è stata preparata da vps-installer"
  PANEL_DOMAIN="$(jq -r '.panel.domain // empty' "$m")"
  PANEL_ROOT="$(jq -r '.panel.path // empty' "$m")"
  [[ -n "$PANEL_DOMAIN" && -n "$PANEL_ROOT" ]] || die "Il manifest non ha un pannello (panel.domain, panel.path)"
  [[ -d "$PANEL_ROOT" ]] || die "Cartella del pannello mancante: $PANEL_ROOT"
  PD_ENV="$PANEL_ROOT/config/.env"
}

pd_git() {
  GIT_SSH_COMMAND="ssh -i '$PD_KEY' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$PD_KNOWN_HOSTS'" \
    git --git-dir="$PD_GIT_DIR" --work-tree="$PANEL_ROOT" \
    -c safe.directory="$PANEL_ROOT" -c advice.detachedHead=false "$@"
}

# pd_repo_init — crea (se manca) la git dir fuori dalla radice e imposta origin.
pd_repo_init() {
  if [[ ! -d "$PD_GIT_DIR" ]]; then
    install -d -m 700 "$PD_GIT_DIR" || return 1
    git --git-dir="$PD_GIT_DIR" init -q -b main || return 1
  fi
  pd_git config core.bare false || return 1
  if pd_git remote get-url origin >/dev/null 2>&1; then
    pd_git remote set-url origin "$PANEL_REPO" || return 1
  else
    pd_git remote add origin "$PANEL_REPO" || return 1
  fi
}

# pd_repo_ok — la git dir è una vera cartella, di root, non scrivibile da altri.
pd_repo_ok() {
  [[ -d "$PD_GIT_DIR" && ! -L "$PD_GIT_DIR" ]] || return 1
  [[ "${VPS_NO_CHOWN:-}" == 1 ]] && return 0
  local info perm
  info="$(stat -c '%u %a' "$PD_GIT_DIR")" || return 1
  [[ "${info%% *}" == 0 ]] || return 1
  perm="${info#* }"
  (( (8#$perm & 8#022) == 0 )) || return 1
}

pd_key_ensure() {
  install -d -m 700 "$(dirname "$PD_KEY")" || return 1
  chmod 700 "$(dirname "$PD_KEY")" || return 1
  if [[ ! -f "$PD_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "vps-panel@$(hostname)" -f "$PD_KEY" || return 1
  fi
  chmod 600 "$PD_KEY" || return 1
  if [[ ! -f "$PD_KEY.pub" ]]; then
    ssh-keygen -y -f "$PD_KEY" >"$PD_KEY.pub" || return 1
    chmod 644 "$PD_KEY.pub" || return 1
  fi
}

pd_latest_tag() {
  pd_git tag -l 'v*' | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n 1
}

pd_current_tag() {
  pd_git describe --tags --exact-match HEAD 2>/dev/null || true
}

# pd_ver_gt A B — vero se la versione A (senza v) è maggiore di B.
pd_ver_gt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# pd_checkout TAG — codice al rilascio TAG; config/.env, logs/ e storage/ hanno
# il contenuto intatto (ignorato da git); proprietà riportata a panel come tutto
# il resto.
# chown -R -P -h sull'intera radice è la forma sicura: coreutils scende con
# fchownat su descrittori di directory e non segue mai i link simbolici, mentre
# un giro per percorso potrebbe essere eluso scambiando una cartella con un link.
# I file di sviluppo del repository (PD_DEV_PATHS) non arrivano nella radice:
# sparse checkout; read-tree li toglie anche da una radice già installata.
PD_DEV_PATHS=(/.claude/ /Documenti/ /tests/ /infra/ /PRODUCT.md)

pd_sparse_setup() {
  local p
  pd_git config core.sparseCheckout true || return 1
  pd_git config core.sparseCheckoutCone false || return 1
  mkdir -p "$PD_GIT_DIR/info" || return 1
  {
    echo '/*'
    for p in "${PD_DEV_PATHS[@]}"; do
      echo "!$p"
    done
  } >"$PD_GIT_DIR/info/sparse-checkout"
}

pd_checkout() {
  pd_sparse_setup || return 1
  pd_git checkout -q -f "$1" || return 1
  pd_git read-tree -mu HEAD || return 1
  [[ "${VPS_NO_CHOWN:-}" == 1 ]] && return 0
  chown -R -P -h panel:panel -- "$PANEL_ROOT" || return 1
}

# pd_env_merge TOKEN — APP_KEY solo se manca (cambiarla renderebbe illeggibili i
# segreti cifrati), TELEGRAM_BOT_TOKEN se TOKEN non è vuoto.
pd_env_merge() {
  local lines="" key
  if [[ -z "$(env_get "$PD_ENV" APP_KEY)" ]]; then
    key="$(openssl rand -base64 32)" || return 1
    [[ -n "$key" ]] || return 1
    lines+="APP_KEY=$key"$'\n'
  fi
  if [[ -n "$1" ]]; then
    lines+="TELEGRAM_BOT_TOKEN=$1"$'\n'
  fi
  [[ -n "$lines" ]] || return 0
  printf '%s' "$lines" | env_merge "$PD_ENV" 600 panel:panel
}

pd_db_name() {
  # Dal manifest, non dal .env di panel (vedi panel_db_name).
  panel_db_name
}

# pd_as_panel CMD... — come utente panel (PD_AS_PANEL=0 solo nei test).
pd_as_panel() {
  if [[ "${PD_AS_PANEL:-1}" == 0 ]]; then
    "$@"
  else
    runuser -u panel -- "$@"
  fi
}

# pd_schema TAG — schema.sql del rilascio TAG, letto dagli oggetti git (root):
# mai dalla radice del pannello, che è scrivibile da panel.
pd_schema() {
  local db
  db="$(pd_db_name)" || return 1
  (set -o pipefail; pd_git show "refs/tags/${1:?tag mancante}:install/schema.sql" | mariadb "$db") || return 1
}

# pd_migrations DA A — install/migrations/X.Y.Z.sql con DA < X.Y.Z ≤ A, in ordine,
# lette dagli oggetti git del tag A (con o senza v).
pd_migrations() {
  local from="${1#v}" to="${2#v}" db f v names
  db="$(pd_db_name)" || return 1
  names="$(pd_git ls-tree --name-only "refs/tags/v$to" install/migrations/ 2>/dev/null)" || return 1
  while IFS= read -r f; do
    f="$(basename "$f")"
    v="${f%.sql}"
    [[ "$f" == "$v.sql" && "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if pd_ver_gt "$v" "$from" && ! pd_ver_gt "$v" "$to"; then
      log "Plancia: migrazione $v"
      (set -o pipefail; pd_git show "refs/tags/v$to:install/migrations/$f" | mariadb "$db") || return 1
    fi
  done < <(printf '%s\n' "$names" | sort -V)
}

# pd_dump TAG — dump gzip del database del pannello (600, nome unico anche per
# due dump nello stesso secondo); stampa il percorso.
pd_dump() {
  local db f stamp
  db="$(pd_db_name)" || return 1
  install -d -m 700 "$PD_BACKUPS" || return 1
  stamp="$(date +%Y%m%d-%H%M%S)" || return 1
  f="$(umask 077 && mktemp "$PD_BACKUPS/${1:-senza-tag}-$stamp-XXXX.sql.gz")" || return 1
  (
    set -o pipefail
    umask 077
    mariadb-dump --single-transaction --routines --events "$db" | gzip >"$f"
  ) || { rm -f "$f"; return 1; }
  find "$PD_BACKUPS" -maxdepth 1 -name '*.sql.gz' -printf '%T@ %p\n' | sort -rn | tail -n +6 \
    | cut -d' ' -f2- | xargs -r rm -f --
  printf '%s\n' "$f"
}

# pd_restore FILE — il database torna esattamente al dump (anche le tabelle create dopo spariscono).
pd_restore() {
  local db
  db="$(pd_db_name)" || return 1
  # un dump illeggibile non deve costare il database che c'è
  gzip -t -- "$1" || return 1
  mariadb -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  (set -o pipefail; gunzip -c "$1" | mariadb "$db") || return 1
}

pd_reload_php() {
  systemctl reload "php$PHP_VERSION-fpm" >>"$VPS_LOG" 2>&1 || return 1
}

pd_php_lint() {
  find "$PANEL_ROOT/app" "$PANEL_ROOT/public" -name '*.php' -print0 2>/dev/null \
    | xargs -0 -r -n 1 -P 4 "$PD_PHP" -l >>"$VPS_LOG" 2>&1 || return 1
}

# pd_health — /health del pannello in locale (Cloudflare e DNS non c'entrano).
pd_health() {
  local url="${PD_HEALTH_URL:-https://$PANEL_DOMAIN/health}"
  local resolve="${PD_CURL_RESOLVE-$PANEL_DOMAIN:443:127.0.0.1}" body
  for _ in 1 2 3; do
    body="$(curl -skf --max-time 5 ${resolve:+--resolve "$resolve"} "$url" 2>/dev/null)" && [[ "$body" == OK ]] && return 0
    sleep "${PD_HEALTH_SLEEP:-2}"
  done
  return 1
}

# pd_super_admin_exists — 0 sì, 1 no, 2 database o prefisso non leggibili.
pd_super_admin_exists() {
  local db prefix n
  db="$(pd_db_name)" || return 2
  prefix="$(env_get "$PD_ENV" DB_PREFIX)"
  prefix="${prefix:-vp_}"
  [[ "$prefix" =~ ^[a-z0-9_]{0,20}$ ]] || return 2
  n="$(mariadb -N -B -e "SELECT COUNT(*) FROM \`${prefix}users\` WHERE role = 'super_admin'" "$db")" || return 2
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  ((n > 0)) || return 1
}

# pd_telegram_ok TOKEN — formato, poi getMe. Il token passa a curl su stdin
# (file di configurazione), mai come argomento: gli argomenti si vedono in ps.
pd_telegram_ok() {
  [[ "$1" =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{30,60}$ ]] || return 1
  [[ "${PD_SKIP_TELEGRAM_CHECK:-0}" == 1 ]] && return 0
  printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$1" \
    | curl -sf --max-time 10 -K - 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1 || return 1
}

pd_cron_install() {
  render_template "$VPS_TEMPLATES/cron-vps-panel.tmpl" "$PD_CRON" 644 root:root PANEL_ROOT
}

pd_manifest() {
  manifest_set '.panel.version = $v | .panel.deployed_at = $t | .panel.repo = $r' \
    --arg v "${1#v}" --arg t "$(date -Iseconds)" --arg r "$PANEL_REPO"
}
