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

@test "fix: soglie float normalizzate a interi nella configurazione salvata" {
  c="$(base_cfg | jq -c '.thresholds.fail_count = 2.0 | .thresholds.f2b_bans = 20.0')"
  run mon_validate_config "$c" '{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fail_count":2,'* ]]
  [[ "$output" == *'"f2b_bans":20,'* ]]
  [[ "$output" != *'.0'* ]]
}

@test "mon_message: testo troncato a 3900 caratteri" {
  t="$(printf 'è%.0s' {1..5000})"
  m="$(mon_message down "$t")"
  [ "$(printf %s "$m" | wc -m)" -eq 3900 ]
}

@test "mon_send: testo lungo troncato, vuoto = permanente senza curl" {
  with_telegram
  curl_stub '{"ok":true}'
  mon_send "$(printf 'a%.0s' {1..5000})"
  t="$(grep '^text=' "$BATS_TEST_TMPDIR/curl.args")"
  [ "${#t}" -eq 3905 ]
  : >"$BATS_TEST_TMPDIR/curl.args"
  run mon_send ""
  [ "$status" -eq 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/curl.args" ]
}

@test "mon_send: codici 1 transitorio, 2 permanente" {
  with_telegram
  curl_stub '{"ok":false,"error_code":400,"description":"x"}'
  run mon_send x
  [ "$status" -eq 2 ]
  curl_stub '{"ok":false,"error_code":403}'
  run mon_send x
  [ "$status" -eq 2 ]
  curl_stub '{"ok":false,"error_code":404}'
  run mon_send x
  [ "$status" -eq 2 ]
  curl_stub '{"ok":false,"error_code":429}'
  run mon_send x
  [ "$status" -eq 1 ]
  curl_stub '{"ok":false,"error_code":502}'
  run mon_send x
  [ "$status" -eq 1 ]
  curl_stub 'nojson'
  run mon_send x
  [ "$status" -eq 1 ]
  curl_stub '' 7
  run mon_send x
  [ "$status" -eq 1 ]
}

@test "mon_send: token o chat_id non validi nel file = 1 senza chiamare curl" {
  base_cfg | jq '.telegram.bot_token = "1\"\nurl = \"file:///etc/passwd"' >"$MON_CONFIG"
  curl_stub '{"ok":true}'
  run mon_send x
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.args" ]
  base_cfg | jq '.telegram.chat_id = "12 34"' >"$MON_CONFIG"
  run mon_send x
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.args" ]
}

@test "mon_flush_queue: il permanente e il vuoto vengono eliminati, si prosegue" {
  with_telegram
  mon_enqueue "veleno"
  : >"$MON_QUEUE/1"
  mon_enqueue "buono"
  # il primo invio risponde 400, il secondo ok
  make_stub curl 'cat >/dev/null; n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); echo $((n+1)) >"$BATS_TEST_TMPDIR/n"
if [ "$n" = 0 ]; then printf "{\"ok\":false,\"error_code\":400}"; else printf "{\"ok\":true}"; fi'
  mon_flush_queue
  [ "$(find "$MON_QUEUE" -type f | wc -l)" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/n")" -eq 2 ]
}

@test "mon_flush_queue: MAX conta i tentativi, non solo i successi" {
  with_telegram
  make_stub curl 'cat >/dev/null; echo x >>"$BATS_TEST_TMPDIR/calls"; printf "{\"ok\":false,\"error_code\":400}"'
  for i in 1 2 3 4 5; do mon_enqueue "m$i"; done
  mon_flush_queue 3
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls")" -eq 3 ]
  [ "$(find "$MON_QUEUE" -type f | wc -l)" -eq 2 ]
}

@test "mon_flush_queue: la scadenza ferma l'invio (curl lento)" {
  with_telegram
  make_stub curl 'cat >/dev/null; sleep 2; echo x >>"$BATS_TEST_TMPDIR/calls"; printf "{\"ok\":true}"'
  for i in 1 2 3 4 5; do mon_enqueue "m$i"; done
  mon_flush_queue 20 $(($(date +%s) + 1))
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  [ "$(find "$MON_QUEUE" -type f | wc -l)" -eq 4 ]
}

