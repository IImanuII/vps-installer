# shellcheck shell=bash
# phpMyAdmin: ultima versione verificata, servita solo su <pannello>/pma/.

step_enabled() {
  is_yes "$WANT_PMA"
}

pma_install_or_update() {
  local latest current
  latest="$(pma_latest_version)" || die "Impossibile leggere l'ultima versione di phpMyAdmin"
  current="$(pma_installed_version)"
  if [[ "$current" == "$latest" ]]; then
    log "phpMyAdmin: versione $current già installata"
  else
    pma_update_to "$latest"
  fi
}

pma_configure() {
  PMA_CONTROL_PASS="$(pma_controlpass_from_config)"
  if [[ -z "$PMA_CONTROL_PASS" ]]; then
    PMA_CONTROL_PASS="$(rand_secret 32)"
    # shellcheck disable=SC2034
    PMA_BLOWFISH="$(rand_secret 32)"
    render_template "$VPS_TEMPLATES/pma-config.inc.php.tmpl" "$PMA_DIR/config.inc.php" 640 root:panel \
      PMA_BLOWFISH PMA_CONTROL_PASS PANEL_ROOT PANEL_DOMAIN
  fi
  mariadb <"$PMA_DIR/sql/create_tables.sql"
  {
    sql_user_grant pma "$PMA_CONTROL_PASS" "SELECT, INSERT, UPDATE, DELETE" '`phpmyadmin`.*'
    echo "FLUSH PRIVILEGES;"
  } | mariadb
}

pma_web_access() {
  local pass
  # Prima il riepilogo, poi l'htpasswd: dopo un errore o un --reset la password
  # mostrata alla fine è sempre quella valida.
  pass="$(summary_get PMA_BASIC_PASS)"
  if [[ -z "$pass" ]]; then
    pass="$(rand_secret 20)"
    summary_set PMA_BASIC_PASS "$pass"
  fi
  printf '%s' "$pass" | pma_set_basic_auth "$ADMIN_USER"
  render_template "$VPS_TEMPLATES/nginx-pma.conf.tmpl" "$NGINX_SNIPPETS/panel.d/pma.conf" 644 root:root \
    VPS_OPT PHP_VERSION
  nginx -t >>"$VPS_LOG" 2>&1
  systemctl reload nginx
}

step_main() {
  log "phpMyAdmin: installazione"
  apt_install xz-utils
  install -d -m 755 "$VPS_OPT"
  pma_install_or_update
  pma_configure
  pma_web_access
}
