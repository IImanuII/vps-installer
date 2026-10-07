setup() {
  load test_helper
  setup_common
}

ips_fixture() {
  printf '173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n190.93.240.0/20\n188.114.96.0/20\n197.234.240.0/22\n198.41.128.0/17\n162.158.0.0/15\n104.16.0.0/13\n104.24.0.0/14\n172.64.0.0/13\n131.0.72.0/22\n'
}

@test "cf_fetch_ips unisce v4 e v6 e scarta righe strane" {
  make_stub curl '
case "${*: -1}" in
  *ips-v4) printf "173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n190.93.240.0/20\n188.114.96.0/20\n<html>\n" ;;
  *ips-v6) printf "2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n" ;;
esac'
  run cf_fetch_ips
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
  [[ "$output" != *html* ]]
  [[ "$output" == *"2606:4700::/32"* ]]
}

@test "cf_fetch_ips fallisce con una lista troppo corta" {
  make_stub curl 'echo "1.2.3.0/24"'
  run cf_fetch_ips
  [ "$status" -eq 1 ]
}

@test "cf_fetch_ips fallisce se curl fallisce" {
  make_stub curl 'exit 22'
  run cf_fetch_ips
  [ "$status" -eq 1 ]
}

@test "realip_snippet" {
  run realip_snippet < <(printf '173.245.48.0/20\n2400:cb00::/32\n')
  [[ "$output" == *"set_real_ip_from 173.245.48.0/20;"* ]]
  [[ "$output" == *"set_real_ip_from 2400:cb00::/32;"* ]]
  [[ "$output" == *"real_ip_header CF-Connecting-IP;"* ]]
}

@test "ufw_stale_rules trova solo le regole obsolete, dalla più alta" {
  local status_out
  status_out='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 41822/tcp                  ALLOW IN    Anywhere                   # ssh
[ 2] 80,443/tcp                 ALLOW IN    173.245.48.0/20            # cloudflare
[ 3] 80,443/tcp                 ALLOW IN    9.9.9.0/24                 # cloudflare
[ 4] 41822/tcp (v6)             ALLOW IN    Anywhere (v6)              # ssh
[ 5] 80,443/tcp (v6)            ALLOW IN    2400:cb00::/32             # cloudflare
[ 6] 80,443/tcp (v6)            ALLOW IN    2001:db8::/32              # cloudflare'
  run ufw_stale_rules cloudflare $'173.245.48.0/20\n2400:cb00::/32' <<<"$status_out"
  [ "${lines[0]}" = "6" ]
  [ "${lines[1]}" = "3" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "cf_apply_ips senza blocco scrive solo lo snippet" {
  export NGINX_SNIPPETS="$BATS_TEST_TMPDIR/snippets"
  cf_fetch_ips() { ips_fixture; }
  make_stub ufw 'echo "ufw $*" >>"$BATS_TEST_TMPDIR/ufw.log"'
  make_stub systemctl 'exit 3'
  cf_apply_ips no
  grep -q "set_real_ip_from 173.245.48.0/20;" "$NGINX_SNIPPETS/cloudflare-realip.conf"
  [ ! -f "$BATS_TEST_TMPDIR/ufw.log" ]
}

@test "cf_apply_ips con blocco aggiunge le regole cloudflare" {
  export NGINX_SNIPPETS="$BATS_TEST_TMPDIR/snippets"
  cf_fetch_ips() { ips_fixture; }
  make_stub ufw 'echo "ufw $*" >>"$BATS_TEST_TMPDIR/ufw.log"'
  make_stub systemctl 'exit 3'
  cf_apply_ips yes
  grep -q "allow proto tcp from 173.245.48.0/20 to any port 80,443 comment cloudflare" "$BATS_TEST_TMPDIR/ufw.log"
}

@test "cf_fetch_ips scarta reti troppo ampie e /0" {
  make_stub curl '
case "${*: -1}" in
  *ips-v4) printf "0.0.0.0/0\n1.0.0.0/7\n2.0.0.0/8\n173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n190.93.240.0/20\n9.9.9.9/33\n" ;;
  *ips-v6) printf "::/0\n2000::/3\n2400::/11\n2400:cb00::/32\n2606:4700::/12\n" ;;
esac'
  run cf_fetch_ips
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]
  [[ "$output" == *"2.0.0.0/8"* ]]
  [[ "$output" == *"2606:4700::/12"* ]]
  for bad in 0.0.0.0/0 1.0.0.0/7 9.9.9.9/33 ::/0 2000::/3 2400::/11; do
    [[ $'\n'"$output"$'\n' != *$'\n'"$bad"$'\n'* ]] || { echo "accettata $bad"; return 1; }
  done
}

@test "cf_fetch_ips fallisce se restano troppo poche reti valide" {
  make_stub curl 'printf "0.0.0.0/0\n::/0\n1.0.0.0/1\n1.0.0.0/2\n1.0.0.0/3\n1.0.0.0/4\n1.0.0.0/5\n1.0.0.0/6\n1.0.0.0/7\n2000::/3\n2000::/4\n"'
  run cf_fetch_ips
  [ "$status" -eq 1 ]
}
