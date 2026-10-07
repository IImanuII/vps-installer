setup() {
  load test_helper
  setup_common
}

@test "server_ipv4 legge l'indirizzo sorgente" {
  make_stub ip 'echo "1.1.1.1 via 203.0.113.1 dev ens3 src 203.0.113.10 uid 0"'
  run server_ipv4
  [ "$output" = "203.0.113.10" ]
}

@test "server_ipv6 prende il primo globale non deprecato" {
  make_stub ip 'cat <<EOF
2: ens3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet6 2001:db8:100::dead/56 scope global deprecated
    inet6 2001:db8:100::1:2cf7/56 scope global
EOF'
  run server_ipv6
  [ "$output" = "2001:db8:100::1:2cf7" ]
}

@test "server_ipv6 vuoto se non c'è IPv6" {
  make_stub ip 'true'
  run server_ipv6
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "dns_points_here" {
  make_stub getent 'printf "203.0.113.10     STREAM panel.miosito.it\n203.0.113.10     DGRAM\n"'
  dns_points_here panel.miosito.it 203.0.113.10
  run dns_points_here panel.miosito.it 1.2.3.4
  [ "$status" -ne 0 ]
}

@test "dns_points_here fallisce se il dominio non risolve" {
  make_stub getent 'exit 2'
  run dns_points_here panel.miosito.it 203.0.113.10
  [ "$status" -ne 0 ]
}

@test "domain_suffixes" {
  run domain_suffixes panel.miosito.it
  [ "${lines[0]}" = "panel.miosito.it" ]
  [ "${lines[1]}" = "miosito.it" ]
  [ "${#lines[@]}" -eq 2 ]
}