@test "mon_transition: since e last_alert corrotti non danno errore" {
  r="$(mon_transition '{"state":"down","fails":1,"since":"x","last_alert":"y"}' fail 1000 "$TH")"
  [ "$(jq -r .event <<<"$r")" = remind ]
  r="$(mon_transition '{"state":"down","since":"x"}' ok 1000 "$TH")"
  [ "$(jq -r .event <<<"$r")" = up ]
  [ "$(jq -r .duration_s <<<"$r")" = 0 ]
}

@test "mon_config_load: null nel file non sovrascrive i predefiniti" {
  echo '{"enabled":true,"urls":null,"thresholds":null,"telegram":null}' >"$MON_CONFIG"
  r="$(mon_config_load)"
  jq -e '.enabled == true and .urls == [] and .thresholds.fail_count == 2 and .telegram.chat_id == ""' <<<"$r"
  echo '{"thresholds":{"fail_count":null,"timeout_s":7},"telegram":{"chat_id":null}}' >"$MON_CONFIG"
  jq -e '.thresholds.fail_count == 2 and .thresholds.timeout_s == 7 and .telegram.chat_id == ""' <<<"$(mon_config_load)"
}

@test "mon_enqueue: temporanei vecchi di oltre un'ora eliminati" {
  mon_enqueue a
  touch -d '2 hours ago' "$MON_QUEUE/.tmp.vecchio"
  touch "$MON_QUEUE/.tmp.recente"
  mon_enqueue b
  [ ! -e "$MON_QUEUE/.tmp.vecchio" ]
  [ -e "$MON_QUEUE/.tmp.recente" ]
}

# --- vps-monitor: lo strumento e un giro completo ---

TOOL_REL=tools/vps-monitor

# tool_env — ambiente per lanciare lo strumento: tutto nel tmp del test, comandi
# di sistema finti, ora iniettata (mezzogiorno a Roma: nessun riepilogo).
tool_env() {
  T="$BATS_TEST_TMPDIR"
  TOOL="$REPO_ROOT/$TOOL_REL"
  unset SUDO_USER
  export VPS_LIB="$REPO_ROOT/lib" MON_LOCK="$T/mon.lock" MON_PROC="$T/proc" \
    MON_LE_LIVE="$T/le" MON_F2B_LOG="$T/f2b.log" MON_REBOOT_FILE="$T/reboot-required"
  NOW="$(TZ=Europe/Rome date -d '2026-10-16 12:00:30' +%s)"
  export MON_NOW="$NOW"
  mkdir -p "$MON_PROC" "$MON_LE_LIVE"
  set_mem 50
  printf '0.10 0.10 0.10 1/100 123\n' >"$MON_PROC/loadavg"
  echo 50 >"$T/disk.pct"
  jq -n '{panel:{domain:"p.test"}, components:{nginx:true, php:"8.4", mariadb:true, redis:true}, cloudflare:{enabled:false}}' >"$VPS_OPT/manifest.json"
  make_stub hostname 'echo vps-test'
  make_stub nproc 'echo 2'
  make_stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1000 500 500 %s%% /\n" "$(cat "$BATS_TEST_TMPDIR/disk.pct")"'
  make_stub journalctl 'echo "$*" >>"$BATS_TEST_TMPDIR/journalctl.calls"; cat "$BATS_TEST_TMPDIR/journal" 2>/dev/null; exit 0'
  make_stub openssl 'cat "$BATS_TEST_TMPDIR/openssl.out" 2>/dev/null'
  make_stub apt 'cat "$BATS_TEST_TMPDIR/apt.out" 2>/dev/null; exit 0'
  make_stub systemctl "$(cat "$BATS_TEST_DIRNAME/monitor_stub_systemctl.bash")"
  make_stub curl "$(cat "$BATS_TEST_DIRNAME/monitor_stub_curl.bash")"
}

# set_url URL CODICE TEMPO [CORPO] — risposta del curl finto per URL
set_url() {
  printf '%s %s %s\n' "$2" "$3" "${4:-OK}" >"$BATS_TEST_TMPDIR/url.$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"
}

