setup() {
  load test_helper
  setup_common
}

@test "render_template sostituisce solo le variabili elencate" {
  printf 'server_name ${PANEL_DOMAIN};\nreturn 301 https://$host$request_uri;\nx ${OTHER}\n' >"$BATS_TEST_TMPDIR/t.tmpl"
  PANEL_DOMAIN=panel.miosito.it
  OTHER=no
  render_template "$BATS_TEST_TMPDIR/t.tmpl" "$BATS_TEST_TMPDIR/out" 644 "$(id -un):$(id -gn)" PANEL_DOMAIN
  grep -qxF 'server_name panel.miosito.it;' "$BATS_TEST_TMPDIR/out"
  grep -qxF 'return 301 https://$host$request_uri;' "$BATS_TEST_TMPDIR/out"
  grep -qxF 'x ${OTHER}' "$BATS_TEST_TMPDIR/out"
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/out")" = "644" ]
}

@test "render_template fallisce se una variabile non è definita" {
  printf '${NOPE_VAR}\n' >"$BATS_TEST_TMPDIR/t.tmpl"
  unset NOPE_VAR
  run render_template "$BATS_TEST_TMPDIR/t.tmpl" "$BATS_TEST_TMPDIR/out" 644 "$(id -un):$(id -gn)" NOPE_VAR
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/out" ]
}

@test "render_template conserva valori con dollari e virgolette" {
  printf 'password "${SMTP_PASS_ESC}"\n' >"$BATS_TEST_TMPDIR/t.tmpl"
  SMTP_PASS_ESC='a$b\"c'
  render_template "$BATS_TEST_TMPDIR/t.tmpl" "$BATS_TEST_TMPDIR/out" 600 "$(id -un):$(id -gn)" SMTP_PASS_ESC
  grep -qxF 'password "a$b\"c"' "$BATS_TEST_TMPDIR/out"
}

@test "i template .tmpl usano solo variabili note" {
  local f v known=("${ANSWER_VARS[@]}" "${KNOWN_TEMPLATE_VARS[@]}")
  shopt -s nullglob
  for f in "$REPO_ROOT"/templates/*.tmpl; do
    for v in $(template_vars_in "$f"); do
      in_list "$v" "${known[@]}" || { echo "$f: variabile sconosciuta $v"; return 1; }
    done
  done
}

@test "i template statici non contengono variabili maiuscole" {
  local f
  shopt -s nullglob
  for f in "$REPO_ROOT"/templates/*; do
    [[ "$f" == *.tmpl || "$f" == */.gitkeep ]] && continue
    [ -z "$(template_vars_in "$f")" ] || { echo "$f: rinominalo .tmpl"; return 1; }
  done
}
