bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  setup_common
  export SSHD_CONFIG_D="$BATS_TEST_TMPDIR/sshd_config.d"
  export SSH_CF_CA="$BATS_TEST_TMPDIR/ssh/vps-cf-ca.pub"
  export SSH_CF_PRINCIPALS="$BATS_TEST_TMPDIR/ssh/vps-cf-principals"
  export SSHTUNNEL_STATE="$VPS_OPT/ssh-tunnel.json"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$SSHD_CONFIG_D" "$BATS_TEST_TMPDIR/ssh"
  : >"$CALLS"
  # shellcheck disable=SC2016
  make_stub sshd 'echo "sshd $*" >>"$CALLS"; [ "${SSHD_FAIL:-0}" = 1 ] && exit 1; exit 0'
  # shellcheck disable=SC2016
  make_stub systemctl 'echo "systemctl $*" >>"$CALLS"; exit 0'
}

@test "st_valid_label accetta e rifiuta" {
  st_valid_label ssh-k3f9x2
  st_valid_label a
  run st_valid_label -a; [ "$status" -ne 0 ]
  run st_valid_label a-; [ "$status" -ne 0 ]
  run st_valid_label A1; [ "$status" -ne 0 ]
  run st_valid_label a.b; [ "$status" -ne 0 ]
  run st_valid_label "$(printf 'a%.0s' {1..64})"; [ "$status" -ne 0 ]
}

@test "st_random_label ha la forma attesa" {
  run st_random_label
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ssh-[a-z0-9]{6}$ ]]
  st_valid_label "$output"
}

@test "st_parse_emails normalizza e toglie i duplicati" {
  run st_parse_emails "Manu@X.it, manu@x.it,altro@y.it"
  [ "$status" -eq 0 ]
  [ "$output" = $'manu@x.it\naltro@y.it' ]
}

@test "st_parse_emails rifiuta 0, 6, non valide" {
  run st_parse_emails "a@x.it,b@x.it,c@x.it,d@x.it,e@x.it,f@x.it"; [ "$status" -eq 1 ]
  run st_parse_emails "x@"; [ "$status" -eq 1 ]
  run st_parse_emails ""; [ "$status" -eq 1 ]
}

@test "st_principals: prefissi unici" {
  run st_principals manu@x.it manu@y.it altro@y.it
  [ "$output" = $'manu\naltro' ]
}

@test "st_sshd_apply scrive i tre file e ricarica" {
  run st_sshd_apply manu "ssh-ed25519 AAAA ca" manu
  [ "$status" -eq 0 ]
  [ -f "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  grep -q TrustedUserCAKeys "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  grep -q "ssh-ed25519 AAAA ca" "$SSH_CF_CA"
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = manu ]
  grep -q "sshd -t" "$CALLS"
  grep -q "systemctl reload ssh" "$CALLS"
}

@test "st_sshd_apply con sshd -t che fallisce ripristina" {
  echo VECCHIO >"$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  SSHD_FAIL=1 run st_sshd_apply manu "ssh-ed25519 AAAA ca" manu
  [ "$status" -eq 1 ]
  [ "$(cat "$SSHD_CONFIG_D/20-vps-cfaccess.conf")" = VECCHIO ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSH_CF_PRINCIPALS/manu" ]
  ! grep -q "reload" "$CALLS"
}

@test "st_sshd_remove toglie i file e ricarica" {
  st_sshd_apply manu "ssh-ed25519 AAAA ca" manu
  : >"$CALLS"
  run st_sshd_remove manu
  [ "$status" -eq 0 ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSH_CF_PRINCIPALS/manu" ]
  grep -q "systemctl reload ssh" "$CALLS"
}

@test "st_state_write crea il file 600 e st_state_get legge" {
  st_state_write '{"host":"ssh-abc123.example.it"}'
  [ "$(stat -c %a "$SSHTUNNEL_STATE")" = 600 ]
  [ "$(st_state_get host)" = ssh-abc123.example.it ]
  [ -z "$(st_state_get nope)" ]
}

@test "st_random_label sopravvive a set -Eeuo pipefail" {
  run bash -c 'set -Eeuo pipefail; for f in "$REPO_ROOT"/lib/*.sh; do source "$f"; done; st_random_label'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ssh-[a-z0-9]{6}$ ]]
}

@test "st_parse_emails non espande i glob" {
  touch "$BATS_TEST_TMPDIR/a@x.it"
  cd "$BATS_TEST_TMPDIR"
  run st_parse_emails "*"
  [ "$status" -eq 1 ]
}

@test "st_sshd_apply senza principal o con utente non valido ritorna 1 senza toccare nulla" {
  run st_sshd_apply manu "ssh-ed25519 AAAA ca"; [ "$status" -eq 1 ]
  run st_sshd_apply manu "ssh-ed25519 AAAA ca" ""; [ "$status" -eq 1 ]
  run st_sshd_apply "../x" "ssh-ed25519 AAAA ca" manu; [ "$status" -eq 1 ]
  run st_sshd_remove "../x"; [ "$status" -eq 1 ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSH_CF_PRINCIPALS" ]
  [ ! -s "$CALLS" ]
}

@test "sshd -t che fallisce ripristina CA e principal preesistenti" {
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo CA-VECCHIA >"$SSH_CF_CA"
  echo vecchio >"$SSH_CF_PRINCIPALS/manu"
  SSHD_FAIL=1 run st_sshd_apply manu "ssh-ed25519 AAAA ca" manu
  [ "$status" -eq 1 ]
  [ "$(cat "$SSH_CF_CA")" = CA-VECCHIA ]
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = vecchio ]
}

