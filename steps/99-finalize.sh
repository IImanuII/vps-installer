# shellcheck shell=bash
# Attiva SSH con test anti-blocco, chiude l'accesso di default, riepilogo, pulizia, riavvio.

ssh_conf_path() {
  echo "${SSH_CONF_PATH:-/etc/ssh/sshd_config.d/10-vps.conf}"
}

# Rimuove la configurazione nuova e ricarica sshd: la porta 22 resta aperta.
ssh_rollback() {
  rm -f "$(ssh_conf_path)"
  systemctl reload ssh || systemctl restart ssh || true
  ssh_watchdog_cancel
}

# Rollback indipendente dal processo: scatta anche se l'installer muore durante l'attesa.
ssh_watchdog_arm() {
  local secs=$((${SSH_CONFIRM_TIMEOUT:-600} + 120)) conf
  conf="$(ssh_conf_path)"
  [[ "$conf" =~ ^[A-Za-z0-9/._-]+$ ]] || return 1
  ssh_watchdog_cancel
  systemd-run --quiet --unit=vps-ssh-rollback --on-active="${secs}s" \
    /bin/sh -c "rm -f '$conf'; systemctl reload ssh || systemctl restart ssh" >>"$VPS_LOG" 2>&1
}

ssh_watchdog_cancel() {
  systemctl stop vps-ssh-rollback.timer vps-ssh-rollback.service 2>/dev/null || true
  systemctl reset-failed vps-ssh-rollback.timer vps-ssh-rollback.service 2>/dev/null || true
}

ssh_wait_confirmation() {
  local before="${1:-}" ip ans tty="${VPS_SSH_TTY:-/dev/tty}"
  local deadline=$((SECONDS + ${SSH_CONFIRM_TIMEOUT:-600}))
  ip="$(server_ipv4)" || ip="IP_DELLA_VPS"
  [[ -n "$ip" ]] || ip="IP_DELLA_VPS"
  cat >>"$tty" <<EOT

=================== TEST ACCESSO SSH ===================
Lascia aperta QUESTA finestra. Aprine una NUOVA e accedi con:

    ssh -p $SSH_PORT -i ~/.ssh/<tua-chiave> -o IdentitiesOnly=yes $ADMIN_USER@$ip

(-i e IdentitiesOnly fanno usare solo quella chiave: evitano l'errore
"Too many authentication failures" se sul tuo PC hai più chiavi SSH.)

Quando sei dentro, torna qui e scrivi OK.
Hai 10 minuti, poi la configurazione SSH viene ripristinata.
=========================================================
EOT
  while ((SECONDS < deadline)); do
    if read -r -t "${SSH_READ_TIMEOUT:-30}" -p "> " ans <"$tty"; then
      if [[ "${ans^^}" == "OK" ]]; then
        if admin_new_session "$ADMIN_USER" "$before"; then
          return 0
        fi
        echo "Non vedo una NUOVA sessione di $ADMIN_USER. Accedi dalla nuova finestra e riprova." >>"$tty"
      fi
    else
      sleep 1
    fi
  done
  return 1
}

finalize_ssh() {
  local conf before socket=no tty="${VPS_SSH_TTY:-/dev/tty}"
  conf="$(ssh_conf_path)"
  if ! { : <"$tty"; } 2>/dev/null; then
    die "Terminale non disponibile per il test di accesso SSH: configurazione non attivata."
  fi
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
    socket=yes
  fi
  if [[ "$socket" == yes ]]; then
    log "SSH: passo da ssh.socket a ssh.service"
    systemctl disable --now ssh.socket >>"$VPS_LOG" 2>&1 || true
    if ! systemctl enable --now ssh.service >>"$VPS_LOG" 2>&1; then
      systemctl enable --now ssh.socket >>"$VPS_LOG" 2>&1 || true
      die "Impossibile avviare ssh.service: ripristinato ssh.socket, configurazione SSH invariata."
    fi
  fi
  install -m 644 "$VPS_ROOT/sshd-10-vps.conf" "$conf"
  if ! sshd -t >>"$VPS_LOG" 2>&1; then
    rm -f "$conf"
    die "Configurazione SSH non valida: ripristinata la precedente."
  fi
  before="$(admin_session_ids "$ADMIN_USER")"
  if ! ssh_watchdog_arm; then
    rm -f "$conf"
    die "Impossibile armare il rollback automatico di SSH: configurazione non attivata."
  fi
  if ! systemctl reload ssh; then
    rm -f "$conf"
    systemctl reload ssh || systemctl restart ssh || true
    ssh_watchdog_cancel
    die "Ricarica di SSH fallita: configurazione ripristinata."
  fi
  trap 'ssh_rollback; exit 129' HUP
  trap 'ssh_rollback; exit 130' INT TERM
  if ! ssh_wait_confirmation "$before"; then
    trap - HUP INT TERM
    ssh_rollback
    die "Accesso non confermato: SSH ripristinato (porta 22 ancora aperta). Controlla chiave e porta, poi riprendi con: sudo bash install.sh (dalla home da cui l'hai lanciato)"
  fi
  trap - HUP INT TERM
  ssh_watchdog_cancel
  if systemctl is-active --quiet vps-ssh-rollback.timer 2>/dev/null; then
    log "ATTENZIONE: il rollback automatico di SSH è ancora attivo: lascio aperta la porta 22"
  elif [[ "$SSH_PORT" != 22 ]]; then
    if ! ufw delete allow 22/tcp >/dev/null 2>&1; then
      log "ATTENZIONE: impossibile chiudere la porta 22 nel firewall, fallo a mano"
    fi
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
  [[ -n "$ip" ]] || ip="IP_DELLA_VPS"
  echo
  echo "=================== INSTALLAZIONE COMPLETATA ==================="
  echo "Annota questi dati: NON verranno mostrati di nuovo."
  echo
  echo "SSH:          ssh -p $SSH_PORT $ADMIN_USER@$ip"
  echo "Componenti:   $(components_summary)"
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
  read -r -p "Premi Invio per cancellare i file dell'installer e riavviare..." _ <"${VPS_TTY:-/dev/tty}" || true
  log "Pulizia dei file dell'installer e riavvio"
  if [[ -n "${VPS_BOOTSTRAP:-}" && -f "$VPS_BOOTSTRAP" ]]; then
    rm -f "$VPS_BOOTSTRAP"
  fi
  # Cancella solo una cartella che è sicuramente dell'installer.
  if [[ "$VPS_ROOT" == /root/vps-installer || -f "$VPS_ROOT/.release" ]]; then
    rm -rf "$VPS_ROOT"
  else
    log "ATTENZIONE: $VPS_ROOT non sembra la cartella dell'installer (manca .release): non la cancello"
  fi
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
