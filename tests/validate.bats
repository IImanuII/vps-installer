setup() {
  load test_helper
  setup_common
}

@test "domini" {
  valid_domain panel.miosito.it
  valid_domain miosito.it
  valid_domain a-b.c-d.example.com
  run valid_domain Panel.Miosito.it; [ "$status" -ne 0 ]
  run valid_domain miosito; [ "$status" -ne 0 ]
  run valid_domain -bad.it; [ "$status" -ne 0 ]
  run valid_domain "bad domain.it"; [ "$status" -ne 0 ]
  run valid_domain ""; [ "$status" -ne 0 ]
}

@test "hostname" {
  valid_hostname vps-01
  run valid_hostname vps.01; [ "$status" -ne 0 ]
  run valid_hostname -vps; [ "$status" -ne 0 ]
}

@test "username: formato e nomi riservati" {
  valid_username manu
  valid_username dev_ops-1
  run valid_username root; [ "$status" -ne 0 ]
  run valid_username debian; [ "$status" -ne 0 ]
  run valid_username panel; [ "$status" -ne 0 ]
  run valid_username site_foo; [ "$status" -ne 0 ]
  run valid_username 1manu; [ "$status" -ne 0 ]
  run valid_username Manu; [ "$status" -ne 0 ]
}

@test "porta SSH" {
  valid_port 22
  valid_port 2222
  valid_port 41822
  run valid_port 80; [ "$status" -ne 0 ]
  run valid_port 666; [ "$status" -ne 0 ]
  run valid_port 3306; [ "$status" -ne 0 ]
  run valid_port 65536; [ "$status" -ne 0 ]
  run valid_port 0022; [ "$status" -ne 0 ]
  run valid_port abc; [ "$status" -ne 0 ]
}

@test "porta SMTP" {
  valid_smtp_port 587
  valid_smtp_port 465
  run valid_smtp_port 26; [ "$status" -ne 0 ]
}

@test "password e righe" {
  valid_password 'Lunga-abbastanza!'
  run valid_password 'corta'; [ "$status" -ne 0 ]
  run valid_password $'abcdefghijkl\nmn'; [ "$status" -ne 0 ]
  valid_line 'utente@gmail.com'
  run valid_line ''; [ "$status" -ne 0 ]
  run valid_line $'a\rb'; [ "$status" -ne 0 ]
}

@test "email" {
  valid_email mario@example.com
  run valid_email mario; [ "$status" -ne 0 ]
  run valid_email 'a b@c.it'; [ "$status" -ne 0 ]
}

@test "fuso orario e locale" {
  mkdir -p "$BATS_TEST_TMPDIR/zi/Europe"
  touch "$BATS_TEST_TMPDIR/zi/Europe/Rome"
  ZONEINFO_DIR="$BATS_TEST_TMPDIR/zi" valid_timezone Europe/Rome
  ZONEINFO_DIR="$BATS_TEST_TMPDIR/zi" run valid_timezone Europe/Milano
  [ "$status" -ne 0 ]
  ZONEINFO_DIR="$BATS_TEST_TMPDIR/zi" run valid_timezone ../etc/passwd
  [ "$status" -ne 0 ]
  valid_locale it_IT.UTF-8
  run valid_locale it_IT; [ "$status" -ne 0 ]
}

@test "token Cloudflare (solo formato)" {
  valid_cf_token "$(printf 'a%.0s' {1..40})"
  run valid_cf_token "corto"; [ "$status" -ne 0 ]
  run valid_cf_token "con spazi $(printf 'a%.0s' {1..40})"; [ "$status" -ne 0 ]
}

@test "chiave SSH pubblica ed25519 valida" {
  ssh-keygen -q -t ed25519 -N '' -C 'manu@pc' -f "$BATS_TEST_TMPDIR/k"
  valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/k.pub")"
}

@test "chiave SSH: rifiuta privata, multilinea, spazzatura, RSA corta" {
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/k"
  run valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/k")"; [ "$status" -ne 0 ]
  run valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/k.pub")"$'\n'"$(cat "$BATS_TEST_TMPDIR/k.pub")"; [ "$status" -ne 0 ]
  run valid_ssh_pubkey "ssh-ed25519 nonbase64!!"; [ "$status" -ne 0 ]
  ssh-keygen -q -t rsa -b 1024 -N '' -f "$BATS_TEST_TMPDIR/r"
  run valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/r.pub")"; [ "$status" -ne 0 ]
}

@test "chiave SSH incollata da Windows passa dopo trim" {
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/k"
  valid_ssh_pubkey "$(trim "  $(cat "$BATS_TEST_TMPDIR/k.pub")"$' \r\n')"
}
