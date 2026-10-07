# shellcheck shell=bash
# Attiva SSH con test anti-blocco, chiude l'accesso di default, riepilogo, pulizia, riavvio.

ssh_wait_confirmation() {
  local ip ans deadline=$((SECONDS + 600))
  ip="$(server_ipv4)" || ip="IP_DELLA_VPS"
  cat >/dev/tty <<EOF

=================== TEST ACCESSO SSH ===================
Lascia aperta QUESTA finestra. Aprine una NUOVA e accedi con:

    ssh -p $SSH_PORT $ADMIN_USER@$ip

Quando sei dentro, torna qui e scrivi OK.
Hai 10 minuti, poi la configurazione SSH viene ripristinata.
=========================================================
EOF
  while ((SECONDS < deadline)); do
    if read -r -t 30 -p "> " ans </dev/tty; then
      if [[ "${ans^^}" == "OK" ]]; then
        if admin_logged_in "$ADMIN_USER"; then
          return 0
        fi
        echo "Non vedo sessioni attive di $ADMIN_USER. Accedi dalla nuova finestra e riprova." >/dev/tty
      fi
    fi
  done
  return 1
}

finalize_ssh() {
  local conf=/etc/ssh/sshd_config.d/10-vps.conf
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    log "SSH: passo da ssh.socket a ssh.service"
    systemctl disable --now ssh.socket >>"$VPS_LOG" 2>&1
    systemctl enable --now ssh.service >>"$VPS_LOG" 2>&1
  fi
  install -m 644 "$VPS_ROOT/sshd-10-vps.conf" "$conf"
  if ! sshd -t >>"$VPS_LOG" 2>&1; then
    rm -f "$conf"
    die "Configurazione SSH non valida: ripristinata la precedente."
  fi
  systemctl reload ssh
  if ! ssh_wait_confirmation; then
    rm -f "$conf"
    systemctl reload ssh
    die "Accesso non confermato: SSH ripristinato (porta 22 ancora aperta). Controlla chiave e porta, poi riprendi con: sudo bash $VPS_ROOT/run.sh"
  fi
  if [[ "$SSH_PORT" != 22 ]]; then
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
  fi
  log "SSH: nuova configurazione attiva e verificata"
}

finalize_default_user() {
  if [[ "$ADMIN_USER" == debian ]] || ! id debian >/dev/null 2>&1; then
    return 0
  fi
  log "Utente debian: bloccato ora, eliminato al prossimo avvio"
  usermod -L -e 1 debian
  rm -f /home/debian/.ssh/authorized_keys
  install -m 644 "$VPS_TEMPLATES/vps-firstboot-cleanup.service" /etc/systemd/system/vps-firstboot-cleanup.service
  systemctl daemon-reload
  systemctl enable vps-firstboot-cleanup.service >>"$VPS_LOG" 2>&1
}

finalize_cloud_init() {
  if [[ -d /etc/cloud ]]; then
    touch /etc/cloud/cloud-init.disabled
    log "cloud-init disattivato"
  fi
}

finalize_mail_test() {
  is_yes "$MAIL_ENABLED" || return 0
  if mail_send_test "$ALERT_EMAIL"; then
    log "Email di prova inviata a $ALERT_EMAIL"
  else
    log "ATTENZIONE: email di prova non inviata (potrai configurarla dal pannello)"
  fi
}

finalize_summary_text() {
  local ip
  summary_load
  ip="$(server_ipv4)" || ip="IP_DELLA_VPS"
  echo
  echo "=================== INSTALLAZIONE COMPLETATA ==================="
  echo "Annota questi dati: NON verranno mostrati di nuovo."
  echo
  echo "SSH:          ssh -p $SSH_PORT $ADMIN_USER@$ip"
  if is_yes "$PANEL_ENABLED"; then
    echo "Pannello:     https://$PANEL_DOMAIN  (pagina segnaposto)"
  fi
  if is_yes "$WANT_PMA"; then
    echo "phpMyAdmin:   https://$PANEL_DOMAIN/pma/"
    echo "  accesso web:  $ADMIN_USER / ${PMA_BASIC_PASS:-(invariata)}"
    echo "  login DB:     panel_dbadmin / ${PANEL_DBADMIN_PASS:-(invariata, vedi $PANEL_ROOT/config/.env)}"
  fi
  if is_yes "$MAIL_ENABLED"; then
    echo "Email avvisi:  $ALERT_EMAIL"
  else
    echo "Email avvisi:  da configurare dal pannello"
  fi
  if is_yes "$CF_ENABLED"; then
    echo "Cloudflare:   imposta SSL/TLS su \"Full (strict)\" nella dashboard della zona."
  fi
  echo "Log:          $VPS_LOG"
  echo "================================================================"
}

finalize_cleanup_and_reboot() {
  read -r -p "Premi Invio per cancellare i file dell'installer e riavviare..." _ </dev/tty || true
  log "Pulizia dei file dell'installer e riavvio"
  if [[ -n "${VPS_BOOTSTRAP:-}" && -f "$VPS_BOOTSTRAP" ]]; then
    rm -f "$VPS_BOOTSTRAP"
  fi
  rm -rf "$VPS_ROOT"
  systemctl reboot
}

step_main() {
  if ! state_done "99-finalize:ssh"; then
    finalize_ssh
    state_mark "99-finalize:ssh"
  fi
  finalize_default_user
  finalize_cloud_init
  finalize_mail_test
  finalize_summary_text >/dev/tty
  finalize_cleanup_and_reboot
}