@test "una scrittura fallita a metà ripristina e non lascia lo snapshot" {
  mkdir -p "$SSH_CF_PRINCIPALS" "$BATS_TEST_TMPDIR/tmp"
  echo CA-VECCHIA >"$SSH_CF_CA"
  echo vecchio >"$SSH_CF_PRINCIPALS/manu"
  chmod 555 "$SSHD_CONFIG_D"
  TMPDIR="$BATS_TEST_TMPDIR/tmp" run st_sshd_apply manu "ssh-ed25519 AAAA ca" manu
  chmod 755 "$SSHD_CONFIG_D"
  [ "$status" -eq 1 ]
  [ "$(cat "$SSH_CF_CA")" = CA-VECCHIA ]
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = vecchio ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
  ! grep -q reload "$CALLS"
}

# ---------------------------------------------------------------------------
# Cloudflare: tunnel, Access, CA, DNS (Task 4)

# cf_env — manifest, token, percorsi finti e uno stub curl che risponde per
# metodo e percorso. Ogni chiamata finisce in $CFLOG come "METODO PERCORSO";
# gli argomenti interi in $CALLS (per verificare che nessun token ci arrivi).
#   CF_FAIL="POST:*/ca"         → errore 400 sulle chiamate che corrispondono
#   CF_404="DELETE:*/apps/app1" → 404
#   CF_DENY="GET:…"             → 403 di autorizzazione (permesso mancante)
#   CF_OTP=1                    → One-time PIN già presente
#   CF_DNS_EXISTS=1             → la zona ha già un record con quel nome
#   CF_NOID="POST:…"            → successo ma senza id nel risultato
#   CF_DNS_ORPHAN=1             → dopo un POST sui DNS, l'elenco mostra il CNAME del tunnel
cf_env() {
  export CFLOG="$BATS_TEST_TMPDIR/cflog"
  export SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
  export SSHTUNNEL_ENV="$VPS_OPT/secrets/cf-tunnel.env"
  export APT_SOURCES_D="$BATS_TEST_TMPDIR/apt"
  export CLOUDFLARED_KEYRING="$BATS_TEST_TMPDIR/keyrings/cloudflare-main.gpg"
  export SITES_DIR="$VPS_OPT/sites"
  mkdir -p "$SYSTEMD_DIR" "$VPS_OPT/secrets" "$SITES_DIR"
  : >"$CFLOG"
  jq -n '{admin_user:"manu", ssh_port:6666, cloudflare:{enabled:true, zone:"example.it"}}' >"$VPS_OPT/manifest.json"
  printf 'dns_cloudflare_api_token = SYSTOKEN-abc123\n' >"$VPS_OPT/secrets/cloudflare.ini"
  # shellcheck disable=SC2016
  make_stub curl '
echo "curl $*" >>"$CALLS"
method=GET data="" wcode=0
while (($#)); do
  case "$1" in
    -X) method="$2"; shift ;;
    --data) data="$2"; shift ;;
    -w) wcode=1; shift ;;
    *) url="$1" ;;
  esac
  shift
done
path="${url#https://api.cloudflare.com/client/v4}"
p="${path%%\?*}"
echo "$method $p" >>"$CFLOG"
key="$method:$p"
code=200
body="{\"success\":true,\"result\":{}}"
for pat in ${CF_FAIL:-}; do
  if [[ "$key" == $pat ]]; then code=400; body="{\"success\":false,\"errors\":[{\"code\":9999,\"message\":\"rifiutato dal test\"}]}"; fi
done
for pat in ${CF_DENY:-}; do
  if [[ "$key" == $pat ]]; then code=403; body="{\"success\":false,\"errors\":[{\"code\":10000,\"message\":\"Authentication error\"}]}"; fi
done
for pat in ${CF_404:-}; do
  if [[ "$key" == $pat ]]; then code=404; body="{\"success\":false,\"errors\":[{\"code\":1003,\"message\":\"not found\"}]}"; fi
