setup() {
  load test_helper
  setup_common
  source "$REPO_ROOT/steps/85-panel.sh"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  CF_ENABLED=yes CF_ZONE_ID=zone123 PANEL_DOMAIN=panel.miosito.it
  server_ipv4() { echo 203.0.113.10; }
  server_ipv6() { echo ""; }
  cf_upsert_record() { echo "upsert $*" >>"$CALLS"; }
  cf_remove_records() { echo "remove $*" >>"$CALLS"; }
}

@test "panel_dns: risposta yes = replace e rimuove AAAA vecchi senza IPv6" {
  CF_DNS_REPLACE=yes
  panel_dns
  grep -qx "upsert zone123 A panel.miosito.it 203.0.113.10 replace" "$CALLS"
  grep -qx "remove zone123 panel.miosito.it AAAA" "$CALLS"
}

@test "panel_dns: risposta no = keep e nota nel riepilogo se un record è stato lasciato" {
  CF_DNS_REPLACE=no
  cf_upsert_record() { echo "upsert $*" >>"$CALLS"; CF_DNS_KEPT="CNAME → miosito.it"; }
  panel_dns
  grep -qx "upsert zone123 A panel.miosito.it 203.0.113.10 keep" "$CALLS"
  run grep -q "^remove" "$CALLS"
  [ "$status" -ne 0 ]
  summary_load
  [[ "$CF_DNS_NOTE" == *"CNAME → miosito.it"* ]]
  [[ "$CF_DNS_NOTE" == *"203.0.113.10"* ]]
}

@test "panel_dns: risposte vecchie (vuota) = comportamento della 1.0.2" {
  CF_DNS_REPLACE=""
  panel_dns
  grep -qx "upsert zone123 A panel.miosito.it 203.0.113.10 " "$CALLS"
  run grep -q "^remove" "$CALLS"
  [ "$status" -ne 0 ]
}

@test "panel_dns: con IPv6 aggiorna anche AAAA" {
  CF_DNS_REPLACE=yes
  server_ipv6() { echo 2001:db8:100::1; }
  panel_dns
  grep -qx "upsert zone123 AAAA panel.miosito.it 2001:db8:100::1 replace" "$CALLS"
}

@test "wizard_dns_records: conflitto + scelta keep imposta CF_DNS_REPLACE=no" {
  source "$REPO_ROOT/wizard.sh"
  PANEL_ENABLED=yes CF_ZONE_ID=zone123 PANEL_DOMAIN=panel.miosito.it CF_API_TOKEN=x
  server_ipv4() { echo 203.0.113.10; }
  server_ipv6() { echo ""; }
  cf_list_records() { echo '{"success":true,"result":[{"type":"CNAME","name":"panel.miosito.it","content":"miosito.it"}]}'; }
  ask_menu() { echo "$2" >"$BATS_TEST_TMPDIR/menu"; printf -v "$1" keep; }
  wizard_dns_records
  [ "$CF_DNS_REPLACE" = no ]
  grep -q "CNAME panel.miosito.it → miosito.it" "$BATS_TEST_TMPDIR/menu"
}

@test "wizard_dns_records: nessun conflitto = nessuna domanda e replace" {
  source "$REPO_ROOT/wizard.sh"
  PANEL_ENABLED=yes CF_ZONE_ID=zone123 PANEL_DOMAIN=panel.miosito.it CF_API_TOKEN=x
  server_ipv4() { echo 203.0.113.10; }
  server_ipv6() { echo ""; }
  cf_list_records() { echo '{"success":true,"result":[]}'; }
  ask_menu() { echo chiamato >"$BATS_TEST_TMPDIR/menu"; }
  wizard_dns_records
  [ "$CF_DNS_REPLACE" = yes ]
  [ ! -f "$BATS_TEST_TMPDIR/menu" ]
}

@test "riepilogo finale mostra l'avviso sul DNS lasciato com'è" {
  source "$REPO_ROOT/steps/99-finalize.sh"
  ADMIN_USER=manu SSH_PORT=41822 PANEL_ENABLED=yes WANT_PMA=no MAIL_ENABLED=no CF_ENABLED=yes
  summary_set CF_DNS_NOTE "panel.miosito.it lasciato com'è su Cloudflare (CNAME → miosito.it)"
  run finalize_summary_text
  [[ "$output" == *"ATTENZIONE:"*"CNAME → miosito.it"* ]]
}