# set_mem PERCENTUALE — RAM disponibile nel /proc finto
set_mem() {
  printf 'MemTotal: 1000000 kB\nMemFree: 100 kB\nMemAvailable: %s kB\n' "$(($1 * 10000))" >"$MON_PROC/meminfo"
}

# mon_cfg [FILTRO] — configurazione di base_cfg (con il filtro) salvata nel file
mon_cfg() {
  mkdir -p "$MON_DIR"
  base_cfg | jq -c "${1:-.}" >"$MON_CONFIG"
}

# round ORA — un giro di _run all'ora data
round() {
  MON_NOW="$1" bash "$TOOL" _run
}

sent() {
  cat "$BATS_TEST_TMPDIR/sent" 2>/dev/null || true
}

@test "vps-monitor _run sotto sudo: comando interno, prima delle librerie" {
  tool_env
  run env SUDO_USER=manu bash "$TOOL" _run
  [ "$status" -eq 1 ]
  [ "$output" = '{"ok":false,"error":"comando interno"}' ]
  rifiuto="$(grep -n 'comando interno' "$TOOL" | head -n1 | cut -d: -f1)"
  sorgente="$(grep -n 'source ' "$TOOL" | head -n1 | cut -d: -f1)"
  [ "$rifiuto" -lt "$sorgente" ]
  [ "$(sed -n 2p "$TOOL")" = '# vps-monitor — sorveglianza della VPS e avvisi Telegram: status, config, test (_run lo lancia il timer)' ]
}

@test "vps-monitor config: salva 600 e abilita il timer; enabled false lo ferma e conserva il token" {
  tool_env
  base_cfg >"$T/in.json"
  run bash -c "bash '$TOOL' config <'$T/in.json' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ "$(stat -c %a "$MON_CONFIG")" = 600 ]
  grep -qxF 'enable --now vps-monitor.timer' "$T/systemctl.calls"
  echo '{"enabled":false,"telegram":{"chat_id":"-100123"}}' >"$T/in2.json"
  run bash -c "bash '$TOOL' config <'$T/in2.json' 2>/dev/null"
  [ "$status" -eq 0 ]
  grep -qxF 'disable --now vps-monitor.timer' "$T/systemctl.calls"
  [ "$(jq -r .telegram.bot_token "$MON_CONFIG")" = "$TOK" ]
  [[ "$output" != *"$TOK"* ]]
}

@test "vps-monitor config: non valido o troppo lungo = errore, file invariato" {
  tool_env
  mon_cfg
  cp "$MON_CONFIG" "$T/prima.json"
  echo '{"enabled":true,"urls":[{"url":"http://x.it/"}]}' >"$T/bad.json"
  run bash -c "bash '$TOOL' config <'$T/bad.json' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [[ "$(jq -r .error <<<"$output")" == *indirizzo* ]]
  cmp "$MON_CONFIG" "$T/prima.json"
  { printf '{"enabled":false,"x":"'; head -c 70000 /dev/zero | tr '\0' a; printf '"}'; } >"$T/big.json"
  run bash -c "bash '$TOOL' config <'$T/big.json' 2>/dev/null"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"64 KiB"* ]]
  cmp "$MON_CONFIG" "$T/prima.json"
  [ ! -f "$T/systemctl.calls" ]
}

@test "vps-monitor status: senza configurazione spento; mai il token" {
  tool_env
  run bash -c "bash '$TOOL' status 2>/dev/null"
  [ "$status" -eq 0 ]
  jq -e '.ok == true and .enabled == false and .telegram_configured == false and .healthchecks == false and .last_run == null and .checks == [] and .alerts == [] and .urls == []' <<<"$output"
  jq -e '.thresholds.fail_count == 2' <<<"$output"
  mon_cfg
  run bash -c "bash '$TOOL' status 2>/dev/null"
  jq -e '.enabled == true and .telegram_configured == true and .healthchecks == true and .urls[0].keyword == "Trip4Free"' <<<"$output"
  [[ "$output" != *"$TOK"* ]]
}