done
if [[ $code == 200 ]]; then
  case "$key" in
    GET:/zones) body="{\"success\":true,\"result\":[{\"id\":\"zone123\"}]}" ;;
    GET:/zones/zone123) body="{\"success\":true,\"result\":{\"id\":\"zone123\",\"account\":{\"id\":\"acc1\"}}}" ;;
    GET:/zones/zone123/dns_records)
      if [[ -n "${CF_DNS_ORPHAN:-}" ]] && grep -q "^POST /zones/zone123/dns_records" "$CFLOG"; then body="{\"success\":true,\"result\":[{\"id\":\"orphan9\",\"type\":\"CNAME\",\"content\":\"tun1.cfargotunnel.com\"},{\"id\":\"altrui\",\"type\":\"CNAME\",\"content\":\"altro.cfargotunnel.com\"}]}"
      elif [[ -n "${CF_DNS_EXISTS:-}" ]]; then body="{\"success\":true,\"result\":[{\"id\":\"x\",\"type\":\"A\"}]}"
      else body="{\"success\":true,\"result\":[]}"; fi ;;
    POST:/zones/zone123/dns_records)
      if [[ "$data" == *ssh-nuovo1* ]]; then body="{\"success\":true,\"result\":{\"id\":\"dns2\"}}"
      else body="{\"success\":true,\"result\":{\"id\":\"dns1\"}}"; fi ;;
    GET:/accounts/acc1/access/identity_providers)
      if [[ -n "${CF_OTP:-}" ]]; then body="{\"success\":true,\"result\":[{\"id\":\"otp9\",\"type\":\"onetimepin\"}]}"
      else body="{\"success\":true,\"result\":[{\"id\":\"gh1\",\"type\":\"github\"}]}"; fi ;;
    POST:/accounts/acc1/access/identity_providers) body="{\"success\":true,\"result\":{\"id\":\"otp1\",\"type\":\"onetimepin\"}}" ;;
    GET:/accounts/acc1/cfd_tunnel | GET:/accounts/acc1/access/apps) body="{\"success\":true,\"result\":[]}" ;;
    POST:/accounts/acc1/cfd_tunnel) body="{\"success\":true,\"result\":{\"id\":\"tun1\",\"token\":\"TUNNELTOKEN-SECRET-xyz\"}}" ;;
    GET:/accounts/acc1/cfd_tunnel/tun1) body="{\"success\":true,\"result\":{\"id\":\"tun1\",\"status\":\"healthy\"}}" ;;
    POST:/accounts/acc1/access/policies) body="{\"success\":true,\"result\":{\"id\":\"pol1\"}}" ;;
    POST:/accounts/acc1/access/apps) body="{\"success\":true,\"result\":{\"id\":\"app1\"}}" ;;
    POST:/accounts/acc1/access/apps/app1/ca) body="{\"success\":true,\"result\":{\"id\":\"ca1\",\"public_key\":\"ecdsa-sha2-nistp256 AAAACAKEY open-ssh-ca@cloudflareaccess.org\"}}" ;;
  esac
fi
for pat in ${CF_NOID:-}; do
  if [[ "$key" == $pat ]]; then body="{\"success\":true,\"result\":{}}"; fi
done
printf "%s" "$body"
if ((wcode)); then printf "\n%s" "$code"; fi
exit 0'
  # shellcheck disable=SC2016
  make_stub cloudflared 'echo "cloudflared $*" >>"$CALLS"; echo "cloudflared version 2025.10.0 (built 2025-10-01)"'
  # shellcheck disable=SC2016
  make_stub apt-get 'echo "apt-get $*" >>"$CALLS"; exit 0'
}

# st_enable riuscito, con stato scritto: base dei test di modifica.
cf_enabled() {
  cf_env
  CF_OTP=1 st_enable ssh-k3f9x2 manu@x.it
  : >"$CFLOG"
  : >"$CALLS"
}

# in_order FILE RIGA... — le righe compaiono nel file in quest'ordine.
in_order() {
  local f="$1" prev=0 n l
  shift
  for l in "$@"; do
    n="$(grep -nxF -- "$l" "$f" | head -1 | cut -d: -f1)"
    [[ -n "$n" ]] || { echo "manca: $l"; return 1; }
    ((n > prev)) || { echo "fuori ordine: $l"; return 1; }
    prev="$n"
  done
}

@test "st_enable: ordine delle chiamate, stato e token del tunnel solo nel file env" {
  cf_env
  run st_enable ssh-k3f9x2 manu@x.it
  [ "$status" -eq 0 ]
  in_order "$CFLOG" \
    "GET /accounts/acc1/access/identity_providers" \
    "POST /accounts/acc1/access/identity_providers" \
    "POST /accounts/acc1/cfd_tunnel" \
    "PUT /accounts/acc1/cfd_tunnel/tun1/configurations" \
    "POST /accounts/acc1/access/apps" \
    "POST /accounts/acc1/access/apps/app1/ca" \
    "POST /zones/zone123/dns_records"
  [ "$(jq -r .tunnel_id "$SSHTUNNEL_STATE")" = tun1 ]
  [ "$(jq -r .app_id "$SSHTUNNEL_STATE")" = app1 ]
  [ "$(jq -r .policy_id "$SSHTUNNEL_STATE")" = pol1 ]
  [ "$(jq -r .dns_id "$SSHTUNNEL_STATE")" = dns1 ]
  [ "$(jq -r .host "$SSHTUNNEL_STATE")" = ssh-k3f9x2.example.it ]
  [ "$(jq -r .label "$SSHTUNNEL_STATE")" = ssh-k3f9x2 ]
  [ "$(jq -r .user "$SSHTUNNEL_STATE")" = manu ]
  [ "$(jq -r .account_id "$SSHTUNNEL_STATE")" = acc1 ]
  [ "$(jq -r .zone_id "$SSHTUNNEL_STATE")" = zone123 ]
  [ -n "$(jq -r .enabled_at "$SSHTUNNEL_STATE")" ]
  [ "$(jq -c .emails "$SSHTUNNEL_STATE")" = '["manu@x.it"]' ]
  [ "$(stat -c %a "$SSHTUNNEL_ENV")" = 600 ]
  grep -qx 'TUNNEL_TOKEN=TUNNELTOKEN-SECRET-xyz' "$SSHTUNNEL_ENV"
  [ -f "$SYSTEMD_DIR/vps-cloudflared.service" ]
  grep -q "systemctl enable --now vps-cloudflared" "$CALLS"
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = manu ]
  grep -q AAAACAKEY "$SSH_CF_CA"
  # Ingresso verso la porta SSH del manifest, CNAME verso il tunnel.
  grep -q 'ssh://localhost:6666' "$CALLS"
  grep -q 'tun1.cfargotunnel.com' "$CALLS"
  # Nessun token in stato, log, argomenti di processo o output.
  for f in "$SSHTUNNEL_STATE" "$VPS_LOG" "$CALLS"; do
    ! grep -q TUNNELTOKEN "$f"
    ! grep -q SYSTOKEN "$f"
  done
  [[ "$output" != *TUNNELTOKEN* && "$output" != *SYSTOKEN* ]]
}

