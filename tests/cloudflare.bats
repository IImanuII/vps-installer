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
  *"dns_records?name="*) echo "${DNS_EXISTING:-{\"success\":true,\"result\":[]\}}" ;;
  *"dns_records/"*) echo "{\"success\":true,\"result\":{\"id\":\"a1\"}}" ;;
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

# Stub dei record esistenti: imposta DNS_EXISTING con la risposta della GET.
@test "cf_upsert_record lascia invariato un CNAME esistente e prosegue" {
  export DNS_EXISTING='{"success":true,"result":[{"id":"c1","type":"CNAME","name":"panel.miosito.it","content":"altro.miosito.it","proxied":true}]}'
  run cf_upsert_record zone123 A panel.miosito.it 203.0.113.10
  [ "$status" -eq 0 ]
  run grep -qE -- "-X (POST|PUT)" "$STUB_LOG"
  [ "$status" -ne 0 ]
  grep -q "CNAME" "$VPS_LOG"
}

@test "cf_upsert_record non modifica un record A già corretto" {
  export DNS_EXISTING='{"success":true,"result":[{"id":"a1","type":"A","name":"panel.miosito.it","content":"203.0.113.10","proxied":true}]}'
  run cf_upsert_record zone123 A panel.miosito.it 203.0.113.10
  [ "$status" -eq 0 ]
  run grep -qE -- "-X (POST|PUT)" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "cf_upsert_record aggiorna un record A con IP diverso" {
  export DNS_EXISTING='{"success":true,"result":[{"id":"a1","type":"A","name":"panel.miosito.it","content":"198.51.100.7","proxied":false}]}'
  run cf_upsert_record zone123 A panel.miosito.it 203.0.113.10
  [ "$status" -eq 0 ]
  grep -q -- "-X PUT" "$STUB_LOG"
  grep -q "dns_records/a1" "$STUB_LOG"
}

@test "cf_upsert_record fallisce se non riesce a leggere i record" {
  export DNS_EXISTING='{"success":false,"result":[],"errors":[{"message":"no"}]}'
  run cf_upsert_record zone123 A panel.miosito.it 203.0.113.10
  [ "$status" -eq 1 ]
  run grep -qE -- "-X (POST|PUT)" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "cf_dns_conflicts elenca CNAME e A/AAAA che puntano altrove" {
  local resp='{"success":true,"result":[
    {"id":"c1","type":"CNAME","name":"panel.miosito.it","content":"miosito.it"},
    {"id":"a1","type":"A","name":"panel.miosito.it","content":"203.0.113.10"},
    {"id":"a2","type":"A","name":"panel.miosito.it","content":"198.51.100.7"},
    {"id":"q1","type":"AAAA","name":"panel.miosito.it","content":"2001:db8::99"},
    {"id":"t1","type":"TXT","name":"panel.miosito.it","content":"x"}]}'
  run cf_dns_conflicts "$resp" 203.0.113.10 2001:db8::1
  [ "${#lines[@]}" -eq 3 ]
  [[ "$output" == *"CNAME panel.miosito.it → miosito.it"* ]]
  [[ "$output" == *"A panel.miosito.it → 198.51.100.7"* ]]
  [[ "$output" == *"AAAA panel.miosito.it → 2001:db8::99"* ]]
  run cf_dns_conflicts '{"success":true,"result":[{"type":"A","name":"p","content":"203.0.113.10"}]}' 203.0.113.10 ""
  [ -z "$output" ]
}

@test "modalità keep: CNAME lasciato, segnalato in CF_DNS_KEPT" {
  export DNS_EXISTING='{"success":true,"result":[{"id":"c1","type":"CNAME","name":"panel.miosito.it","content":"miosito.it","proxied":true}]}'
  CF_DNS_KEPT=""
  cf_upsert_record zone123 A panel.miosito.it 203.0.113.10 keep
  [[ "$CF_DNS_KEPT" == *"CNAME → miosito.it"* ]]
  run grep -qE -- "-X (POST|PUT|DELETE)" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "modalità keep: A con altro IP non viene toccato" {
  export DNS_EXISTING='{"success":true,"result":[{"id":"a1","type":"A","name":"panel.miosito.it","content":"198.51.100.7","proxied":true}]}'
  CF_DNS_KEPT=""
  cf_upsert_record zone123 A panel.miosito.it 203.0.113.10 keep
  [[ "$CF_DNS_KEPT" == *"A → 198.51.100.7"* ]]
  run grep -qE -- "-X (POST|PUT|DELETE)" "$STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "modalità replace: il CNAME viene eliminato e si crea il record A" {
  export DNS_EXISTING='{"success":true,"result":[{"id":"c1","type":"CNAME","name":"panel.miosito.it","content":"miosito.it","proxied":true}]}'
  cf_upsert_record zone123 A panel.miosito.it 203.0.113.10 replace
  grep -q -- "-X DELETE.*dns_records/c1" "$STUB_LOG"
  grep -q -- "-X POST" "$STUB_LOG"
  [ "$(grep -n -- '-X DELETE' "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n -- '-X POST' "$STUB_LOG" | cut -d: -f1)" ]
}

@test "cf_remove_records elimina i record di un tipo" {
  export DNS_EXISTING='{"success":true,"result":[{"id":"q1","type":"AAAA","name":"panel.miosito.it","content":"2001:db8::99"},{"id":"a1","type":"A","name":"panel.miosito.it","content":"203.0.113.10"}]}'
  cf_remove_records zone123 panel.miosito.it AAAA
  grep -q -- "-X DELETE.*dns_records/q1" "$STUB_LOG"
  run grep -q "dns_records/a1" "$STUB_LOG"
  [ "$status" -ne 0 ]
}
