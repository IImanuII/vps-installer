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