@test "st_enable: app Access type ssh, sessione 1h, solo One-time PIN, policy con le email" {
  cf_env
  CF_OTP=1 st_enable ssh-k3f9x2 manu@x.it altro@y.it
  app="$(grep -- '--data' "$CALLS" | grep '"type":"ssh"' | head -1)"
  [[ "$app" == *'"domain":"ssh-k3f9x2.example.it"'* ]]
  [[ "$app" == *'"session_duration":"1h"'* ]]
  [[ "$app" == *'"allowed_idps":["otp9"]'* ]]
  [[ "$app" == *'"auto_redirect_to_identity":true'* ]]
  [[ "$app" == *'"policies":[{"id":"pol1","precedence":1}]'* ]]
  pol="$(grep -- '--data' "$CALLS" | grep '"decision":"allow"' | head -1)"
  [[ "$pol" == *'{"email":{"email":"manu@x.it"}}'* ]]
  [[ "$pol" == *'{"email":{"email":"altro@y.it"}}'* ]]
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = $'manu\naltro' ]
}

@test "st_enable: One-time PIN già presente → nessuna creazione" {
  cf_env
  CF_OTP=1 run st_enable ssh-k3f9x2 manu@x.it
  [ "$status" -eq 0 ]
  ! grep -q "POST /accounts/acc1/access/identity_providers" "$CFLOG"
}

@test "st_enable: CA rifiutata → annulla tutto, niente DNS né sshd né stato" {
  cf_env
  rc=0
  CF_FAIL="POST:*/ca" st_enable ssh-k3f9x2 manu@x.it || rc=$?
  [ "$rc" -eq 1 ]
  [ -n "$ST_ERR" ]
  [[ "$ST_ERR" != *TOKEN* ]]
  ! grep -q "POST /zones/zone123/dns_records" "$CFLOG"
  grep -qx "DELETE /accounts/acc1/access/apps/app1" "$CFLOG"
  grep -qx "DELETE /accounts/acc1/access/policies/pol1" "$CFLOG"
  grep -qx "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
  grep -q "systemctl disable --now vps-cloudflared" "$CALLS"
  [ ! -e "$SYSTEMD_DIR/vps-cloudflared.service" ]
  [ ! -e "$SSHTUNNEL_ENV" ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_enable: DNS rifiutato → annulla app, tunnel e sshd, niente stato" {
  cf_env
  CF_FAIL="POST:/zones/zone123/dns_records" run st_enable ssh-k3f9x2 manu@x.it
  [ "$status" -eq 1 ]
  grep -q "DELETE /accounts/acc1/access/apps/app1" "$CFLOG"
  grep -q "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_PRINCIPALS/manu" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
  # Il tunnel si cancella solo dopo aver fermato cloudflared e pulito le connessioni.
  in_order "$CFLOG" "DELETE /accounts/acc1/cfd_tunnel/tun1/connections" "DELETE /accounts/acc1/cfd_tunnel/tun1"
}

@test "st_enable: rifiuta se già attivo, nome occupato, email non valide o permessi mancanti" {
  cf_env
  st_enable ssh-k3f9x2 manu@x.it
  : >"$CFLOG"
  run st_enable ssh-altro1 manu@x.it; [ "$status" -eq 1 ]
  ! grep -q "^POST" "$CFLOG"
  rm -f "${SSHTUNNEL_STATE:?}"
  CF_DNS_EXISTS=1 run st_enable ssh-altro1 manu@x.it; [ "$status" -eq 1 ]
  ! grep -q "^POST" "$CFLOG"
  run st_enable ssh-altro1 "non-una-email"; [ "$status" -eq 1 ]
  run st_enable "Bad_Label" manu@x.it; [ "$status" -eq 1 ]
  CF_DENY="GET:/accounts/acc1/cfd_tunnel" run st_enable ssh-altro1 manu@x.it; [ "$status" -eq 1 ]
  ! grep -q "^POST" "$CFLOG"
}

@test "st_enable: Cloudflare spento nel manifest → errore senza chiamate" {
  cf_env
  jq -n '{admin_user:"manu", ssh_port:6666, cloudflare:{enabled:false}}' >"$VPS_OPT/manifest.json"
  run st_enable ssh-k3f9x2 manu@x.it
  [ "$status" -eq 1 ]
  [ ! -s "$CFLOG" ]
}

@test "st_set_emails aggiorna la policy e i principal" {
  cf_enabled
  run st_set_emails altro@y.it
  [ "$status" -eq 0 ]
  grep -q "PUT /accounts/acc1/access/policies/pol1" "$CFLOG"
  grep -- '--data' "$CALLS" | grep -q '{"email":{"email":"altro@y.it"}}'
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = altro ]
  [ "$(jq -c .emails "$SSHTUNNEL_STATE")" = '["altro@y.it"]' ]
}

