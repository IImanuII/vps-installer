bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  export MON_DIR="$BATS_TEST_TMPDIR/mon" MON_STATE_DIR="$BATS_TEST_TMPDIR/state"
  setup_common
  mkdir -p "$MON_DIR"
  TOK="123456:ABCdefGHIjklMNOpqrSTUvwxYZ0123456789_-"
  TH='{"fail_count":2,"slow_count":5,"remind_min":30}'
}

# configurazione completa e valida
base_cfg() {
  jq -n --arg t "$TOK" '{enabled:true,telegram:{bot_token:$t,chat_id:"-100123"},
    healthchecks_url:"https://hc-ping.com/abc-123/slug_1",
    urls:[{url:"https://trip4free.org/",keyword:"Trip4Free"}],
    thresholds:{fail_count:2,timeout_s:10,slow_s:3,slow_count:5,remind_min:30,disk_warn_pct:85,disk_crit_pct:95,mem_avail_pct:10,mem_minutes:5,load_factor:2,load_minutes:10,cert_days:14,f2b_bans:20,f2b_minutes:10}}'
}

# bad FILTRO_JQ: il filtro rende la configurazione non valida
bad() {
  local c
  c="$(base_cfg | jq -c "$1")"
  run mon_validate_config "$c" '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == ERR:* ]]
  [[ "$output" != *"{"* ]]
}

@test "mon_defaults: spento, soglie predefinite esatte" {
  d="$(mon_defaults)"
  jq -e '.enabled == false and .telegram == {bot_token:"",chat_id:""} and .healthchecks_url == "" and .urls == []' <<<"$d"
  jq -e '.thresholds == {fail_count:2,timeout_s:10,slow_s:3,slow_count:5,remind_min:30,disk_warn_pct:85,disk_crit_pct:95,mem_avail_pct:10,mem_minutes:5,load_factor:2,load_minutes:10,cert_days:14,f2b_bans:20,f2b_minutes:10}' <<<"$d"
}

@test "mon_validate_config: configurazione valida stampata" {
  run mon_validate_config "$(base_cfg)" '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r .telegram.bot_token <<<"$output")" = "$TOK" ]
  [ "$(jq -r '.urls[0].keyword' <<<"$output")" = Trip4Free ]
}

@test "mon_validate_config: soglie e keyword mancanti prendono i predefiniti" {
  c='{"enabled":false,"urls":[{"url":"https://a.example.it/x?y=1"}]}'
  run mon_validate_config "$c" '{}'
  [ "$status" -eq 0 ]
  jq -e '.thresholds.fail_count == 2 and .urls[0].keyword == "" and .healthchecks_url == ""' <<<"$output"
}

@test "mon_validate_config: ogni regola violata rifiuta" {
  bad '.telegram.bot_token = "abc"'
  bad '.telegram.bot_token = "1234:short"'
  bad '.telegram.bot_token = 5'
  bad '.telegram.chat_id = "abc"'
  bad '.telegram.chat_id = "12345678901234567890123"'
  bad '.healthchecks_url = "http://hc-ping.com/abc"'
  bad '.healthchecks_url = "https://hc-ping.com.evil.it/abc"'
  bad '.healthchecks_url = "https://hc-ping.com/"'
  bad '.healthchecks_url = "https://hc-ping.com/abc\n"'
  bad '.urls = [range(21) | {url:"https://a.example.it/",keyword:""}]'
  bad '.urls[0].url = "http://trip4free.org/"'
  bad '.urls[0].url = "https://user@trip4free.org/"'
  bad '.urls[0].url = "https://trip4free.org:8443/"'
  bad '.urls[0].url = "https://trip4free.org/a b"'
  bad '.urls[0].url = "https://trip4free.org/\n"'
  bad '.urls[0].url = "https://trip4free.org/" + ("a" * 491)'
  bad '.urls[0].url = "https://-a.it/"'
  bad '.urls[0].url = "https://localhost/"'
  bad '.urls[0].url = 5'
  bad '.urls[0].keyword = ("k" * 101)'
  bad '.urls[0].keyword = "a\tb"'
  bad '.urls = "x"'
  bad '.enabled = "si"'
  bad '.thresholds.fail_count = 0'
  bad '.thresholds.fail_count = 11'
  bad '.thresholds.fail_count = 1.5'
  bad '.thresholds.fail_count = "2"'
  bad '.thresholds.timeout_s = 1'
  bad '.thresholds.timeout_s = 31'
  bad '.thresholds.slow_s = 0'
  bad '.thresholds.slow_s = 31'
  bad '.thresholds.slow_count = 0'
  bad '.thresholds.slow_count = 31'
  bad '.thresholds.remind_min = 4'
  bad '.thresholds.remind_min = 1441'
  bad '.thresholds.disk_warn_pct = 49'
  bad '.thresholds.disk_crit_pct = 100'
  bad '.thresholds.disk_warn_pct = 95'
  bad '.thresholds.disk_warn_pct = 96'
  bad '.thresholds.mem_avail_pct = 0'
  bad '.thresholds.mem_avail_pct = 51'
  bad '.thresholds.mem_minutes = 0'
  bad '.thresholds.mem_minutes = 61'
  bad '.thresholds.load_minutes = 61'
  bad '.thresholds.f2b_minutes = 0'
  bad '.thresholds.load_factor = 0'
  bad '.thresholds.load_factor = 11'
  bad '.thresholds.cert_days = 0'
  bad '.thresholds.cert_days = 31'
  bad '.thresholds.f2b_bans = 0'
  bad '.thresholds.f2b_bans = 1001'
}

