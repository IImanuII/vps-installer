bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
  export BK_BACKUPS="$BATS_TEST_TMPDIR/bk" BK_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$BK_LOCK_DIR"
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
  run ! grep -q '^runuser' "$CALLS"
  site_reg_update php.miosito.it '.type = "wordpress" | .state = "active"'
  vs list
  [ "$(jq -r '[.sites[].placeholder] | unique | join(",")' <<<"$output")" = false ]
  run ! grep -q '^runuser' "$CALLS"
}

@test "WordPress richiede Redis con le ACL" {
  jq '.components.redis_acl = false' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  run --separate-stderr bash -c "printf 'Password-db-1234567890\nPassword-admin-wp-12345\n' | bash '$T' create miosito.it --type wordpress --title 'Il blog' --admin-user gestore --admin-email io@miosito.it --login-path accesso-7k2f"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"--tools-only"* ]]
}

@test "lavori su un sito rifiutati con 'ripristino in corso' mentre il suo lock è preso" {
  export BK_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$BK_LOCK_DIR"
  vs create blog.miosito.it --type php
  bash "$T" _run create blog.miosito.it
  site_reg_update blog.miosito.it '.db = true'
  exec {lk}>>"$BK_LOCK_DIR/vps-site.site_blog_miosito_it.lock"
  flock -n "$lk"
  local c
  for c in db-password db-create wp-install delete disable enable; do
    run --separate-stderr bash -c "printf 'Nuova-password-456789\n' | bash '$T' $c blog.miosito.it --title T --admin-user ana --admin-email a@b.it --login-path accesso"
    [ "$status" -eq 1 ] || { echo "accettato: $c"; false; }
    [[ "$output" == *"ripristino in corso"* ]] || { echo "messaggio $c: $output"; false; }
  done
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  # un lavoro già in coda si ferma allo stesso modo, il sito non si tocca
  site_reg_update blog.miosito.it '.state = "deleting" | .prev_state = "active"'
  run bash "$T" _run delete blog.miosito.it
  [ "$status" -ne 0 ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  exec {lk}>&-
}

# --- create --from-backup ---------------------------------------------------

@test "create --from-backup: sito WordPress da un archivio locale, tipo, www e percorso di login dal manifest" {
  fb_archive blog.miosito.it wordpress yes yes accesso-7k2f
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = creating ]
  [ "$(site_reg_get blog.miosito.it .type)" = wordpress ]
  [ "$(site_reg_get blog.miosito.it .www)" = true ]
  [ "$(site_reg_get blog.miosito.it .db)" = true ]
  [ "$(site_reg_get blog.miosito.it .from_backup.source)" = local ]
  [ "$(site_reg_get blog.miosito.it .from_backup.name)" = "$FB_ARC" ]
  [ "$(site_reg_get blog.miosito.it .from_backup.login_path)" = accesso-7k2f ]
  # una sola password (il database), nessuna password admin né dati di WordPress da installare
  [ "$(cat "$SITES_RUN/site_blog_miosito_it.pass")" = Password-db-1234567890 ]
  [ "$(stat -c %a "$SITES_RUN/site_blog_miosito_it.pass")" = 600 ]
  [ ! -e "$SITES_RUN/site_blog_miosito_it.wpargs" ]
  [ ! -e "$SITES_RUN/site_blog_miosito_it.wppass" ]
  grep -q '^systemd-run --unit vps-site-site_blog_miosito_it-create ' "$CALLS"
  run grep -c 'Password-db' "$CALLS"
  [ "$output" = 0 ]
}

@test "create --from-backup: sito statico e sito PHP senza database, nessuna password" {
  fb_archive fisso.miosito.it static no no
  vs create fisso.miosito.it --from-backup "$FB_ARC"
  [ "$status" -eq 0 ]
  [ "$(site_reg_get fisso.miosito.it '"\(.type) \(.www) \(.db)"')" = "static false false" ]
  fb_archive dyn.miosito.it php no no
  vs create dyn.miosito.it --from-backup "$FB_ARC"
  [ "$status" -eq 0 ]
  [ "$(site_reg_get dyn.miosito.it '"\(.type) \(.db) \(.wordpress)"')" = "php false null" ]
}

