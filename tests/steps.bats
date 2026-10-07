setup() {
  load test_helper
  setup_common
}

@test "ogni step è bash valido e definisce step_main senza codice al livello superiore" {
  local f count=0
  for f in "$REPO_ROOT"/steps/[0-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    bash -n "$f"
    run bash -c "source '$f' >/dev/null; declare -F step_main >/dev/null"
    [ "$status" -eq 0 ] || { echo "$f: manca step_main"; return 1; }
    run bash -c "source '$f'"
    [ -z "$output" ] || { echo "$f: produce output al caricamento"; return 1; }
  done
  [ "$count" -gt 0 ]
}

@test "sshd-10-vps.conf disattiva password e limita gli utenti" {
  SSH_PORT=41822 ROOT_LOGIN=no SSH_ALLOW_USERS=manu
  render_template "$REPO_ROOT/templates/sshd-10-vps.conf.tmpl" "$BATS_TEST_TMPDIR/sshd" 644 "$(id -un):$(id -gn)" SSH_PORT ROOT_LOGIN SSH_ALLOW_USERS
  grep -qxF 'Port 41822' "$BATS_TEST_TMPDIR/sshd"
  grep -qxF 'PasswordAuthentication no' "$BATS_TEST_TMPDIR/sshd"
  grep -qxF 'PermitRootLogin no' "$BATS_TEST_TMPDIR/sshd"
  grep -qxF 'AllowUsers manu' "$BATS_TEST_TMPDIR/sshd"
}

@test "jail sshd sulla porta scelta con backend systemd" {
  SSH_PORT=41822 SSH_IGNORE_IP=""
  render_template "$REPO_ROOT/templates/jail-sshd.local.tmpl" "$BATS_TEST_TMPDIR/jail" 644 "$(id -un):$(id -gn)" SSH_PORT SSH_IGNORE_IP
  grep -qE '^port += 41822$' "$BATS_TEST_TMPDIR/jail"
  grep -qE '^backend += systemd$' "$BATS_TEST_TMPDIR/jail"
}

@test "nginx.conf: default server 444, reject handshake, real_ip incluso, utente www-data" {
  local f="$REPO_ROOT/templates/nginx.conf"
  grep -qxF 'user www-data;' "$f"
  grep -q 'return 444;' "$f"
  grep -q 'ssl_reject_handshake on;' "$f"
  grep -q 'include /etc/nginx/snippets/cloudflare-realip.conf;' "$f"
  grep -q 'limit_req_zone $binary_remote_addr zone=req_limit_per_ip' "$f"
  grep -q 'X-Content-Type-Options "nosniff"' "$REPO_ROOT/templates/nginx-security-headers.conf"
  run grep -qi 'X-Xss-Protection' "$REPO_ROOT/templates/nginx-security-headers.conf"
  [ "$status" -ne 0 ]
  run grep -q 'ssl_stapling' "$REPO_ROOT/templates/nginx-ssl-params.conf"
  [ "$status" -ne 0 ]
}

@test "vhost e pool del pannello" {
  PANEL_DOMAIN=panel.miosito.it PANEL_ROOT=/var/www/panel.miosito.it
  render_template "$REPO_ROOT/templates/nginx-panel.conf.tmpl" "$BATS_TEST_TMPDIR/vhost" 644 "$(id -un):$(id -gn)" PANEL_DOMAIN PANEL_ROOT PHP_VERSION
  grep -q 'server_name panel.miosito.it;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'ssl_certificate /etc/letsencrypt/live/panel.miosito.it/fullchain.pem;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'root /var/www/panel.miosito.it/public;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'include /etc/nginx/snippets/panel.d/\*.conf;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'limit_req zone=req_limit_per_ip' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'return 301 https://$host$request_uri;' "$BATS_TEST_TMPDIR/vhost"
  render_template "$REPO_ROOT/templates/php-pool-panel.conf.tmpl" "$BATS_TEST_TMPDIR/pool" 644 "$(id -un):$(id -gn)" PANEL_ROOT PHP_VERSION VPS_OPT
  grep -qxF 'listen = /run/php/php8.4-fpm-panel.sock' "$BATS_TEST_TMPDIR/pool"
  grep -q "open_basedir\] = /var/www/panel.miosito.it/:$VPS_OPT/phpmyadmin/:$VPS_OPT/manifest.json" "$BATS_TEST_TMPDIR/pool"
}

@test "configurazione phpMyAdmin e location nginx" {
  PMA_BLOWFISH=abcdefghijklmnopqrstuvwxyz012345 PMA_CONTROL_PASS=Ctrl123 PANEL_ROOT=/var/www/panel.miosito.it PANEL_DOMAIN=panel.miosito.it
  render_template "$REPO_ROOT/templates/pma-config.inc.php.tmpl" "$BATS_TEST_TMPDIR/cfg" 640 "$(id -un):$(id -gn)" PMA_BLOWFISH PMA_CONTROL_PASS PANEL_ROOT PANEL_DOMAIN
  grep -q "\['controlpass'\] = 'Ctrl123';" "$BATS_TEST_TMPDIR/cfg"
  grep -q "\['AllowRoot'\] = false;" "$BATS_TEST_TMPDIR/cfg"
  grep -q "TempDir'\] = '/var/www/panel.miosito.it/storage/pma-tmp';" "$BATS_TEST_TMPDIR/cfg"
  render_template "$REPO_ROOT/templates/nginx-pma.conf.tmpl" "$BATS_TEST_TMPDIR/pma" 644 "$(id -un):$(id -gn)" VPS_OPT PHP_VERSION
  grep -q 'auth_basic_user_file /etc/nginx/.htpasswd-pma;' "$BATS_TEST_TMPDIR/pma"
  grep -q 'fastcgi_param SCRIPT_FILENAME $request_filename;' "$BATS_TEST_TMPDIR/pma"
  grep -q "alias $VPS_OPT/phpmyadmin/;" "$BATS_TEST_TMPDIR/pma"
}

@test "jail sshd: ignoreip con e senza IP del client" {
  SSH_PORT=41822 SSH_IGNORE_IP=203.0.113.7
  render_template "$REPO_ROOT/templates/jail-sshd.local.tmpl" "$BATS_TEST_TMPDIR/jail" 644 "$(id -un):$(id -gn)" SSH_PORT SSH_IGNORE_IP
  grep -qxF 'ignoreip = 127.0.0.1/8 ::1 203.0.113.7' "$BATS_TEST_TMPDIR/jail"
  SSH_IGNORE_IP=""
  render_template "$REPO_ROOT/templates/jail-sshd.local.tmpl" "$BATS_TEST_TMPDIR/jail" 644 "$(id -un):$(id -gn)" SSH_PORT SSH_IGNORE_IP
  grep -qE '^ignoreip = 127\.0\.0\.1/8 ::1 ?$' "$BATS_TEST_TMPDIR/jail"
}