@test "st_set_emails: sshd che fallisce rimette la policy di prima" {
  cf_enabled
  SSHD_FAIL=1 run st_set_emails altro@y.it
  [ "$status" -eq 1 ]
  [ "$(grep -c "PUT /accounts/acc1/access/policies/pol1" "$CFLOG")" -eq 2 ]
  last="$(grep -- '"decision":"allow"' "$CALLS" | tail -1)"
  [[ "$last" == *'"manu@x.it"'* ]]
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = manu ]
  [ "$(jq -c .emails "$SSHTUNNEL_STATE")" = '["manu@x.it"]' ]
}

@test "st_set_host: nuovo CNAME prima di cancellare il vecchio, stato aggiornato" {
  cf_enabled
  run st_set_host ssh-nuovo1
  [ "$status" -eq 0 ]
  in_order "$CFLOG" \
    "PUT /accounts/acc1/cfd_tunnel/tun1/configurations" \
    "PUT /accounts/acc1/access/apps/app1" \
    "POST /zones/zone123/dns_records" \
    "DELETE /zones/zone123/dns_records/dns1"
  # Il vecchio nome esce subito dall'ingresso: quando l'app Access lo lascia,
  # il suo CNAME (ancora presente) non deve portare a sshd senza protezione.
  [ "$(grep -c 'ssh://localhost' "$CALLS")" -eq 1 ]
  cfg="$(grep 'ssh://localhost' "$CALLS")"
  [[ "$cfg" == *ssh-nuovo1.example.it* && "$cfg" != *ssh-k3f9x2* ]]
  [ "$(jq -r .host "$SSHTUNNEL_STATE")" = ssh-nuovo1.example.it ]
  [ "$(jq -r .label "$SSHTUNNEL_STATE")" = ssh-nuovo1 ]
  [ "$(jq -r .dns_id "$SSHTUNNEL_STATE")" = dns2 ]
}

@test "st_set_host: DNS nuovo rifiutato → app e ingresso tornano al vecchio nome" {
  cf_enabled
  CF_FAIL="POST:/zones/zone123/dns_records" run st_set_host ssh-nuovo1
  [ "$status" -eq 1 ]
  ! grep -q "DELETE /zones/zone123/dns_records/dns1" "$CFLOG"
  [ "$(grep -c "PUT /accounts/acc1/access/apps/app1" "$CFLOG")" -eq 2 ]
  last_app="$(grep -- '"type":"ssh"' "$CALLS" | tail -1)"
  [[ "$last_app" == *'"domain":"ssh-k3f9x2.example.it"'* ]]
  last_cfg="$(grep 'ssh://localhost' "$CALLS" | tail -1)"
  [[ "$last_cfg" != *ssh-nuovo1* ]]
  [ "$(jq -r .host "$SSHTUNNEL_STATE")" = ssh-k3f9x2.example.it ]
}

@test "st_set_host: DNS nuovo fallito → cancella il CNAME del tunnel rimasto, non gli altri" {
  cf_enabled
  CF_DNS_ORPHAN=1 CF_FAIL="POST:/zones/zone123/dns_records" run st_set_host ssh-nuovo1
  [ "$status" -eq 1 ]
  grep -qx "DELETE /zones/zone123/dns_records/orphan9" "$CFLOG"
  ! grep -q "DELETE /zones/zone123/dns_records/altrui" "$CFLOG"
  ! grep -q "DELETE /zones/zone123/dns_records/dns1" "$CFLOG"
}

