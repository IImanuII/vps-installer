setup() {
  load test_helper
  setup_common
}

@test "l'ambiente di test è pronto" {
  [ -d "$VPS_ROOT" ]
  [ "$VPS_NO_CHOWN" = "1" ]
}

@test "make_stub sostituisce un comando" {
  make_stub hostname 'echo finto'
  run hostname
  [ "$output" = "finto" ]
}
