setup() {
  load test_helper
  setup_common
  export CERTBOT_LOG="$BATS_TEST_TMPDIR/certbot.args"
  make_stub certbot 'printf "%s\n" "$*" >>"$CERTBOT_LOG"'
  server_ipv4() { echo 203.0.113.10; }
}

@test "con Cloudflare usa la challenge DNS" {
  CF_ENABLED=yes
  ssl_obtain_cert panel.miosito.it
  grep -q -- "--dns-cloudflare-credentials $VPS_OPT/secrets/cloudflare.ini" "$CERTBOT_LOG"
  grep -q -- "--register-unsafely-without-email" "$CERTBOT_LOG"
  run grep -q -- "--webroot" "$CERTBOT_LOG"
  [ "$status" -ne 0 ]
}

@test "senza Cloudflare usa il webroot se il DNS punta qui" {
  CF_ENABLED=no
  dns_points_here() { return 0; }
  ssl_obtain_cert panel.miosito.it
  grep -q -- "--webroot -w /var/www/_acme" "$CERTBOT_LOG"
}

@test "senza Cloudflare si ferma con istruzioni se il DNS non punta qui" {
  CF_ENABLED=no
  dns_points_here() { return 1; }
  run ssl_obtain_cert panel.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"non punta a 203.0.113.10"* ]]
  [[ "$output" == *"run.sh"* ]]
  [ ! -f "$CERTBOT_LOG" ]
}

@test "errore di certbot diventa un messaggio chiaro" {
  CF_ENABLED=yes
  make_stub certbot 'exit 1'
  run ssl_obtain_cert panel.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"certbot non è riuscito"* ]]
}