@test "st_disable con l'app già cancellata (404) completa" {
  cf_enabled
  CF_404="DELETE:/accounts/acc1/access/apps/app1 DELETE:/accounts/acc1/access/apps/app1/ca" run st_disable
  [ "$status" -eq 0 ]
  in_order "$CFLOG" "DELETE /zones/zone123/dns_records/dns1" "DELETE /accounts/acc1/access/apps/app1" "DELETE /accounts/acc1/cfd_tunnel/tun1"
  grep -q "systemctl disable --now vps-cloudflared" "$CALLS"
  [ ! -e "$SYSTEMD_DIR/vps-cloudflared.service" ]
  [ ! -e "$SSHTUNNEL_ENV" ]
  [ ! -e "$SSH_CF_PRINCIPALS/manu" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_disable: un errore vero (non 404) si ferma e conserva lo stato" {
  cf_enabled
  CF_FAIL="DELETE:/accounts/acc1/access/apps/app1" run st_disable
  [ "$status" -eq 1 ]
  [ -f "$SSHTUNNEL_STATE" ]
  ! grep -q "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
}

@test "unità vps-cloudflared: token nell'ambiente, non negli argomenti" {
  u="$REPO_ROOT/templates/vps-cloudflared.service"
  grep -qx 'EnvironmentFile=/opt/vps/secrets/cf-tunnel.env' "$u"
  grep -qx 'ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run' "$u"
  grep -qx 'DynamicUser=yes' "$u"
  grep -qx 'NoNewPrivileges=yes' "$u"
  grep -qx 'Restart=on-failure' "$u"
  grep -qx 'After=network-online.target' "$u"
  grep -qx 'Wants=network-online.target' "$u"
  ! grep -q -- '--token' "$u"
}

@test "st_cloudflared_install: già presente → niente apt" {
  cf_env
  run st_cloudflared_install
  [ "$status" -eq 0 ]
  ! grep -q apt-get "$CALLS"
}

@test "st_cloudflared_install: repository Cloudflare con chiave verificata" {
  cf_env
  rm -f "$BATS_TEST_TMPDIR/bin/cloudflared"
  if command -v cloudflared; then skip "cloudflared installato sul sistema di test"; fi
  # Verifica del fingerprint finta: qui conta il flusso, non gpg.
  gpg_keyring_install() { echo "keyring $*" >>"$CALLS"; mkdir -p "$(dirname "$2")"; cp "$1" "$2"; }
  # shellcheck disable=SC2016
  make_stub curl 'echo "curl $*" >>"$CALLS"; while (($#)); do [ "$1" = -o ] && echo KEY >"$2"; shift; done; exit 0'
  # shellcheck disable=SC2016
  make_stub apt-get 'echo "apt-get $*" >>"$CALLS"; case "$*" in *install*) printf "#!/bin/sh\necho cloudflared version 1\n" >"$BATS_TEST_TMPDIR/bin/cloudflared"; chmod +x "$BATS_TEST_TMPDIR/bin/cloudflared";; esac; exit 0'
  run st_cloudflared_install
  [ "$status" -eq 0 ]
  grep -q "https://pkg.cloudflare.com/cloudflare-main.gpg" "$CALLS"
  grep -q "CC94B39C77AE7342A68B89628A682D308D4E5E73" "$CALLS"
  grep -qxF "deb [signed-by=$CLOUDFLARED_KEYRING] https://pkg.cloudflare.com/cloudflared any main" "$APT_SOURCES_D/cloudflared.list"
  grep -q "apt-get .*install.*cloudflared" "$CALLS"
}

@test "st_cloudflared_install: chiave non scaricabile → 1 con ST_ERR, niente repository" {
  cf_env
  rm -f "$BATS_TEST_TMPDIR/bin/cloudflared"
  if command -v cloudflared; then skip "cloudflared installato sul sistema di test"; fi
  make_stub curl 'exit 22'
  rc=0
  st_cloudflared_install || rc=$?
  [ "$rc" -eq 1 ]
  [ -n "$ST_ERR" ]
  [ ! -e "$APT_SOURCES_D/cloudflared.list" ]
}

@test "st_host_free: libero, sito registrato (anche www), record DNS" {
  cf_env
  export CF_API_TOKEN=SYSTOKEN-abc123
  run st_host_free ssh-abc123.example.it
  [ "$status" -eq 0 ]
  echo '{"domain":"ssh-abc123.example.it","www":false}' >"$SITES_DIR/ssh-abc123.example.it.json"
  rc=0; st_host_free ssh-abc123.example.it || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ST_REASON" = "usato da un sito" ]
  rm -f "${SITES_DIR:?}/ssh-abc123.example.it.json"
  echo '{"domain":"blog.example.it","www":true}' >"$SITES_DIR/blog.example.it.json"
  rc=0; st_host_free www.blog.example.it || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ST_REASON" = "usato da un sito" ]
  rc=0; CF_DNS_EXISTS=1 st_host_free ssh-abc123.example.it || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ST_REASON" = "esiste già un record DNS" ]
}

@test "st_status_json: Cloudflare spento → solo cloudflare:false" {
  cf_env
  jq -n '{admin_user:"manu", cloudflare:{enabled:false}}' >"$VPS_OPT/manifest.json"
  run --separate-stderr st_status_json
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"cloudflare":false}' ]
}

@test "st_status_json: non attivo" {
  cf_env
  CF_OTP=1 run --separate-stderr st_status_json
  [ "$status" -eq 0 ]
  jq -e '.ok and .cloudflare and .zone == "example.it" and .perms == {tunnel:true, access:true, idp:true}
    and .zerotrust and .otp and (.enabled | not) and .host == null and .emails == [] and .user == "manu"
    and .service == "missing" and .cloudflared_version == "2025.10.0" and .tunnel_status == null
    and .drift == []' <<<"$output"
}

@test "st_status_json: attivo e completo, poi pezzi cancellati a mano → drift" {
  cf_enabled
  run --separate-stderr st_status_json
  [ "$status" -eq 0 ]
  jq -e '.enabled and .host == "ssh-k3f9x2.example.it" and .emails == ["manu@x.it"]
    and .service == "active" and .tunnel_status == "healthy" and .drift == []' <<<"$output"
  CF_404="GET:/accounts/acc1/access/apps/app1" run --separate-stderr st_status_json
  jq -e '.drift == ["app"]' <<<"$output"
  rm -f "${SYSTEMD_DIR:?}/vps-cloudflared.service"
  CF_404="GET:/zones/zone123/dns_records/dns1 GET:/accounts/acc1/cfd_tunnel/tun1" run --separate-stderr st_status_json
  jq -e '.drift == ["dns","tunnel","service"] and .service == "missing" and .tunnel_status == null' <<<"$output"
  [[ "$output" != *TOKEN* ]]
}

@test "st_status_json: Cloudflare che non risponde → ok:false" {
  cf_env
  make_stub curl 'exit 7'
  run --separate-stderr st_status_json
  [ "$status" -eq 1 ]
  jq -e '.ok == false and (.error | length > 0)' <<<"$output"
}

# ---------------------------------------------------------------------------
# Correzioni della revisione del Task 4

@test "st_enable: nome del tunnel unico per VPS e etichetta" {
  cf_env
  CF_OTP=1 st_enable ssh-k3f9x2 manu@x.it
  grep -- '--data' "$CALLS" | grep -q "\"name\":\"vps-$(hostname -s)-ssh-k3f9x2\""
}