@test "create --from-backup: dominio diverso da quello del manifest o del nome, rifiutato" {
  fb_archive blog.miosito.it php no no
  cp "$BK_BACKUPS/$FB_ARC" "$BK_BACKUPS/sites/altro.miosito.it-20261001-040000.tar.gz"
  vs create altro.miosito.it --from-backup sites/altro.miosito.it-20261001-040000.tar.gz
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"blog.miosito.it"*"altro.miosito.it"* ]]
  vs create altro.miosito.it --from-backup "$FB_ARC"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"blog.miosito.it"* ]]
  run site_reg_exists altro.miosito.it
  [ "$status" -eq 1 ]
}

@test "create --from-backup: copia vecchia, nomi non validi, opzioni in conflitto" {
  fb_archive blog.miosito.it php no no
  mkdir -p "$BATS_TEST_TMPDIR/vecchia/x"
  tar -czf "$BK_BACKUPS/sites/vecchio.miosito.it-20260901-120000.tar.gz" -C "$BATS_TEST_TMPDIR/vecchia" x
  vs create vecchio.miosito.it --from-backup sites/vecchio.miosito.it-20260901-120000.tar.gz
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"formato vecchio"* ]]
  local n
  for n in ../sites/x panel/blog.miosito.it-20261001-040000.tar.gz sites/blog.miosito.it-20261001-040000.sql.gz /etc/passwd "sites/a b" remote:_pannello/pannello-20261001-0400.sql.gz remote:x sites/inesistente.miosito.it-20261001-040000.tar.gz; do
    vs create blog.miosito.it --from-backup "$n"
    [ "$status" -eq 1 ] || { echo "accettato: $n"; false; }
  done
  vs create blog.miosito.it --from-backup "$FB_ARC" --type php
  [ "$status" -eq 1 ]
  vs create blog.miosito.it --from-backup "$FB_ARC" --www
  [ "$status" -eq 1 ]
  vs create blog.miosito.it --from-backup "$FB_ARC" --db
  [ "$status" -eq 1 ]
  vs create blog.miosito.it --from-backup "$FB_ARC" --title x
  [ "$status" -eq 1 ]
  vs create blog.miosito.it --from-backup
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  run site_reg_exists blog.miosito.it
  [ "$status" -eq 1 ]
}

@test "create --from-backup: manifest con valori strani rifiutato (tipo, login, coerenza, dominio)" {
  fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  local w="$BATS_TEST_TMPDIR/m" arc="$BK_BACKUPS/$FB_ARC" f
  mkdir -p "$w"
  tar -xzf "$arc" -C "$w"
  for f in '.type = "perl"' '.login_path = "wp-admin"' '.login_path = null' '.sha256.db = null' '.domain = "x.it"'; do
    mkdir -p "$w/n"
    cp "$w/files.tar.gz" "$w/db.sql.gz" "$w/n/"
    jq "$f" "$w/manifest.json" >"$w/n/manifest.json"
    tar -czf "$BK_BACKUPS/sites/blog.miosito.it-20261002-040000.tar.gz" -C "$w/n" manifest.json files.tar.gz db.sql.gz
    run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup sites/blog.miosito.it-20261002-040000.tar.gz"
    [ "$status" -eq 1 ] || { echo "accettato: $f"; false; }
    rm -rf "$w/n"
  done
  run site_reg_exists blog.miosito.it
  [ "$status" -eq 1 ]
}

@test "create --from-backup: password del database mancante o non valida, nessun registro" {
  fb_archive blog.miosito.it php no yes
  vs create blog.miosito.it --from-backup "$FB_ARC"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"password"* ]]
  run bash -c "printf 'corta\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  [ "$status" -eq 1 ]
  run site_reg_exists blog.miosito.it
  [ "$status" -eq 1 ]
}

@test "create --from-backup: WordPress richiede Redis con le ACL anche senza installarlo" {
  fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  jq '.components.redis_acl = false' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"--tools-only"* ]]
}

