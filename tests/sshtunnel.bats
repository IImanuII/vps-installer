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
