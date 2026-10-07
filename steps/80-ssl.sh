# shellcheck shell=bash
# Certbot (Debian) e certificato del dominio del pannello.

step_enabled() {
  is_yes "$WANT_CERTBOT"
}

step_main() {
  log "SSL: installo certbot"
  apt_install certbot python3-certbot-dns-cloudflare
  install -D -m 755 "$VPS_TEMPLATES/certbot-reload-nginx.sh" /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  if is_yes "$CF_ENABLED"; then
    printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" \
      | write_file "$VPS_OPT/secrets/cloudflare.ini" 600 root:root
  fi
  if is_yes "$PANEL_ENABLED"; then
    ssl_obtain_cert "$PANEL_DOMAIN"
  fi
}
