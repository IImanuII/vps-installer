setup() {
  load test_helper
  setup_common
}

@test "le risposte sopravvivono a caratteri speciali" {
  ADMIN_USER=manu
  ADMIN_PASS=$'p@ss $word \'quote\' "dq" \\back'
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

@test "SSH_IGNORE_IP: derivato da SSH_CLIENT se manca, vuoto altrimenti" {
  unset SSH_IGNORE_IP
  SSH_CLIENT='203.0.113.7 51234 22' answers_derive
  [ "$SSH_IGNORE_IP" = 203.0.113.7 ]
  unset SSH_IGNORE_IP SSH_CLIENT
  answers_derive
  [ "$SSH_IGNORE_IP" = "" ]
  [[ -v SSH_IGNORE_IP ]]
}

@test "SSH_IGNORE_IP: il valore salvato vince, quelli non validi sono scartati" {
  SSH_IGNORE_IP=2001:db8::1 SSH_CLIENT='203.0.113.7 51234 22'
  answers_derive
  [ "$SSH_IGNORE_IP" = 2001:db8::1 ]
  unset SSH_IGNORE_IP
  SSH_CLIENT='1.2.3.4;rm 51234 22' answers_derive
  [ "$SSH_IGNORE_IP" = "" ]
  SSH_IGNORE_IP=$'1.2.3.4\n[sshd]'
  SSH_CLIENT=''
  answers_derive
  [ "$SSH_IGNORE_IP" = "" ]
}

@test "SSH_IGNORE_IP viene salvato in answers.env" {
  SSH_IGNORE_IP=203.0.113.7 answers_save
  unset SSH_IGNORE_IP SSH_CLIENT
  answers_load
  [ "$SSH_IGNORE_IP" = 203.0.113.7 ]
}