@test "_run create da archivio WordPress: nessun wp core install, wp-config e utente Redis nuovi, poi _restore all, sito attivo" {
  fb_backup_stub
  # www solo sul dominio principale della zona: qui il sottodominio non lo ha
  fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  [ "$status" -eq 0 ]
  run bash "$T" _run create blog.miosito.it
  [ "$status" -eq 0 ]
  # WordPress non si scarica né si installa: i file arrivano dall'archivio
  run grep -E 'core (download|install)|plugin install' "$CALLS"
  [ "$status" -eq 1 ]
  # il ripristino parte dall'unità del lavoro, con la copia giusta e la modalità giusta
  [ "$(cat "$BATS_TEST_TMPDIR/fb.calls")" = "_restore local blog.miosito.it $FB_ARC all" ]
  # ... quando il sito è ancora "creating" (il pannello lo vede come una creazione)
  [ "$(cat "$BATS_TEST_TMPDIR/fb.state")" = creating ]
  [ "$(site_reg_get blog.miosito.it '"\(.state) \(.job.op) \(.job.step) \(.job.error)"')" = "active create done null" ]
  [ "$(site_reg_get blog.miosito.it '"\(.type) \(.wordpress.login_path)"')" = "wordpress accesso-7k2f" ]
  # wp-config.php nuovo, con la password nuova (non quella dell'archivio) e le chiavi
  w="$SITES_WWW/blog.miosito.it/wp-config.php"
  grep -q "define( 'DB_PASSWORD', 'Password-db-1234567890' );" "$w"
  run grep -q 'wp-config vecchio' "$w"
  [ "$status" -eq 1 ]
  grep -q "^user site_blog_miosito_it on " "$REDIS_ACL_FILE"
  [ -f "$CRON_D/vps-site-site_blog_miosito_it" ]
  [ -f "$NGINX_CONF_D/blog.miosito.it.conf" ]
  grep -qx 'DB_PASS=Password-db-1234567890' "$SITES_WWW/blog.miosito.it/db.env"
  [ ! -e "$SITES_RUN/site_blog_miosito_it.pass" ]
}

@test "_run create da archivio senza database: _restore files (statico e PHP)" {
  fb_backup_stub
  fb_archive fisso.miosito.it static no no
  vs create fisso.miosito.it --from-backup "$FB_ARC"
  run bash "$T" _run create fisso.miosito.it
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fb.calls")" = "_restore local fisso.miosito.it $FB_ARC files" ]
  [ "$(site_reg_get fisso.miosito.it .state)" = active ]
}

@test "_run create da archivio: ripristino fallito, il sito resta attivo e vuoto con il motivo" {
  fb_backup_stub
  export FB_STUB_RC=1 FB_STUB_ERR="la copia è stata manomessa"
  fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  run bash "$T" _run create blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = active ]
  [ "$(site_reg_get blog.miosito.it .job.step)" = restore ]
  [[ "$(site_reg_get blog.miosito.it .job.error)" == *"la copia è stata manomessa"* ]]
  [ -d "$SITES_WWW/blog.miosito.it/public" ]
  # il sito è comunque configurato come WordPress, pronto per un ripristino dalla pagina Backup
  [ "$(site_reg_get blog.miosito.it .type)" = wordpress ]
  [ -f "$NGINX_CONF_D/blog.miosito.it.conf" ]
}

@test "_run create da archivio: un passo prima del ripristino fallisce, si disfa tutto come in una creazione" {
  fb_backup_stub
  fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  export STUB_RC_certbot=1
  run bash "$T" _run create blog.miosito.it
  [ "$status" -eq 1 ]
  [ "$(site_reg_get blog.miosito.it .state)" = error ]
  [ ! -e "$BATS_TEST_TMPDIR/fb.calls" ]
}

