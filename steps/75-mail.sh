# shellcheck shell=bash
# msmtp: installato sempre, configurato solo se richiesto (altrimenti dal pannello).

step_main() {
  echo "msmtp msmtp/apparmor boolean false" | debconf-set-selections
  apt_install msmtp msmtp-mta
  if is_yes "$MAIL_ENABLED"; then
    log "Email: configuro msmtp ($SMTP_HOST:$SMTP_PORT)"
    mail_render_config
  else
    log "Email: da configurare dal pannello"
  fi
}
