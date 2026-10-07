# shellcheck shell=bash
# Strumenti per il pannello: /opt/vps/{bin,lib,templates}, manifest, sudoers, cron.

step_main() {
  log "Strumenti: installo /opt/vps"
  install -d -m 755 "$VPS_OPT" "$VPS_OPT/bin" "$VPS_OPT/lib" "$VPS_OPT/templates"
  install -d -m 700 "$VPS_OPT/secrets"
  install -m 644 "$VPS_ROOT"/lib/*.sh "$VPS_OPT/lib/"
  install -m 644 "$VPS_ROOT"/templates/* "$VPS_OPT/templates/"
  install -m 755 "$VPS_ROOT"/tools/vps-* "$VPS_OPT/bin/"
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
