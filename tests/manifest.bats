setup() {
  load test_helper
  setup_common
  server_ipv4() { echo 203.0.113.10; }
  server_ipv6() { echo ""; }
  pma_installed_version() { echo 5.2.3; }
  HOSTNAME_NEW=vps-01 ADMIN_USER=manu SSH_PORT=41822 ROOT_LOGIN=no
  WANT_NGINX=yes WANT_PHP=yes WANT_MARIADB=yes WANT_REDIS=no WANT_CERTBOT=yes WANT_PMA=yes
  CF_ENABLED=yes CF_LOCK_ORIGIN=yes CF_ZONE=miosito.it
  MAIL_ENABLED=no ALERT_EMAIL=""
  PANEL_ENABLED=yes PANEL_DOMAIN=panel.miosito.it PANEL_ROOT=/var/www/panel.miosito.it
}

@test "manifest_build produce il JSON del contratto" {
  run manifest_build
  [ "$status" -eq 0 ]
  [ "$(jq -r .admin_user <<<"$output")" = manu ]
  [ "$(jq -r .ssh_port <<<"$output")" = 41822 ]
  [ "$(jq -r .ipv6 <<<"$output")" = null ]
  [ "$(jq -r .components.php <<<"$output")" = "8.4" ]
  [ "$(jq -r .components.redis <<<"$output")" = false ]
  [ "$(jq -r .components.phpmyadmin <<<"$output")" = "5.2.3" ]
  [ "$(jq -r .cloudflare.origin_locked <<<"$output")" = true ]
  [ "$(jq -r .mail.configured <<<"$output")" = false ]
  [ "$(jq -r .panel.php_socket <<<"$output")" = "/run/php/php8.4-fpm-panel.sock" ]
  [ "$(jq -r .conventions.site_db_prefix <<<"$output")" = site_ ]
}

@test "manifest senza pannello" {
  PANEL_ENABLED=no
  run manifest_build
  [ "$(jq -r .panel <<<"$output")" = null ]
}

@test "manifest_write e manifest_set" {
  manifest_write
  [ "$(stat -c %a "$VPS_OPT/manifest.json")" = "640" ]
  manifest_set '.mail.configured = true | .mail.alert_email = $e' --arg e avvisi@gmail.com
  [ "$(jq -r .mail.alert_email "$VPS_OPT/manifest.json")" = avvisi@gmail.com ]
}
