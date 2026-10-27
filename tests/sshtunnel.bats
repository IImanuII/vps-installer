bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  setup_common
  export SSHD_CONFIG_D="$BATS_TEST_TMPDIR/sshd_config.d"
  export SSH_CF_CA="$BATS_TEST_TMPDIR/ssh/vps-cf-ca.pub"
  export SSH_CF_PRINCIPALS="$BATS_TEST_TMPDIR/ssh/vps-cf-principals"
  export SSHTUNNEL_STATE="$VPS_OPT/ssh-tunnel.json"
  export SUDOERS_D="$BATS_TEST_TMPDIR/sudoers.d"
  export PASSWD_FAKE="$BATS_TEST_TMPDIR/passwd"
  export LINGER_D="$BATS_TEST_TMPDIR/linger"
  export HOME_BASE="$BATS_TEST_TMPDIR/home"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$SSHD_CONFIG_D" "$BATS_TEST_TMPDIR/ssh" "$SUDOERS_D" "$HOME_BASE"
  : >"$PASSWD_FAKE"
  : >"$CALLS"
  # getent legge un passwd finto: "nome:x:1000:1000:GECOS:/home/nome:/bin/bash".
  # shellcheck disable=SC2016
  make_stub getent '[ "$1" = passwd ] || exit 2; awk -F: -v u="$2" '"'"'$1 == u { print; f = 1 } END { exit !f }'"'"' "$PASSWD_FAKE" || exit 2'
  # shellcheck disable=SC2016
  make_stub sshd 'echo "sshd $*" >>"$CALLS"; [ "${SSHD_FAIL:-0}" = 1 ] && exit 1; exit 0'
  # shellcheck disable=SC2016
  make_stub systemctl 'echo "systemctl $*" >>"$CALLS"
[ "${RELOAD_FAIL:-0}" = 1 ] && [ "$1 $2" = "reload ssh" ] && exit 1
[ "${ACTIVE_FAIL:-0}" = 1 ] && [ "$1" = is-active ] && exit 3
exit 0'
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

