# shellcheck shell=bash
# /opt/vps/manifest.json: informazioni non segrete lette dal pannello.

manifest_path() {
  printf '%s/manifest.json' "$VPS_OPT"
}

manifest_group() {
  if getent group panel >/dev/null 2>&1; then
    echo panel
  else
    echo root
  fi
}

manifest_build() {
  jq -n \
    --arg version "$VPS_INSTALLER_VERSION" --arg at "$(date -Iseconds)" \
    --arg hostname "$HOSTNAME_NEW" --arg ipv4 "$(server_ipv4)" --arg ipv6 "$(server_ipv6)" \
    --arg user "$ADMIN_USER" --argjson port "$SSH_PORT" --arg root "$ROOT_LOGIN" \
    --arg nginx "$WANT_NGINX" --arg php "$WANT_PHP" --arg phpv "$PHP_VERSION" \
    --arg mariadb "$WANT_MARIADB" --arg redis "$WANT_REDIS" --arg certbot "$WANT_CERTBOT" \
    --arg pma "$(pma_installed_version)" \
    --arg cf "$CF_ENABLED" --arg cflock "$CF_LOCK_ORIGIN" --arg zone "$CF_ZONE" \
    --arg mail "$MAIL_ENABLED" --arg alert "$ALERT_EMAIL" \
    --arg panel "$PANEL_ENABLED" --arg pdomain "$PANEL_DOMAIN" --arg proot "$PANEL_ROOT" \
    '{
      installer_version: $version,
      installed_at: $at,
      hostname: $hostname,
      ipv4: $ipv4,
      ipv6: (if $ipv6 == "" then null else $ipv6 end),
      admin_user: $user,
      ssh_port: $port,
      root_login: $root,
      components: {
        nginx: ($nginx == "yes"),
        php: (if $php == "yes" then $phpv else null end),
        mariadb: ($mariadb == "yes"),
        redis: ($redis == "yes"),
        certbot: ($certbot == "yes"),
        phpmyadmin: (if $pma == "" then null else $pma end)
      },
      cloudflare: {
        enabled: ($cf == "yes"),
        origin_locked: ($cf == "yes" and $cflock == "yes"),
        zone: (if $cf == "yes" then $zone else null end),
        ips_updated_at: null
      },
      mail: {
        configured: ($mail == "yes"),
        alert_email: (if $mail == "yes" then $alert else null end)
      },
      panel: (if $panel == "yes" then {
        domain: $pdomain,
        path: $proot,
        php_socket: ("/run/php/php" + $phpv + "-fpm-panel.sock"),
        pma_path: "/pma/"
      } else null end),
      conventions: {
        site_root: "/var/www/<dominio>",
        site_db_prefix: "site_",
        site_user_prefix: "site_"
      }
    }'
}

manifest_write() {
  manifest_build | write_file "$(manifest_path)" 640 "root:$(manifest_group)"
}

# manifest_set FILTRO [ARGOMENTI_JQ...]
manifest_set() {
  local filter="$1" f
  shift
  f="$(manifest_path)"
  jq "$@" "$filter" "$f" | write_file "$f" 640 "root:$(manifest_group)"
}
