bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
  T="$REPO_ROOT/tools/vps-site"
}

# Solo stdout: Plancia legge quello, e i log di vps-site vanno su stderr.
vs() {
  run --separate-stderr bash "$T" "$@"
}

@test "zones: le zone del token" {
  export CF_ZONES="miosito.it altro.it"
  vs zones
  [ "$status" -eq 0 ]
  [ "$(jq -c .zones <<<"$output")" = '["miosito.it","altro.it"]' ]
}

@test "list senza siti" {
  vs list
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"ok":true,"sites":[]}' ]
}

@test "create statico: registro in creazione e lavoro avviato con systemd-run" {
  vs create blog.miosito.it --type static
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = creating ]
  [ "$(site_reg_get blog.miosito.it .state)" = creating ]
  grep -q "^systemd-run --unit vps-site-site_blog_miosito_it-create --collect --quiet $VPS_SITE_SELF _run create blog.miosito.it" "$CALLS"
}

@test "create --db: password da stdin in un file 600, mai negli argomenti" {
  run bash -c "printf 'Password-di-prova-123\n' | bash '$T' create blog.miosito.it --type php --www --db"
  [ "$status" -eq 0 ]
  f="$SITES_RUN/site_blog_miosito_it.pass"
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(cat "$f")" = Password-di-prova-123 ]
  run grep -c Password-di-prova "$CALLS"
  [ "$output" = 0 ]
  [ "$(site_reg_get blog.miosito.it .www)" = true ]
}

@test "create: argomenti rifiutati" {
  vs create www.miosito.it --type static
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"--www"* ]]
  vs create blog.miosito.it --type perl
  [ "$status" -eq 1 ]
  vs create blog.miosito.it --type static --db
  [[ "$(jq -r .error <<<"$output")" == *"PHP"* ]]
  vs create blog.miosito.it --type static --www --www
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  vs create blog.miosito.it --type static --boh
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  vs create 'a b.miosito.it' --type static
  [ "$status" -eq 1 ]
  vs create blog.miosito.it
  [ "$status" -eq 1 ]
  run bash -c "printf 'corta\n' | bash '$T' create blog.miosito.it --type php --db"
  [ "$status" -eq 1 ]
  run ! site_reg_exists blog.miosito.it
}

@test "create con Cloudflare spento: errore chiaro" {
  jq '.cloudflare.enabled = false' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  vs create blog.miosito.it --type static
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *Cloudflare* ]]
}

@test "create: systemd-run che fallisce lascia il sito in errore" {
  export STUB_RC_systemd_run=1
  vs create blog.miosito.it --type static
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
}

@test "_run e _prune rifiutati sotto sudo" {
  run env SUDO_USER=panel VPS_OPT="$VPS_OPT" VPS_LIB="$VPS_LIB" bash "$T" _run create blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"comando interno"* ]]
  run env SUDO_USER=panel bash "$T" _prune
  [ "$status" -eq 1 ]
}

@test "_run create porta il sito ad attivo; show lo restituisce" {
  vs create blog.miosito.it --type php
  run bash "$T" _run create blog.miosito.it
  [ "$status" -eq 0 ]
  vs show blog.miosito.it
  [ "$(jq -r .site.state <<<"$output")" = active ]
}

@test "disable ed enable" {
  vs create blog.miosito.it --type php
  bash "$T" _run create blog.miosito.it
  vs disable blog.miosito.it
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = disabled ]
  grep -q 'return 503;' "$NGINX_CONF_D/blog.miosito.it.conf"
  vs disable blog.miosito.it
  [ "$status" -eq 1 ]
  vs enable blog.miosito.it
  [ "$(jq -r .state <<<"$output")" = active ]
  grep -q fastcgi_pass "$NGINX_CONF_D/blog.miosito.it.conf"
}

@test "disable con il lucchetto occupato: riprova" {
  vs create blog.miosito.it --type static
  bash "$T" _run create blog.miosito.it
  flock "$SITES_LOCK" sleep 5 >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  vs disable blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"riprova"* ]]
  kill "$pid" 2>/dev/null || true
}

@test "delete: stato deleting, stato precedente salvato, lavoro avviato" {
  vs create blog.miosito.it --type static
  bash "$T" _run create blog.miosito.it
  vs delete blog.miosito.it
  [ "$status" -eq 0 ]
  [ "$(site_reg_get blog.miosito.it .state)" = deleting ]
  [ "$(site_reg_get blog.miosito.it .prev_state)" = active ]
  grep -q '^systemd-run --unit vps-site-site_blog_miosito_it-delete ' "$CALLS"
  vs delete blog.miosito.it
  [ "$status" -eq 1 ]
}

@test "db-create e db-password" {
  vs create blog.miosito.it --type php
  bash "$T" _run create blog.miosito.it
  run bash -c "printf 'Password-di-prova-123\n' | bash '$T' db-create blog.miosito.it"
  [ "$status" -eq 0 ]
  [ "$(site_reg_get blog.miosito.it .db)" = true ]
  run bash -c "printf 'Password-di-prova-123\n' | bash '$T' db-create blog.miosito.it"
  [ "$status" -eq 1 ]
  run bash -c "printf 'Nuova-password-456789\n' | bash '$T' db-password blog.miosito.it"
  [ "$status" -eq 0 ]
  grep -qx 'DB_PASS=Nuova-password-456789' "$SITES_WWW/blog.miosito.it/db.env"
}

@test "comandi su un sito inesistente o con dominio non valido" {
  for c in show disable enable delete db-create db-password; do
    vs "$c" nessuno.miosito.it
    [ "$status" -eq 1 ]
    [[ "$(jq -r .error <<<"$output")" == *"non trovato"* ]]
    vs "$c" '../../etc'
    [ "$status" -eq 1 ]
  done
  vs boh
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
}

@test "l'output è sempre un solo oggetto JSON" {
  vs create blog.miosito.it --type static
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  vs create blog.miosito.it --type static
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}