@test "vps-monitor test: ok, errore di Telegram con la descrizione, non configurato" {
  tool_env
  run bash -c "bash '$TOOL' test 2>/dev/null"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"non configurato"* ]]
  mon_cfg
  run bash -c "bash '$TOOL' test 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  grep -qxF '✅ vps-test: messaggio di prova' "$T/sent"
  echo '{"ok":false,"error_code":401,"description":"Unauthorized: token revocato"}' >"$T/tg.resp"
  run bash -c "bash '$TOOL' test 2>/dev/null"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"Unauthorized: token revocato"* ]]
}

@test "giro: indirizzo giù dopo 2 giri, nessun promemoria a 5 min, rientro con durata; token mai in curl né nel log" {
  tool_env
  mon_cfg '.urls = [{url:"https://a.test/",keyword:""},{url:"https://b.test/",keyword:""}]'
  set_url https://b.test/ 502 0.2 errore
  run round "$NOW"
  [ "$status" -eq 0 ]
  [ -z "$(sent)" ]
  run round $((NOW + 60))
  [ "$status" -eq 0 ]
  [ "$(sent)" = '🔴 vps-test: https://b.test/ è giù da 1 min (HTTP 502)' ]
  run round $((NOW + 360))
  [ "$(sent | wc -l)" -eq 1 ]
  set_url https://b.test/ 200 0.2
  run round $((NOW + 420))
  [ "$(sent | wc -l)" -eq 2 ]
  [ "$(sent | tail -n1)" = '🟢 vps-test: https://b.test/ di nuovo raggiungibile (giù per 7 min)' ]
  run bash -c "bash '$TOOL' status 2>/dev/null"
  jq -e '.checks | map(select(.id == "url:https://a.test/"))[0] | .kind == "url" and .state == "ok" and .code == 200 and .time_ms == 100' <<<"$output"
  jq -e '(.alerts | length) == 2 and (.last_run | test("^2026-10-16T"))' <<<"$output"
  ! grep -qF "$TOK" "$T/curl.args"
  ! grep -qF "$TOK" "$VPS_LOG"
}

@test "giro: indirizzo lento dopo 5 giri e parola attesa assente" {
  tool_env
  mon_cfg '.urls = [{url:"https://a.test/",keyword:""},{url:"https://k.test/",keyword:"Benvenuti"}]'
  set_url https://a.test/ 200 4.5
  set_url https://k.test/ 200 0.1 'pagina-vuota'
  for i in 0 1 2 3 4; do run round $((NOW + i * 60)); done
  [[ "$(sent)" == *'🟡 vps-test: https://a.test/ è lento: 4.5 s (soglia 3 s)'* ]]
  [[ "$(sent)" == *'🔴 vps-test: https://k.test/ è giù da 1 min (parola attesa assente)'* ]]
}

@test "giro: /health del pannello con --resolve verso 127.0.0.1" {
  tool_env
  mon_cfg '.urls = []'
  run round "$NOW"
  [ "$status" -eq 0 ]
  grep -qxF -- '--resolve' "$T/curl.args"
  grep -qxF 'p.test:443:127.0.0.1' "$T/curl.args"
  grep -qxF 'https://p.test/health' "$T/curl.args"
  set_url https://p.test/health 200 0.1 'non-va'
  run round $((NOW + 60))
  run round $((NOW + 120))
  [[ "$(sent)" == *'https://p.test/health è giù'* ]]
}

@test "giro: servizio fermo riavviato; alla quarta caduta nell'ora riavvii sospesi, un solo avviso" {
  tool_env
  mon_cfg '.urls = []'
  for i in 0 1 2; do
    touch "$T/down.redis-server"
    run round $((NOW + i * 60))
    [ "$status" -eq 0 ]
  done
  [ "$(grep -c '^restart redis-server$' "$T/systemctl.calls")" -eq 3 ]
  [ "$(sent | grep -c 'redis-server era fermo, riavviato')" -eq 3 ]
  touch "$T/down.redis-server"
  run round $((NOW + 180))
  run round $((NOW + 240))
  [ "$(grep -c '^restart redis-server$' "$T/systemctl.calls")" -eq 3 ]
  [ "$(sent | grep -c 'continua a cadere: riavvii automatici sospesi per un.ora')" -eq 1 ]
  [[ "$(sent | tail -n1)" == '🔴 vps-test: redis-server'* ]]
}

