setup() {
  load test_helper
  setup_common
}

@test "admin_logged_in trova la sessione" {
  make_stub loginctl 'printf "  3 1000 debian - pts/0 active no -\n  7 1001 manu   - pts/1 active no -\n"'
  admin_logged_in manu
  run admin_logged_in altro
  [ "$status" -ne 0 ]
}

@test "admin_logged_in senza sessioni" {
  make_stub loginctl 'true'
  run admin_logged_in manu
  [ "$status" -ne 0 ]
}

loginctl_stub() {
  make_stub loginctl 'case "$1" in
list-sessions) printf "  3 1000 debian - pts/0\n  7 1001 manu - pts/1\n  8 1001 manu - -\n  9 1001 manu - pts/2\n" ;;
show-session) case "$2" in 8) echo manager ;; *) echo user ;; esac ;;
esac'
}

@test "admin_session_ids elenca solo le sessioni user dell'utente" {
  loginctl_stub
  run admin_session_ids manu
  [ "$output" = "$(printf '7\n9')" ]
}

@test "admin_new_session: nessuna nuova sessione" {
  loginctl_stub
  run admin_new_session manu "$(printf '7\n9')"
  [ "$status" -ne 0 ]
}

@test "admin_new_session: una sessione nuova" {
  loginctl_stub
  admin_new_session manu "7"
}

@test "admin_new_session: una sessione manager non conta" {
  loginctl_stub
  run admin_new_session manu "$(printf '7\n9')"
  [ "$status" -ne 0 ]
  run admin_new_session altro ""
  [ "$status" -ne 0 ]
}
