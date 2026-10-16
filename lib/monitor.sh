# shellcheck shell=bash
# Libreria di vps-monitor: configurazione, stato, macchina a stati, messaggi,
# invio su Telegram e coda. Solo variabili con default e funzioni: nessun
# effetto al caricamento (la libreria viene letta da ogni strumento).

: "${VPS_OPT:=/opt/vps}"
: "${MON_DIR:=$VPS_OPT/monitor}"
: "${MON_CONFIG:=$MON_DIR/config.json}"
: "${MON_STATE_DIR:=/var/lib/vps-monitor}"
: "${MON_STATE:=$MON_STATE_DIR/state.json}"
: "${MON_QUEUE:=$MON_STATE_DIR/queue}"
: "${MON_LOCK:=/run/vps-monitor.lock}"
: "${TELEGRAM_API:=https://api.telegram.org}"

# mon_defaults — configurazione predefinita (spenta, senza Telegram né indirizzi).
mon_defaults() {
  jq -nc '{
    enabled: false,
    telegram: {bot_token: "", chat_id: ""},
    healthchecks_url: "",
    urls: [],
    thresholds: {
      fail_count: 2, timeout_s: 10, slow_s: 3, slow_count: 5, remind_min: 30,
      disk_warn_pct: 85, disk_crit_pct: 95, mem_avail_pct: 10, mem_minutes: 5,
      load_factor: 2, load_minutes: 10, cert_days: 14, f2b_bans: 20, f2b_minutes: 10
    }
  }'
}

