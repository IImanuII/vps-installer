setup() {
  load test_helper
  setup_common
}

@test "json_ok semplice e con argomenti" {
  run json_ok
  [ "$output" = '{"ok":true}' ]
  run json_ok --arg v 1.2 '{ok:true,version:$v}'
  [ "$output" = '{"ok":true,"version":"1.2"}' ]
}

@test "json_err esce con 1 e JSON valido" {
  run json_err 'token "non" valido'
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'token "non" valido' ]
  [ "$(jq -r .ok <<<"$output")" = false ]
}

@test "tool_init trasforma die in errore JSON" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/tools.sh'; tool_init; die 'rotto' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = rotto ]
}

@test "read_stdin_limited tronca l'input" {
  run bash -c "source '$REPO_ROOT/lib/tools.sh'; printf '0123456789' | read_stdin_limited 4"
  [ "$output" = "0123" ]
}
