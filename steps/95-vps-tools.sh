# shellcheck shell=bash
# Strumenti per il pannello: /opt/vps/{bin,lib,templates}, manifest, sudoers, cron, siti.

step_main() {
  log "Strumenti: installo /opt/vps"
  opt_install_files
  manifest_write
  opt_system_files
  if is_yes "$CF_ENABLED"; then
    manifest_set '.cloudflare.ips_updated_at = $t' --arg t "$(date -Iseconds)"
  fi
}
