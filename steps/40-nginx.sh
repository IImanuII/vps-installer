# shellcheck shell=bash
# Nginx dal repository ufficiale nginx.org.

# shellcheck disable=SC2034
NGINX_KEY_FPRS=(
  573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62
  8540A6F18833A80E9C1653A42FD21310B49F6B46
  9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3
)

step_enabled() {
  is_yes "$WANT_NGINX"
}

step_main() {
  local keyring=/usr/share/keyrings/nginx-archive-keyring.gpg tmp
  log "Nginx: repository nginx.org"
  tmp="$(mktemp)"
  curl -fsS --max-time 30 -o "$tmp" https://nginx.org/keys/nginx_signing.key
  gpg_keyring_install "$tmp" "$keyring" "${NGINX_KEY_FPRS[@]}"
  rm -f "$tmp"
  printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
    | write_file /etc/apt/preferences.d/99nginx 644 root:root
  apt_add_repo nginx "$keyring" "deb [signed-by=$keyring] https://nginx.org/packages/debian $(os_codename) nginx"
  apt_install nginx apache2-utils

  log "Nginx: configurazione"
  rm -f /etc/nginx/conf.d/default.conf
  install -d -m 755 "$NGINX_SNIPPETS" /var/www /var/www/_acme
  if [[ ! -f "$NGINX_SNIPPETS/cloudflare-realip.conf" ]]; then
    echo "# Cloudflare non attivo" | write_file "$NGINX_SNIPPETS/cloudflare-realip.conf" 644 root:root
  fi
  install -m 644 "$VPS_TEMPLATES/nginx-ssl-params.conf" "$NGINX_SNIPPETS/ssl-params.conf"
  install -m 644 "$VPS_TEMPLATES/nginx-security-headers.conf" "$NGINX_SNIPPETS/security-headers.conf"
  install -m 644 "$VPS_TEMPLATES/nginx-acme.conf" "$NGINX_SNIPPETS/acme.conf"
  install -m 644 "$VPS_TEMPLATES/nginx.conf" /etc/nginx/nginx.conf
  nginx -t >>"$VPS_LOG" 2>&1
  systemctl enable nginx >>"$VPS_LOG" 2>&1
  systemctl restart nginx

  if is_yes "$CF_ENABLED"; then
    rm -f /etc/fail2ban/jail.d/vps-nginx.local
  else
    log "Nginx: jail fail2ban per Nginx"
    install -m 644 "$VPS_TEMPLATES/jail-nginx.local" /etc/fail2ban/jail.d/vps-nginx.local
  fi
  systemctl restart fail2ban
}
