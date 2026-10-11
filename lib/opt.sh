# shellcheck shell=bash
# /opt/vps: script, librerie e template dell'installer.

opt_install_files() {
  install -d -m 755 "$VPS_OPT" "$VPS_OPT/bin" "$VPS_OPT/lib" "$VPS_OPT/templates"
  install -d -m 700 "$VPS_OPT/secrets"
  install -m 644 "$VPS_ROOT"/lib/*.sh "$VPS_OPT/lib/"
  install -m 644 "$VPS_ROOT"/templates/* "$VPS_OPT/templates/"
  install -m 755 "$VPS_ROOT"/tools/vps-* "$VPS_OPT/bin/"
}

# opt_tools_only — aggiorna gli script su una VPS già installata, senza procedura guidata.
opt_tools_only() {
  [[ -f "$(manifest_path)" ]] || die "Manifest assente: macchina mai installata con questo installer. Lancia install.sh senza --tools-only."
  opt_install_files
  manifest_set '.installer_version = $v' --arg v "$VPS_INSTALLER_VERSION"
  log "Script di /opt/vps aggiornati alla versione $VPS_INSTALLER_VERSION."
}
