# shellcheck shell=bash
# Firewall UFW e fail2ban per SSH. Le jail Nginx arrivano con lo step 40.

step_main() {
  apt_install ufw fail2ban python3-systemd nftables

  log "Firewall: UFW"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp comment ssh-installer >/dev/null
  ufw allow "$SSH_PORT/tcp" comment ssh >/dev/null

  mkdir -p "$NGINX_SNIPPETS"
  if is_yes "$CF_ENABLED" && is_yes "$CF_LOCK_ORIGIN"; then
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
  else
    ufw allow 80/tcp comment http >/dev/null
    ufw allow 443/tcp comment https >/dev/null
  fi
  if is_yes "$CF_ENABLED"; then
    log "Firewall: IP Cloudflare (real_ip$(is_yes "$CF_LOCK_ORIGIN" && echo ' + blocco origine'))"
    cf_apply_ips "$CF_LOCK_ORIGIN"
  else
    echo "# Cloudflare non attivo" | write_file "$NGINX_SNIPPETS/cloudflare-realip.conf" 644 root:root
  fi
  ufw --force enable >/dev/null

  log "Firewall: fail2ban per SSH sulla porta $SSH_PORT"
  render_template "$VPS_TEMPLATES/jail-sshd.local.tmpl" /etc/fail2ban/jail.d/vps-sshd.local 644 root:root \
    SSH_PORT SSH_IGNORE_IP
  systemctl enable fail2ban >>"$VPS_LOG" 2>&1
  systemctl restart fail2ban
}
