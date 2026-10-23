setup() {
  load test_helper
  setup_common
  export VPS_LIB="$REPO_ROOT/lib" MSMTPRC_LINK="$BATS_TEST_TMPDIR/msmtprc" ALIASES_FILE="$BATS_TEST_TMPDIR/aliases"
  T="$REPO_ROOT/tools"
  jq -n '{admin_user:"manu", cloudflare:{enabled:true, origin_locked:false, zone:"miosito.it"}, mail:{configured:false}, components:{phpmyadmin:"5.2.3"}}' >"$VPS_OPT/manifest.json"
}

@test "vps-status restituisce JSON valido" {
  make_stub systemctl 'echo active'
  make_stub apt 'printf "Listing...\nnginx/stable 1.28 amd64 [upgradable from: 1.27]\n"'
  run bash "$T/vps-status"
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
  [ "$(jq -r .services.nginx <<<"$output")" = active ]
  [ "$(jq -r .updates.upgradable <<<"$output")" = 1 ]
  jq -e '.disk.total > 0' <<<"$output"
}

@test "vps-cf-token rifiuta token malformati senza chiamare Cloudflare" {
  make_stub curl 'echo chiamato >>"$BATS_TEST_TMPDIR/curl.called"'
  run bash -c "printf 'corto' | bash '$T/vps-cf-token' set"
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -f "$BATS_TEST_TMPDIR/curl.called" ]
}

@test "vps-cf-token senza azione valida" {
  run bash "$T/vps-cf-token" boh
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
}

@test "vps-smtp set scrive la configurazione e aggiorna il manifest" {
  run bash -c "printf '%s' '{\"host\":\"smtp.gmail.com\",\"port\":587,\"user\":\"manu@gmail.com\",\"pass\":\"app pass\",\"from\":\"manu@gmail.com\",\"alert_email\":\"avvisi@gmail.com\"}' | bash '$T/vps-smtp' set"
  [ "$status" -eq 0 ]
  grep -qxF 'host smtp.gmail.com' "$VPS_OPT/secrets/msmtprc"
  [ "$(jq -r .mail.configured "$VPS_OPT/manifest.json")" = true ]
  [ "$(jq -r .mail.alert_email "$VPS_OPT/manifest.json")" = avvisi@gmail.com ]
}

@test "vps-smtp set rifiuta input non valido" {
  run bash -c "printf '%s' '{\"host\":\"smtp gmail\",\"port\":587}' | bash '$T/vps-smtp' set"
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -f "$VPS_OPT/secrets/msmtprc" ]
}

@test "vps-pma-pass rifiuta password corte" {
  run bash -c "printf 'corta' | bash '$T/vps-pma-pass' set"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"12 caratteri"* ]]
}

@test "vps-pma-update non fa nulla se già aggiornato" {
  export PMA_DIR="$VPS_OPT/phpmyadmin"
  mkdir -p "$PMA_DIR/libraries/classes"
  printf "    public const VERSION = '5.2.3' . VERSION_SUFFIX;\n" >"$PMA_DIR/libraries/classes/Version.php"
  make_stub curl 'echo "{\"version\":\"5.2.3\"}"'
  run bash "$T/vps-pma-update"
  [ "$status" -eq 0 ]
  [ "$(jq -r .updated <<<"$output")" = false ]
}

@test "il sudoers elenca solo gli script wrapper" {
  f="$REPO_ROOT/templates/sudoers-vps-panel"
  run grep -c '/opt/vps/bin/vps-' "$f"
  [ "$output" -ge 1 ]
  run grep -q 'ALL$' "$f"
  [ "$status" -ne 0 ]
  grep -qxF 'Defaults:panel env_reset' "$f"
  grep -qxF 'panel ALL=(root) NOPASSWD: /opt/vps/bin/vps-status, /opt/vps/bin/vps-cf-token, /opt/vps/bin/vps-cf-purge, /opt/vps/bin/vps-cf-ips-update, /opt/vps/bin/vps-smtp, /opt/vps/bin/vps-pma-pass, /opt/vps/bin/vps-pma-update, /opt/vps/bin/vps-site, /opt/vps/bin/vps-monitor, /opt/vps/bin/vps-files, /opt/vps/bin/vps-backup' "$f"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$f"
  fi
}

