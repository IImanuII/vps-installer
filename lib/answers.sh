# shellcheck shell=bash
# Risposte della procedura guidata: salvataggio, caricamento, variabili derivate.

ANSWER_VARS=(
  HOSTNAME_NEW TIMEZONE LOCALE
  ADMIN_USER ADMIN_PASS ADMIN_PUBKEY
  SSH_PORT ROOT_LOGIN
  WANT_NGINX WANT_PHP WANT_MARIADB WANT_REDIS WANT_CERTBOT WANT_PMA
  PANEL_ENABLED PANEL_DOMAIN
  CF_ENABLED CF_API_TOKEN CF_ZONE CF_ZONE_ID CF_LOCK_ORIGIN
  MAIL_ENABLED SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM ALERT_EMAIL
)

answers_save() {
  local file="${1:-$VPS_ANSWERS}" v
  for v in "${ANSWER_VARS[@]}"; do
    printf '%s=%q\n' "$v" "${!v:-}"
  done | write_file "$file" 600 "$(id -un):$(id -gn)"
}

answers_load() {
  local file="${1:-$VPS_ANSWERS}" v
  [[ -f "$file" ]] || die "File delle risposte non trovato: $file"
  source "$file"
  for v in "${ANSWER_VARS[@]}"; do
    export "${v?}"
  done
  answers_derive
}

answers_derive() {
  PANEL_ROOT="/var/www/${PANEL_DOMAIN:-_}"
  if [[ "${ROOT_LOGIN:-no}" == "prohibit-password" ]]; then
    SSH_ALLOW_USERS="${ADMIN_USER:-} root"
  else
    SSH_ALLOW_USERS="${ADMIN_USER:-}"
  fi
  export PANEL_ROOT SSH_ALLOW_USERS
}
