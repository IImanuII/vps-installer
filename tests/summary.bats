setup() {
  load test_helper
  setup_common
}

@test "summary_set e summary_load" {
  summary_set PMA_BASIC_PASS 'abc$def'
  summary_set PANEL_DBADMIN_PASS 'xyz'
  [ "$(stat -c %a "$VPS_ROOT/summary.env")" = "600" ]
  unset PMA_BASIC_PASS PANEL_DBADMIN_PASS
  summary_load
  [ "$PMA_BASIC_PASS" = 'abc$def' ]
  [ "$PANEL_DBADMIN_PASS" = 'xyz' ]
}

@test "summary_load senza file non fallisce" {
  run summary_load
  [ "$status" -eq 0 ]
}

@test "summary_get legge una chiave senza toccare l'ambiente" {
  summary_set PMA_BASIC_PASS 'abc$def'
  unset PMA_BASIC_PASS
  [ "$(summary_get PMA_BASIC_PASS)" = 'abc$def' ]
  [ -z "${PMA_BASIC_PASS:-}" ]
  PANEL_DBADMIN_PASS=dall-ambiente
  [ "$(summary_get PANEL_DBADMIN_PASS)" = "" ]
}
