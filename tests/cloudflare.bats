setup() {
  load test_helper
  setup_common
  export STUB_LOG="$BATS_TEST_TMPDIR/curl.args" STUB_HDR="$BATS_TEST_TMPDIR/curl.hdr"
  make_stub curl '
printf "%s\n" "$*" >>"$STUB_LOG"
for a in "$@"; do case "$a" in @*) cat "${a#@}" >>"$STUB_HDR";; esac; done
url="${*: -1}"
case "$url" in
  *"name=panel.miosito.it&"*) echo "{\"success\":true,\"result\":[]}" ;;
  *"name=miosito.it&"*) echo "{\"success\":true,\"result\":[{\"id\":\"zone123\",\"name\":\"miosito.it\"}]}" ;;
  *"dns_records?type=A"*) echo "{\"success\":true,\"result\":[]}" ;;
  *"dns_records") echo "{\"success\":true,\"result\":{\"id\":\"rec1\"}}" ;;
  *) echo "{\"success\":false,\"result\":[],\"errors\":[{\"message\":\"boh\"}]}" ;;
esac'
  export CF_API_TOKEN="tok_SEGRETO_1234567890abcdefghijklmnop"
}

@test "il token non compare mai negli argomenti di curl" {
  cf_api GET /zones >/dev/null
  run grep -q "SEGRETO" "$STUB_LOG"
  [ "$status" -ne 0 ]
  grep -q "Authorization: Bearer tok_SEGRETO" "$STUB_HDR"
}

@test "cf_api senza token muore" {
  unset CF_API_TOKEN
  run cf_api GET /zones
  [ "$status" -eq 1 ]
}

@test "cf_find_zone risale fino alla zona" {
  run cf_find_zone panel.miosito.it
  [ "$status" -eq 0 ]
  [ "$output" = "zone123 miosito.it" ]
}

@test "cf_find_zone fallisce se nessuna zona è accessibile" {
  run cf_find_zone panel.altro.it
  [ "$status" -eq 1 ]
}

@test "cf_upsert_record crea il record se non esiste" {
  cf_upsert_record zone123 A panel.miosito.it 203.0.113.10
  grep -q -- "-X POST" "$STUB_LOG"
  grep -q '"proxied":true' "$STUB_LOG"
}

@test "cf_token_from_ini legge il token" {
  printf 'dns_cloudflare_api_token = abc_DEF-123\n' >"$BATS_TEST_TMPDIR/cf.ini"
  run cf_token_from_ini "$BATS_TEST_TMPDIR/cf.ini"
  [ "$output" = "abc_DEF-123" ]
}

@test "cf_write_ini scrive il token per certbot con permessi 600" {
  cf_write_ini "$CF_API_TOKEN"
  grep -qxF "dns_cloudflare_api_token = $CF_API_TOKEN" "$VPS_OPT/secrets/cloudflare.ini"
  [ "$(stat -c %a "$VPS_OPT/secrets/cloudflare.ini")" = 600 ]
  [ "$(stat -c %a "$VPS_OPT/secrets")" = 700 ]
  [ "$(cf_token_from_ini)" = "$CF_API_TOKEN" ]
}
