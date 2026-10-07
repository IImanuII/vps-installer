setup() {
  load test_helper
  setup_common
}

@test "le risposte sopravvivono a caratteri speciali" {
  ADMIN_USER=manu
  ADMIN_PASS=$'p@ss $word \'quote\' "dq" \back'
  SMTP_PASS='a$b`c'
  ADMIN_PUBKEY='ssh-ed25519 AAAAC3Nza manu@pc'
  answers_save
  [ "$(stat -c %a "$VPS_ANSWERS")" = "600" ]
  local expected_pass="$ADMIN_PASS" expected_smtp="$SMTP_PASS"
  unset ADMIN_USER ADMIN_PASS SMTP_PASS ADMIN_PUBKEY
  answers_load
  [ "$ADMIN_PASS" = "$expected_pass" ]
  [ "$SMTP_PASS" = "$expected_smtp" ]
  [ "$ADMIN_PUBKEY" = "ssh-ed25519 AAAAC3Nza manu@pc" ]
}

@test "answers_load esporta e calcola le variabili derivate" {
  ADMIN_USER=manu ROOT_LOGIN=no PANEL_DOMAIN=panel.miosito.it
  answers_save
  unset ADMIN_USER ROOT_LOGIN PANEL_DOMAIN
  answers_load
  [ "$PANEL_ROOT" = "/var/www/panel.miosito.it" ]
  [ "$SSH_ALLOW_USERS" = "manu" ]
  run bash -c 'echo "$ADMIN_USER"'
  [ "$output" = "manu" ]
}

@test "con root prohibit-password anche root è in AllowUsers" {
  ADMIN_USER=manu ROOT_LOGIN=prohibit-password
  answers_derive
  [ "$SSH_ALLOW_USERS" = "manu root" ]
}

@test "answers_load fallisce se il file manca" {
  run answers_load "$BATS_TEST_TMPDIR/nessuno.env"
  [ "$status" -eq 1 ]
}
