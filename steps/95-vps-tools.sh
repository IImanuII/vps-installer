# shellcheck shell=bash
# Strumenti per il pannello: /opt/vps/{bin,lib,templates}, manifest, sudoers, cron.

step_main() {
  log "Strumenti: installo /opt/vps"
  opt_install_files
  manifest_write

  if is_yes "$PANEL_ENABLED"; then
    local tmp
    tmp="$(mktemp)"
    cp "$VPS_TEMPLATES/sudoers-vps-panel" "$tmp"
    if ! visudo -cqf "$tmp"; then
      rm -f "$tmp"
      die "Regole sudoers non valide"
    fi
    install -m 440 -o root -g root "$tmp" /etc/sudoers.d/vps-panel
    rm -f "$tmp"
  else
    rm -f /etc/sudoers.d/vps-panel
  fi

  if is_yes "$CF_ENABLED"; then
    install -m 644 "$VPS_TEMPLATES/cron-vps" /etc/cron.d/vps
    manifest_set '.cloudflare.ips_updated_at = $t' --arg t "$(date -Iseconds)"
  else
    rm -f /etc/cron.d/vps
  fi
}
