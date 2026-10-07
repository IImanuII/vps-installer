# shellcheck shell=bash
# Dominio del pannello: utente, cartelle, DB, pool PHP, DNS Cloudflare, vhost.

step_enabled() {
  is_yes "$PANEL_ENABLED"
}

panel_user_and_dirs() {
  if ! id panel >/dev/null 2>&1; then
    useradd --system --home-dir "$PANEL_ROOT" --no-create-home --shell /usr/sbin/nologin --user-group panel
  fi
  usermod -aG panel www-data
  # www-data (gruppo panel) attraversa la radice e legge public/ e logs/;
  # codice e configurazione restano solo dell'utente panel.
  install -d -m 750 -o panel -g panel "$PANEL_ROOT" "$PANEL_ROOT/public" "$PANEL_ROOT/logs"
  install -d -m 700 -o panel -g panel "$PANEL_ROOT/app" "$PANEL_ROOT/config"
  install -d -m 700 -o panel -g panel "$PANEL_ROOT/storage" "$PANEL_ROOT/storage/sessions" \
    "$PANEL_ROOT/storage/tmp" "$PANEL_ROOT/storage/pma-tmp"
  if [[ ! -e "$PANEL_ROOT/public/index.php" && ! -e "$PANEL_ROOT/public/index.html" ]]; then
    install -m 640 -o panel -g panel "$VPS_TEMPLATES/panel-placeholder.html" "$PANEL_ROOT/public/index.html"
  fi
}

panel_database() {
  local env="$PANEL_ROOT/config/.env" db_pass admin_pass
  db_pass="$(env_get "$env" DB_PASS)"
  admin_pass="$(env_get "$env" DBADMIN_PASS)"
  if [[ -z "$db_pass" ]]; then db_pass="$(rand_secret 32)"; fi
  if [[ -z "$admin_pass" ]]; then
    admin_pass="$(rand_secret 24)"
    summary_set PANEL_DBADMIN_PASS "$admin_pass"
  fi
  {
    sql_db_with_user panel panel "$db_pass"
    sql_user_grant panel_dbadmin "$admin_pass" "ALL PRIVILEGES" '`site\_%`.*'
    echo "FLUSH PRIVILEGES;"
  } | mariadb
  printf 'DB_HOST=localhost\nDB_NAME=panel\nDB_USER=panel\nDB_PASS=%s\nDBADMIN_USER=panel_dbadmin\nDBADMIN_PASS=%s\n' \
    "$db_pass" "$admin_pass" | env_merge "$env" 600 panel:panel
}

panel_php_pool() {
  local pool_dir="/etc/php/$PHP_VERSION/fpm/pool.d"
  render_template "$VPS_TEMPLATES/php-pool-panel.conf.tmpl" "$pool_dir/panel.conf" 644 root:root \
    PANEL_ROOT PHP_VERSION VPS_OPT
  if [[ -f "$pool_dir/www.conf" ]]; then
    mv "$pool_dir/www.conf" "$pool_dir/www.conf.disabled"
  fi
  "php-fpm$PHP_VERSION" -t >>"$VPS_LOG" 2>&1
  systemctl restart "php$PHP_VERSION-fpm"
}

panel_dns() {
  local v6
  is_yes "$CF_ENABLED" || return 0
  log "Pannello: record DNS su Cloudflare"
  cf_upsert_record "$CF_ZONE_ID" A "$PANEL_DOMAIN" "$(server_ipv4)" || die "Record A su Cloudflare non creato"
  v6="$(server_ipv6)"
  if [[ -n "$v6" ]]; then
    cf_upsert_record "$CF_ZONE_ID" AAAA "$PANEL_DOMAIN" "$v6" || die "Record AAAA su Cloudflare non creato"
  fi
}

panel_vhost() {
  install -d -m 755 "$NGINX_SNIPPETS/panel.d"
  render_template "$VPS_TEMPLATES/nginx-panel.conf.tmpl" "/etc/nginx/conf.d/$PANEL_DOMAIN.conf" 644 root:root \
    PANEL_DOMAIN PANEL_ROOT PHP_VERSION
  nginx -t >>"$VPS_LOG" 2>&1
  systemctl reload nginx
}

step_main() {
  log "Pannello: preparo $PANEL_DOMAIN"
  panel_user_and_dirs
  panel_database
  panel_php_pool
  panel_dns
  panel_vhost
}
