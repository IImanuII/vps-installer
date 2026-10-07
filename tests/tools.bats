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
  grep -qxF 'panel ALL=(root) NOPASSWD: /opt/vps/bin/vps-status, /opt/vps/bin/vps-cf-token, /opt/vps/bin/vps-cf-ips-update, /opt/vps/bin/vps-smtp, /opt/vps/bin/vps-pma-pass, /opt/vps/bin/vps-pma-update' "$f"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$f"
  fi
}

@test "vps-cf-token set salva il token con permessi 600" {
  make_stub curl 'echo "{\"result\":[{\"id\":\"zid\"}]}"'
  mkdir -p "$VPS_OPT/secrets"
  tok="$(printf 'a%.0s' {1..40})"
  run bash -c "printf '%s' '$tok' | bash '$T/vps-cf-token' set"
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
