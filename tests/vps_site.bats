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

# Aspetta che il lucchetto sia davvero preso dal processo in background.
wait_locked() {
  local i
  for i in {1..50}; do
    flock -n "$1" true || return 0
    sleep 0.1
  done
  return 1
}

teardown() {
  [[ -z "${pid:-}" ]] || kill "$pid" 2>/dev/null || true
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
  [[ "$output" == *"comando interno"* ]]
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
  wait_locked "$SITES_LOCK"
  vs disable blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"riprova"* ]]
}

@test "lucchetto del registro occupato: create e delete chiedono di riprovare" {
  vs create blog.miosito.it --type static
  bash "$T" _run create blog.miosito.it
  flock "$SITES_LOCK.reg" sleep 30 >/dev/null 2>&1 &
  pid=$!
  wait_locked "$SITES_LOCK.reg"
  vs delete blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"riprova"* ]]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  vs create altro.miosito.it --type static
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"riprova"* ]]
  run ! site_reg_exists altro.miosito.it
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
  [ "$status" -eq 0 ]
  jq -e 'type == "object"' <<<"$output"
  [ "$(printf '%s
' "$output" | wc -l)" -eq 1 ]
  vs create blog.miosito.it --type static
  [ "$status" -eq 1 ]
  jq -e 'type == "object" and .ok == false' <<<"$output"
  [ "$(printf '%s
' "$output" | wc -l)" -eq 1 ]
}

# --- Revisione finale: rilancio in un'unità systemd ---

# systemd-run finto: annota gli argomenti e ciò che arriva su stdin, risponde
# come farebbe il vps-site interno ed esce con un codice riconoscibile.
stub_systemd_run_pipe() {
  # shellcheck disable=SC2016
  make_stub systemd-run 'echo "systemd-run $*" >>"$CALLS"; cat >"$BATS_TEST_TMPDIR/stdin"; echo "{\"ok\":true,\"interno\":true}"; exit 7'
}

@test "sotto sudo vps-site si rilancia con systemd-run, stdin e codice d'uscita compresi" {
  stub_systemd_run_pipe
  run --separate-stderr bash -c "printf 'Nuova-password-456789\n' | SUDO_USER=panel bash '$T' db-password blog.miosito.it"
  [ "$status" -eq 7 ]
  [ "$(jq -r .interno <<<"$output")" = true ]
  grep -qx 'systemd-run --wait --pipe --collect --quiet --service-type=exec --setenv=VPS_SITE_VIA_SYSTEMD=1 /opt/vps/bin/vps-site db-password blog.miosito.it' "$CALLS"
  [ "$(cat "$BATS_TEST_TMPDIR/stdin")" = Nuova-password-456789 ]
}

@test "senza sudo nessun rilancio" {
  stub_systemd_run_pipe
  vs list
  [ "$status" -eq 0 ]
  run ! grep -qs -- '--pipe' "$CALLS"
}

@test "_run e _prune rifiutati sotto sudo prima del rilancio, e dentro l'unità rilanciata" {
  stub_systemd_run_pipe
  run env SUDO_USER=panel bash "$T" _run create blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"comando interno"* ]]
  run ! grep -qs systemd-run "$CALLS"
  for c in _run _prune; do
    run env VPS_SITE_VIA_SYSTEMD=1 VPS_OPT="$VPS_OPT" VPS_LIB="$VPS_LIB" bash "$T" "$c" create blog.miosito.it
    [ "$status" -eq 1 ]
    [[ "$output" == *"comando interno"* ]]
  done
}

@test "dentro l'unità rilanciata l'ambiente non sceglie le librerie" {
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  echo "touch '$BATS_TEST_TMPDIR/caricata'" >"$BATS_TEST_TMPDIR/evil/x.sh"
  # L'esito non conta (fuori dalla VPS /opt/vps/lib non c'è): conta che evil/ non sia letta.
  env VPS_SITE_VIA_SYSTEMD=1 VPS_LIB="$BATS_TEST_TMPDIR/evil" VPS_OPT="$BATS_TEST_TMPDIR/evil" bash "$T" list >/dev/null 2>&1 || true
  [ ! -e "$BATS_TEST_TMPDIR/caricata" ]
}

@test "create --www rifiutato se www.<dominio> è il pannello" {
  jq '.panel.domain = "www.miosito.it"' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  vs create miosito.it --type static --www
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"pannello"* ]]
  run ! site_reg_exists miosito.it
  vs create miosito.it --type static
  [ "$status" -eq 0 ]
}

wp_opts=(--title "Il blog" --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f)

@test "create --type wordpress: due righe di stdin in file 600, argomenti in un JSON 600" {
  run --separate-stderr bash -c "printf 'Password-db-1234567890\nPassword-admin-wp-12345\n' | bash '$T' create miosito.it --type wordpress --www --title 'Il blog' --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f --cloudflare"
  [ "$status" -eq 0 ]
  [ "$(cat "$SITES_RUN/site_miosito_it.pass")" = Password-db-1234567890 ]
  [ "$(cat "$SITES_RUN/site_miosito_it.wppass")" = Password-admin-wp-12345 ]
  [ "$(stat -c %a "$SITES_RUN/site_miosito_it.wppass")" = 600 ]
  [ "$(jq -r .login_path "$SITES_RUN/site_miosito_it.wpargs")" = accesso-7k2f ]
  [ "$(jq -r .cloudflare "$SITES_RUN/site_miosito_it.wpargs")" = true ]
  [ "$(site_reg_get miosito.it .type)" = wordpress ]
  [ "$(site_reg_get miosito.it .db)" = true ]
}