@test "st_enable: id mancante in una risposta di successo → errore e annullamento" {
  local what
  for what in "POST:/accounts/acc1/access/policies" "POST:/accounts/acc1/access/apps" "POST:/zones/zone123/dns_records"; do
    cf_env
    rm -f "$SSHTUNNEL_STATE"
    rc=0
    CF_OTP=1 CF_NOID="$what" st_enable ssh-k3f9x2 manu@x.it || rc=$?
    [ "$rc" -eq 1 ]
    [ -n "$ST_ERR" ]
    [ ! -e "$SSHTUNNEL_STATE" ]
    grep -qx "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
    [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  done
}

@test "st_enable: DNS fallito → cancella il CNAME del tunnel rimasto, non gli altri" {
  cf_env
  CF_OTP=1 CF_DNS_ORPHAN=1 CF_FAIL="POST:/zones/zone123/dns_records" run st_enable ssh-k3f9x2 manu@x.it
  [ "$status" -eq 1 ]
  grep -qx "DELETE /zones/zone123/dns_records/orphan9" "$CFLOG"
  ! grep -q "DELETE /zones/zone123/dns_records/altrui" "$CFLOG"
  in_order "$CFLOG" "DELETE /zones/zone123/dns_records/orphan9" "DELETE /accounts/acc1/access/apps/app1"
}

@test "st_set_host: vecchio CNAME non cancellato → resta in stale_dns_ids e disable lo toglie" {
  cf_enabled
  CF_FAIL="DELETE:/zones/zone123/dns_records/dns1" run st_set_host ssh-nuovo1
  [ "$status" -eq 0 ]
  [ "$(jq -c .stale_dns_ids "$SSHTUNNEL_STATE")" = '["dns1"]' ]
  [ "$(jq -r .dns_id "$SSHTUNNEL_STATE")" = dns2 ]
  : >"$CFLOG"
  run st_disable
  [ "$status" -eq 0 ]
  grep -qx "DELETE /zones/zone123/dns_records/dns1" "$CFLOG"
  grep -qx "DELETE /zones/zone123/dns_records/dns2" "$CFLOG"
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_disable: id vecchio già assente (404) non blocca" {
  cf_enabled
  CF_FAIL="DELETE:/zones/zone123/dns_records/dns1" st_set_host ssh-nuovo1
  CF_404="DELETE:/zones/zone123/dns_records/dns1" run st_disable
  [ "$status" -eq 0 ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_status_json: policy mancante (404) → drift app, senza duplicati" {
  cf_enabled
  CF_404="GET:/accounts/acc1/access/policies/pol1" run --separate-stderr st_status_json
  jq -e '.drift == ["app"]' <<<"$output"
  CF_404="GET:/accounts/acc1/access/policies/pol1 GET:/accounts/acc1/access/apps/app1" run --separate-stderr st_status_json
  jq -e '.drift == ["app"]' <<<"$output"
  CF_DENY="GET:/accounts/acc1/access/policies/pol1" run --separate-stderr st_status_json
  jq -e '.drift == []' <<<"$output"
}

# ---------------------------------------------------------------------------
# Strumento vps-ssh-tunnel (contratto con la Plancia)

# st: lo strumento, solo stdout (i log vanno su stderr).
st() {
  run --separate-stderr bash "$REPO_ROOT/tools/vps-ssh-tunnel" "$@"
}

# st_in JSON ARGOMENTI... — come st, con il JSON su stdin.
st_in() {
  local json="$1"
  shift
  run --separate-stderr bash -c 'printf "%s" "$1" | bash "$2" "${@:3}"' _ "$json" "$REPO_ROOT/tools/vps-ssh-tunnel" "$@"
}

cli_env() {
  cf_env
  export VPS_LIB="$REPO_ROOT/lib" SSHTUNNEL_LOCK="$BATS_TEST_TMPDIR/ssht.lock"
}

@test "vps-ssh-tunnel: argomenti sconosciuti o mancanti → uso:" {
  cli_env
  st boh
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  st
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  st check-host
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  st status extra
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  st disable extra
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  [ ! -s "$CFLOG" ]
}

@test "vps-ssh-tunnel status: Cloudflare spento → {ok:true,cloudflare:false}" {
  cli_env
  jq -n '{admin_user:"manu", cloudflare:{enabled:false}}' >"$VPS_OPT/manifest.json"
  st status
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"cloudflare":false}' ]
}

@test "vps-ssh-tunnel status: attivo, app sparita su Cloudflare → drift app" {
  cli_env
  cf_enabled
  CF_404="GET:/accounts/acc1/access/apps/app1" st status
  [ "$status" -eq 0 ]
  jq -e '.ok and .enabled and .host == "ssh-k3f9x2.example.it" and (.drift | index("app"))' <<<"$output"
  [[ "$output" != *TOKEN* ]]
}

@test "vps-ssh-tunnel status: Cloudflare che non risponde → ok:false" {
  cli_env
  make_stub curl 'exit 7'
  st status
  [ "$status" -eq 1 ]
  jq -e '.ok == false and (.error | length > 0)' <<<"$output"
}

@test "vps-ssh-tunnel random" {
  cli_env
  st random
  [ "$status" -eq 0 ]
  jq -e '.ok and (.label | test("^ssh-[a-z0-9]{6}$"))' <<<"$output"
}

@test "vps-ssh-tunnel check-host: libero, sito registrato, record DNS, nome non valido" {
  cli_env
  st check-host ssh-abc123
  [ "$status" -eq 0 ]
  jq -e '.ok and .host == "ssh-abc123.example.it" and .free == true and .reason == null' <<<"$output"
  echo '{"domain":"ssh-abc123.example.it","www":false}' >"$SITES_DIR/ssh-abc123.example.it.json"
  st check-host ssh-abc123
  jq -e '.free == false and .reason == "usato da un sito"' <<<"$output"
  rm -f "${SITES_DIR:?}/ssh-abc123.example.it.json"
  CF_DNS_EXISTS=1 st check-host ssh-abc123
  jq -e '.free == false and .reason == "esiste già un record DNS"' <<<"$output"
  st check-host "Bad_Label"
  [ "$status" -eq 0 ]
  jq -e '.ok and .free == false and .reason == "nome non valido"' <<<"$output"
}

@test "vps-ssh-tunnel enable: email non valide → errore e nessuna chiamata a curl" {
  cli_env
  st_in '{"label":"ssh-k3f9x2","emails":"non-una-email"}' enable
  [ "$status" -eq 1 ]
  jq -e '.ok == false and (.error | length > 0)' <<<"$output"
  [ ! -s "$CFLOG" ]
  ! grep -q '^curl' "$CALLS"
}

@test "vps-ssh-tunnel enable: JSON non valido → errore" {
  cli_env
  st_in 'non json' enable
  [ "$status" -eq 1 ]
  jq -e '.ok == false' <<<"$output"
  [ ! -s "$CFLOG" ]
}

@test "vps-ssh-tunnel: lock occupato → un'altra operazione in corso" {
  cli_env
  exec 8>"$SSHTUNNEL_LOCK"
  flock -n 8
  st_in '{"label":"ssh-k3f9x2","emails":"manu@x.it"}' enable
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"in corso"* ]]
  st disable
  [[ "$(jq -r .error <<<"$output")" == *"in corso"* ]]
  [ ! -s "$CFLOG" ]
  # status non prende il lock: si può sempre leggere.
  st status
  [ "$status" -eq 0 ]
  exec 8>&-
}

