# shellcheck shell=bash
# Risposte della procedura guidata: salvataggio, caricamento, variabili derivate.

ANSWER_VARS=(
  HOSTNAME_NEW TIMEZONE LOCALE
  ADMIN_USER ADMIN_PASS ADMIN_PUBKEY
  SSH_PORT ROOT_LOGIN SSH_IGNORE_IP
  WANT_NGINX WANT_PHP WANT_MARIADB WANT_REDIS WANT_CERTBOT WANT_PMA
  PANEL_ENABLED PANEL_DOMAIN
  CF_ENABLED CF_API_TOKEN CF_ZONE CF_ZONE_ID CF_LOCK_ORIGIN CF_DNS_REPLACE
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
  # IP da non bannare in fail2ban: quello salvato dalla procedura guidata o,
  # se manca, quello da cui è collegato ora l'utente. Solo se è un IP.
  if [[ -z "${SSH_IGNORE_IP:-}" ]]; then
    SSH_IGNORE_IP="$(ssh_client_ip)"
  fi
  if ! [[ "$SSH_IGNORE_IP" =~ ^[0-9A-Fa-f:.]*$ ]]; then
    SSH_IGNORE_IP=""
  fi
  export PANEL_ROOT SSH_ALLOW_USERS SSH_IGNORE_IP
}

# ssh_client_ip — IP del client SSH (da SSH_CLIENT), vuoto se ignoto o non valido.
ssh_client_ip() {
  local ip="${SSH_CLIENT:-}"
  ip="${ip%% *}"
  if [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ && "$ip" == *[.:]* ]]; then
    printf '%s' "$ip"
  fi
}
