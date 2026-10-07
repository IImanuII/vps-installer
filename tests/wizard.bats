setup() {
  load test_helper
  setup_common
}

@test "wizard.sh si carica senza eseguire main" {
  run bash -c "source '$REPO_ROOT/wizard.sh'; declare -F ask_input wizard_cloudflare wizard_summary >/dev/null"
  [ "$status" -eq 0 ]
}

@test "wizard_defaults azzera tutte le risposte" {
  source "$REPO_ROOT/wizard.sh"
  ADMIN_USER=vecchio
  wizard_defaults
  [ "$ADMIN_USER" = "" ]
  [ "$WANT_NGINX" = no ]
  [ "$CF_ENABLED" = no ]
}

@test "wizard_cloudflare: token rifiutato, 'skip' disattiva Cloudflare" {
  source "$REPO_ROOT/wizard.sh"
  make_stub whiptail '
for a in "$@"; do
  case "$a" in
    --yesno) exit 0 ;;
    --passwordbox) echo "abcdefghijklmnopqrstuvwxyz0123456789ABCD" >&2; exit 0 ;;
    --menu) echo skip >&2; exit 0 ;;
    --msgbox) exit 0 ;;
  esac
done
exit 1'
  cf_find_zone() { return 1; }
  server_ipv4() { return 1; }
  wizard_defaults
  PANEL_ENABLED=yes PANEL_DOMAIN=panel.example.com
  wizard_cloudflare
  [ "$CF_ENABLED" = no ]
  [ "$CF_API_TOKEN" = "" ]
  [ "$CF_ZONE_ID" = "" ]
}

@test "ask_input non ripropone la chiave rifiutata come default" {
  source "$REPO_ROOT/wizard.sh"
  make_stub whiptail '
case "$*" in
  *--inputbox*) printf "%s\n" "$@" >>"$BATS_TEST_TMPDIR/argv"; n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0)
    echo $((n+1)) >"$BATS_TEST_TMPDIR/n"
    if [ "$n" -eq 0 ]; then echo "PRIVATE-SECRET" >&2; else echo good >&2; fi; exit 0 ;;
  *--msgbox*) exit 0 ;;
esac
exit 1'
  v_ok() { [[ "$1" == good ]]; }
  ask_input ADMIN_PUBKEY "testo" "" v_ok "errore"
  [ "$ADMIN_PUBKEY" = good ]
  run grep -c PRIVATE-SECRET "$BATS_TEST_TMPDIR/argv"
  [ "$output" = 0 ]
}