@test "st_sshd_apply scrive i tre file e ricarica" {
  run st_sshd_apply "ssh-ed25519 AAAA ca" manu
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
  SSHD_FAIL=1 run st_sshd_apply "ssh-ed25519 AAAA ca" manu
  [ "$status" -eq 1 ]
  [ "$(cat "$SSHD_CONFIG_D/20-vps-cfaccess.conf")" = VECCHIO ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSH_CF_PRINCIPALS/manu" ]
  ! grep -q "reload" "$CALLS"
}

@test "st_sshd_remove toglie i file e ricarica" {
  st_sshd_apply "ssh-ed25519 AAAA ca" manu
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

@test "st_sshd_apply senza principal o con utente non valido ritorna 1 senza toccare nulla" {
  run st_sshd_apply "ssh-ed25519 AAAA ca"; [ "$status" -eq 1 ]
  run st_sshd_apply "ssh-ed25519 AAAA ca" ""; [ "$status" -eq 1 ]
  run st_sshd_apply "ssh-ed25519 AAAA ca" "../x"; [ "$status" -eq 1 ]
  run st_sshd_remove "../x"; [ "$status" -eq 1 ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSH_CF_PRINCIPALS" ]
  [ ! -s "$CALLS" ]
}

@test "sshd -t che fallisce ripristina CA e principal preesistenti" {
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo CA-VECCHIA >"$SSH_CF_CA"
  echo vecchio >"$SSH_CF_PRINCIPALS/manu"
  SSHD_FAIL=1 run st_sshd_apply "ssh-ed25519 AAAA ca" manu
  [ "$status" -eq 1 ]
  [ "$(cat "$SSH_CF_CA")" = CA-VECCHIA ]
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = vecchio ]
}

@test "una scrittura fallita a metà ripristina e non lascia lo snapshot" {
  mkdir -p "$SSH_CF_PRINCIPALS" "$BATS_TEST_TMPDIR/tmp"
  echo CA-VECCHIA >"$SSH_CF_CA"
  echo vecchio >"$SSH_CF_PRINCIPALS/manu"
  chmod 555 "$SSHD_CONFIG_D"
  TMPDIR="$BATS_TEST_TMPDIR/tmp" run st_sshd_apply "ssh-ed25519 AAAA ca" manu
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
  export APT_CONF_D="$BATS_TEST_TMPDIR/apt.conf.d"
  export CLOUDFLARED_BIN="$BATS_TEST_TMPDIR/bin/cloudflared"
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
  user_stubs
}

# st_enable riuscito, con stato scritto: base dei test di modifica.
cf_enabled() {
  cf_env
  CF_OTP=1 st_enable ssh-k3f9x2 manu@x.it true
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
  run st_enable ssh-k3f9x2 manu@x.it true
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
  [ "$(jq -r .account_id "$SSHTUNNEL_STATE")" = acc1 ]
  [ "$(jq -r .zone_id "$SSHTUNNEL_STATE")" = zone123 ]
  [ -n "$(jq -r .enabled_at "$SSHTUNNEL_STATE")" ]
  [ "$(jq -c .users "$SSHTUNNEL_STATE")" = '[{"email":"manu@x.it","user":"manu","sudo":true}]' ]
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
  CF_OTP=1 st_enable ssh-k3f9x2 manu@x.it true
  app="$(grep -- '--data' "$CALLS" | grep '"type":"ssh"' | head -1)"
  [[ "$app" == *'"domain":"ssh-k3f9x2.example.it"'* ]]
  [[ "$app" == *'"session_duration":"1h"'* ]]
  [[ "$app" == *'"allowed_idps":["otp9"]'* ]]
  [[ "$app" == *'"auto_redirect_to_identity":true'* ]]
  [[ "$app" == *'"policies":[{"id":"pol1","precedence":1}]'* ]]
  pol="$(grep -- '--data' "$CALLS" | grep '"decision":"allow"' | head -1)"
  [[ "$pol" == *'{"email":{"email":"manu@x.it"}}'* ]]
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = manu ]
}

@test "st_enable: One-time PIN già presente → nessuna creazione" {
  cf_env
  CF_OTP=1 run st_enable ssh-k3f9x2 manu@x.it true
  [ "$status" -eq 0 ]
  ! grep -q "POST /accounts/acc1/access/identity_providers" "$CFLOG"
}

@test "st_enable: CA rifiutata → annulla tutto, niente DNS né sshd né stato" {
  cf_env
  rc=0
  CF_FAIL="POST:*/ca" st_enable ssh-k3f9x2 manu@x.it true || rc=$?
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
  CF_FAIL="POST:/zones/zone123/dns_records" run st_enable ssh-k3f9x2 manu@x.it true
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
  st_enable ssh-k3f9x2 manu@x.it true
  : >"$CFLOG"
  run st_enable ssh-altro1 manu@x.it; [ "$status" -eq 1 ]
  ! grep -q "^POST" "$CFLOG"
  rm -f "${SSHTUNNEL_STATE:?}"
  : >"$PASSWD_FAKE"
  CF_DNS_EXISTS=1 run st_enable ssh-altro1 manu@x.it; [ "$status" -eq 1 ]
  ! grep -q "^POST" "$CFLOG"
  run st_enable ssh-altro1 "non-una-email"; [ "$status" -eq 1 ]
  run st_enable "Bad_Label" manu@x.it; [ "$status" -eq 1 ]
  CF_DENY="GET:/accounts/acc1/cfd_tunnel/*" run st_enable ssh-altro1 manu@x.it; [ "$status" -eq 1 ]
  ! grep -q "^POST" "$CFLOG"
}

@test "st_enable: Cloudflare spento nel manifest → errore senza chiamate" {
  cf_env
  jq -n '{admin_user:"manu", ssh_port:6666, cloudflare:{enabled:false}}' >"$VPS_OPT/manifest.json"
  run st_enable ssh-k3f9x2 manu@x.it true
  [ "$status" -eq 1 ]
  [ ! -s "$CFLOG" ]
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
    and .zerotrust and .otp and (.enabled | not) and .host == null and .users == [] and (has("emails") | not) and (has("user") | not)
    and .service == "missing" and .cloudflared_version == "2025.10.0" and .tunnel_status == null
    and .drift == []' <<<"$output"
}

@test "st_status_json: attivo e completo, poi pezzi cancellati a mano → drift" {
  cf_enabled
  run --separate-stderr st_status_json
  [ "$status" -eq 0 ]
  jq -e '.enabled and .host == "ssh-k3f9x2.example.it"
    and .users == [{email: "manu@x.it", user: "manu", sudo: true}]
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
  CF_OTP=1 st_enable ssh-k3f9x2 manu@x.it true
  grep -- '--data' "$CALLS" | grep -q "\"name\":\"vps-$(hostname -s)-ssh-k3f9x2\""
}

@test "st_enable: id mancante in una risposta di successo → errore e annullamento" {
  local what
  for what in "POST:/accounts/acc1/access/policies" "POST:/accounts/acc1/access/apps" "POST:/zones/zone123/dns_records"; do
    cf_env
    rm -f "$SSHTUNNEL_STATE"
    rc=0
    CF_OTP=1 CF_NOID="$what" st_enable ssh-k3f9x2 manu@x.it true || rc=$?
    [ "$rc" -eq 1 ]
    [ -n "$ST_ERR" ]
    [ ! -e "$SSHTUNNEL_STATE" ]
    grep -qx "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
    [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  done
}

@test "st_enable: DNS fallito → cancella il CNAME del tunnel rimasto, non gli altri" {
  cf_env
  CF_OTP=1 CF_DNS_ORPHAN=1 CF_FAIL="POST:/zones/zone123/dns_records" run st_enable ssh-k3f9x2 manu@x.it true
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

@test "st_status_json: organizzazione non leggibile → zerotrust false e idp mancante" {
  cf_enabled
  CF_DENY="GET:/accounts/acc1/access/organizations" run --separate-stderr st_status_json
  jq -e '.zerotrust == false and .perms == {tunnel:true, access:true, idp:false}' <<<"$output"
  CF_DENY="GET:/accounts/acc1/access/organizations GET:/accounts/acc1/access/identity_providers/*" run --separate-stderr st_status_json
  jq -e '.zerotrust == false and .perms.idp == false' <<<"$output"
}

@test "st_enable: organizzazione non leggibile → permesso idp mancante" {
  cf_env
  CF_DENY="GET:/accounts/acc1/access/organizations" run st_enable ssh-altro1 manu@x.it true
  [ "$status" -eq 1 ]
  ! grep -q "^POST" "$CFLOG"
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
  st_in '{"label":"ssh-k3f9x2","email":"non-una-email","sudo":true}' enable
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
  st_in '{"label":"ssh-k3f9x2","email":"manu@x.it","sudo":true}' enable
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

@test "vps-ssh-tunnel: enable, add-user, set-sudo, remove-user, set-host, disable; nessun segreto in output" {
  cli_env
  export CF_OTP=1
  st_in '{"label":"ssh-k3f9x2","email":"Manu@x.it","sudo":true}' enable
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"host":"ssh-k3f9x2.example.it"}' ]
  [[ "$stderr" != *TUNNELTOKEN* && "$stderr" != *SYSTOKEN* ]]
  [ -f "$SSHTUNNEL_STATE" ]

  st_in '{"email":"Anna@y.it","sudo":false}' add-user
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"user":"anna"}' ]

  st_in '{"email":"anna@y.it","sudo":true}' set-sudo
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"user":"anna","sudo":true}' ]
  [ -f "$SUDOERS_D/vps-ssh-anna" ]

  st status
  jq -e '.users == [{email:"manu@x.it",user:"manu",sudo:true},{email:"anna@y.it",user:"anna",sudo:true}]
    and (has("emails") | not) and .drift == []' <<<"$output"

  st_in '{"email":"anna@y.it"}' remove-user
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"user":"anna"}' ]
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]

  st set-host ssh-nuovo1
  [ "$status" -eq 0 ]
  jq -e '.ok and .from == "ssh-k3f9x2.example.it" and .host == "ssh-nuovo1.example.it"' <<<"$output"

  st disable
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ ! -e "$SSHTUNNEL_STATE" ]
  [ ! -e "$SUDOERS_D/vps-ssh-manu" ]
  for f in "$VPS_LOG" "$CALLS"; do
    ! grep -q TUNNELTOKEN "$f"
    ! grep -q SYSTOKEN "$f"
  done
}

@test "vps-ssh-tunnel set-emails non esiste più → errore d'uso" {
  cli_env
  st_in '{"emails":"a@x.it"}' set-emails
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
  [[ "$(jq -r .error <<<"$output")" != *set-emails* ]]
  [ ! -s "$CFLOG" ]
}

@test "vps-ssh-tunnel add-user, set-sudo, enable: sudo deve essere un booleano JSON" {
  cli_env
  local cmd body
  for cmd in enable add-user set-sudo; do
    for body in '"true"' '1' 'null' '"false"'; do
      st_in "{\"label\":\"ssh-k3f9x2\",\"email\":\"manu@x.it\",\"sudo\":$body}" "$cmd"
      [ "$status" -eq 1 ]
      [ "$(jq -r .error <<<"$output")" = "sudo deve essere true o false" ]
    done
    st_in '{"label":"ssh-k3f9x2","email":"manu@x.it"}' "$cmd"
    [ "$status" -eq 1 ]
    [ "$(jq -r .error <<<"$output")" = "sudo deve essere true o false" ]
  done
  [ ! -s "$CFLOG" ]
  ! grep -qE '^(useradd|userdel)' "$CALLS"
}

@test "vps-ssh-tunnel add-user e remove-user: errori in italiano come json_err" {
  cli_env
  CF_OTP=1 st_in '{"label":"ssh-k3f9x2","email":"manu@x.it","sudo":false}' enable
  [ "$status" -eq 0 ]
  st_in '{"email":"manu@x.it"}' remove-user
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "l'ultima persona non si può eliminare: per togliere tutto usa Disattiva" ]
  st_in '{"email":"MANU@z.it","sudo":false}' add-user
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "c'è già una persona con il nome utente manu" ]
}