@test "mon_validate_config: limiti accettati ai bordi" {
  c="$(base_cfg | jq -c '.thresholds.fail_count = 10 | .thresholds.f2b_bans = 1000 | .thresholds.disk_warn_pct = 50 | .thresholds.disk_crit_pct = 51 | .urls = [range(20) | {url:"https://a.example.it/",keyword:("k" * 100)}]')"
  run mon_validate_config "$c" '{}'
  [ "$status" -eq 0 ]
  c="$(base_cfg | jq -c '.urls[0].url = "https://trip4free.org/" + ("a" * 490)')"
  [ "$(jq -j '.urls[0].url' <<<"$c" | LC_ALL=C wc -c)" -eq 512 ]
  run mon_validate_config "$c" '{}'
  [ "$status" -eq 0 ]
}

@test "mon_validate_config: JSON non valido o non oggetto" {
  run mon_validate_config 'non json' '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == ERR:* ]]
  run mon_validate_config '[1]' '{}'
  [[ "$output" == ERR:* ]]
  run mon_validate_config '' '{}'
  [[ "$output" == ERR:* ]]
}

@test "mon_validate_config: token assente nel nuovo e' conservato dal vecchio" {
  old="$(base_cfg)"
  new="$(base_cfg | jq -c 'del(.telegram.bot_token) | .enabled = false')"
  run mon_validate_config "$new" "$old"
  [ "$status" -eq 0 ]
  [ "$(jq -r .telegram.bot_token <<<"$output")" = "$TOK" ]
  [ "$(jq -r .enabled <<<"$output")" = false ]
  # due salvataggi di fila senza token
  once="$(mon_validate_config "$new" "$old")"
  twice="$(mon_validate_config "$new" "$once")"
  [ "$(jq -r .telegram.bot_token <<<"$twice")" = "$TOK" ]
  # nessun token ne' prima ne' dopo: vuoto
  run mon_validate_config "$new" 'garbage'
  [ "$status" -eq 0 ]
  [ "$(jq -r .telegram.bot_token <<<"$output")" = "" ]
}

@test "mon_config_load: assente o corrotto = predefiniti; presente = file" {
  [ "$(mon_config_load | jq -c .)" = "$(mon_defaults | jq -c .)" ]
  echo 'xx' >"$MON_CONFIG"
  [ "$(mon_config_load | jq -c .)" = "$(mon_defaults | jq -c .)" ]
  base_cfg >"$MON_CONFIG"
  [ "$(mon_config_load | jq -r .telegram.chat_id)" = "-100123" ]
}

@test "mon_transition: 1 fail con fail_count 2 = nessun evento" {
  r="$(mon_transition '{}' fail 1000 "$TH")"
  [ "$(jq -r .event <<<"$r")" = none ]
  [ "$(jq -r .check.fails <<<"$r")" = 1 ]
  [ "$(jq -r .check.state <<<"$r")" = ok ]
}

