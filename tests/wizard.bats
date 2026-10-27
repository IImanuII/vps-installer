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

@test "wizard_cloudflare: token rifiutato, il menu non offre 'skip' e 'quit' esce con 1" {
  source "$REPO_ROOT/wizard.sh"
  make_stub whiptail '
for a in "$@"; do
  case "$a" in
    --yesno) exit 0 ;;
    --passwordbox) echo "abcdefghijklmnopqrstuvwxyz0123456789ABCD" >&2; exit 0 ;;
    --menu) printf "%s\n" "$@" >"$BATS_TEST_TMPDIR/menu"; echo quit >&2; exit 0 ;;
    --msgbox) exit 0 ;;
  esac
done
exit 1'
  cf_find_zone() { return 1; }
  server_ipv4() { return 1; }
  wizard_defaults
  PANEL_ENABLED=yes PANEL_DOMAIN=panel.example.com
  run wizard_cloudflare
  [ "$status" -eq 1 ]
  run grep -q skip "$BATS_TEST_TMPDIR/menu"
  [ "$status" -ne 0 ]
  grep -q retry "$BATS_TEST_TMPDIR/menu"
}

@test "wizard_cloudflare: senza pannello non chiede nulla e Cloudflare resta spento" {
  source "$REPO_ROOT/wizard.sh"
  make_stub whiptail 'printf "%s\n" "$@" >>"$BATS_TEST_TMPDIR/argv"; exit 0'
  server_ipv4() { return 1; }
  wizard_defaults
  PANEL_ENABLED=no
  wizard_cloudflare
  [ "$CF_ENABLED" = no ]
  run grep -s "Usi Cloudflare" "$BATS_TEST_TMPDIR/argv"
  [ "$status" -ne 0 ]
}

@test "wizard_cloudflare: col pannello Cloudflare e' obbligatorio e il token mostra i permessi" {
  source "$REPO_ROOT/wizard.sh"
  make_stub whiptail '
printf "%s\n" "$@" >>"$BATS_TEST_TMPDIR/argv"
for a in "$@"; do
  case "$a" in
    --passwordbox) echo "abcdefghijklmnopqrstuvwxyz0123456789ABCD" >&2; exit 0 ;;
    --yesno|--msgbox) exit 0 ;;
  esac
done
exit 1'
  cf_find_zone() { echo "zid example.com"; }
  cf_account_id() { echo acc; }
  cf_check_ssh_perms() { return 0; }
  cf_list_records() { return 1; }
  server_ipv4() { return 1; }
  wizard_defaults
  PANEL_ENABLED=yes PANEL_DOMAIN=panel.example.com
  wizard_cloudflare
  [ "$CF_ENABLED" = yes ]
  [ "$CF_ZONE" = example.com ]
  run grep -s "Usi Cloudflare" "$BATS_TEST_TMPDIR/argv"
  [ "$status" -ne 0 ]
  grep -q "Cloudflare Tunnel" "$BATS_TEST_TMPDIR/argv"
}

@test "wizard_cloudflare: permessi mancanti, menu 'mancano' e retry con token buono" {
  source "$REPO_ROOT/wizard.sh"
  make_stub whiptail '
for a in "$@"; do
  case "$a" in
    --passwordbox) echo "abcdefghijklmnopqrstuvwxyz0123456789ABCD" >&2; exit 0 ;;
    --menu) printf "%s\n" "$@" >>"$BATS_TEST_TMPDIR/menu"; echo retry >&2; exit 0 ;;
    --yesno|--msgbox) exit 0 ;;
  esac
done
exit 1'
  cf_find_zone() { echo "zid example.com"; }
  cf_account_id() { echo acc; }
  cf_check_ssh_perms() {
    local n; n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0)
    echo $((n+1)) >"$BATS_TEST_TMPDIR/n"
    if [ "$n" -eq 0 ]; then echo tunnel; return 1; fi
    return 0
  }
  cf_list_records() { return 1; }
  server_ipv4() { return 1; }
  wizard_defaults
  PANEL_ENABLED=yes PANEL_DOMAIN=panel.example.com
  wizard_cloudflare
  grep -q "mancano" "$BATS_TEST_TMPDIR/menu"
  grep -q "Cloudflare Tunnel" "$BATS_TEST_TMPDIR/menu"
  [ "$CF_ZONE" = example.com ]
  [ "$CF_ZONE_ID" = zid ]
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

@test "wizard_defaults prende l'IP del client SSH" {
  source "$REPO_ROOT/wizard.sh"
  SSH_CLIENT='198.51.100.9 50000 22' wizard_defaults
  [ "$SSH_IGNORE_IP" = 198.51.100.9 ]
  SSH_CLIENT= wizard_defaults
  [ "$SSH_IGNORE_IP" = "" ]
}

@test "wizard_cloudflare: permessi access/idp mancanti → il menu ricorda di attivare Zero Trust" {
  source "$REPO_ROOT/wizard.sh"
  make_stub whiptail '
for a in "$@"; do
  case "$a" in
    --yesno) exit 0 ;;
    --passwordbox) echo "abcdefghijklmnopqrstuvwxyz0123456789ABCD" >&2; exit 0 ;;
    --menu) printf "%s
" "$@" >"$BATS_TEST_TMPDIR/menu"; echo quit >&2; exit 0 ;;
    --msgbox) exit 0 ;;
  esac
done
exit 1'
  cf_find_zone() { echo "zone1 example.com"; }
  cf_account_id() { echo acc1; }
  cf_check_ssh_perms() { printf '%s
' "$MISSING"; return 1; }
  server_ipv4() { return 1; }
  wizard_defaults
  PANEL_ENABLED=yes PANEL_DOMAIN=panel.example.com
  MISSING=access run wizard_cloudflare
  [ "$status" -eq 1 ]
  grep -q "Zero Trust non è ancora attivo" "$BATS_TEST_TMPDIR/menu"
  rm -f "$BATS_TEST_TMPDIR/menu"
  MISSING=tunnel run wizard_cloudflare
  [ "$status" -eq 1 ]
  ! grep -q "Zero Trust non è ancora attivo" "$BATS_TEST_TMPDIR/menu"
}
