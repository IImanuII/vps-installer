bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  setup_common
  export VPS_LIB="$REPO_ROOT/lib"
  T="$REPO_ROOT/tools/vps-f2b"
  # fail2ban-client finto: risponde come la 1.1 su Debian 13; annota le chiamate.
  make_stub fail2ban-client '
echo "$*" >>"$BATS_TEST_TMPDIR/f2b.calls"
[ -e "$BATS_TEST_TMPDIR/f2b.down" ] && exit 255
case "$*" in
  ping) echo "Server replied: pong" ;;
  status) printf "Status\n|- Number of jail:\t2\n\`- Jail list:\tsshd, nginx-limit\n" ;;
  "status sshd") printf "Status for the jail: sshd\n|- Filter\n|  |- Currently failed:\t3\n|  |- Total failed:\t40\n|  \`- Journal matches:\t_SYSTEMD_UNIT=ssh.service + _COMM=sshd\n\`- Actions\n   |- Currently banned:\t2\n   |- Total banned:\t7\n   \`- Banned IP list:\t203.0.113.7 2001:db8::5\n" ;;
  "status nginx-limit") printf "Status for the jail: nginx-limit\n|- Filter\n|  |- Currently failed:\t0\n|  |- Total failed:\t0\n|  \`- File list:\t/var/log/nginx/error.log\n\`- Actions\n   |- Currently banned:\t0\n   |- Total banned:\t0\n   \`- Banned IP list:\t\n" ;;
  "get sshd banip --with-time") printf "203.0.113.7 \t2026-10-26 22:00:00 + 3600 = 2026-10-26 23:00:00\n2001:db8::5 \t2026-10-26 22:10:00 + -1 = 9999-12-31 23:59:59\n" ;;
  "get nginx-limit banip --with-time") ;;
  "unban 203.0.113.7") echo 1 ;;
  unban*) echo 0 ;;
  *) exit 1 ;;
esac'
}

@test "vps-f2b status: jail, conteggi, IP con la fine del ban" {
  run bash "$T" status
  [ "$status" -eq 0 ]
  [ "$(jq -c '.jails[0]' <<<"$output")" = '{"name":"sshd","currently_failed":3,"total_banned":7,"banned":[{"ip":"203.0.113.7","until":"2026-10-26 23:00:00"},{"ip":"2001:db8::5","until":"9999-12-31 23:59:59"}]}' ]
  [ "$(jq -c '.jails[1]' <<<"$output")" = '{"name":"nginx-limit","currently_failed":0,"total_banned":0,"banned":[]}' ]
}

@test "vps-f2b status: fail2ban fermo, errore chiaro" {
  touch "$BATS_TEST_TMPDIR/f2b.down"
  run bash "$T" status
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"fail2ban non risponde"* ]]
}

@test "vps-f2b unban: sblocca da tutte le jail e dice quante" {
  run --separate-stderr bash "$T" unban 203.0.113.7
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"ip":"203.0.113.7","unbanned":1}' ]
  grep -qxF 'unban 203.0.113.7' "$BATS_TEST_TMPDIR/f2b.calls"
  run --separate-stderr bash "$T" unban 2001:db8::9
  [ "$(jq -r .unbanned <<<"$output")" = 0 ]
}

@test "vps-f2b unban: indirizzi non validi rifiutati senza chiamare fail2ban" {
  for ip in 256.1.1.1 1.2.3 "1.2.3.4 --all" "-x" 10.0.0.0/8 "a:b;rm" ""; do
    run bash "$T" unban "$ip"
    [ "$status" -eq 1 ]
    [[ "$(jq -r .error <<<"$output")" == *"non valido"* ]]
  done
  run bash "$T" unban 1.2.3.4 altro
  [ "$status" -eq 1 ]
  ! grep -q '^unban' "$BATS_TEST_TMPDIR/f2b.calls" 2>/dev/null
}

@test "vps-f2b: azione sconosciuta" {
  run bash "$T" ban 1.2.3.4
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
}

@test "f2b_valid_ip" {
  f2b_valid_ip 1.2.3.4
  f2b_valid_ip 255.255.255.255
  f2b_valid_ip ::1
  f2b_valid_ip 2001:db8::ffff:1.2.3.4
  ! f2b_valid_ip 1.2.3.256
  ! f2b_valid_ip 01.2.3
  ! f2b_valid_ip abc
  ! f2b_valid_ip "1.2.3.4 "
}

@test "sudoers: vps-f2b è consentito al pannello" {
  grep -qF '/opt/vps/bin/vps-f2b' "$REPO_ROOT/templates/sudoers-vps-panel"
}