@test "vps-cf-token set salva il token con permessi 600" {
  _cf_curl_zone miosito.it
  mkdir -p "$VPS_OPT/secrets"
  tok="$(printf 'a%.0s' {1..40})"
  run bash -c "printf '%s' '$tok' | bash '$T/vps-cf-token' set 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
  grep -qxF "dns_cloudflare_api_token = $tok" "$VPS_OPT/secrets/cloudflare.ini"
  [ "$(stat -c %a "$VPS_OPT/secrets/cloudflare.ini")" = 600 ]
}

@test "in caso di errore stdout contiene un solo oggetto JSON" {
  run bash -c "printf 'corto' | bash '$T/vps-cf-token' set 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -sc 'length' <<<"$output")" = 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
}

@test "vps-pma-pass rifiuta password oltre 72 byte" {
  long="$(printf 'a%.0s' {1..80})"
  run bash -c "printf '%s' '$long' | bash '$T/vps-pma-pass' set"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"72"* ]]
}

_cf_ini() {
  mkdir -p "$VPS_OPT/secrets"
  CF_TOK="$(printf 'b%.0s' {1..40})"
  printf 'dns_cloudflare_api_token = %s\n' "$CF_TOK" >"$VPS_OPT/secrets/cloudflare.ini"
}

# curl finto: annota gli argomenti, risponde secondo l'URL (l'ultimo argomento).
_cf_curl() {
  make_stub curl '
printf "%s\n" "$@" >>"$BATS_TEST_TMPDIR/curl.args"
for a; do last="$a"; done
case "$last" in
  *"/zones?name=miosito.it&status=active") echo "{\"success\":true,\"result\":[{\"id\":\"zid1\"}]}" ;;
  *"/zones?name="*) echo "{\"success\":true,\"result\":[]}" ;;
  *purge_cache) cat "$BATS_TEST_TMPDIR/purge.json" 2>/dev/null || echo "{\"success\":true}" ;;
  *) echo "{\"success\":false}" ;;
esac'
}

@test "vps-cf-purge --all svuota la zona con purge_everything" {
  _cf_ini; _cf_curl
  run bash -c "bash '$T/vps-cf-purge' miosito.it --all </dev/null 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(jq -r .purged <<<"$output")" = all ]
  grep -qF '/zones/zid1/purge_cache' "$BATS_TEST_TMPDIR/curl.args"
  grep -qF '{"purge_everything":true}' "$BATS_TEST_TMPDIR/curl.args"
  ! grep -qF "$CF_TOK" "$BATS_TEST_TMPDIR/curl.args"
  ! grep -qF "$CF_TOK" "$VPS_LOG"
}

@test "vps-cf-purge con indirizzi da stdin, righe vuote ignorate" {
  _cf_ini; _cf_curl
  run bash -c "printf 'https://miosito.it/a\n\n  HTTPS://Blog.miosito.it/b  \r\n' | bash '$T/vps-cf-purge' miosito.it 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(jq -r .purged <<<"$output")" = 2 ]
  grep -qF '{"files":["https://miosito.it/a","HTTPS://Blog.miosito.it/b"]}' "$BATS_TEST_TMPDIR/curl.args"
}

@test "vps-cf-purge rifiuta prima di chiamare purge_cache" {
  _cf_ini; _cf_curl
  run bash -c "printf 'https://altro.it/a\n' | bash '$T/vps-cf-purge' miosito.it"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "indirizzo non valido: https://altro.it/a" ]
  run bash -c "printf '' | bash '$T/vps-cf-purge' miosito.it"
  [ "$(jq -r .error <<<"$output")" = "nessun indirizzo" ]
  run bash -c "for i in \$(seq 31); do echo https://miosito.it/\$i; done | bash '$T/vps-cf-purge' miosito.it"
  [ "$(jq -r .error <<<"$output")" = "troppi indirizzi: il limite è 30" ]
  run bash "$T/vps-cf-purge" altro.it --all </dev/null
  [ "$(jq -r .error <<<"$output")" = "zona non trovata: altro.it" ]
  run bash "$T/vps-cf-purge" 'Miosito.it' --all </dev/null
  [ "$(jq -r .error <<<"$output")" = "zona non valida" ]
  run bash "$T/vps-cf-purge" miosito.it --boh </dev/null
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  ! grep -qF purge_cache "$BATS_TEST_TMPDIR/curl.args"
}

