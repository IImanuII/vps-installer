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
  SSH_PORT=41822
  render_template "$REPO_ROOT/templates/jail-sshd.local.tmpl" "$BATS_TEST_TMPDIR/jail" 644 "$(id -un):$(id -gn)" SSH_PORT
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
