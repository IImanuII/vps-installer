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
  # Password vuota con SMTP_PASS_ESC gia' impostato (mail_saved_pass_esc): si tiene la salvata.
  if [[ -n "$SMTP_PASS" || -z "${SMTP_PASS_ESC:-}" ]]; then
    # shellcheck disable=SC2034
    SMTP_PASS_ESC="$(mail_escape "$SMTP_PASS")"
  fi
  install -d -m 700 "$VPS_OPT/secrets"
  render_template "$VPS_TEMPLATES/msmtprc.tmpl" "$VPS_OPT/secrets/msmtprc" 600 root:root \
    SMTP_HOST SMTP_PORT SMTP_TLS_STARTTLS SMTP_FROM SMTP_USER SMTP_PASS_ESC
  ln -sfn "$VPS_OPT/secrets/msmtprc" "$MSMTPRC_LINK"
  printf 'root: %s\ndefault: %s\n' "$ALERT_EMAIL" "$ALERT_EMAIL" | write_file "$ALIASES_FILE" 644 root:root
}

# mail_saved_pass_esc — la password salvata in msmtprc, gia' con l'escape (vuoto se non c'e').
mail_saved_pass_esc() {
  local f="$VPS_OPT/secrets/msmtprc"
  [[ -f "$f" ]] || return 0
  sed -n 's/^password "\(.*\)"$/\1/p' "$f" | head -n 1
}

# mail_conf_get CHIAVE — un valore della sezione account di msmtprc (host, port, user, from).
mail_conf_get() {
  awk -v k="$1" '/^account / { a = 1 } a && $1 == k { sub("^" k " ", ""); print; exit }' "$VPS_OPT/secrets/msmtprc"
}

# _mail_reason STDERR — la riga piu' utile dello stderr di msmtp, senza prefisso ne' controlli.
# Prima la risposta del server ("535 ... not accepted"), poi la prima riga di msmtp che non sia
# il generico "could not send mail". msmtp non scrive mai la password.
_mail_reason() {
  local r
  r="$(grep -m 1 'server message:' <<<"$1" || true)"
  [[ -n "$r" ]] || r="$(grep 'msmtp: ' <<<"$1" | grep -v 'could not send mail' | head -n 1 || true)"
  [[ -n "$r" ]] || r="$(tail -n 1 <<<"$1")"
  r="${r##*msmtp: }"
  r="${r#server message: }"
  r="$(tr -d '[:cntrl:]' <<<"$r")"
  printf '%s' "${r:0:200}"
}

# mail_send_test EMAIL — 0 se msmtp ha accettato; altrimenti MAIL_ERR dice perche'.
mail_send_test() {
  local to="$1" from host err rc=0
  from="$(mail_conf_get from)"
  host="$(hostname)"
  err="$(printf 'Subject: Email di prova da %s\nFrom: %s\nTo: %s\nContent-Type: text/plain; charset=UTF-8\n\nEmail di prova inviata da %s il %s.\n' \
    "$host" "$from" "$to" "$host" "$(date '+%F %T')" | msmtp -t 2>&1)" || rc=$?
  [[ -z "$err" ]] || printf '%s\n' "$err" >>"$VPS_LOG"
  ((rc == 0)) && return 0
  # shellcheck disable=SC2034 # letto da vps-smtp
  MAIL_ERR="$(_mail_reason "$err")"
  return 1
}