@test "mon_transition: down, nessun evento a 10 min, remind a 30, up con durata" {
  s="$(mon_transition '{}' fail 1000 "$TH" | jq -c .check)"
  r="$(mon_transition "$s" fail 1060 "$TH")"
  [ "$(jq -r .event <<<"$r")" = down ]
  s="$(jq -c .check <<<"$r")"
  [ "$(jq -r .state <<<"$s")" = down ]
  [ "$(jq -r .last_alert <<<"$s")" = 1060 ]
  r="$(mon_transition "$s" fail $((1060 + 600)) "$TH")"
  [ "$(jq -r .event <<<"$r")" = none ]
  s="$(jq -c .check <<<"$r")"
  r="$(mon_transition "$s" fail $((1060 + 1800)) "$TH")"
  [ "$(jq -r .event <<<"$r")" = remind ]
  s="$(jq -c .check <<<"$r")"
  r="$(mon_transition "$s" fail $((1060 + 1860)) "$TH")"
  [ "$(jq -r .event <<<"$r")" = none ]
  s="$(jq -c .check <<<"$r")"
  r="$(mon_transition "$s" ok 2800 "$TH")"
  [ "$(jq -r .event <<<"$r")" = up ]
  # il problema e' iniziato al primo esito negativo (1000)
  [ "$(jq -r .duration_s <<<"$r")" = 1800 ]
  [ "$(jq -r .check.state <<<"$r")" = ok ]
  [ "$(jq -r .check.fails <<<"$r")" = 0 ]
  r2="$(mon_transition "$(jq -c .check <<<"$r")" ok 2860 "$TH")"
  [ "$(jq -r .event <<<"$r2")" = none ]
}

@test "mon_transition: un ok in mezzo azzera il conteggio dei fallimenti" {
  s="$(mon_transition '{}' fail 1000 "$TH" | jq -c .check)"
  s="$(mon_transition "$s" ok 1060 "$TH" | jq -c .check)"
  r="$(mon_transition "$s" fail 1120 "$TH")"
  [ "$(jq -r .event <<<"$r")" = none ]
}

@test "mon_transition: 5 slow = slow, poi ok = up; 1 slow e un ok = niente" {
  s='{}'
  for t in 1 2 3 4; do
    r="$(mon_transition "$s" slow $((t * 60)) "$TH")"
    [ "$(jq -r .event <<<"$r")" = none ]
    s="$(jq -c .check <<<"$r")"
  done
  r="$(mon_transition "$s" slow 300 "$TH")"
  [ "$(jq -r .event <<<"$r")" = slow ]
  [ "$(jq -r .check.state <<<"$r")" = warn ]
  s="$(jq -c .check <<<"$r")"
  r="$(mon_transition "$s" ok 900 "$TH")"
  [ "$(jq -r .event <<<"$r")" = up ]
  [ "$(jq -r .duration_s <<<"$r")" = 840 ]
  s="$(mon_transition '{}' slow 60 "$TH" | jq -c .check)"
  r="$(mon_transition "$s" ok 120 "$TH")"
  [ "$(jq -r .event <<<"$r")" = none ]
  [ "$(jq -r .check.slows <<<"$r")" = 0 ]
}

@test "mon_transition: stato vuoto o spazzatura = come nuovo, soglie mancanti = predefinite" {
  r="$(mon_transition '' fail 1000 '{}')"
  [ "$(jq -r .event <<<"$r")" = none ]
  r="$(mon_transition 'xx' ok 1000 'yy')"
  [ "$(jq -r .event <<<"$r")" = none ]
}

@test "mon_state_load: assente o corrotto = stato vuoto" {
  [ "$(mon_state_load | jq -c .)" = '{"checks":{},"alerts":[],"cursor":{}}' ]
  mkdir -p "$MON_STATE_DIR"
  echo '{rotto' >"$MON_STATE"
  run mon_state_load
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"checks":{},"alerts":[],"cursor":{}}' ]
  echo '[1,2]' >"$MON_STATE"
  [ "$(mon_state_load | jq -c .)" = '{"checks":{},"alerts":[],"cursor":{}}' ]
}

@test "mon_state_save / mon_state_load: giro completo, permessi 600" {
  mon_state_save '{"checks":{"disk":{"state":"warn"}},"alerts":[],"cursor":{"ssh":"x"}}'
  [ "$(stat -c %a "$MON_STATE")" = 600 ]
  [ "$(mon_state_load | jq -r .checks.disk.state)" = warn ]
  [ "$(mon_state_load | jq -r .cursor.ssh)" = x ]
}