@test "vps-cf-purge: rifiuto di Cloudflare riportato, senza Cloudflare attivo errore" {
  _cf_ini; _cf_curl
  echo '{"success":false,"errors":[{"code":1134,"message":"Too many requests"}]}' >"$BATS_TEST_TMPDIR/purge.json"
  run bash -c "bash '$T/vps-cf-purge' miosito.it --all </dev/null 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "Cloudflare ha rifiutato la richiesta: Too many requests" ]
  rm -f "$VPS_OPT/secrets/cloudflare.ini"
  run bash -c "bash '$T/vps-cf-purge' miosito.it --all </dev/null 2>/dev/null"
  [ "$(jq -r .error <<<"$output")" = "Cloudflare non è attivo su questa VPS" ]
}

@test "vps-cf-purge: più di 40000 byte su stdin sono troppi indirizzi" {
  _cf_ini; _cf_curl
  run bash -c "{ echo https://miosito.it/a; head -c 40010 /dev/zero | tr '\0' x; } | bash '$T/vps-cf-purge' miosito.it 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "troppi indirizzi: il limite è 30" ]
  ! grep -qF purge_cache "$BATS_TEST_TMPDIR/curl.args"
}

@test "vps-cf-purge: rete assente e zona assente hanno errori diversi" {
  _cf_ini
  make_stub curl 'exit 7'
  run bash -c "bash '$T/vps-cf-purge' miosito.it --all </dev/null 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "Cloudflare non risponde" ]
  _cf_curl
  run bash -c "bash '$T/vps-cf-purge' altro.it --all </dev/null 2>/dev/null"
  [ "$(jq -r .error <<<"$output")" = "zona non trovata: altro.it" ]
}

# curl finto per vps-cf-token: zone visibili in $BATS_TEST_TMPDIR/zones (una per riga).
_cf_curl_zone() {
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/zones"
  make_stub curl '
printf "%s\n" "$@" >>"$BATS_TEST_TMPDIR/curl.args"
for a; do last="$a"; done
case "$last" in
  *"/zones?status=active&per_page=50&page=1")
    jq -Rn "{success: true, result: [inputs | {name: .}], result_info: {total_pages: 1}}" <"$BATS_TEST_TMPDIR/zones" ;;
  *"/zones?name="*)
    n="${last#*name=}"; n="${n%%&*}"
    if grep -qxF "$n" "$BATS_TEST_TMPDIR/zones"; then echo "{\"success\":true,\"result\":[{\"id\":\"z-$n\"}]}"; else echo "{\"success\":true,\"result\":[]}"; fi ;;
  *) echo "{\"success\":false}" ;;
esac'
}

_cf_sito() {
  mkdir -p "$VPS_OPT/sites"
  jq -n --arg d "$1" --arg z "$2" '{domain: $d, zone: (if $z == "" then null else {id: "x", name: $z} end)}' >"$VPS_OPT/sites/$1.json"
}

@test "vps-cf-token set rifiuta un token che non vede le zone dei siti" {
  _cf_ini; _cf_curl_zone miosito.it altro.it
  _cf_sito blog.miosito.it miosito.it
  _cf_sito shop.terzo.it terzo.it
  _cf_sito quarto.it quarto.it
  _cf_sito vecchio.it ""
  tok="$(printf 'c%.0s' {1..40})"
  run bash -c "printf '%s' '$tok' | bash '$T/vps-cf-token' set"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "il token non vede le zone: quarto.it, terzo.it" ]
  grep -qxF "dns_cloudflare_api_token = $CF_TOK" "$VPS_OPT/secrets/cloudflare.ini"
}

@test "vps-cf-token set accetta un token che vede tutte le zone; test le conta" {
  _cf_ini; _cf_curl_zone miosito.it terzo.it altro.it
  _cf_sito shop.terzo.it terzo.it
  tok="$(printf 'c%.0s' {1..40})"
  run bash -c "printf '%s\n' '$tok' | bash '$T/vps-cf-token' set"
  [ "$status" -eq 0 ]
  grep -qxF "dns_cloudflare_api_token = $tok" "$VPS_OPT/secrets/cloudflare.ini"
  run bash "$T/vps-cf-token" test
  [ "$status" -eq 0 ]
  [ "$(jq -r .zones <<<"$output")" = 3 ]
  ! grep -qF "$tok" "$BATS_TEST_TMPDIR/curl.args"
  ! grep -qF "$tok" "$VPS_LOG"
}

@test "vps-cf-token test segnala le zone dei siti non più visibili" {
  _cf_ini; _cf_curl_zone miosito.it
  _cf_sito shop.terzo.it terzo.it
  run bash "$T/vps-cf-token" test
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "il token non vede le zone: terzo.it" ]
}