@test "giro: servizio che non riparte" {
  tool_env
  mon_cfg '.urls = []'
  touch "$T/down.mariadb" "$T/norestart.mariadb"
  run round "$NOW"
  [ "$(sent)" = '🔴 vps-test: mariadb fermo, riavvio non riuscito' ]
}

@test "giro: disco 87% giallo, 96% rosso; RAM al 5% per 5 giri avvisa al quinto" {
  tool_env
  mon_cfg '.urls = []'
  echo 87 >"$T/disk.pct"
  run round "$NOW"
  [ "$(sent)" = '🟡 vps-test: disco al 87%' ]
  echo 96 >"$T/disk.pct"
  run round $((NOW + 60))
  [ "$(sent | tail -n1)" = '🔴 vps-test: disco al 96%' ]
  echo 50 >"$T/disk.pct"
  set_mem 5
  for i in 2 3 4 5; do run round $((NOW + i * 60)); done
  [[ "$(sent)" != *RAM* ]]
  run round $((NOW + 360))
  [ "$(sent | tail -n1)" = '🟡 vps-test: RAM disponibile al 5% da 5 min' ]
}

@test "giro: due accessi SSH dal journal, al giro dopo nessuno" {
  tool_env
  mon_cfg '.urls = []'
  {
    echo "$((NOW - 10)).123456 vps sshd[1]: Accepted publickey for iimanuii from 1.2.3.4 port 5 ssh2"
    echo "$((NOW - 5)).000001 vps sshd[2]: Accepted publickey for iimanuii from 1.2.3.4 port 5 ssh2"
    echo "$((NOW - 4)).000001 vps sshd[3]: Failed password for root from 9.9.9.9 port 5 ssh2"
  } >"$T/journal"
  run round "$NOW"
  [ "$(sent | grep -c '^🔐 vps-test: accesso SSH di iimanuii da 1.2.3.4 (publickey)$')" -eq 2 ]
  grep -q -- '-u ssh' "$T/journalctl.calls"
  run round $((NOW + 60))
  [ "$(sent | grep -c '🔐')" -eq 2 ]
  grep -q -- "--since @$NOW" "$T/journalctl.calls"
}

@test "giro: fail2ban oltre soglia e certificato in scadenza" {
  tool_env
  mon_cfg '.urls = []'
  for i in $(seq 1 25); do
    echo "$(date -d "@$((NOW - 60))" '+%F %T'),123 fail2ban.actions [1]: NOTICE  [sshd] Ban 10.0.0.$i"
  done >"$MON_F2B_LOG"
  echo "$(date -d "@$((NOW - 7200))" '+%F %T'),123 fail2ban.actions [1]: NOTICE  [sshd] Ban 10.9.9.9" >>"$MON_F2B_LOG"
  mkdir -p "$MON_LE_LIVE/sito.it"
  touch "$MON_LE_LIVE/sito.it/cert.pem"
  echo "notAfter=$(date -u -d "@$((NOW + 5 * 86400 + 100))" '+%b %e %H:%M:%S %Y GMT')" >"$T/openssl.out"
  run round "$NOW"
  [[ "$(sent)" == *'🟡 vps-test: fail2ban: 25 IP bloccati negli ultimi 10 min'* ]]
  [[ "$(sent)" == *'🟡 vps-test: il certificato di sito.it scade tra 5 giorni'* ]]
}

@test "giro: riepilogo delle 9 solo con contenuto e una volta al giorno" {
  tool_env
  mon_cfg '.urls = []'
  N9="$(TZ=Europe/Rome date -d '2026-10-16 09:00:30' +%s)"
  run round "$N9"
  [ -z "$(sent)" ]
  rm -f "$MON_STATE"
  printf 'Listing...\na/stable 2 amd64 [upgradable from: 1]\nb/stable-security 2 amd64 [upgradable from: 1]\nc/stable 2 amd64 [upgradable from: 1]\n' >"$T/apt.out"
  run round $((N9 + 60))
  [ "$(sent)" = '📋 vps-test: riepilogo — 3 aggiornamenti (1 di sicurezza)' ]
  run round $((N9 + 120))
  [ "$(sent | wc -l)" -eq 1 ]
}

