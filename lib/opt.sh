# shellcheck shell=bash
# /opt/vps: script, librerie e template dell'installer.

# Cartella dei link ai comandi da lanciare con sudo: /opt/vps/bin non è nel
# secure_path di sudo su Debian, /usr/local/sbin sì.
: "${VPS_SBIN:=/usr/local/sbin}"
: "${SUDOERS_D:=/etc/sudoers.d}"
: "${CRON_D:=/etc/cron.d}"
: "${SYSTEMD_DIR:=/etc/systemd/system}"

opt_install_files() {
  local t
  install -d -m 755 "$VPS_OPT" "$VPS_OPT/bin" "$VPS_OPT/lib" "$VPS_OPT/templates"
  install -d -m 700 "$VPS_OPT/secrets"
  install -m 644 "$VPS_ROOT"/lib/*.sh "$VPS_OPT/lib/"
  install -m 644 "$VPS_ROOT"/templates/* "$VPS_OPT/templates/"
  install -m 755 "$VPS_ROOT"/tools/vps-* "$VPS_OPT/bin/"
  install -d -m 755 "$VPS_SBIN"
  for t in vps-panel-install vps-panel-update; do
    ln -sfn "$VPS_OPT/bin/$t" "$VPS_SBIN/$t"
  done
}

# opt_tools_only — aggiorna gli script su una VPS già installata, senza procedura guidata.
opt_tools_only() {
  [[ -f "$(manifest_path)" ]] || die "Manifest assente: macchina mai installata con questo installer. Lancia install.sh senza --tools-only."
  opt_install_files
  opt_system_files
  manifest_set '.installer_version = $v' --arg v "$VPS_INSTALLER_VERSION"
  log "Script di /opt/vps aggiornati alla versione $VPS_INSTALLER_VERSION."
}

# opt_system_files — la parte di sistema degli script: sudoers del pannello,
# cron, cartelle dei siti e pagina di manutenzione. La chiama anche
# --tools-only: senza, una VPS già installata riceverebbe vps-site ma il
# pannello non avrebbe il permesso di eseguirlo.
opt_system_files() {
  local m tmp
  m="$(manifest_path)"
  if [[ "$(jq -r '.panel != null' "$m")" == true ]]; then
    tmp="$(mktemp)"
    cp "$VPS_TEMPLATES/sudoers-vps-panel" "$tmp"
    if ! visudo -cqf "$tmp"; then
      rm -f "$tmp"
      die "Regole sudoers non valide"
    fi
    install -m 440 "$tmp" "$SUDOERS_D/vps-panel"
    own root:root "$SUDOERS_D/vps-panel"
    rm -f "$tmp"
  else
    rm -f "$SUDOERS_D/vps-panel"
  fi
  if [[ "$(jq -r '.cloudflare.enabled == true' "$m")" == true ]]; then
    install -m 644 "$VPS_TEMPLATES/cron-vps" "$CRON_D/vps"
  else
    rm -f "$CRON_D/vps"
  fi
  install -d -m 750 "$SITES_DIR"
  own "root:$(manifest_group)" "$SITES_DIR"
  install -d -m 700 "$(dirname "$SITES_BACKUPS")" "$SITES_BACKUPS"
  install -d -m 755 "$SITES_WWW/_maintenance"
  install -m 644 "$VPS_TEMPLATES/maintenance.html" "$SITES_WWW/_maintenance/_maintenance.html"
  if ! dpkg -s acl >/dev/null 2>&1; then
    apt_install acl || die "Pacchetto acl non installato"
  fi
  wpcli_install || log "ATTENZIONE: WP-CLI non installato: WordPress non sarà disponibile finché non riesce"
  if [[ "$(jq -r '.components.redis == true' "$m")" == true ]]; then
    redis_acl_setup || log "ATTENZIONE: Redis con utenti ACL non configurato: WordPress non sarà disponibile (dettagli in $VPS_LOG)"
  fi
  opt_monitor_files
}

# opt_monitor_files — unità systemd e cartelle di vps-monitor. Il timer resta
# spento finché `vps-monitor config` non riceve enabled:true; in un aggiornamento
# (--tools-only) con la sorveglianza già attiva lo si riabilita.
opt_monitor_files() {
  local u
  for u in vps-monitor.service vps-monitor.timer; do
    install -m 644 "$VPS_TEMPLATES/$u" "$SYSTEMD_DIR/$u"
    own root:root "$SYSTEMD_DIR/$u"
  done
  install -d -m 700 "$MON_DIR" "$MON_STATE_DIR" "$MON_QUEUE"
  systemctl daemon-reload >>"$VPS_LOG" 2>&1 || log "ATTENZIONE: systemctl daemon-reload non riuscito"
  if [[ -f "$MON_CONFIG" && "$(jq -r '.enabled == true' "$MON_CONFIG" 2>/dev/null)" == true ]]; then
    systemctl enable --now vps-monitor.timer >>"$VPS_LOG" 2>&1 || log "ATTENZIONE: timer di vps-monitor non abilitato"
  fi
}
