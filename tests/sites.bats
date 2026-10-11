bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
}

@test "site_slug: dominio corto e dominio lungo troncato con hash" {
  [ "$(site_slug blog.miosito.it)" = site_blog_miosito_it ]
  [ "$(site_slug un-sottodominio-molto-lungo.esempio.it)" = site_un_sottodominio_molto__0129 ]
  [ "$(site_slug un-sottodominio-molto-lungo.esempio.it | wc -c)" -eq 32 ]
}

@test "site_validate_new accetta un dominio nuovo" {
  run site_validate_new blog.miosito.it
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "site_validate_new rifiuta forme e nomi non ammessi" {
  for d in "Blog.miosito.it" "blog miosito.it" "blog;rm.it" "../etc" "a/b.it" "miosito" "" "_acme" "-x.miosito.it"; do
    run site_validate_new "$d"
    [ "$status" -eq 1 ]
    [[ "$output" == *"non valido"* ]]
  done
  run site_validate_new www.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"--www"* ]]
  run site_validate_new panel.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"pannello"* ]]
}

@test "site_validate_new rifiuta un sito esistente, una cartella estranea, uno slug già usato" {
  site_reg_new blog.miosito.it php no no
  run site_validate_new blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"esiste già"* ]]

  mkdir -p "$SITES_WWW/altro.miosito.it"
  run site_validate_new altro.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"cartella"* ]]

  # blog-miosito.it ha lo stesso slug di blog.miosito.it
  run site_validate_new blog-miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"site_blog_miosito_it"* ]]
}

@test "site_reg_new scrive un registro 640 in creazione, senza segreti" {
  site_reg_new blog.miosito.it php yes yes
  f="$(site_reg_path blog.miosito.it)"
  [ "$(stat -c %a "$f")" = 640 ]
  [ "$(stat -c %a "$SITES_DIR")" = 750 ]
  [ "$(jq -r .state "$f")" = creating ]
  [ "$(jq -r .slug "$f")" = site_blog_miosito_it ]
  [ "$(jq -r .www "$f")" = true ]
  [ "$(jq -r .db "$f")" = true ]
  [ "$(jq -r .job.step "$f")" = queued ]
  [ "$(jq -r '.dns_records | length' "$f")" = 0 ]
}

@test "site_job aggiorna passo ed errore; site_reg_update conserva il resto" {
  site_reg_new blog.miosito.it static no no
  site_job blog.miosito.it create cert "certificato rifiutato"
  [ "$(site_reg_get blog.miosito.it .job.step)" = cert ]
  [ "$(site_reg_get blog.miosito.it .job.error)" = "certificato rifiutato" ]
  jq -e '.job.ts > 0' "$(site_reg_path blog.miosito.it)"
  site_job blog.miosito.it create done
  [ "$(site_reg_get blog.miosito.it .job.error)" = null ]
  site_reg_update blog.miosito.it '.state = $s' --arg s active
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ "$(site_reg_get blog.miosito.it .type)" = static ]
}

@test "site_fail scrive il motivo in SITE_ERROR_FILE e restituisce 1" {
  SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_fail "qualcosa non va"
  [ "$status" -eq 1 ]
  [ "$(cat "$SITE_ERROR_FILE")" = "qualcosa non va" ]
}

@test "cf_list_zones elenca le zone visibili dal token" {
  export CF_ZONES="miosito.it altro.it" CF_API_TOKEN=x
  run cf_list_zones
  [ "$status" -eq 0 ]
  [ "$output" = $'miosito.it\naltro.it' ]
}

@test "site_dns_add crea A per dominio e www e annota gli id" {
  site_reg_new miosito.it static yes no
  export CF_API_TOKEN=x
  site_dns_add miosito.it
  [ "$(site_reg_get miosito.it .zone.name)" = miosito.it ]
  [ "$(site_reg_get miosito.it '.dns_records | length')" = 2 ]
  [ "$(site_reg_get miosito.it '.dns_records[1].name')" = www.miosito.it ]
  grep -q '"proxied":true' "$BATS_TEST_TMPDIR/cf.log"
  [ "$(grep -c '^POST ' "$BATS_TEST_TMPDIR/cf.log")" = 2 ]
}

@test "site_dns_add con IPv6 crea anche AAAA" {
  jq '.ipv6 = "2001:db8::1"' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  site_reg_new blog.miosito.it static no no
  export CF_API_TOKEN=x
  site_dns_add blog.miosito.it
  grep -q '"type":"AAAA"' "$BATS_TEST_TMPDIR/cf.log"
  [ "$(site_reg_get blog.miosito.it '.dns_records | length')" = 2 ]
}

@test "site_dns_add riusa un record già giusto e non lo annota" {
  echo '{"success":true,"result":[{"id":"vecchio","type":"A","name":"blog.miosito.it","content":"203.0.113.10","proxied":true}]}' \
    >"$BATS_TEST_TMPDIR/cf-records-blog.miosito.it.json"
  site_reg_new blog.miosito.it static no no
  export CF_API_TOKEN=x
  site_dns_add blog.miosito.it
  run grep -c '^POST ' "$BATS_TEST_TMPDIR/cf.log"
  [ "$output" = 0 ]
  [ "$(site_reg_get blog.miosito.it '.dns_records | length')" = 0 ]
}

@test "site_dns_add: un record che punta altrove ferma tutto prima di creare" {
  echo '{"success":true,"result":[{"id":"c1","type":"CNAME","name":"www.miosito.it","content":"altrove.net"}]}' \
    >"$BATS_TEST_TMPDIR/cf-records-www.miosito.it.json"
  site_reg_new miosito.it static yes no
  export CF_API_TOKEN=x SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_dns_add miosito.it
  [ "$status" -eq 1 ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"punta altrove"* ]]
  run grep -c '^POST ' "$BATS_TEST_TMPDIR/cf.log"
  [ "$output" = 0 ]
}

@test "site_dns_add: zona non visibile dal token spiega i permessi" {
  site_reg_new blog.sconosciuto.it static no no
  export CF_API_TOKEN=x SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_dns_add blog.sconosciuto.it
  [ "$status" -eq 1 ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"Zone: Read"*"DNS: Edit"* ]]
}

@test "site_dns_remove toglie solo i record annotati" {
  site_reg_new miosito.it static yes no
  export CF_API_TOKEN=x
  site_dns_add miosito.it
  site_dns_remove miosito.it
  grep -q '^DELETE .*/zones/z-miosito.it/dns_records/rec1' "$BATS_TEST_TMPDIR/cf.log"
  grep -q '^DELETE .*/zones/z-miosito.it/dns_records/rec2' "$BATS_TEST_TMPDIR/cf.log"
  [ "$(site_reg_get miosito.it '.dns_records | length')" = 0 ]
}

@test "site_cert_issue chiede un certificato per tutti i nomi via DNS Cloudflare" {
  site_reg_new miosito.it static yes no
  site_cert_issue miosito.it
  grep -q -- '--cert-name miosito.it' "$CALLS"
  grep -q -- '--dns-cloudflare ' "$CALLS"
  grep -q -- '-d miosito.it -d www.miosito.it' "$CALLS"
}

@test "site_cert_issue: certbot che fallisce dà un motivo" {
  site_reg_new blog.miosito.it static no no
  export STUB_RC_certbot=1 SITE_ERROR_FILE="$BATS_TEST_TMPDIR/err"
  run site_cert_issue blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$(cat "$SITE_ERROR_FILE")" == *"Let's Encrypt"* ]]
}
