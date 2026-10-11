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

# pd_checkout TAG — codice al rilascio TAG; config/.env, logs/ e storage/ sono
# ignorati da git e restano come sono. Tutto torna a panel.
# chown -R -P -h sull'intera radice è la forma sicura: coreutils scende con
# fchownat su descrittori di directory e non segue mai i link simbolici, mentre
# un giro per percorso potrebbe essere eluso scambiando una cartella con un link.
pd_checkout() {
  pd_git checkout -q -f "$1" || return 1
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