@test "mon_message: emoji e nome della VPS" {
  h="$(hostname)"
  [ "$(mon_message down x)" = "🔴 $h: x" ]
  [ "$(mon_message up x)" = "🟢 $h: x" ]
  [ "$(mon_message warn x)" = "🟡 $h: x" ]
  [ "$(mon_message ssh x)" = "🔐 $h: x" ]
  [ "$(mon_message summary x)" = "📋 $h: x" ]
  [ "$(mon_message test x)" = "✅ $h: x" ]
}

# curl_stub RISPOSTA [CODICE_USCITA]: annota argomenti e stdin
curl_stub() {
  export CURL_REPLY="$1" CURL_RC="${2:-0}"
  make_stub curl 'printf "%s\n" "$@" >>"$BATS_TEST_TMPDIR/curl.args"
cat >>"$BATS_TEST_TMPDIR/curl.stdin"
if [ "$CURL_RC" != 0 ]; then exit "$CURL_RC"; fi
printf "%s" "$CURL_REPLY"'
}

with_telegram() { base_cfg >"$MON_CONFIG"; }

@test "mon_send: token solo in stdin, testo e chat con --data-urlencode" {
  with_telegram
  curl_stub '{"ok":true,"result":{}}'
  run mon_send "ciao mondo"
  [ "$status" -eq 0 ]
  ! grep -q "$TOK" "$BATS_TEST_TMPDIR/curl.args"
  grep -qxF "url = \"https://api.telegram.org/bot$TOK/sendMessage\"" "$BATS_TEST_TMPDIR/curl.stdin"
  grep -qxF -- '--data-urlencode' "$BATS_TEST_TMPDIR/curl.args"
  grep -qxF 'chat_id=-100123' "$BATS_TEST_TMPDIR/curl.args"
  grep -qxF 'text=ciao mondo' "$BATS_TEST_TMPDIR/curl.args"
  grep -qxF -- '--max-time' "$BATS_TEST_TMPDIR/curl.args"
  grep -qxF -- '-K' "$BATS_TEST_TMPDIR/curl.args"
}

@test "mon_send: risposta ok:false, curl che fallisce o config senza token = errore" {
  with_telegram
  curl_stub '{"ok":false,"description":"no"}'
  run mon_send x
  [ "$status" -ne 0 ]
  curl_stub '' 7
  run mon_send x
  [ "$status" -ne 0 ]
  curl_stub '<html>'
  run mon_send x
  [ "$status" -ne 0 ]
  rm -f "$MON_CONFIG"
  curl_stub '{"ok":true}'
  run mon_send x
  [ "$status" -ne 0 ]
}

@test "mon_enqueue: 505 messaggi = 500 file, restano i piu' recenti" {
  for i in $(seq 1 505); do mon_enqueue "m$i"; done
  [ "$(find "$MON_QUEUE" -type f | wc -l)" -eq 500 ]
  [ "$(stat -c %a "$MON_QUEUE")" = 700 ]
  first="$(find "$MON_QUEUE" -type f | sort | head -n 1)"
  [ "$(cat "$first")" = m6 ]
}

@test "mon_flush_queue: curl ok = coda vuota, rispetta MAX" {
  with_telegram
  curl_stub '{"ok":true}'
  for i in 1 2 3 4 5; do mon_enqueue "m$i"; done
  mon_flush_queue 2
  [ "$(find "$MON_QUEUE" -type f | wc -l)" -eq 3 ]
  grep -qxF 'text=m1' "$BATS_TEST_TMPDIR/curl.args"
  mon_flush_queue
  [ "$(find "$MON_QUEUE" -type f | wc -l)" -eq 0 ]
}

@test "mon_flush_queue: curl che fallisce = coda invariata, un solo tentativo" {
  with_telegram
  curl_stub '' 7
  for i in 1 2 3; do mon_enqueue "m$i"; done
  run mon_flush_queue
  [ "$status" -eq 0 ]
  [ "$(find "$MON_QUEUE" -type f | wc -l)" -eq 3 ]
  [ "$(grep -c '^text=' "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
}

@test "mon_flush_queue: coda assente non e' un errore" {
  run mon_flush_queue
  [ "$status" -eq 0 ]
}
