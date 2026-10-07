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