@test "vps-site: un comando su un sito tiene il lock condiviso fino alla fine; un lavoro (_run) per tutta la sua durata" {
  run bash -c "printf 'Password-di-prova-123\n' | bash '$T' create blog.miosito.it --type php --db"
  bash "$T" _run create blog.miosito.it
  local lk="$BK_LOCK_DIR/vps-site.site_blog_miosito_it.lock" i held=no
  # db-password legge la password da stdin: finché non arriva il comando è in corso
  { sleep 3; echo 'Nuova-password-456789'; } | bash "$T" db-password blog.miosito.it >/dev/null 2>&1 &
  pid=$!
  for i in {1..25}; do
    if ! flock -x -n "$lk" true 2>/dev/null; then held=si; break; fi
    sleep 0.1
  done
  [ "$held" = si ]
  wait "$pid"
  pid=""
  flock -x -n "$lk" true

  # il lavoro: durante il suo corpo il lock c'è (mariadb finto lo controlla), a lavoro finito no
  site_reg_update blog.miosito.it '.prev_state = .state | .state = "deleting"'
  make_stub mariadb 'if flock -x -n "$BK_LOCK_DIR/vps-site.site_blog_miosito_it.lock" true; then echo libero >>"$BATS_TEST_TMPDIR/job.lock"; else echo preso >>"$BATS_TEST_TMPDIR/job.lock"; fi; cat >/dev/null; exit 0'
  run bash "$T" _run delete blog.miosito.it
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/job.lock" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/job.lock")" = preso ]
}

# --- create --from-backup: fix round 1 ----------------------------------------

@test "create --from-backup: una copia parziale (solo database o solo file) non basta a ricreare il sito" {
  FB_PARTS=db fb_archive blog.miosito.it php no yes
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"copia parziale: non basta a ricreare il sito"* ]]
  FB_PARTS=files fb_archive dyn.miosito.it php no no
  vs create dyn.miosito.it --from-backup "$FB_ARC"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"copia parziale"* ]]
  run site_reg_exists blog.miosito.it
  [ "$status" -eq 1 ]
  run site_reg_exists dyn.miosito.it
  [ "$status" -eq 1 ]
}

@test "create --from-backup: il campo db del manifest deve essere booleano e d'accordo col checksum" {
  fb_archive blog.miosito.it php no yes
  local w="$BATS_TEST_TMPDIR/m" f
  mkdir -p "$w"
  tar -xzf "$BK_BACKUPS/$FB_ARC" -C "$w"
  for f in '.db = false' '.db = "true"' 'del(.db)' '.parts = "files"'; do
    mkdir -p "$w/n"
    cp "$w/files.tar.gz" "$w/db.sql.gz" "$w/n/"
    jq "$f" "$w/manifest.json" >"$w/n/manifest.json"
    tar -czf "$BK_BACKUPS/sites/blog.miosito.it-20261002-040000.tar.gz" -C "$w/n" manifest.json files.tar.gz db.sql.gz
    run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup sites/blog.miosito.it-20261002-040000.tar.gz"
    [ "$status" -eq 1 ] || { echo "accettato: $f"; false; }
    rm -rf "$w/n"
  done
}

@test "create --from-backup: con un giro o un ripristino in corso (lock globale di vps-backup) si rifiuta subito" {
  fb_archive blog.miosito.it php no no
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  vs create blog.miosito.it --from-backup "$FB_ARC"
  exec {gl}>&-
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"backup o ripristino in corso, riprova più tardi"* ]]
  run site_reg_exists blog.miosito.it
  [ "$status" -eq 1 ]
  vs create blog.miosito.it --from-backup "$FB_ARC"
  [ "$status" -eq 0 ]
}

@test "_run create da archivio: il lock globale dei lavori è libero durante il ripristino e ripreso dopo" {
  fb_backup_stub
  fb_archive fisso.miosito.it static no no
  vs create fisso.miosito.it --from-backup "$FB_ARC"
  run bash "$T" _run create fisso.miosito.it
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fb.joblock")" = libero ]
  [ "$(site_reg_get fisso.miosito.it .state)" = active ]
  # un lavoro (di un altro sito) può prendere il lock mentre si ripristina: lo prova lo stub
  grep -q 'BK_LOCK_WAIT' "$REPO_ROOT/lib/sites.sh"
}

