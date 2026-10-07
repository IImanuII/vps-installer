setup() {
  load test_helper
  setup_common
  mkdir -p "$VPS_ROOT/steps"
  source "$REPO_ROOT/run.sh"
  export OUT="$BATS_TEST_TMPDIR/out"
}

@test "esegue gli step in ordine e segna lo stato" {
  printf 'step_main() { echo 10 >>"$OUT"; }\n' >"$VPS_ROOT/steps/10-a.sh"
  printf 'step_main() { echo 20 >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  run_steps
  [ "$(cat "$OUT")" = $'10\n20' ]
  state_done 10-a
  state_done 20-b
}

@test "salta gli step già completati" {
  printf 'step_main() { echo 10 >>"$OUT"; }\n' >"$VPS_ROOT/steps/10-a.sh"
  state_mark 10-a
  run_steps
  [ ! -f "$OUT" ]
}

@test "salta gli step non richiesti ma li segna" {
  printf 'step_enabled() { return 1; }\nstep_main() { echo no >>"$OUT"; }\n' >"$VPS_ROOT/steps/40-nginx.sh"
  run_steps
  [ ! -f "$OUT" ]
  state_done 40-nginx
}

@test "si ferma al primo errore e la ripresa riparte da lì" {
  printf 'step_main() { echo 10 >>"$OUT"; }\n' >"$VPS_ROOT/steps/10-a.sh"
  printf 'step_main() { false; echo mai >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  printf 'step_main() { echo 30 >>"$OUT"; }\n' >"$VPS_ROOT/steps/30-c.sh"
  run run_steps
  [ "$status" -ne 0 ]
  [ "$(cat "$OUT")" = "10" ]
  run state_done 20-b
  [ "$status" -ne 0 ]
  printf 'step_main() { echo 20 >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  run_steps
  [ "$(cat "$OUT")" = $'10\n20\n30' ]
}

@test "uno step non eredita step_enabled dal precedente" {
  printf 'step_enabled() { return 1; }\nstep_main() { :; }\n' >"$VPS_ROOT/steps/10-a.sh"
  printf 'step_main() { echo 20 >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  run_steps
  [ "$(cat "$OUT")" = "20" ]
}

@test "lo step vede le risposte e le variabili derivate" {
  ADMIN_USER=manu PANEL_DOMAIN=panel.miosito.it answers_save
  printf 'step_main() { echo "$ADMIN_USER $PANEL_ROOT" >>"$OUT"; }\n' >"$VPS_ROOT/steps/10-a.sh"
  run_steps
  [ "$(cat "$OUT")" = "manu /var/www/panel.miosito.it" ]
}

@test "il comando che fallisce finisce nel log" {
  printf 'step_main() { false_cmd_xyz; }\n' >"$VPS_ROOT/steps/10-a.sh"
  run run_steps
  [ "$status" -ne 0 ]
  grep -q "false_cmd_xyz" "$VPS_LOG"
}