@test "giro: Telegram giù = messaggi in coda e stato salvato; al giro dopo coda svuotata" {
  tool_env
  mon_cfg '.urls = [{url:"https://b.test/",keyword:""}]'
  set_url https://b.test/ 502 0.2
  touch "$T/tg.down"
  run round "$NOW"
  run round $((NOW + 60))
  [ "$status" -eq 0 ]
  [ "$(find "$MON_STATE_DIR/queue" -type f | wc -l)" -eq 1 ]
  jq -e '.checks["url:https://b.test/"].state == "down"' "$MON_STATE"
  rm -f "$T/tg.down"
  run round $((NOW + 120))
  [ "$(find "$MON_STATE_DIR/queue" -type f | wc -l)" -eq 0 ]
  [[ "$(sent)" == *'https://b.test/ è giù'* ]]
}

@test "giro: Telegram non configurato = nessuna coda, avviso solo nello stato" {
  tool_env
  mon_cfg '.urls = [{url:"https://b.test/",keyword:""}] | .telegram = {bot_token:"",chat_id:""}'
  set_url https://b.test/ 502 0.2
  run round "$NOW"
  run round $((NOW + 60))
  [ ! -d "$MON_STATE_DIR/queue" ] || [ "$(find "$MON_STATE_DIR/queue" -type f | wc -l)" -eq 0 ]
  jq -e '(.alerts | length) == 1' "$MON_STATE"
}

@test "giro: ping a Healthchecks a ogni giro; spento = nessun giro" {
  tool_env
  mon_cfg '.urls = []'
  run round "$NOW"
  run round $((NOW + 60))
  [ "$(grep -cxF 'https://hc-ping.com/abc-123/slug_1' "$T/pings")" -eq 2 ]
  mon_cfg '.enabled = false'
  rm -f "$T/curl.args"
  run round $((NOW + 120))
  [ "$status" -eq 0 ]
  [ ! -f "$T/curl.args" ]
}

@test "giro: state.json corrotto riparte da vuoto senza errori né avvisi di rientro" {
  tool_env
  mon_cfg
  mkdir -p "$MON_STATE_DIR"
  echo '{"checks":{"url:https://trip4free.org/":{"state":"down"' >"$MON_STATE"
  set_url https://trip4free.org/ 200 0.1 'Benvenuti-su-Trip4Free'
  run round "$NOW"
  [ "$status" -eq 0 ]
  [[ "$output" != *"errore interno"* ]]
  [ -z "$(sent)" ]
  jq -e '.checks["url:https://trip4free.org/"].state == "ok"' "$MON_STATE"
}

