setup() {
  load test_helper
  setup_common
  source "$REPO_ROOT/steps/99-finalize.sh"
  ADMIN_USER=manu SSH_PORT=41822 PANEL_ENABLED=yes PANEL_DOMAIN=panel.miosito.it PANEL_ROOT=/var/www/panel.miosito.it
  WANT_PMA=yes MAIL_ENABLED=no CF_ENABLED=yes
  server_ipv4() { echo 203.0.113.10; }
}

@test "il riepilogo contiene accesso SSH, pannello e credenziali phpMyAdmin" {
  summary_set PMA_BASIC_PASS 'Pma-Segreta-1'
  summary_set PANEL_DBADMIN_PASS 'Db-Segreta-1'
  run finalize_summary_text
  [[ "$output" == *"ssh -p 41822 manu@203.0.113.10"* ]]
  [[ "$output" == *"https://panel.miosito.it/pma/"* ]]
  [[ "$output" == *"manu / Pma-Segreta-1"* ]]
  [[ "$output" == *"panel_dbadmin / Db-Segreta-1"* ]]
  [[ "$output" == *"Full (strict)"* ]]
}

@test "il riepilogo non inventa password già esistenti" {
  run finalize_summary_text
  [[ "$output" == *"(invariata)"* ]]
}

@test "il riepilogo non finisce nel log" {
  summary_set PMA_BASIC_PASS 'Pma-Segreta-1'
  finalize_summary_text >/dev/null
  ! grep -q 'Pma-Segreta-1' "$VPS_LOG" 2>/dev/null
}

ssh_env() {
  export SSH_CONF_PATH="$BATS_TEST_TMPDIR/10-vps.conf" VPS_SSH_TTY="$BATS_TEST_TMPDIR/tty"
  export SSH_CONFIRM_TIMEOUT=2 SSH_READ_TIMEOUT=1
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  echo "OK" >"$VPS_SSH_TTY"
  echo "conf" >"$VPS_ROOT/sshd-10-vps.conf"
  make_stub systemctl 'echo "systemctl $*" >>'"$CALLS"'; case "$1" in is-enabled|is-active) exit 1;; esac; exit 0'
  make_stub sshd 'exit 0'
  make_stub systemd-run 'echo "systemd-run $*" >>'"$CALLS"
  make_stub ufw 'echo "ufw $*" >>'"$CALLS"
  make_stub loginctl 'case "$1" in
list-sessions) cat '"$BATS_TEST_TMPDIR"'/sessions ;;
show-session) echo user ;;
esac'
  printf '  7 1001 manu - pts/1\n' >"$BATS_TEST_TMPDIR/sessions"
}

@test "finalize_ssh: sshd -t fallito, conf rimossa e errore" {
  ssh_env
  make_stub sshd 'exit 1'
  run finalize_ssh
  [ "$status" -ne 0 ]
  [ ! -e "$SSH_CONF_PATH" ]
}

@test "finalize_ssh: reload fallito, conf rimossa" {
  ssh_env
  make_stub systemctl 'echo "systemctl $*" >>'"$CALLS"'; case "$1" in is-enabled|is-active) exit 1;; reload) exit 1;; esac; exit 0'
  run finalize_ssh
  [ "$status" -ne 0 ]
  [ ! -e "$SSH_CONF_PATH" ]
}

@test "finalize_ssh: enable ssh.service fallito, ssh.socket ripristinato" {
  ssh_env
  make_stub systemctl 'echo "systemctl $*" >>'"$CALLS"'; case "$1" in is-enabled) exit 0;; enable) [ "$3" = ssh.service ] && exit 1;; esac; exit 0'
  run finalize_ssh
  [ "$status" -ne 0 ]
  grep -qF 'systemctl enable --now ssh.socket' "$CALLS"
}

