# shellcheck shell=bash
# Certificati Let's Encrypt (usato dall'installer e, in futuro, da vps-site).

ssl_obtain_cert() {
  local d="$1" ip
  local args=(certonly -n --agree-tos --register-unsafely-without-email
    --keep-until-expiring --cert-name "$d" -d "$d")
  if is_yes "${CF_ENABLED:-no}"; then
    args+=(--dns-cloudflare --dns-cloudflare-credentials "$VPS_OPT/secrets/cloudflare.ini"
      --dns-cloudflare-propagation-seconds 30)
  else
    ip="$(server_ipv4)"
    if ! dns_points_here "$d" "$ip"; then
      die "Il dominio $d non punta a $ip. Crea il record DNS A ($d -> $ip), attendi la propagazione e riprendi con: sudo bash $VPS_ROOT/run.sh"
    fi
    args+=(--webroot -w /var/www/_acme)
  fi
  log "SSL: richiedo il certificato per $d"
  certbot "${args[@]}" >>"$VPS_LOG" 2>&1 \
    || die "certbot non è riuscito a ottenere il certificato per $d (dettagli in $VPS_LOG)"
}