@test "giro: 20 indirizzi in timeout finiscono in parallelo" {
  tool_env
  mon_cfg '.urls = [range(20) | {url:"https://t\(.).test/",keyword:""}] | .thresholds.timeout_s = 2'
  for i in $(seq 0 19); do set_url "https://t$i.test/" sleep 1; done
  SECONDS=0
  run round "$NOW"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  [ "$(jq '[.checks | to_entries[] | select(.key | startswith("url:https://t")) | select(.value.fails == 1)] | length' "$MON_STATE")" -eq 20 ]
}

# --- Fix round 1 ---

@test "fix: indirizzi con [ ] { } rifiutati (curl li espanderebbe)" {
  bad '.urls[0].url = "https://trip4free.org/[1-99999999]"'
  bad '.urls[0].url = "https://trip4free.org/{a,b}"'
  bad '.urls[0].url = "https://trip4free.org/a]"'
  bad '.urls[0].url = "https://trip4free.org/a}"'
}

@test "fix: curl degli indirizzi e di Healthchecks con -q --globoff, corpo al massimo 2 MiB" {
  tool_env
  mon_cfg '.urls = [{url:"https://a.test/",keyword:""}]'
  run round "$NOW"
  [ "$status" -eq 0 ]
  # primo argomento di ogni chiamata a curl = -q (letto solo se primo)
  [ "$(awk 'NR == 1 || p == "---" { n++; if ($0 == "-q") q++ } { p = $0 } END { print n - q }' "$T/curl.args")" -eq 0 ]
  [ "$(grep -cxF -- '--globoff' "$T/curl.args")" -eq 3 ]
  grep -A1 -xF -- '--max-filesize' "$T/curl.args" | grep -qxF 2097152
  [ "$(head -n1 "$T/curl.args")" = -q ]
}

@test "fix: riavvio che non finisce = giro nei tempi, riavvio già salvato nello stato" {
  tool_env
  mon_cfg '.urls = []'
  touch "$T/down.nginx"
  echo 30 >"$T/restart.sleep"
  SECONDS=0
  MON_RESTART_TIMEOUT=1 run round "$NOW"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  grep -qxF 'restart nginx' "$T/systemctl.calls"
  jq -e --argjson n "$NOW" '.checks["service:nginx"].restarts == [$n]' "$T/state.snap"
  jq -e --argjson n "$NOW" '.checks["service:nginx"].restarts == [$n]' "$MON_STATE"
  ! pgrep -f 'sleep 30' >/dev/null
}

@test "fix: oltre il tempo del giro niente riavvii, controlli delle 6 ore né riepilogo; stato e ping sì" {
  tool_env
  mon_cfg '.urls = []'
  N9="$(TZ=Europe/Rome date -d '2026-10-16 09:00:30' +%s)"
  printf 'Listing...\na/stable 2 amd64 [upgradable from: 1]\n' >"$T/apt.out"
  touch "$T/down.nginx"
  MON_ROUND_S=0 run round "$N9"
  [ "$status" -eq 0 ]
  ! grep -q '^restart' "$T/systemctl.calls"
  jq -e '.cursor.periodic == null and .summary_day == null and .last_run != null' "$MON_STATE"
  jq -e 'has("checks") and (.checks | has("service:nginx") | not)' "$MON_STATE"
  [ -z "$(sent)" ]
  grep -qxF 'https://hc-ping.com/abc-123/slug_1' "$T/pings"
  # al giro dopo, nei tempi, tutto riparte
  run round $((N9 + 60))
  grep -qxF 'restart nginx' "$T/systemctl.calls"
  jq -e '.cursor.periodic != null and .summary_day != null' "$MON_STATE"
}

@test "fix: riavvii che falliscono, al quarto 'continua a cadere' una volta sola" {
  tool_env
  mon_cfg '.urls = []'
  touch "$T/down.mariadb" "$T/norestart.mariadb"
  for i in 0 1 2 3 4; do run round $((NOW + i * 60)); done
  [ "$(grep -c '^restart mariadb$' "$T/systemctl.calls")" -eq 3 ]
  [ "$(sent | grep -c 'mariadb fermo, riavvio non riuscito')" -eq 1 ]
  [ "$(sent | grep -cxF "🔴 vps-test: mariadb continua a cadere: riavvii automatici sospesi per un'ora")" -eq 1 ]
}

@test "fix: fail2ban conta solo i Ban veri, non i Restore Ban" {
  tool_env
  mon_cfg '.urls = []'
  for i in $(seq 1 25); do
    echo "$(date -d "@$((NOW - 60))" '+%F %T'),123 fail2ban.actions [1]: NOTICE  [sshd] Restore Ban 10.0.0.$i"
  done >"$MON_F2B_LOG"
  run round "$NOW"
  [[ "$(sent)" != *fail2ban* ]]
  jq -e '.checks.f2b.value == 0' "$MON_STATE"
}

@test "fix: SSH solo dalle righe di sshd/sshd-session, righe contraffatte ignorate" {
  tool_env
  mon_cfg '.urls = []'
  {
    echo "$((NOW - 10)).1 vps sshd-session[7]: Accepted publickey for iimanuii from 1.2.3.4 port 5 ssh2"
    echo "$((NOW - 9)).1 vps sshd[3]: Invalid user Accepted publickey for evil from 6.6.6.6 port 1 from 9.9.9.9 port 2"
    echo "$((NOW - 8)).1 vps sshd[3]: Connection closed by invalid user x Accepted password for evil from 6.6.6.6 port 1"
    echo "$((NOW - 7)).1 vps logger[9]: Accepted publickey for evil from 6.6.6.6 port 1 ssh2"
  } >"$T/journal"
  run round "$NOW"
  [ "$(sent)" = '🔐 vps-test: accesso SSH di iimanuii da 1.2.3.4 (publickey)' ]
}