@test "finalize_ssh: timeout senza nuova sessione, conf rimossa e porta 22 intatta" {
  ssh_env
  : >"$VPS_SSH_TTY"
  run finalize_ssh
  [ "$status" -ne 0 ]
  [ ! -e "$SSH_CONF_PATH" ]
  run grep -q 'ufw delete' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "finalize_ssh: confermo con la sola vecchia sessione, non confermato" {
  ssh_env
  run finalize_ssh
  [ "$status" -ne 0 ]
  run grep -q 'ufw delete' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "finalize_ssh: nuova sessione, confermato e porta 22 chiusa" {
  ssh_env
  make_stub systemctl 'echo "systemctl $*" >>'"$CALLS"'; case "$1" in is-enabled|is-active) exit 1;; reload) printf "  7 1001 manu - pts/1\n  9 1001 manu - pts/2\n" >'"$BATS_TEST_TMPDIR"'/sessions;; esac; exit 0'
  run finalize_ssh
  [ "$status" -eq 0 ]
  [ -e "$SSH_CONF_PATH" ]
  grep -qF 'ufw delete allow 22/tcp' "$CALLS"
}

@test "finalize_ssh: watchdog armato prima del reload e annullato alla conferma" {
  ssh_env
  make_stub systemctl 'echo "systemctl $*" >>'"$CALLS"'; case "$1" in is-enabled|is-active) exit 1;; reload) printf "  7 1001 manu - pts/1\n  9 1001 manu - pts/2\n" >'"$BATS_TEST_TMPDIR"'/sessions;; esac; exit 0'
  run finalize_ssh
  [ "$status" -eq 0 ]
  local arm reload stop
  arm="$(grep -n '^systemd-run .*--unit=vps-ssh-rollback' "$CALLS" | head -1 | cut -d: -f1)"
  reload="$(grep -n '^systemctl reload ssh' "$CALLS" | head -1 | cut -d: -f1)"
  stop="$(grep -n '^systemctl stop vps-ssh-rollback' "$CALLS" | tail -1 | cut -d: -f1)"
  [ -n "$arm" ] && [ -n "$reload" ] && [ -n "$stop" ]
  [ "$arm" -lt "$reload" ]
  [ "$reload" -lt "$stop" ]
  grep -qF -- "--on-active=122s" "$CALLS"
}

@test "finalize_ssh: systemd-run fallito, SSH non attivato" {
  ssh_env
  make_stub systemd-run 'exit 1'
  run finalize_ssh
  [ "$status" -ne 0 ]
  [ ! -e "$SSH_CONF_PATH" ]
  run grep -q '^systemctl reload ssh' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "finalize_ssh: tty non apribile, nessuna conf installata" {
  ssh_env
  export VPS_SSH_TTY="$BATS_TEST_TMPDIR/nonexistent/tty"
  run finalize_ssh
  [ "$status" -ne 0 ]
  [ ! -e "$SSH_CONF_PATH" ]
}

@test "finalize_ssh: stop e reset-failed del watchdog prima di systemd-run" {
  ssh_env
  run finalize_ssh
  local stop reset arm
  stop="$(grep -n '^systemctl stop vps-ssh-rollback' "$CALLS" | head -1 | cut -d: -f1)"
  reset="$(grep -n '^systemctl reset-failed vps-ssh-rollback' "$CALLS" | head -1 | cut -d: -f1)"
  arm="$(grep -n '^systemd-run ' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$stop" ] && [ -n "$reset" ] && [ -n "$arm" ]
  [ "$stop" -lt "$arm" ]
  [ "$reset" -lt "$arm" ]
}

@test "finalize_ssh: timer ancora attivo dopo la conferma, porta 22 non chiusa" {
  ssh_env
  make_stub systemctl 'echo "systemctl $*" >>'"$CALLS"'; case "$1" in is-enabled) exit 1;; is-active) [ "$3" = vps-ssh-rollback.timer ] && exit 0; exit 1;; reload) printf "  7 1001 manu - pts/1\n  9 1001 manu - pts/2\n" >'"$BATS_TEST_TMPDIR"'/sessions;; esac; exit 0'
  run finalize_ssh
  [ "$status" -eq 0 ]
  run grep -q 'ufw delete' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "finalize_ssh: percorso conf con caratteri strani, SSH non attivato" {
  ssh_env
  export SSH_CONF_PATH="$BATS_TEST_TMPDIR/it's.conf"
  run finalize_ssh
  [ "$status" -ne 0 ]
  [ ! -e "$SSH_CONF_PATH" ]
}
