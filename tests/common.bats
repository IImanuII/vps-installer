setup() {
  load test_helper
  setup_common
}

@test "write_file scrive in modo atomico con i permessi richiesti" {
  printf 'segreto\n' | write_file "$BATS_TEST_TMPDIR/f" 600 "$(id -un):$(id -gn)"
  [ "$(cat "$BATS_TEST_TMPDIR/f")" = "segreto" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/f")" = "600" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '.tmp.*')" ]
}

@test "rand_secret genera stringhe alfanumeriche della lunghezza richiesta" {
  run rand_secret 20
  [ "${#output}" -eq 20 ]
  [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
  run rand_secret
  [ "${#output}" -eq 32 ]
}

@test "state_mark e state_done tracciano gli step" {
  run state_done 10-system
  [ "$status" -ne 0 ]
  state_mark 10-system
  state_done 10-system
  run state_done 10-sys
  [ "$status" -ne 0 ]
}

@test "state_mark non fallisce se la cartella è stata cancellata" {
  rm -rf "$VPS_ROOT"
  run state_mark 99-finalize
  [ "$status" -eq 0 ]
}

@test "trim toglie CR e spazi ai lati" {
  run trim $'  ssh-ed25519 AAAA nome \r\n'
  [ "$output" = "ssh-ed25519 AAAA nome" ]
}

@test "env_get legge una chiave e restituisce vuoto se manca" {
  printf 'DB_PASS=abc123\nDB_USER=panel\n' >"$BATS_TEST_TMPDIR/.env"
  run env_get "$BATS_TEST_TMPDIR/.env" DB_PASS
  [ "$output" = "abc123" ]
  run env_get "$BATS_TEST_TMPDIR/.env" NOPE
  [ "$output" = "" ]
  run env_get "$BATS_TEST_TMPDIR/manca.env" DB_PASS
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "is_yes e in_list" {
  is_yes yes
  run is_yes no
  [ "$status" -ne 0 ]
  in_list b a b c
  run in_list z a b c
  [ "$status" -ne 0 ]
}

@test "die scrive nel log ed esce con 1" {
  run die "qualcosa"
  [ "$status" -eq 1 ]
  grep -q "ERRORE: qualcosa" "$VPS_LOG"
}

@test "env_merge sostituisce le chiavi date e conserva le altre righe" {
  local f="$BATS_TEST_TMPDIR/.env"
  printf '# commento\nDB_HOST=vecchio\nAPP_KEY=mia-chiave\nDB_PASS=vecchia\n\nMAIL_FROM=a@b.it\n' >"$f"
  printf 'DB_HOST=localhost\nDB_PASS=n$u\o"va\nDBADMIN_USER=panel_dbadmin\n' | env_merge "$f" 600 "$(id -un):$(id -gn)"
  [ "$(cat "$f")" = $'# commento\nDB_HOST=localhost\nAPP_KEY=mia-chiave\nDB_PASS=n$u\o"va\n\nMAIL_FROM=a@b.it\nDBADMIN_USER=panel_dbadmin' ]
  [ "$(stat -c %a "$f")" = 600 ]
}

@test "env_merge crea il file se manca ed elimina chiavi duplicate" {
  local f="$BATS_TEST_TMPDIR/.env"
  printf 'A=1\n' | env_merge "$f" 640 "$(id -un):$(id -gn)"
  [ "$(cat "$f")" = "A=1" ]
  [ "$(stat -c %a "$f")" = 640 ]
  printf 'A=0\nB=x\nA=00\n' >"$f"
  printf 'A=2\n' | env_merge "$f" 600 "$(id -un):$(id -gn)"
  [ "$(cat "$f")" = $'A=2\nB=x' ]
}