# Programma jq di validazione: legge la configurazione nuova, stampa la
# configurazione risultante oppure {"err":"messaggio"}. Il token vecchio arriva
# dall'ambiente (OLDTOK), mai dagli argomenti. I messaggi non contengono mai
# valori della configurazione.
# shellcheck disable=SC2016
_MON_VALIDATE_JQ='
def isint: type == "number" and . == floor;
def nocntrl: test("[[:cntrl:]]") | not;
def obj(m): if type == "object" then . else error(m) end;
. as $in
| try (
    ($in | obj("la configurazione deve essere un oggetto")) as $in
    | ($in | if has("enabled") then .enabled else false end) as $en
    | (if ($en | type) == "boolean" then . else error("enabled deve essere vero o falso") end) as $_a
    | ($in | if has("telegram") then .telegram else {} end | obj("telegram deve essere un oggetto")) as $tg
    | ($tg | if has("bot_token") then .bot_token else (env.OLDTOK // "") end) as $tok
    | (if ($tok | type) == "string" and ($tok == "" or ($tok | test("^[0-9]{5,15}:[A-Za-z0-9_-]{30,60}\\z"))) then . else error("bot_token non valido") end) as $_b
    | ($tg | if has("chat_id") then .chat_id else "" end) as $chat
    | (if ($chat | type) == "string" and ($chat == "" or ($chat | test("^-?[0-9]{1,20}\\z"))) then . else error("chat_id non valido") end) as $_c
    | ($in | if has("healthchecks_url") then .healthchecks_url else "" end) as $hc
    | (if ($hc | type) == "string" and ($hc == "" or ($hc | test("^https://hc-ping\\.com/[A-Za-z0-9_/-]{1,150}\\z"))) then . else error("healthchecks_url non valido") end) as $_d
    | ($in | if has("urls") then .urls else [] end) as $urls
    | (if ($urls | type) == "array" then . else error("urls deve essere un elenco") end) as $_e
    | (if ($urls | length) <= 20 then . else error("al massimo 20 indirizzi") end) as $_f
    | ($urls | map(
        obj("ogni indirizzo deve essere un oggetto")
        | (.url) as $u
        | (if ($u | type) == "string"
              and ($u | utf8bytelength) <= 512
              and ($u | test("^https://[a-z0-9.-]+([/?#]|\\z)"))
              and ($u | test("[[:cntrl:][:space:]]") | not)
           then . else error("indirizzo non valido (https, senza credenziali né spazi, al massimo 512 byte)") end) as $_u
        | (if has("keyword") then .keyword else "" end) as $k
        | (if ($k | type) == "string" and ($k | utf8bytelength) <= 100 and ($k | nocntrl)
           then . else error("parola attesa non valida (al massimo 100 byte, senza caratteri di controllo)") end) as $_k
        | {url: $u, keyword: $k}
      )) as $nurls
    | ($in | if has("thresholds") then .thresholds else {} end | obj("thresholds deve essere un oggetto")) as $th0
    | {fail_count: [1,10], timeout_s: [2,30], slow_s: [1,30], slow_count: [1,30], remind_min: [5,1440],
       disk_warn_pct: [50,99], disk_crit_pct: [50,99], mem_avail_pct: [1,50], mem_minutes: [1,60],
       load_factor: [1,10], load_minutes: [1,60], cert_days: [1,30], f2b_bans: [1,1000], f2b_minutes: [1,60]} as $lim
    | ({fail_count: 2, timeout_s: 10, slow_s: 3, slow_count: 5, remind_min: 30,
        disk_warn_pct: 85, disk_crit_pct: 95, mem_avail_pct: 10, mem_minutes: 5,
        load_factor: 2, load_minutes: 10, cert_days: 14, f2b_bans: 20, f2b_minutes: 10} as $dflt
       | reduce ($lim | keys[]) as $key ($dflt;
           . + {($key): ($th0 | if has($key) then .[$key] else $dflt[$key] end)})) as $th
    | ($lim | to_entries | map(
        . as $e
        | $th[$e.key] as $v
        | if ($v | isint) and $v >= $e.value[0] and $v <= $e.value[1] then 0
          else error("soglia non valida: " + $e.key) end)) as $_g
    | (if $th.disk_warn_pct < $th.disk_crit_pct then . else error("disk_warn_pct deve essere minore di disk_crit_pct") end) as $_h
    | {enabled: $en, telegram: {bot_token: $tok, chat_id: $chat}, healthchecks_url: $hc,
       urls: $nurls, thresholds: ($th | map_values(floor))}
  ) catch {err: .}
'

# mon_validate_config JSON_NUOVO [JSON_VECCHIO] — stampa la configurazione
# risultante (bot_token assente nel nuovo = quello del vecchio) oppure, con
# errore, "ERR: messaggio" su stdout. Non scrive nulla.
mon_validate_config() {
  local LC_ALL=C new="${1-}" old="${2-}" oldtok out host
  oldtok="$(jq -r '(.telegram.bot_token // "") | if type == "string" then . else "" end' <<<"$old" 2>/dev/null)" || oldtok=""
  if ! out="$(OLDTOK="$oldtok" jq -c "$_MON_VALIDATE_JQ" <<<"$new" 2>/dev/null)" || [[ -z "$out" ]]; then
    printf 'ERR: JSON non valido\n'
    return 1
  fi
  if jq -e 'has("err")' >/dev/null 2>&1 <<<"$out"; then
    printf 'ERR: %s\n' "$(jq -r '.err' <<<"$out")"
    return 1
  fi
  # L'host di ogni indirizzo segue la regola dei domini del resto dell'installer.
  while IFS= read -r host; do
    if ! valid_domain "$host"; then
      printf 'ERR: host dell'\''indirizzo non valido\n'
      return 1
    fi
  done < <(jq -r '.urls[].url | capture("^https://(?<h>[a-z0-9.-]+)").h' <<<"$out")
  printf '%s\n' "$out"
}

# mon_config_load — configurazione corrente (predefinita se il file manca o è corrotto).
mon_config_load() {
  local out
  if [[ -f "$MON_CONFIG" ]] &&
    out="$(jq -c --argjson d "$(mon_defaults)" '
      def dn: with_entries(select(.value != null));
      if type == "object" then
        dn | (if (.telegram | type) == "object" then .telegram |= dn else del(.telegram) end)
        | (if (.thresholds | type) == "object" then .thresholds |= dn else del(.thresholds) end)
        | $d * .
      else error("no") end' "$MON_CONFIG" 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    mon_defaults
  fi
}

# mon_state_load — stato corrente; vuoto se il file manca o non è JSON.
mon_state_load() {
  local out
  if [[ -f "$MON_STATE" ]] &&
    out="$(jq -c '(if type == "object" then . else error("no") end)
      | ({checks: {}, alerts: [], cursor: {}} + .)
      | .checks = (if (.checks | type) == "object" then .checks else {} end)
      | .alerts = (if (.alerts | type) == "array" then .alerts else [] end)
      | .cursor = (if (.cursor | type) == "object" then .cursor else {} end)' "$MON_STATE" 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '{"checks":{},"alerts":[],"cursor":{}}\n'
  fi
}

# mon_state_save JSON — scrittura atomica, root:root 600.
mon_state_save() {
  jq -e . >/dev/null 2>&1 <<<"$1" || return 1
  install -d -m 700 "$MON_STATE_DIR"
  jq -c . <<<"$1" | write_file "$MON_STATE" 600 root:root
}

# mon_transition STATO_CHECK ESITO ORA SOGLIE — funzione pura. ESITO: ok|fail|slow.
# Stampa {"check":{state,fails,slows,since,last_alert},"event":"down|up|slow|remind|none","duration_s":N}.
# since = ora del primo esito negativo del problema. Uno "slow" su un controllo
# già giù non lo fa rientrare (serve un ok) e non produce promemoria (voluto: il
# promemoria di un controllo giù nasce dai nuovi "fail"). Stato o soglie illeggibili = valori
# predefiniti (stato nuovo; fail_count 2, slow_count 5, remind_min 30).
mon_transition() {
  jq -nc --arg s "${1-}" --arg o "${2-}" --arg now "${3-}" --arg th "${4-}" '
    def num($v; $d): if ($v | type) == "number" then $v else $d end;
    def obj: if type == "object" then . else {} end;
    ($now | tonumber) as $n
    | ($th | fromjson? // {} | obj) as $t
    | num($t.fail_count; 2) as $fc
    | num($t.slow_count; 5) as $sc
    | num($t.remind_min; 30) as $rm
    | ($s | fromjson? // {} | obj) as $x
    | {state: (if $x.state == "down" or $x.state == "warn" then $x.state else "ok" end),
       fails: num($x.fails; 0), slows: num($x.slows; 0),
       since: num($x.since; null), last_alert: num($x.last_alert; null)} as $c
    | def due($d): $d.last_alert == null or ($n - $d.last_alert) >= $rm * 60;
      (if $o == "ok" then
        if $c.state != "ok" then
          {check: {state: "ok", fails: 0, slows: 0, since: null, last_alert: null},
           event: "up", duration_s: (if $c.since == null then 0 else $n - $c.since end)}
        else
          {check: {state: "ok", fails: 0, slows: 0, since: null, last_alert: null}, event: "none"}
        end
      elif $o == "fail" then
        ($c + {fails: ($c.fails + 1), slows: 0, since: ($c.since // $n)}) as $d
        | if $d.fails < $fc then {check: $d, event: "none"}
          elif $d.state != "down" then {check: ($d + {state: "down", last_alert: $n}), event: "down"}
          elif due($d) then {check: ($d + {last_alert: $n}), event: "remind"}
          else {check: $d, event: "none"} end
      elif $o == "slow" then
        ($c + {slows: ($c.slows + 1), fails: 0, since: ($c.since // $n)}) as $d
        | if $d.state == "down" or $d.slows < $sc then {check: $d, event: "none"}
          elif $d.state != "warn" then {check: ($d + {state: "warn", last_alert: $n}), event: "slow"}
          elif due($d) then {check: ($d + {last_alert: $n}), event: "remind"}
          else {check: $d, event: "none"} end
      else error("esito sconosciuto") end)
    | .duration_s = (.duration_s // 0)' 2>/dev/null
}

# _mon_trunc TESTO — al massimo 3900 caratteri (sotto il limite di Telegram, 4096).
_mon_trunc() {
  jq -nr --arg t "$1" '$t[0:3900]'
}

# mon_message TIPO TESTO — "<emoji> <hostname>: <testo>" (testo troncato a 3900 caratteri).
mon_message() {
  local emoji
  case "$1" in
    down) emoji="🔴" ;;
    up) emoji="🟢" ;;
    warn) emoji="🟡" ;;
    ssh) emoji="🔐" ;;
    summary) emoji="📋" ;;
    test) emoji="✅" ;;
    *) emoji="ℹ️" ;;
  esac
  _mon_trunc "$(printf '%s %s: %s' "$emoji" "$(hostname)" "$2")"
}

# mon_send TESTO — il token sta nell'indirizzo: passa a curl da stdin (-K -),
# mai negli argomenti. Codici: 0 inviato; 1 errore transitorio (curl, 429, 5xx,
# risposta senza JSON, configurazione mancante o non valida: curl non viene
# chiamato); 2 rifiuto permanente (error_code 400/403/404, testo vuoto).
mon_send() {
  local cfg tok chat resp text code
  cfg="$(mon_config_load)"
  tok="$(jq -r '.telegram.bot_token // empty' <<<"$cfg")"
  chat="$(jq -r '.telegram.chat_id // empty' <<<"$cfg")"
  [[ -n "$tok" && -n "$chat" ]] || return 1
  # Difesa in profondità: niente virgolette o a capo nella configurazione di curl.
  [[ "$tok" =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{30,60}$ ]] || return 1
  [[ "$chat" =~ ^-?[0-9]{1,20}$ ]] || return 1
  text="$(_mon_trunc "$1")"
  [[ -n "$text" ]] || return 2
  resp="$(printf 'url = "%s/bot%s/sendMessage"\n' "$TELEGRAM_API" "$tok" \
    | curl -sS --max-time 10 -K - --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" 2>/dev/null)" || return 1
  if jq -e '.ok == true' >/dev/null 2>&1 <<<"$resp"; then
    return 0
  fi
  code="$(jq -r '.error_code // empty' 2>/dev/null <<<"$resp")" || code=""
  case "$code" in
    400 | 403 | 404) return 2 ;;
    *) return 1 ;;
  esac
}

# mon_enqueue TESTO — accoda un messaggio non consegnato (al massimo 500, i più
# vecchi si scartano); elimina i temporanei abbandonati da più di un'ora.
mon_enqueue() {
  local name tmp n
  local -a files
  install -d -m 700 "$MON_STATE_DIR" "$MON_QUEUE"
  find "$MON_QUEUE" -maxdepth 1 -name '.tmp.*' -mmin +60 -delete 2>/dev/null || true
  name="$(date +%s%N)"
  while [[ -e "$MON_QUEUE/$name" ]]; do name=$((name + 1)); done
  tmp="$MON_QUEUE/.tmp.$name"
  (
    umask 077
    printf '%s' "$1" >"$tmp"
  )
  mv -f "$tmp" "$MON_QUEUE/$name"
  files=("$MON_QUEUE"/[0-9]*)
  n=${#files[@]}
  if ((n > 500)); then
    rm -f -- "${files[@]:0:n-500}"
  fi
  return 0
}

# mon_flush_queue [MAX] [SCADENZA_EPOCH] — invia i messaggi in coda dal più
# vecchio. Si ferma al primo errore transitorio, dopo MAX tentativi (default 20)
# o quando l'ora raggiunge SCADENZA_EPOCH (se data). I rifiuti permanenti e i
# file vuoti vengono eliminati. Ritorna sempre 0.
mon_flush_queue() {
  local max="${1:-20}" deadline="${2:-}" f tries=0 msg rc
  [[ -d "$MON_QUEUE" ]] || return 0
  for f in "$MON_QUEUE"/[0-9]*; do
    [[ -f "$f" ]] || continue
    if [[ ! -s "$f" ]]; then
      rm -f "$f"
      continue
    fi
    ((tries < max)) || break
    if [[ -n "$deadline" ]] && (($(date +%s) >= deadline)); then
      break
    fi
    tries=$((tries + 1))
    msg="$(cat "$f")"
    rc=0
    mon_send "$msg" || rc=$?
    case "$rc" in
      0 | 2) rm -f "$f" ;;
      *) break ;;
    esac
  done
  return 0
}