@test "_run create da archivio: il ripristino aspetta un giro in corso (BK_LOCK_WAIT) invece di fallire subito" {
  fb_backup_stub
  # shellcheck disable=SC2016
  make_stub vps-backup-fb 'echo "wait=${BK_LOCK_WAIT:-} fd9=$(ls -l /proc/self/fd 2>/dev/null | grep -c vps-site.lock)" >>"$BATS_TEST_TMPDIR/fb.env"; echo "{\"ok\":true,\"finished\":true,\"restore_ok\":true}"'
  fb_archive fisso.miosito.it static no no
  vs create fisso.miosito.it --from-backup "$FB_ARC"
  run bash "$T" _run create fisso.miosito.it
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fb.env")" = "wait=600 fd9=0" ]
}

@test "_run create da archivio WordPress: il prefisso delle tabelle viene dal manifest" {
  fb_backup_stub
  FB_PREFIX=xy7_ fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  [ "$(bk_manifest "$BK_BACKUPS/$FB_ARC" | jq -r .table_prefix)" = xy7_ ]
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  [ "$status" -eq 0 ]
  [ "$(site_reg_get blog.miosito.it .from_backup.table_prefix)" = xy7_ ]
  run bash "$T" _run create blog.miosito.it
  [ "$status" -eq 0 ]
  grep -qx "\$table_prefix = 'xy7_';" "$SITES_WWW/blog.miosito.it/wp-config.php"
}

@test "_run create da archivio WordPress: prefisso predefinito wp_ se il manifest non ne ha uno valido" {
  fb_backup_stub
  fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  local w="$BATS_TEST_TMPDIR/m"
  mkdir -p "$w/n"
  tar -xzf "$BK_BACKUPS/$FB_ARC" -C "$w"
  cp "$w/files.tar.gz" "$w/db.sql.gz" "$w/n/"
  jq '.table_prefix = "wp_; DROP"' "$w/manifest.json" >"$w/n/manifest.json"
  tar -czf "$BK_BACKUPS/sites/blog.miosito.it-20261002-040000.tar.gz" -C "$w/n" manifest.json files.tar.gz db.sql.gz
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup sites/blog.miosito.it-20261002-040000.tar.gz"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"prefisso"* ]]
  # senza il campo: wp_
  jq 'del(.table_prefix)' "$w/manifest.json" >"$w/n/manifest.json"
  tar -czf "$BK_BACKUPS/sites/blog.miosito.it-20261002-040000.tar.gz" -C "$w/n" manifest.json files.tar.gz db.sql.gz
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup sites/blog.miosito.it-20261002-040000.tar.gz"
  [ "$status" -eq 0 ]
  run bash "$T" _run create blog.miosito.it
  grep -qx "\$table_prefix = 'wp_';" "$SITES_WWW/blog.miosito.it/wp-config.php"
}

@test "_run create da archivio WordPress: ripristino fallito, niente cron; un ripristino riuscito dopo lo installa" {
  fb_backup_stub
  export FB_STUB_RC=1
  fb_archive blog.miosito.it wordpress no yes accesso-7k2f
  run --separate-stderr bash -c "printf 'Password-db-1234567890\n' | bash '$T' create blog.miosito.it --from-backup '$FB_ARC'"
  run bash "$T" _run create blog.miosito.it
  [ "$status" -eq 1 ]
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it" ]
  [ -f "$NGINX_CONF_D/blog.miosito.it.conf" ]
}

@test "site_undo_create: il passo wpcfg toglie l'utente Redis e il cron come wp" {
  nuovo() { site_reg_new "$1" "$2" "$3" "$4"; }
  nuovo blog.miosito.it wordpress no yes
  printf 'user default off\nuser site_blog_miosito_it on #abc ~site_blog_miosito_it:* +@all\n' >"$REDIS_ACL_FILE"
  site_wp_cron_add blog.miosito.it
  [ -f "$CRON_D/vps-site-site_blog_miosito_it" ]
  site_undo_create blog.miosito.it wpcfg
  run ! grep -q '^user site_blog_miosito_it ' "$REDIS_ACL_FILE"
  [ ! -e "$CRON_D/vps-site-site_blog_miosito_it" ]
}