@test "vps-ssh-tunnel: un errore di enable arriva come json_err senza segreti" {
  cli_env
  CF_OTP=1 CF_FAIL="POST:*/ca" st_in '{"label":"ssh-k3f9x2","email":"manu@x.it","sudo":true}' enable
  [ "$status" -eq 1 ]
  jq -e '.ok == false and (.error | length > 0)' <<<"$output"
  [[ "$output" != *TOKEN* ]]
  [ ! -e "$SSHTUNNEL_STATE" ]
  grep -qx "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
}

@test "vps-ssh-tunnel sotto sudo azzera i percorsi dell'ambiente" {
  t="$REPO_ROOT/tools/vps-ssh-tunnel"
  grep -q 'SSHD_CONFIG_D SSH_CF_CA SSH_CF_PRINCIPALS SUDOERS_D LINGER_D SSHTUNNEL_STATE SSHTUNNEL_ENV SSHTUNNEL_LOCK' "$t"
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
  st_in '{"email":"manu@x.it","sudo":true}' enable
  [ "$status" -eq 1 ]
  jq -e '.ok == false' <<<"$output"
  st_in '{"label":"","email":"manu@x.it","sudo":true}' enable
  [ "$status" -eq 1 ]
  [ ! -s "$CFLOG" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "vps-ssh-tunnel: il rilancio in unità systemd usa il percorso assoluto fisso" {
  t="$REPO_ROOT/tools/vps-ssh-tunnel"
  grep -q 'systemd-run --wait --pipe' "$t"
  grep -q '/opt/vps/bin/vps-ssh-tunnel "\$@"' "$t"
}

@test "st_sshd_apply: reload che fallisce dopo sshd -t ripristina i file di prima, rc 1" {
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo CA-VECCHIA >"$SSH_CF_CA"
  echo vecchio >"$SSH_CF_PRINCIPALS/manu"
  RELOAD_FAIL=1 run st_sshd_apply "ssh-ed25519 AAAA ca" manu
  [ "$status" -eq 1 ]
  [ "$(cat "$SSH_CF_CA")" = CA-VECCHIA ]
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = vecchio ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  # un secondo tentativo di reload con la configurazione di prima
  [ "$(grep -c "systemctl reload ssh" "$CALLS")" -eq 2 ]
}

@test "st_sshd_apply: snapshot che fallisce → rc 1 senza scrivere nulla" {
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo CA-VECCHIA >"$SSH_CF_CA"
  cp() { return 1; }
  run st_sshd_apply "ssh-ed25519 AAAA ca" manu
  unset -f cp
  [ "$status" -eq 1 ]
  [ "$(cat "$SSH_CF_CA")" = CA-VECCHIA ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -s "$CALLS" ]
}

@test "st_enable: reload di sshd fallito → annullamento completo, messaggio veritiero" {
  cf_env
  rc=0
  RELOAD_FAIL=1 st_enable ssh-k3f9x2 manu@x.it true || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$ST_ERR" == *"sshd è rimasto com'era"* ]]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
  grep -qx "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
}

@test "_st_rollback: un passo che fallisce lo dice in ST_ERR" {
  cf_env
  rc=0
  CF_FAIL="POST:*/ca DELETE:/accounts/acc1/access/apps/app1" st_enable ssh-k3f9x2 manu@x.it true || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$ST_ERR" == *"annullamento incompleto: controlla Cloudflare"* ]]
}

@test "_st_rollback: tutto ok → ST_ERR senza avviso di annullamento incompleto" {
  cf_env
  rc=0
  CF_FAIL="POST:*/ca" st_enable ssh-k3f9x2 manu@x.it true || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$ST_ERR" != *"annullamento incompleto"* ]]
}

@test "hook apt di cloudflared: installato con l'unità, tolto da st_disable" {
  cf_enabled
  h="$APT_CONF_D/90vps-cloudflared"
  [ -f "$h" ]
  grep -q 'try-restart vps-cloudflared.service' "$h"
  grep -q 'DPkg::Post-Invoke' "$h"
  run st_disable
  [ "$status" -eq 0 ]
  [ ! -e "$h" ]
}

@test "unità vps-cloudflared: Type=exec e hook apt documentato nel handoff" {
  grep -qx 'Type=exec' "$REPO_ROOT/templates/vps-cloudflared.service"
  grep -q '90vps-cloudflared' "$REPO_ROOT/docs/PANEL-HANDOFF.md"
}

@test "st_enable: servizio non attivo dopo enable → errore e annullamento" {
  cf_env
  rc=0
  ACTIVE_FAIL=1 st_enable ssh-k3f9x2 manu@x.it true || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$ST_ERR" == *cloudflared* ]]
  [ ! -e "$SYSTEMD_DIR/vps-cloudflared.service" ]
  [ ! -e "$APT_CONF_D/90vps-cloudflared" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
  grep -qx "DELETE /accounts/acc1/cfd_tunnel/tun1" "$CFLOG"
}

@test "st_cloudflared_install: serve il binario nel percorso fisso, non basta il PATH" {
  cf_env
  rm -f "$CLOUDFLARED_BIN"
  export CLOUDFLARED_BIN="$BATS_TEST_TMPDIR/assente/cloudflared"
  make_stub curl 'exit 22'
  rc=0
  st_cloudflared_install || rc=$?
  [ "$rc" -eq 1 ]
}

@test "st_set_host: porta mancante nel manifest → errore, nessuna chiamata API" {
  cf_enabled
  jq '.ssh_port = ""' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  rc=0
  st_set_host ssh-nuovo1 || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$ST_ERR" == *ssh_port* ]]
  [ ! -s "$CFLOG" ]
}

@test "st_set_host: Cloudflare spento o zona vuota → errore, nessuna chiamata API" {
  cf_enabled
  jq '.cloudflare.zone = ""' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  rc=0
  st_set_host ssh-nuovo1 || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$CFLOG" ]
  jq '.cloudflare.zone = "example.it" | .cloudflare.enabled = false' "$VPS_OPT/manifest.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$VPS_OPT/manifest.json"
  rc=0
  st_set_host ssh-nuovo1 || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$CFLOG" ]
}

# --- utenti Linux e drop-in per più utenti (1.11.0) ---

user_stubs() {
  local c
  for c in useradd usermod userdel loginctl pkill crontab atrm find; do
    # shellcheck disable=SC2016
    make_stub "$c" 'echo "$(basename "$0") $*" >>"$CALLS"; [ "${USERADD_FAIL:-0}" = 1 ] && [ "$(basename "$0")" = useradd ] && exit 1; [ "${USERMOD_FAIL:-0}" = 1 ] && [ "$(basename "$0")" = usermod ] && exit 1
exit 0'
  done
  # useradd e userdel tengono aggiornato il passwd finto, così gli esiti si leggono
  # come su una macchina vera (l'utente c'è o non c'è). USERADD_FAIL=1 → nessun
  # account; USERDEL_BUSY=1 → exit 8 senza -f (utente in uso); USERDEL_FAIL=1 →
  # exit 1 e l'account resta; USERDEL_PARTIAL=1 → toglie l'account ma esce 1.
  # shellcheck disable=SC2016
  make_stub useradd 'echo "useradd $*" >>"$CALLS"; [ "${USERADD_FAIL:-0}" = 1 ] && exit 1
name="${@: -1}"; echo "$name:x:1001:1001:vps-ssh-tunnel:/home/$name:/bin/bash" >>"$PASSWD_FAKE"; exit 0'
  # shellcheck disable=SC2016
  make_stub userdel 'echo "userdel $*" >>"$CALLS"; name="${@: -1}"
[ "${USERDEL_FAIL:-0}" = 1 ] && exit 1
if [ "${USERDEL_BUSY:-0}" = 1 ] && [[ " $* " != *" -f "* ]]; then exit 8; fi
sed -i "/^$name:/d" "$PASSWD_FAKE"
[ "${USERDEL_PARTIAL:-0}" = 1 ] && exit 1
exit 0'

  # pgrep: con PGREP_BUSY=N segnala un processo vivo per le prime N chiamate.
  # shellcheck disable=SC2016
  make_stub pgrep 'echo "pgrep $*" >>"$CALLS"; n=$(cat "$BATS_TEST_TMPDIR/pgrep.n" 2>/dev/null || echo 0)
[ "$n" -lt "${PGREP_BUSY:-0}" ] || exit 1
echo $((n + 1)) >"$BATS_TEST_TMPDIR/pgrep.n"; exit 0'
  # atq: un lavoro di mario e uno di root.
  # shellcheck disable=SC2016
  make_stub atq 'printf "7	Thu Oct 27 10:00:00 2026 a mario
8	Thu Oct 27 10:00:00 2026 a root
"'
  # shellcheck disable=SC2016
  make_stub visudo 'echo "visudo $*" >>"$CALLS"; [ "${VISUDO_FAIL:-0}" = 1 ] && exit 1; exit 0'
}

@test "st_user_name: prefisso minuscolo, rifiuta i non validi" {
  run st_user_name Mario.Rossi@x.it
  [ "$status" -eq 0 ]; [ "$output" = mario.rossi ]
  run st_user_name 'mario+x@a.it'; [ "$status" -eq 1 ]
  run st_user_name '.m@a.it'; [ "$status" -eq 1 ]
  run st_user_name 'm.@a.it'; [ "$status" -eq 1 ]
  run st_user_name '1abc@a.it'; [ "$status" -eq 1 ]
  run st_user_name "$(printf 'a%.0s' {1..33})@a.it"; [ "$status" -eq 1 ]
  run st_user_name "$(printf 'a%.0s' {1..32})@a.it"; [ "$status" -eq 0 ]
}

@test "st_parse_user normalizza e rifiuta" {
  run st_parse_user "  Mario@X.it "
  [ "$status" -eq 0 ]; [ "$output" = mario@x.it ]
  run st_parse_user "x@"; [ "$status" -eq 1 ]
}

@test "st_user_ours: assente 1, nostro 0, estraneo 2" {
  user_stubs
  echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"
  echo "root:x:0:0:root:/root:/bin/bash" >>"$PASSWD_FAKE"
  run st_user_ours anna; [ "$status" -eq 1 ]
  run st_user_ours mario; [ "$status" -eq 0 ]
  run st_user_ours root; [ "$status" -eq 2 ]
}

@test "st_user_create crea l'utente con password bloccata" {
  user_stubs
  run st_user_create mario
  [ "$status" -eq 0 ]
  grep -qx "useradd -m -s /bin/bash -c vps-ssh-tunnel mario" "$CALLS"
  grep -qxF "usermod -p * mario" "$CALLS"
}

@test "st_user_create: useradd o usermod che falliscono → rc 1, nulla resta" {
  user_stubs
  USERADD_FAIL=1 run st_user_create mario
  [ "$status" -eq 1 ]
  ! grep -q "^usermod" "$CALLS"
  : >"$CALLS"
  USERMOD_FAIL=1 run st_user_create mario
  [ "$status" -eq 1 ]
  grep -qx "userdel -r mario" "$CALLS"
}

@test "st_user_create: useradd fallito a metà ma account creato → lo toglie; utente estraneo intatto" {
  user_stubs
  # useradd "fallisce" dopo aver scritto l'account.
  # shellcheck disable=SC2016
  make_stub useradd 'echo "useradd $*" >>"$CALLS"; echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"; exit 12'
  run st_user_create mario
  [ "$status" -eq 1 ]
  grep -qx "userdel -r mario" "$CALLS"
  : >"$CALLS"
  echo "anna:x:1002:1002:Anna:/home/anna:/bin/bash" >>"$PASSWD_FAKE"
  run st_user_create anna
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
}

@test "st_user_delete di un utente estraneo → rc 2 senza toccare nulla" {
  user_stubs
  echo "root:x:0:0:root:/root:/bin/bash" >>"$PASSWD_FAKE"
  run st_user_delete root
  [ "$status" -eq 2 ]
  ! grep -qE "^(userdel|pkill|loginctl|crontab|find|atrm)" "$CALLS"
}

@test "st_user_delete di un nostro utente: ordine, at, find, file" {
  user_stubs
  echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"
  echo "mario ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-mario"
  mkdir -p "$SSH_CF_PRINCIPALS" "$LINGER_D"
  echo mario >"$SSH_CF_PRINCIPALS/mario"
  : >"$LINGER_D/mario"
  run st_user_delete mario
  [ "$status" -eq 0 ]
  [ ! -e "$SUDOERS_D/vps-ssh-mario" ]
  [ ! -e "$SSH_CF_PRINCIPALS/mario" ]
  [ ! -e "$LINGER_D/mario" ]
  expected=$'loginctl disable-linger mario
loginctl terminate-user mario
pkill -KILL -u mario
crontab -r -u mario
atrm 7
find /tmp /var/tmp /dev/shm -xdev -user mario -delete
userdel -r mario'
  [ "$(grep -E '^(loginctl|pkill|crontab|atrm|find|userdel)' "$CALLS")" = "$expected" ]
  ! grep -qx "atrm 8" "$CALLS"
}

@test "st_user_delete aspetta che i processi escano; userdel -r esce con 8 (in uso) → userdel -f -r" {
  user_stubs
  echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"
  echo "mario ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-mario"
  PGREP_BUSY=2 USERDEL_BUSY=1 run st_user_delete mario
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pgrep' "$CALLS")" -eq 3 ]
  grep -qx "userdel -r mario" "$CALLS"
  grep -qx "userdel -f -r mario" "$CALLS"
  [ ! -e "$SUDOERS_D/vps-ssh-mario" ]
}

@test "st_user_delete: userdel che fallisce con un altro codice non usa -f" {
  user_stubs
  echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"
  echo "mario ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-mario"
  USERDEL_FAIL=1 run st_user_delete mario
  [ "$status" -eq 1 ]
  ! grep -q "userdel -f" "$CALLS"
  # L'account c'è ancora: sudoers coerente con lui.
  [ -e "$SUDOERS_D/vps-ssh-mario" ]
}

@test "st_user_delete: userdel in errore ma account sparito → toglie comunque sudoers e principal" {
  user_stubs
  echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"
  echo "mario ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-mario"
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo mario >"$SSH_CF_PRINCIPALS/mario"
  USERDEL_PARTIAL=1 run st_user_delete mario
  [ "$status" -eq 0 ]
  [ ! -e "$SUDOERS_D/vps-ssh-mario" ]
  [ ! -e "$SSH_CF_PRINCIPALS/mario" ]
  ! grep -q "userdel -f" "$CALLS"
}

@test "st_user_delete: il principal sparisce PRIMA di fermare i processi" {
  user_stubs
  echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo mario >"$SSH_CF_PRINCIPALS/mario"
  # shellcheck disable=SC2016
  make_stub pkill 'if [ -e "$SSH_CF_PRINCIPALS/mario" ]; then echo "pkill con principal presente" >>"$CALLS"; else echo "pkill $*" >>"$CALLS"; fi; exit 0'
  # shellcheck disable=SC2016
  make_stub loginctl 'if [ -e "$SSH_CF_PRINCIPALS/mario" ]; then echo "loginctl con principal presente" >>"$CALLS"; else echo "loginctl $*" >>"$CALLS"; fi; exit 0'
  run st_user_delete mario
  [ "$status" -eq 0 ]
  ! grep -q "principal presente" "$CALLS"
  grep -q "^pkill -KILL -u mario" "$CALLS"
}

@test "st_user_delete: userdel che fallisce del tutto → rc 1 e sudoers intatto" {
  user_stubs
  echo "mario:x:1001:1001:vps-ssh-tunnel:/home/mario:/bin/bash" >>"$PASSWD_FAKE"
  echo "mario ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-mario"
  USERDEL_FAIL=1 run st_user_delete mario
  [ "$status" -eq 1 ]
  [ -e "$SUDOERS_D/vps-ssh-mario" ]
}

@test "st_sshd_apply rifiuta un utente estraneo (utente dell'installazione, root) senza toccare nulla" {
  user_stubs
  echo "manu:x:1000:1000:Manu:/home/manu:/bin/bash" >>"$PASSWD_FAKE"
  echo "root:x:0:0:root:/root:/bin/bash" >>"$PASSWD_FAKE"
  run st_sshd_apply "ssh-ed25519 AAAA ca" mario manu
  [ "$status" -ne 0 ]
  run st_sshd_apply "ssh-ed25519 AAAA ca" root
  [ "$status" -ne 0 ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSH_CF_PRINCIPALS" ]
  ! grep -qE "sshd|reload" "$CALLS"
}

@test "st_sudo_set true rifiuta un utente estraneo" {
  user_stubs
  echo "root:x:0:0:root:/root:/bin/bash" >>"$PASSWD_FAKE"
  run st_sudo_set root true
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$SUDOERS_D")" ]
}

@test "st_user_delete di un utente assente è idempotente" {
  user_stubs
  run st_user_delete anna
  [ "$status" -eq 0 ]
  ! grep -q "^userdel" "$CALLS"
}

@test "st_sudo_set true scrive il file 440 validato, false lo toglie" {
  user_stubs
  run st_sudo_set mario true
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$SUDOERS_D/vps-ssh-mario")" = 440 ]
  [ "$(cat "$SUDOERS_D/vps-ssh-mario")" = "mario ALL=(ALL) NOPASSWD:ALL" ]
  grep -q "^visudo -cf" "$CALLS"
  run st_sudo_set mario false
  [ "$status" -eq 0 ]
  [ ! -e "$SUDOERS_D/vps-ssh-mario" ]
}

@test "st_sudo_set con visudo che fallisce → rc 1, nessun file" {
  user_stubs
  VISUDO_FAIL=1 run st_sudo_set mario true
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$SUDOERS_D")" ]
}

@test "st_sshd_apply con più utenti: drop-in, principal, pulizia dei vecchi" {
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo iimanuii >"$SSH_CF_PRINCIPALS/iimanuii"
  run st_sshd_apply "ssh-ed25519 AAAA ca" mario anna
  [ "$status" -eq 0 ]
  d="$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  grep -qx "AllowUsers mario anna" "$d"
  grep -qx "Match User mario,anna" "$d"
  grep -qx "    AuthorizedKeysFile none" "$d"
  grep -q "^TrustedUserCAKeys" "$d"
  # Match per ultimo e uno solo; niente utente dell'installazione.
  [ "$(grep -c '^Match' "$d")" -eq 1 ]
  [ "$(tail -n 1 "$d")" = "    AuthorizedKeysFile none" ]
  ! grep -q iimanuii "$d"
  [ "$(cat "$SSH_CF_PRINCIPALS/mario")" = mario ]
  [ "$(cat "$SSH_CF_PRINCIPALS/anna")" = anna ]
  [ ! -e "$SSH_CF_PRINCIPALS/iimanuii" ]
  grep -q "sshd -t" "$CALLS"
  grep -q "systemctl reload ssh" "$CALLS"
}

@test "st_sshd_apply con sshd -t che fallisce ripristina anche i principal tolti" {
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo iimanuii >"$SSH_CF_PRINCIPALS/iimanuii"
  echo VECCHIO >"$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  echo CA-VECCHIA >"$SSH_CF_CA"
  SSHD_FAIL=1 run st_sshd_apply "ssh-ed25519 AAAA ca" mario anna
  [ "$status" -eq 1 ]
  [ "$(cat "$SSH_CF_PRINCIPALS/iimanuii")" = iimanuii ]
  [ ! -e "$SSH_CF_PRINCIPALS/mario" ]
  [ ! -e "$SSH_CF_PRINCIPALS/anna" ]
  [ "$(cat "$SSHD_CONFIG_D/20-vps-cfaccess.conf")" = VECCHIO ]
  [ "$(cat "$SSH_CF_CA")" = CA-VECCHIA ]
  ! grep -q "reload" "$CALLS"
}

@test "st_sshd_remove con più nomi toglie drop-in, CA e i loro principal" {
  st_sshd_apply "ssh-ed25519 AAAA ca" mario anna
  run st_sshd_remove mario anna
  [ "$status" -eq 0 ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSH_CF_PRINCIPALS/mario" ]
  [ ! -e "$SSH_CF_PRINCIPALS/anna" ]
}

# --- enable, add-user, remove-user, set-sudo, disable, status con gli utenti (1.11.0) ---

# add_people NOME... — aggiunge persone (nome@y.it, senza sudo) a un accesso attivo.
add_people() {
  local n
  for n in "$@"; do
    st_add_user "$n@y.it" false || return 1
  done
  : >"$CFLOG"
  : >"$CALLS"
}

# call_line PATTERN — numero della prima riga di CALLS che corrisponde.
call_line() {
  grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1
}

@test "st_enable crea l'utente prima di sshd, con sudo; stato users e policy con l'email" {
  cf_env
  CF_OTP=1 run st_enable ssh-k3f9x2 manu@x.it true
  [ "$status" -eq 0 ]
  grep -qx "useradd -m -s /bin/bash -c vps-ssh-tunnel manu" "$CALLS"
  [ "$(cat "$SUDOERS_D/vps-ssh-manu")" = "manu ALL=(ALL) NOPASSWD:ALL" ]
  [ "$(jq -c .users "$SSHTUNNEL_STATE")" = '[{"email":"manu@x.it","user":"manu","sudo":true}]' ]
  ! jq -e 'has("emails") or has("user")' "$SSHTUNNEL_STATE"
  grep -- '--data' "$CALLS" | grep '"decision":"allow"' | grep -q '{"email":{"email":"manu@x.it"}}'
  [ "$(call_line '^useradd')" -lt "$(call_line '^sshd -t')" ]
  grep -qx "AllowUsers manu" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
}

@test "st_enable senza sudo: nessun sudoers, stato sudo false" {
  cf_env
  CF_OTP=1 run st_enable ssh-k3f9x2 manu@x.it false
  [ "$status" -eq 0 ]
  [ ! -e "$SUDOERS_D/vps-ssh-manu" ]
  [ "$(jq -r '.users[0].sudo' "$SSHTUNNEL_STATE")" = false ]
}

# enable_fails — st_enable che fallisce (le variabili di guasto sono già esportate):
# l'utente creato deve sparire con tutto il resto.
enable_fails() {
  local rc=0
  CF_OTP=1 st_enable ssh-k3f9x2 manu@x.it true || rc=$?
  [ "$rc" -eq 1 ]
  grep -qx "useradd -m -s /bin/bash -c vps-ssh-tunnel manu" "$CALLS"
  grep -qx "userdel -r manu" "$CALLS"
  ! grep -q '^manu:' "$PASSWD_FAKE"
  [ -z "$(ls -A "$SUDOERS_D")" ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_PRINCIPALS/manu" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_enable: fallimento sulla CA → utente eliminato, niente sudoers né drop-in" {
  cf_env
  export CF_FAIL="POST:*/ca"
  enable_fails
}

@test "st_enable: fallimento nella creazione del tunnel → utente eliminato" {
  cf_env
  export CF_FAIL="POST:/accounts/acc1/cfd_tunnel"
  enable_fails
}

@test "st_enable: sshd -t che fallisce → utente eliminato" {
  cf_env
  export SSHD_FAIL=1
  enable_fails
}

@test "st_enable: reload di sshd fallito → utente eliminato" {
  cf_env
  export RELOAD_FAIL=1
  enable_fails
}

@test "st_enable: visudo che fallisce → utente eliminato" {
  cf_env
  export VISUDO_FAIL=1
  enable_fails
}

@test "st_enable: utente omonimo già esistente (root, creato a mano, nostro GECOS fuori stato) → rifiutato, nessuna chiamata" {
  cf_env
  echo "root:x:0:0:root:/root:/bin/bash" >>"$PASSWD_FAKE"
  echo "anna:x:1002:1002:Anna:/home/anna:/bin/bash" >>"$PASSWD_FAKE"
  echo "bob:x:1003:1003:vps-ssh-tunnel:/home/bob:/bin/bash" >>"$PASSWD_FAKE"
  local e rc
  for e in root@x.it anna@x.it bob@x.it; do
    rc=0
    CF_OTP=1 st_enable ssh-k3f9x2 "$e" true || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ST_ERR" = "l'utente ${e%%@*} esiste già sulla VPS e non è stato creato dall'accesso SSH" ]
  done
  [ ! -s "$CFLOG" ]
  ! grep -qE '^(useradd|userdel|usermod)' "$CALLS"
}

@test "st_enable: sudo non booleano o nome utente non valido → rifiutato" {
  cf_env
  rc=0; st_enable ssh-k3f9x2 manu@x.it yes || rc=$?; [ "$rc" -eq 1 ]
  rc=0; st_enable ssh-k3f9x2 manu@x.it || rc=$?; [ "$rc" -eq 1 ]
  rc=0; st_enable ssh-k3f9x2 'mario+x@x.it' true || rc=$?; [ "$rc" -eq 1 ]
  [ ! -s "$CFLOG" ]
  ! grep -q '^useradd' "$CALLS"
}

@test "st_add_user: utente senza sudoers, drop-in con tutti, policy con due email DOPO useradd" {
  cf_enabled
  rc=0
  st_add_user Anna@Y.it false || rc=$?
  [ "$rc" -eq 0 ]
  [ "$ST_USER" = anna ]
  grep -qx "useradd -m -s /bin/bash -c vps-ssh-tunnel anna" "$CALLS"
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  grep -qx "AllowUsers manu anna" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  grep -qx "Match User manu,anna" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  [ "$(cat "$SSH_CF_PRINCIPALS/anna")" = anna ]
  pol="$(grep -- '--data' "$CALLS" | grep '"decision":"allow"' | tail -1)"
  [[ "$pol" == *'{"email":{"email":"manu@x.it"}}'* && "$pol" == *'{"email":{"email":"anna@y.it"}}'* ]]
  # La policy per ultima: prima l'utente e sshd, poi Cloudflare.
  [ "$(call_line '^useradd')" -lt "$(call_line 'policies/pol1')" ]
  [ "$(call_line '^systemctl reload ssh')" -lt "$(call_line 'policies/pol1')" ]
  [ "$(jq -c '.users' "$SSHTUNNEL_STATE")" = '[{"email":"manu@x.it","user":"manu","sudo":true},{"email":"anna@y.it","user":"anna","sudo":false}]' ]
}

@test "st_add_user con sudo scrive il sudoers" {
  cf_enabled
  st_add_user anna@y.it true
  [ "$(cat "$SUDOERS_D/vps-ssh-anna")" = "anna ALL=(ALL) NOPASSWD:ALL" ]
  [ "$(jq -r '.users[1].sudo' "$SSHTUNNEL_STATE")" = true ]
}

@test "st_add_user: policy che fallisce → utente eliminato, drop-in solo con manu" {
  cf_enabled
  rc=0
  CF_FAIL="PUT:/accounts/acc1/access/policies/pol1" st_add_user anna@y.it true || rc=$?
  [ "$rc" -eq 1 ]
  [ -n "$ST_ERR" ]
  grep -qx "userdel -r anna" "$CALLS"
  ! grep -q '^anna:' "$PASSWD_FAKE"
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  [ ! -e "$SSH_CF_PRINCIPALS/anna" ]
  grep -qx "AllowUsers manu" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  grep -qx "Match User manu" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  [ "$(cat "$SSH_CF_PRINCIPALS/manu")" = manu ]
  [ "$(jq -c '[.users[].email]' "$SSHTUNNEL_STATE")" = '["manu@x.it"]' ]
}

@test "st_add_user: sshd o sudoers che falliscono → utente eliminato, policy mai toccata" {
  cf_enabled
  rc=0
  SSHD_FAIL=1 st_add_user anna@y.it true || rc=$?
  [ "$rc" -eq 1 ]
  grep -qx "userdel -r anna" "$CALLS"
  ! grep -q 'policies/pol1' "$CALLS"
  grep -qx "AllowUsers manu" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  : >"$CALLS"
  rc=0
  VISUDO_FAIL=1 st_add_user anna@y.it true || rc=$?
  [ "$rc" -eq 1 ]
  grep -qx "userdel -r anna" "$CALLS"
  ! grep -q '^anna:' "$PASSWD_FAKE"
  ! grep -q 'policies/pol1' "$CALLS"
}

@test "st_add_user: duplicato, utente estraneo, nome non valido, 6ª persona → rifiutati senza modifiche" {
  cf_enabled
  add_people anna
  local rc
  # stesso nome utente con un'altra email (maiuscole comprese)
  rc=0; st_add_user ANNA@z.it false || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ST_ERR" = "c'è già una persona con il nome utente anna" ]
  # utente estraneo
  echo "root:x:0:0:root:/root:/bin/bash" >>"$PASSWD_FAKE"
  # con una cartella in /home il messaggio resta quello dell'utente estraneo
  mkdir -p "$HOME_BASE/root"
  rc=0; st_add_user root@x.it true || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ST_ERR" = "l'utente root esiste già sulla VPS e non è stato creato dall'accesso SSH" ]
  rc=0; st_add_user 'm+x@x.it' true || rc=$?
  [ "$rc" -eq 1 ]
  add_people bob carl dina
  [ "$(jq '.users | length' "$SSHTUNNEL_STATE")" -eq 5 ]
  : >"$CFLOG"; : >"$CALLS"
  rc=0; st_add_user eva@y.it false || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ST_ERR" = "massimo 5 persone" ]
  [ ! -s "$CFLOG" ]
  ! grep -qE '^(useradd|userdel|usermod|sshd|systemctl)' "$CALLS"
  [ "$(jq '.users | length' "$SSHTUNNEL_STATE")" -eq 5 ]
}

@test "st_add_user: stato 1.10.0 (senza users) → chiede di disattivare" {
  cf_enabled
  jq 'del(.users) | .emails = ["manu@x.it"] | .user = "manu"' "$SSHTUNNEL_STATE" >"$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$SSHTUNNEL_STATE"
  rc=0; st_add_user anna@y.it false || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$ST_ERR" == *"versione precedente"* ]]
  ! grep -q '^useradd' "$CALLS"
}

@test "st_remove_user: policy aggiornata PRIMA di userdel; stato con solo manu" {
  cf_enabled
  add_people anna
  echo "anna ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-anna"
  rc=0
  st_remove_user Anna@y.it || rc=$?
  [ "$rc" -eq 0 ]
  [ "$ST_USER" = anna ]
  pol="$(grep -- '--data' "$CALLS" | grep '"decision":"allow"' | tail -1)"
  [[ "$pol" == *'"manu@x.it"'* && "$pol" != *'anna@y.it'* ]]
  [ "$(call_line 'policies/pol1')" -lt "$(call_line '^userdel')" ]
  [ "$(call_line 'policies/pol1')" -lt "$(call_line '^pkill')" ]
  ! grep -q '^anna:' "$PASSWD_FAKE"
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  [ ! -e "$SSH_CF_PRINCIPALS/anna" ]
  grep -qx "AllowUsers manu" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  [ "$(jq -c '[.users[].user]' "$SSHTUNNEL_STATE")" = '["manu"]' ]
}

@test "st_remove_user: policy che fallisce → nessuna userdel, anna ancora nello stato e in sshd" {
  cf_enabled
  add_people anna
  rc=0
  CF_FAIL="PUT:/accounts/acc1/access/policies/pol1" st_remove_user anna@y.it || rc=$?
  [ "$rc" -eq 1 ]
  [ -n "$ST_ERR" ]
  ! grep -qE '^(userdel|pkill|loginctl|sshd|systemctl)' "$CALLS"
  grep -q '^anna:' "$PASSWD_FAKE"
  [ "$(cat "$SSH_CF_PRINCIPALS/anna")" = anna ]
  grep -qx "AllowUsers manu anna" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  [ "$(jq -c '[.users[].user]' "$SSHTUNNEL_STATE")" = '["manu","anna"]' ]
}

@test "st_remove_user: userdel che fallisce → policy, sshd e principal rimessi, stato intatto" {
  cf_enabled
  add_people anna
  rc=0
  USERDEL_FAIL=1 st_remove_user anna@y.it || rc=$?
  [ "$rc" -eq 1 ]
  grep -q '^anna:' "$PASSWD_FAKE"
  # l'ultimo PUT della policy riporta anna
  last="$(grep -- '"decision":"allow"' "$CALLS" | tail -1)"
  [[ "$last" == *'anna@y.it'* ]]
  [ "$(cat "$SSH_CF_PRINCIPALS/anna")" = anna ]
  grep -qx "AllowUsers manu anna" "$SSHD_CONFIG_D/20-vps-cfaccess.conf"
  [ "$(jq -c '[.users[].user]' "$SSHTUNNEL_STATE")" = '["manu","anna"]' ]
}

@test "st_remove_user: l'ultima persona, una persona assente o un utente non più nostro → rifiutati" {
  cf_enabled
  rc=0; st_remove_user manu@x.it || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ST_ERR" = "l'ultima persona non si può eliminare: per togliere tutto usa Disattiva" ]
  add_people anna
  rc=0; st_remove_user nessuno@y.it || rc=$?
  [ "$rc" -eq 1 ]
  # anna diventa di qualcun altro (GECOS cambiato): non si elimina
  sed -i 's/^anna:x:1001:1001:vps-ssh-tunnel/anna:x:1001:1001:Anna/' "$PASSWD_FAKE"
  rc=0; st_remove_user anna@y.it || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$CFLOG" ]
  ! grep -qE '^(userdel|pkill|loginctl)' "$CALLS"
  [ "$(jq '.users | length' "$SSHTUNNEL_STATE")" -eq 2 ]
}

@test "st_set_sudo: scrive e toglie il sudoers, stato aggiornato" {
  cf_enabled
  add_people anna
  rc=0; st_set_sudo anna@y.it true || rc=$?
  [ "$rc" -eq 0 ]
  [ "$ST_USER" = anna ]
  [ "$(stat -c %a "$SUDOERS_D/vps-ssh-anna")" = 440 ]
  [ "$(jq -r '.users[1].sudo' "$SSHTUNNEL_STATE")" = true ]
  st_set_sudo anna@y.it false
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  [ "$(jq -r '.users[1].sudo' "$SSHTUNNEL_STATE")" = false ]
  [ ! -s "$CFLOG" ]
}

@test "st_set_sudo: visudo che fallisce, persona assente o utente non più nostro → rifiutato, stato intatto" {
  cf_enabled
  add_people anna
  rc=0; VISUDO_FAIL=1 st_set_sudo anna@y.it true || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(jq -r '.users[1].sudo' "$SSHTUNNEL_STATE")" = false ]
  rc=0; st_set_sudo nessuno@y.it true || rc=$?
  [ "$rc" -eq 1 ]
  sed -i 's/^anna:x:1001:1001:vps-ssh-tunnel/anna:x:1001:1001:Anna/' "$PASSWD_FAKE"
  rc=0; st_set_sudo anna@y.it true || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  [ "$(jq -r '.users[1].sudo' "$SSHTUNNEL_STATE")" = false ]
}

@test "add-user, remove-user e set-sudo con una persona sparita o non nostra → rifiutati, nulla cambia" {
  cf_enabled
  add_people anna
  before="$(cat "$SSHTUNNEL_STATE")"
  # anna cancellata a mano: lo stato la tiene ancora
  sed -i '/^anna:/d' "$PASSWD_FAKE"
  : >"$CALLS"
  for cmd in "st_add_user bob@y.it false" "st_remove_user manu@x.it" "st_set_sudo manu@x.it true"; do
    rc=0; $cmd || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$ST_ERR" == *"usa Disattiva"* ]]
  done
  [ ! -s "$CFLOG" ]
  [ "$(cat "$SSHTUNNEL_STATE")" = "$before" ]
  ! grep -qE '^(useradd|userdel)' "$CALLS"
  [ ! -e "$SSH_CF_PRINCIPALS/bob" ]
}

@test "st_disable con uno stato senza nomi validi toglie comunque drop-in e CA" {
  cf_enabled
  jq 'del(.users) | del(.emails) | del(.user)' "$SSHTUNNEL_STATE" >"$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$SSHTUNNEL_STATE"
  [ -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  run st_disable
  [ "$status" -eq 0 ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_CA" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_disable elimina gli utenti dello stato, non quelli estranei" {
  cf_enabled
  add_people anna
  echo "anna ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-anna"
  # un terzo nello stato che sulla VPS è di qualcun altro (root): mai toccato
  echo "root:x:0:0:root:/root:/bin/bash" >>"$PASSWD_FAKE"
  jq '.users += [{email: "root@x.it", user: "root", sudo: false}]' "$SSHTUNNEL_STATE" >"$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$SSHTUNNEL_STATE"
  run st_disable
  [ "$status" -eq 0 ]
  grep -qx "userdel -r manu" "$CALLS"
  grep -qx "userdel -r anna" "$CALLS"
  ! grep -qE '^(userdel|pkill|loginctl|crontab).* root( |$)' "$CALLS"
  grep -q '^root:' "$PASSWD_FAKE"
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  [ ! -e "$SSHD_CONFIG_D/20-vps-cfaccess.conf" ]
  [ ! -e "$SSH_CF_PRINCIPALS/anna" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_disable con stato 1.10.0: toglie i principal vecchi, non elimina nessun utente" {
  cf_enabled
  jq 'del(.users) | .emails = ["manuele@x.it"] | .user = "manu"' "$SSHTUNNEL_STATE" >"$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$SSHTUNNEL_STATE"
  echo manuele >"$SSH_CF_PRINCIPALS/manuele"
  : >"$CALLS"
  run st_disable
  [ "$status" -eq 0 ]
  [ ! -e "$SSH_CF_PRINCIPALS/manuele" ]
  ! grep -q '^userdel' "$CALLS"
  grep -q '^manu:' "$PASSWD_FAKE"
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_disable: eliminazione di un utente fallita → errore e stato conservato" {
  cf_enabled
  rc=0
  USERDEL_FAIL=1 st_disable || rc=$?
  [ "$rc" -eq 1 ]
  [ -f "$SSHTUNNEL_STATE" ]
  [[ "$ST_ERR" == *manu* ]]
}

@test "st_status_json: stato 1.10.0 → drift users; utente sparito o non più nostro → drift users" {
  cf_enabled
  cp "$SSHTUNNEL_STATE" "$BATS_TEST_TMPDIR/nuovo.json"
  jq 'del(.users) | .emails = ["manu@x.it"] | .user = "manu"' "$BATS_TEST_TMPDIR/nuovo.json" >"$SSHTUNNEL_STATE"
  run --separate-stderr st_status_json
  jq -e '.enabled and .users == [] and (.drift | index("users"))' <<<"$output"
  # stato nuovo ma l'utente non esiste più sulla VPS
  cp "$BATS_TEST_TMPDIR/nuovo.json" "$SSHTUNNEL_STATE"
  : >"$PASSWD_FAKE"
  run --separate-stderr st_status_json
  jq -e '.users == [{email:"manu@x.it",user:"manu",sudo:true}] and .drift == ["users"]' <<<"$output"
  # utente presente ma non più nostro
  echo "manu:x:1000:1000:Manu:/home/manu:/bin/bash" >"$PASSWD_FAKE"
  run --separate-stderr st_status_json
  jq -e '.drift == ["users"]' <<<"$output"
  echo "manu:x:1000:1000:vps-ssh-tunnel:/home/manu:/bin/bash" >"$PASSWD_FAKE"
  run --separate-stderr st_status_json
  jq -e '.drift == []' <<<"$output"
}

@test "st_user_delete di un account estraneo: toglie il nostro sudoers e principal, non tocca l'account" {
  user_stubs
  echo "anna:x:1002:1002:Anna:/home/anna:/bin/bash" >>"$PASSWD_FAKE"
  echo "anna ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-anna"
  mkdir -p "$SSH_CF_PRINCIPALS"
  echo anna >"$SSH_CF_PRINCIPALS/anna"
  run st_user_delete anna
  [ "$status" -eq 2 ]
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  [ ! -e "$SSH_CF_PRINCIPALS/anna" ]
  grep -q '^anna:' "$PASSWD_FAKE"
  ! grep -qE '^(userdel|pkill|loginctl|crontab|find|atrm|usermod)' "$CALLS"
}

@test "st_disable con un account estraneo omonimo: lo lascia, ma il nostro sudoers non sopravvive" {
  cf_enabled
  add_people anna
  echo "anna ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_D/vps-ssh-anna"
  sed -i 's/^anna:x:1001:1001:vps-ssh-tunnel/anna:x:1001:1001:Anna/' "$PASSWD_FAKE"
  run st_disable
  [ "$status" -eq 0 ]
  grep -q '^anna:' "$PASSWD_FAKE"
  ! grep -qx "userdel -r anna" "$CALLS"
  [ ! -e "$SUDOERS_D/vps-ssh-anna" ]
  [ ! -e "$SSHTUNNEL_STATE" ]
}

@test "st_user_create e add-user: una /home/<nome> già presente → rifiutato, nessuna chiamata" {
  user_stubs
  mkdir -p "$HOME_BASE/mario"
  run st_user_create mario
  [ "$status" -eq 1 ]
  ! grep -q '^useradd' "$CALLS"
  [ -d "$HOME_BASE/mario" ]
  cf_enabled
  mkdir -p "$HOME_BASE/anna"
  rc=0; st_add_user anna@y.it false || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$ST_ERR" == *"esiste già sulla VPS"* ]]
  ! grep -q '^useradd' "$CALLS"
  [ -d "$HOME_BASE/anna" ]
}

@test "il rilancio in systemd-run e il lucchetto coprono tutti i comandi che modificano" {
  t="$REPO_ROOT/tools/vps-ssh-tunnel"
  grep -qE '^  enable \| add-user \| remove-user \| set-sudo \| set-host \| disable\)' "$t"
  local c
  for c in enable add-user remove-user set-sudo set-host disable; do
    # ogni ramo del case finale prende il lucchetto prima di leggere o agire
    awk -v c="$c" '$0 ~ "^  " c "\)" { f = 1; next } f && /^    ;;/ { exit } f && /lock_or_die/ { ok = 1 } END { exit !ok }' "$t"
  done
}

@test "_st_rollback: l'avviso di annullamento incompleto non parla solo di Cloudflare" {
  cf_env
  rc=0
  CF_FAIL="POST:*/ca DELETE:/accounts/acc1/access/apps/app1" st_enable ssh-k3f9x2 manu@x.it true || rc=$?
  [[ "$ST_ERR" == *"controlla Cloudflare e la VPS"* ]]
}
