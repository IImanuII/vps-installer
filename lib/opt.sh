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

# opt_panel_pool — sulle installazioni fatte prima della 1.5.2 il pool del
# pannello non ha /opt/vps/bin in open_basedir: la dashboard non legge l'elenco
# degli script. Si aggiunge solo quel percorso (cartella di root, script di
# sola lettura), si verifica con php-fpm -t e si ricarica; se qualcosa non va
# torna il file di prima.
opt_panel_pool() {
  local m ver f bak
  m="$(manifest_path)"
  ver="$(jq -r '.components.php // empty' "$m")"
  [[ -n "$ver" && "$(jq -r '.panel != null' "$m")" == true ]] || return 0
  f="${PANEL_POOL_FILE:-/etc/php/$ver/fpm/pool.d/panel.conf}"
  [[ -f "$f" ]] || return 0
  grep -q '^php_admin_value\[open_basedir\]' "$f" || return 0
  if grep '^php_admin_value\[open_basedir\]' "$f" | grep -qF "$VPS_OPT/bin/"; then
    return 0
  fi
  bak="$(mktemp)"
  cp -p "$f" "$bak"
  sed -i "/^php_admin_value\[open_basedir\]/ s#\$#:$VPS_OPT/bin/#" "$f"
  if "php-fpm$ver" -t >>"$VPS_LOG" 2>&1 && systemctl reload "php$ver-fpm" >>"$VPS_LOG" 2>&1; then
    rm -f "$bak"
    log "Pool del pannello: $VPS_OPT/bin/ aggiunto a open_basedir"
  else
    mv -f "$bak" "$f"
    log "ATTENZIONE: pool del pannello non aggiornato (php-fpm -t o reload falliti), lasciato com'era"
  fi
}

# opt_panel_vhost — le installazioni precedenti alla 1.6.0 hanno il vhost del
# pannello senza fastcgi_read_timeout: le operazioni sui file (fino a 120 s)
# verrebbero tagliate dal default di nginx (60 s). Si aggiunge la riga
# `fastcgi_read_timeout 150s;` subito dopo il fastcgi_pass del pool del pannello,
# si verifica con nginx -t e si ricarica; se qualcosa non va torna il file di
# prima e --tools-only prosegue.
opt_panel_vhost() {
  local m dom f bak
  m="$(manifest_path)"
  dom="$(jq -r '.panel.domain // empty' "$m")"
  [[ -n "$dom" ]] || return 0
  f="${PANEL_VHOST_FILE:-${NGINX_CONF_D:-/etc/nginx/conf.d}/$dom.conf}"
  [[ -f "$f" ]] || return 0
  grep -q 'fastcgi_read_timeout' "$f" && return 0
  grep -q '^[[:space:]]*fastcgi_pass .*-fpm-panel\.sock;' "$f" || return 0
  bak="$(mktemp)"
  cp -p "$f" "$bak"
  sed -i 's/^\([[:space:]]*\)\(fastcgi_pass .*-fpm-panel\.sock;\)/&\n\1fastcgi_read_timeout 150s;/' "$f"
  if nginx -t >>"$VPS_LOG" 2>&1 && systemctl reload nginx >>"$VPS_LOG" 2>&1; then
    rm -f "$bak"
    log "Vhost del pannello: aggiunto fastcgi_read_timeout 150s"
  else
    mv -f "$bak" "$f"
    log "ATTENZIONE: vhost del pannello non aggiornato (nginx -t o reload falliti), lasciato com'era"
  fi
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
  # zip e unzip: li usa il file manager (vps-files zip, unzip, download-zip);
  # rclone: le copie su Google Drive (vps-backup)
  for pkg in zip unzip rclone; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      apt_install "$pkg" || die "Pacchetto $pkg non installato"
    fi
  done
  wpcli_install || log "ATTENZIONE: WP-CLI non installato: WordPress non sarà disponibile finché non riesce"
  if [[ "$(jq -r '.components.redis == true' "$m")" == true ]]; then
    redis_acl_setup || log "ATTENZIONE: Redis con utenti ACL non configurato: WordPress non sarà disponibile (dettagli in $VPS_LOG)"
  fi
  opt_monitor_files
  opt_backup_files
  opt_panel_pool
  opt_panel_vhost
  # Aggiornamenti automatici: anche Nginx di nginx.org (dalla 1.5.3). Solo sulle
  # macchine che hanno gia' la configurazione dell'installer.
  if [[ -f "${APT_CONF_D:-/etc/apt/apt.conf.d}/52vps-unattended" ]]; then
    install -m 644 "$VPS_TEMPLATES/apt-52vps-unattended" "${APT_CONF_D:-/etc/apt/apt.conf.d}/52vps-unattended"
  fi
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

# opt_backup_files — unità systemd, cartelle e configurazione iniziale di vps-backup.
# Il timer resta spento finché `vps-backup config` non riceve enabled:true; in un
# aggiornamento (--tools-only) con il backup già attivo lo si riabilita (il drop-in
# con l'orario scelto sta già in .timer.d e non si tocca). La configurazione
# esistente non si sovrascrive mai.
opt_backup_files() {
  local u d
  for u in vps-backup.service vps-backup.timer; do
    install -m 644 "$VPS_TEMPLATES/$u" "$SYSTEMD_DIR/$u"
    own root:root "$SYSTEMD_DIR/$u"
  done
  install -d -m 700 "$BK_DIR" "$BK_BACKUPS"
  for d in panel sites restore tmp; do
    install -d -m 700 "$BK_BACKUPS/$d"
  done
  if [[ ! -f "$BK_CONFIG" ]]; then
    bk_config_json | write_file "$BK_CONFIG" 600 root:root
  fi
  systemctl daemon-reload >>"$VPS_LOG" 2>&1 || log "ATTENZIONE: systemctl daemon-reload non riuscito"
  if [[ "$(jq -r '.enabled == true' "$BK_CONFIG" 2>/dev/null)" == true && -f "${BK_RCLONE_CONF:-$VPS_OPT/secrets/rclone.conf}" ]]; then
    systemctl enable --now vps-backup.timer >>"$VPS_LOG" 2>&1 || log "ATTENZIONE: timer di vps-backup non abilitato"
  fi
}
