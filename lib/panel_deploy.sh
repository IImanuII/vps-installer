# shellcheck shell=bash
# Installazione e aggiornamento di Plancia (vps-panel-install, vps-panel-update).
# Git lavora in place nella radice del pannello, come root, con una deploy key
# di sola lettura che l'utente panel non può leggere; i file restano di panel.
# Ogni funzione può essere chiamata in un `if`: dove errexit non vale, ogni
# comando che può fallire ha il suo `|| return 1`.

: "${PANEL_REPO:=git@github.com:IImanuII/vps-panel.git}"
: "${PD_REPO_WEB:=https://github.com/IImanuII/vps-panel}"
: "${PD_KEY:=$VPS_OPT/secrets/panel-deploy-key}"
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
  GIT_SSH_COMMAND="ssh -i $PD_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$PD_KNOWN_HOSTS" \
    git -c safe.directory="$PANEL_ROOT" -c advice.detachedHead=false -C "$PANEL_ROOT" "$@"
}

pd_key_ensure() {
  [[ -f "$PD_KEY" ]] && return 0
  install -d -m 700 "$(dirname "$PD_KEY")" || return 1
  ssh-keygen -q -t ed25519 -N '' -C "vps-panel@$(hostname)" -f "$PD_KEY" || return 1
  chmod 600 "$PD_KEY"
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

# pd_checkout TAG — codice al rilascio TAG; config/.env, logs/ e storage/ sono
# ignorati da git e restano come sono. Tutto torna dell'utente panel.
pd_checkout() {
  pd_git checkout -q -f "$1" || return 1
  own -R panel:panel "$PANEL_ROOT" || return 1
}

# pd_env_merge TOKEN — APP_KEY solo se manca (cambiarla renderebbe illeggibili i
# segreti cifrati), TELEGRAM_BOT_TOKEN se TOKEN non è vuoto.
pd_env_merge() {
  local lines=""
  if [[ -z "$(env_get "$PD_ENV" APP_KEY)" ]]; then
    lines+="APP_KEY=$(openssl rand -base64 32)"$'\n'
  fi
  if [[ -n "$1" ]]; then
    lines+="TELEGRAM_BOT_TOKEN=$1"$'\n'
  fi
  [[ -n "$lines" ]] || return 0
  printf '%s' "$lines" | env_merge "$PD_ENV" 600 panel:panel
}

pd_db_name() {
  local db
  db="$(env_get "$PD_ENV" DB_NAME)"
  sql_ident_ok "$db" || return 1
  printf '%s\n' "$db"
}

# pd_as_panel CMD... — come utente panel (PD_AS_PANEL=0 solo nei test).
pd_as_panel() {
  if [[ "${PD_AS_PANEL:-1}" == 0 ]]; then
    "$@"
  else
    runuser -u panel -- "$@"
  fi
}
