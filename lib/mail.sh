# shellcheck shell=bash
# Email in uscita tramite msmtp.

: "${MSMTPRC_LINK:=/etc/msmtprc}"
: "${ALIASES_FILE:=/etc/aliases}"

mail_escape() {
  # shellcheck disable=SC1003
  local s="$1" b='\' d='"'
  s="${s//"$b"/"$b$b"}"
  s="${s//"$d"/"$b$d"}"
  printf '%s' "$s"
}

mail_render_config() {
  SMTP_TLS_STARTTLS=on
  if [[ "$SMTP_PORT" == 465 ]]; then
    # shellcheck disable=SC2034
    SMTP_TLS_STARTTLS=off
  fi
  # shellcheck disable=SC2034
  SMTP_PASS_ESC="$(mail_escape "$SMTP_PASS")"
  install -d -m 700 "$VPS_OPT/secrets"
  render_template "$VPS_TEMPLATES/msmtprc.tmpl" "$VPS_OPT/secrets/msmtprc" 600 root:root \
    SMTP_HOST SMTP_PORT SMTP_TLS_STARTTLS SMTP_FROM SMTP_USER SMTP_PASS_ESC
  ln -sfn "$VPS_OPT/secrets/msmtprc" "$MSMTPRC_LINK"
  printf 'root: %s\ndefault: %s\n' "$ALERT_EMAIL" "$ALERT_EMAIL" | write_file "$ALIASES_FILE" 644 root:root
}

mail_send_test() {
  local to="$1" from host
  from="$(awk '$1 == "from" { print $2; exit }' "$VPS_OPT/secrets/msmtprc")"
  host="$(hostname)"
  printf 'Subject: Email di prova da %s\nFrom: %s\nTo: %s\nContent-Type: text/plain; charset=UTF-8\n\nEmail di prova inviata da %s il %s.\n' \
    "$host" "$from" "$to" "$host" "$(date '+%F %T')" | msmtp -t >>"$VPS_LOG" 2>&1
}
