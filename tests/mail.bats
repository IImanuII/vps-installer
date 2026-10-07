setup() {
  load test_helper
  setup_common
  export MSMTPRC_LINK="$BATS_TEST_TMPDIR/msmtprc-link" ALIASES_FILE="$BATS_TEST_TMPDIR/aliases"
  SMTP_HOST=smtp.gmail.com SMTP_PORT=587 SMTP_USER=manu@gmail.com
  SMTP_PASS='ab"c\d$e' SMTP_FROM=manu@gmail.com ALERT_EMAIL=avvisi@gmail.com
}

@test "mail_escape protegge virgolette e backslash" {
  run mail_escape 'a"b\c'
  [ "$output" = 'a\"b\\c' ]
}

@test "mail_render_config scrive msmtprc, symlink e alias" {
  mail_render_config
  local f="$VPS_OPT/secrets/msmtprc"
  [ "$(stat -c %a "$f")" = "600" ]
  grep -qxF 'host smtp.gmail.com' "$f"
  grep -qxF 'tls_starttls on' "$f"
  grep -qxF 'password "ab\"c\\d$e"' "$f"
  [ "$(readlink "$MSMTPRC_LINK")" = "$f" ]
  grep -qxF 'root: avvisi@gmail.com' "$ALIASES_FILE"
}

@test "porta 465 usa TLS diretto" {
  SMTP_PORT=465
  mail_render_config
  grep -qxF 'tls_starttls off' "$VPS_OPT/secrets/msmtprc"
}