@test "create --type wordpress: opzioni mancanti, non valide o --db" {
  vs create miosito.it --type wordpress "${wp_opts[@]:0:6}"
  [[ "$(jq -r .error <<<"$output")" == *"--login-path"* ]]
  vs create miosito.it --type wordpress --title "Il blog" --admin-user admin --admin-email io@miosito.it --login-path accesso-7k2f
  [[ "$(jq -r .error <<<"$output")" == *"utente"* ]]
  vs create miosito.it --type wordpress --title "Il blog" --admin-user gestore --admin-email io@miosito.it --login-path wp-admin
  [[ "$(jq -r .error <<<"$output")" == *"percorso"* ]]
  vs create miosito.it --type wordpress --db "${wp_opts[@]}"
  [ "$status" -eq 1 ]
  vs create blog.miosito.it --type php --title x
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  run bash -c "printf 'Password-db-1234567890\n' | bash '$T' create miosito.it --type wordpress --title 'Il blog' --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [ "$status" -eq 1 ]
  run site_reg_exists miosito.it
  [ "$status" -eq 1 ]
}

@test "wp-install: solo su PHP attivo con DB e segnaposto; avvia il lavoro wpinstall" {
  run bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --type php --db"
  bash "$T" _run create blog.miosito.it
  run --separate-stderr bash -c "printf 'Password-admin-wp-12345\n' | bash '$T' wp-install blog.miosito.it --title 'Il blog' --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = installing ]
  [ "$(site_reg_get blog.miosito.it .state)" = installing ]
  [ "$(site_reg_get blog.miosito.it .job.op)" = wpinstall ]
  grep -q '^systemd-run --unit vps-site-site_blog_miosito_it-wpinstall ' "$CALLS"
  [ "$(cat "$SITES_RUN/site_blog_miosito_it.wppass")" = Password-admin-wp-12345 ]
}

@test "wp-install: se il lavoro non parte, il sito torna attivo e i file di passaggio spariscono" {
  run bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --type php --db"
  bash "$T" _run create blog.miosito.it
  STUB_RC_systemd_run=1 run --separate-stderr bash -c "printf 'Password-admin-wp-12345\n' | bash '$T' wp-install blog.miosito.it --title 'Il blog' --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ ! -e "$SITES_RUN/site_blog_miosito_it.wppass" ]
  [ ! -e "$SITES_RUN/site_blog_miosito_it.wpargs" ]
}

@test "wp-install rifiutato: statico, senza DB, public/ con file propri" {
  vs create statico.miosito.it --type static
  bash "$T" _run create statico.miosito.it
  run bash -c "printf 'Password-admin-wp-12345\n' | bash '$T' wp-install statico.miosito.it --title T --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [ "$status" -eq 1 ]
  vs create nodb.miosito.it --type php
  bash "$T" _run create nodb.miosito.it
  run bash -c "printf 'Password-admin-wp-12345\n' | bash '$T' wp-install nodb.miosito.it --title T --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [[ "$output" == *"database"* ]]
  run bash -c "printf 'Password-db-1234567890\n' | bash '$T' create pieno.miosito.it --type php --db"
  bash "$T" _run create pieno.miosito.it
  echo x >"$SITES_WWW/pieno.miosito.it/public/mio.html"
  run bash -c "printf 'Password-admin-wp-12345\n' | bash '$T' wp-install pieno.miosito.it --title T --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [[ "$output" == *"non è vuota"* ]]
  [ "$(site_reg_get pieno.miosito.it .state)" = active ]
}

@test "list: placeholder vero sul sito appena creato, falso dopo un upload" {
  vs create blog.miosito.it --type php
  bash "$T" _run create blog.miosito.it
  vs list
  [ "$(jq -r '.sites[0].placeholder' <<<"$output")" = true ]
  echo x >"$SITES_WWW/blog.miosito.it/public/mio.html"
  vs list
  [ "$(jq -r '.sites[0].placeholder' <<<"$output")" = false ]
  vs show blog.miosito.it
  [ "$(jq -r '.site.placeholder' <<<"$output")" = false ]
}

@test "list: index.html collegato a una FIFO, risposta subito con placeholder false" {
  vs create blog.miosito.it --type php
  bash "$T" _run create blog.miosito.it
  pub="$SITES_WWW/blog.miosito.it/public"
  rm "$pub/index.html"
  mkfifo "$BATS_TEST_TMPDIR/fifo"
  ln -s "$BATS_TEST_TMPDIR/fifo" "$pub/index.html"
  run --separate-stderr timeout 10 bash "$T" list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sites[0].placeholder' <<<"$output")" = false ]
}

@test "list: siti statici, WordPress o non attivi hanno placeholder false senza leggere public/" {
  vs create blog.miosito.it --type static
  bash "$T" _run create blog.miosito.it
  vs create php.miosito.it --type php
  bash "$T" _run create php.miosito.it
  vs disable php.miosito.it
  : >"$CALLS"
  vs list
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.sites[].placeholder] | unique | join(",")' <<<"$output")" = false ]
  ! grep -q '^runuser' "$CALLS"
  site_reg_update php.miosito.it '.type = "wordpress" | .state = "active"'
  vs list
  [ "$(jq -r '[.sites[].placeholder] | unique | join(",")' <<<"$output")" = false ]
  ! grep -q '^runuser' "$CALLS"
}

@test "WordPress richiede Redis con le ACL" {
  jq '.components.redis_acl = false' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  run --separate-stderr bash -c "printf 'Password-db-1234567890\nPassword-admin-wp-12345\n' | bash '$T' create miosito.it --type wordpress --title 'Il blog' --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"--tools-only"* ]]
}