@test "vps-ssh-tunnel: enable, set-emails, set-host, disable; nessun segreto in output" {
  cli_env
  export CF_OTP=1
  st_in '{"label":"ssh-k3f9x2","emails":"Manu@x.it, altro@y.it"}' enable
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"host":"ssh-k3f9x2.example.it"}' ]
  [[ "$stderr" != *TUNNELTOKEN* && "$stderr" != *SYSTOKEN* ]]
  [ -f "$SSHTUNNEL_STATE" ]

  st_in '{"emails":"nuovo@z.it"}' set-emails
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"emails":["nuovo@z.it"]}' ]

  st set-host ssh-nuovo1
  [ "$status" -eq 0 ]
  jq -e '.ok and .from == "ssh-k3f9x2.example.it" and .host == "ssh-nuovo1.example.it"' <<<"$output"

  st disable
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ ! -e "$SSHTUNNEL_STATE" ]
  for f in "$VPS_LOG" "$CALLS"; do
    ! grep -q TUNNELTOKEN "$f"
    ! grep -q SYSTOKEN "$f"
  done
}

@test "vps-ssh-tunnel: un errore di enable arriva come json_err senza segreti" {
  cli_env
  CF_OTP=1 CF_FAIL="POST:*/ca" st_in '{"label":"ssh-k3f9x2","emails":"manu@x.it"}' enable
  [ "$status" -eq 1 ]
  jq -e '.ok == false and (.error | length > 0)' <<<"$output"
  [[ "$output" != *TOKEN* ]]
  [ ! -e "$SSHTUNNEL_STATE" ]
  grep -qx "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
}

@test "vps-ssh-tunnel sotto sudo azzera i percorsi dell'ambiente" {
  t="$REPO_ROOT/tools/vps-ssh-tunnel"
  grep -q 'SSHD_CONFIG_D SSH_CF_CA SSH_CF_PRINCIPALS SSHTUNNEL_STATE SSHTUNNEL_ENV SSHTUNNEL_LOCK' "$t"
  for v in SYSTEMD_DIR APT_SOURCES_D CLOUDFLARED_KEYRING CF_API_TOKEN SITES_DIR CF_API; do
    grep -q "$v" "$t"
  done
}

@test "sudoers consente vps-ssh-tunnel; jail sshd non banna localhost" {
  grep -qF '/opt/vps/bin/vps-ssh-tunnel' "$REPO_ROOT/templates/sudoers-vps-panel"
  grep -qE '^ignoreip = 127\.0\.0\.1/8 ::1( |$)' "$REPO_ROOT/templates/jail-sshd.local.tmpl"
}

@test "vps-ssh-tunnel enable: l'etichetta è obbligatoria, niente generazione silenziosa" {
  cli_env
  st_in '{"emails":"manu@x.it"}' enable
  [ "$status" -eq 1 ]
  jq -e '.ok == false' <<<"$output"
  st_in '{"label":"","emails":"manu@x.it"}' enable
  [ "$status" -eq 1 ]
  [ ! -s "$CFLOG" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "vps-ssh-tunnel: il rilancio in unità systemd usa il percorso assoluto fisso" {
  t="$REPO_ROOT/tools/vps-ssh-tunnel"
  grep -q 'systemd-run --wait --pipe' "$t"
  grep -q '/opt/vps/bin/vps-ssh-tunnel "\$@"' "$t"
}
