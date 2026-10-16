# shellcheck shell=bash
# vps-monitor: i controlli di un giro (`vps-monitor _run`, spec §2.3) e la
# risposta di `vps-monitor status`. Si appoggia a lib/monitor.sh. Solo variabili
# con default e funzioni: nessun effetto al caricamento.
#
# Un giro lavora su variabili globali, così le funzioni dei controlli non girano
# in sottoshell: MON_NOW_S (ora del giro), MON_TH (soglie), MON_ST (stato),
# MON_MSGS (messaggi nuovi, nell'ordine), MON_ALERTS (gli stessi, per l'elenco
# delle ultime 24 ore, senza il riepilogo), MON_SEEN (controlli visti nel giro).
# Il giro gira senza `set -e`: un controllo che fallisce non ferma gli altri.

: "${MON_PROC:=/proc}"
: "${MON_LE_LIVE:=/etc/letsencrypt/live}"
: "${MON_F2B_LOG:=/var/log/fail2ban.log}"
: "${MON_REBOOT_FILE:=/var/run/reboot-required}"

# Controlli ogni 6 ore (certificati, token Cloudflare) e limiti per giro.
MON_PERIODIC_S=21600
MON_SSH_MAX=10
MON_RESTARTS_MAX=3
# Tempo di un giro: oltre MON_ROUND_S secondi dall'inizio si rimandano al giro
# dopo riavvii, controlli delle 6 ore e riepilogo (systemd ferma il giro a 55 s).
: "${MON_ROUND_S:=40}"
: "${MON_RESTART_TIMEOUT:=10}"
# Corpo di una risposta: al massimo 2 MiB (non deve riempire /tmp).
MON_MAX_BODY=2097152

# _mon_late — vero se il tempo del giro (MON_DEADLINE) è finito.
_mon_late() {
  (($(date +%s) >= ${MON_DEADLINE:-0}))
}

# _mon_th CHIAVE — una soglia dalla configurazione del giro.
_mon_th() {
  jq -r --arg k "$1" '.[$k]' <<<"$MON_TH"
}

# _mon_mins SECONDI — minuti arrotondati per eccesso, almeno 1.
_mon_mins() {
  local s="${1:-0}" m
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  m=$(((s + 59) / 60))
  if ((m < 1)); then m=1; fi
  printf '%s' "$m"
}

# _mon_st FILTRO [ARGOMENTI jq] — aggiorna MON_ST; se jq fallisce lo stato resta com'era.
_mon_st() {
  local out
  if out="$(jq -c "$@" <<<"$MON_ST")" && [[ -n "$out" ]]; then
    MON_ST="$out"
  else
    log "vps-monitor: aggiornamento dello stato non riuscito"
  fi
}

_mon_check_get() {
  jq -c --arg id "$1" '.checks[$id] // {} | if type == "object" then . else {} end' <<<"$MON_ST" 2>/dev/null || printf '{}'
}

_mon_check_put() {
  MON_SEEN+=("$1")
  _mon_st --arg id "$1" --argjson c "$2" '.checks[$id] = $c'
}

# _mon_say TIPO TESTO — nuovo messaggio del giro.
_mon_say() {
  local m
  m="$(mon_message "$1" "$2")"
  MON_MSGS+=("$m")
  if [[ "$1" != summary ]]; then MON_ALERTS+=("$m"); fi
}

# _mon_step ID ESITO EXTRA_JSON — controlli a contatori (indirizzi): applica
# mon_transition e salva il controllo con i campi in più. Lascia in MON_EV
# l'evento, in MON_DUR la durata (al rientro), in MON_PREV lo stato di prima e
# in MON_SINCE l'inizio del problema.
_mon_step() {
  local old res
  old="$(_mon_check_get "$1")"
  MON_PREV="$(jq -r '.state // "ok"' <<<"$old" 2>/dev/null)" || MON_PREV=ok
  MON_EV=none MON_DUR=0 MON_SINCE=""
  res="$(mon_transition "$old" "$2" "$MON_NOW_S" "$MON_TH")" || res=""
  [[ -n "$res" ]] || return 0
  read -r MON_EV MON_DUR MON_SINCE < <(jq -r '[.event, .duration_s, (.check.since // "")] | @tsv' <<<"$res")
  _mon_check_put "$1" "$(jq -c --argjson x "$3" '.check + $x' <<<"$res")"
}

# _mon_level ID LIVELLO EXTRA_JSON — controlli a livello (ok|warn|down: risorse,
# servizi, certificati...): avviso quando il livello cambia, promemoria ogni
# remind_min se il problema continua, rientro con la durata. MON_EV:
# new|up|remind|none; MON_DUR, MON_PREV e MON_SINCE come in _mon_step.
_mon_level() {
  local old res
  old="$(_mon_check_get "$1")"
  MON_EV=none MON_DUR=0 MON_SINCE=""
  res="$(jq -c --arg l "$2" --argjson n "$MON_NOW_S" --argjson rm "$(_mon_th remind_min)" --argjson x "$3" '
    def num($v; $d): if ($v | type) == "number" then $v else $d end;
    (if .state == "warn" or .state == "down" then .state else "ok" end) as $s
    | num(.since; null) as $since
    | num(.last_alert; null) as $la
    | (if $l == "ok" then
        {ev: (if $s == "ok" then "none" else "up" end),
         dur: (if $s == "ok" then 0 else $n - ($since // $n) end),
         c: {state: "ok", since: null, last_alert: null}}
      elif $l != $s then {ev: "new", dur: 0, c: {state: $l, since: ($since // $n), last_alert: $n}}
      elif $la == null or ($n - $la) >= $rm * 60 then
        {ev: "remind", dur: 0, c: {state: $l, since: ($since // $n), last_alert: $n}}
      else {ev: "none", dur: 0, c: {state: $l, since: ($since // $n), last_alert: $la}} end)
    | {prev: $s, ev, dur, c: (.c + $x)}' <<<"$old" 2>/dev/null)" || res=""
  if [[ -z "$res" ]]; then
    MON_PREV=ok
    return 0
  fi
  read -r MON_PREV MON_EV MON_DUR MON_SINCE < <(jq -r '[.prev, .ev, .dur, (.c.since // "")] | @tsv' <<<"$res")
  _mon_check_put "$1" "$(jq -c '.c' <<<"$res")"
}

# _mon_for — minuti dall'inizio del problema (MON_SINCE) a ora.
_mon_for() {
  _mon_mins $((MON_NOW_S - ${MON_SINCE:-$MON_NOW_S}))
}

# ---------------------------------------------------------------- indirizzi

# _mon_fetch URL TIMEOUT PREFISSO [RESOLVE] — un indirizzo (in background):
# corpo in PREFISSO.body, "uscita_curl codice tempo" in PREFISSO.res.
_mon_fetch() {
  local out rc=0
  local -a extra=()
  if [[ -n "${4:-}" ]]; then extra=(--resolve "$4"); fi
  out="$(curl -q -sS --globoff --max-filesize "$MON_MAX_BODY" -o "$3.body" -w '%{http_code} %{time_total}' --max-time "$2" "${extra[@]}" "$1" 2>/dev/null)" || rc=$?
  printf '%s %s\n' "$rc" "${out:-000 0}" >"$3.res"
}

# mon_check_urls — /health del pannello (dritto a 127.0.0.1) e gli indirizzi
# della configurazione, tutti in parallelo con --max-time timeout_s.
mon_check_urls() {
  local dir dom to slow n i id url kw rc code t ms outcome detail ts
  local -a ids=() urls=() kws=() res=()
  to="$(_mon_th timeout_s)"
  slow="$(_mon_th slow_s)"
  dom="$(jq -r '.panel.domain // empty' "$(manifest_path)" 2>/dev/null)" || dom=""
  if [[ -n "$dom" ]] && valid_domain "$dom"; then
    ids+=(health) urls+=("https://$dom/health") kws+=("") res+=("$dom:443:127.0.0.1")
  fi
  n="$(jq -r '.urls | length' <<<"$MON_CFG")" || n=0
  for ((i = 0; i < n; i++)); do
    url="$(jq -r --argjson i "$i" '.urls[$i].url' <<<"$MON_CFG")"
    kw="$(jq -r --argjson i "$i" '.urls[$i].keyword // ""' <<<"$MON_CFG")"
    ids+=("url:$url") urls+=("$url") kws+=("$kw") res+=("")
  done
  ((${#ids[@]})) || return 0
  dir="$(mktemp -d)"
  for i in "${!ids[@]}"; do
    _mon_fetch "${urls[$i]}" "$to" "$dir/$i" "${res[$i]}" &
  done
  wait
  for i in "${!ids[@]}"; do
    id="${ids[$i]}" url="${urls[$i]}" kw="${kws[$i]}"
    rc=1 code=000 t=0
    if [[ -f "$dir/$i.res" ]]; then read -r rc code t <"$dir/$i.res"; fi
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    [[ "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]] || t=0
    ms="$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }')"
    outcome=ok detail=""
    if ((rc != 0)); then
      outcome=fail
      case "$rc" in
        28) detail="nessuna risposta in $to s" ;;
        63) detail="risposta oltre 2 MiB" ;;
        *) detail="errore di connessione" ;;
      esac
    elif [[ "$id" == health ]] && { [[ "$code" != 200 ]] || ! head -c 1048576 "$dir/$i.body" 2>/dev/null | grep -qF OK; }; then
      outcome=fail detail="HTTP $code"
    elif [[ "$code" == 000 ]] || ((10#$code >= 500)); then
      outcome=fail detail="HTTP $code"
    elif [[ -n "$kw" ]] && ! head -c 1048576 "$dir/$i.body" 2>/dev/null | grep -qF -- "$kw"; then
      outcome=fail detail="parola attesa assente"
    elif awk -v t="$t" -v s="$slow" 'BEGIN { exit !(t > s) }'; then
      outcome=slow
    fi
    _mon_step "$id" "$outcome" "$(jq -nc --arg l "$url" --argjson c "$((10#$code))" --argjson ms "$ms" --arg d "$detail" \
      '{kind: "url", label: $l, code: (if $c == 0 then null else $c end), time_ms: $ms, detail: $d}')"
    ts="$(awk -v t="$t" 'BEGIN { printf "%.1f", t }')"
    case "$MON_EV" in
      down) _mon_say down "$url è giù da $(_mon_for) min ($detail)" ;;
      remind)
        if [[ "$MON_PREV" == down ]]; then
          _mon_say down "$url è ancora giù da $(_mon_for) min ($detail)"
        else
          _mon_say warn "$url è ancora lento da $(_mon_for) min: $ts s (soglia $slow s)"
        fi
        ;;
      slow) _mon_say warn "$url è lento: $ts s (soglia $slow s)" ;;
      up)
        if [[ "$MON_PREV" == down ]]; then
          _mon_say up "$url di nuovo raggiungibile (giù per $(_mon_mins "$MON_DUR") min)"
        else
          _mon_say up "$url di nuovo veloce (lento per $(_mon_mins "$MON_DUR") min)"
        fi
        ;;
    esac
  done
  rm -rf "$dir"
}

# ---------------------------------------------------------------- servizi

# mon_services — i servizi da sorvegliare secondo il manifest.
mon_services() {
  local c
  c="$(jq -c '.components // {} | if type == "object" then . else {} end' "$(manifest_path)" 2>/dev/null)" || c='{}'
  [[ -n "$c" ]] || c='{}'
  if [[ "$(jq -r '.nginx == true' <<<"$c")" == true ]]; then echo nginx; fi
  if [[ "$(jq -r '.php != null and .php != false' <<<"$c")" == true ]]; then echo "php$PHP_VERSION-fpm"; fi
  if [[ "$(jq -r '.mariadb == true' <<<"$c")" == true ]]; then echo mariadb; fi
  if [[ "$(jq -r '.redis == true' <<<"$c")" == true ]]; then echo redis-server; fi
  echo fail2ban
}

# _mon_svc_extra NOME RIAVVII_JSON SOSPESI — campi in più del controllo di un servizio.
_mon_svc_extra() {
  jq -nc --arg l "$1" --argjson r "$2" --argjson sp "$3" '{kind: "service", label: $l, restarts: $r, suspended: $sp}'
}

# _mon_service NOME — attivo = ok; fermo = un riavvio (al massimo 3 l'ora,
# poi "riavvii sospesi" finché non passa un'ora dall'ultimo). Il riavvio si
# registra e si salva nello stato PRIMA di lanciarlo: un giro fermato da
# systemd a metà non perde il conto dei riavvii. Oltre la scadenza del giro
# il riavvio si rimanda al giro dopo.
_mon_service() {
  local s="$1" id="service:$1" old restarts n was
  old="$(_mon_check_get "$id")"
  restarts="$(jq -c --argjson n "$MON_NOW_S" '[(.restarts // []) | if type == "array" then .[] else empty end
    | numbers | select(. > $n - 3600)]' <<<"$old" 2>/dev/null)" || restarts='[]'
  [[ -n "$restarts" ]] || restarts='[]'
  if systemctl is-active --quiet "$s"; then
    _mon_level "$id" ok "$(_mon_svc_extra "$s" "$restarts" false)"
    if [[ "$MON_EV" == up ]]; then _mon_say up "$s di nuovo attivo (fermo per $(_mon_mins "$MON_DUR") min)"; fi
    return 0
  fi
  n="$(jq 'length' <<<"$restarts")"
  if ((n >= MON_RESTARTS_MAX)); then
    was="$(jq -r '.suspended == true' <<<"$old" 2>/dev/null)" || was=false
    _mon_level "$id" down "$(_mon_svc_extra "$s" "$restarts" true)"
    if [[ "$was" != true ]]; then
      _mon_say down "$s continua a cadere: riavvii automatici sospesi per un'ora"
    elif [[ "$MON_EV" == remind ]]; then
      _mon_say down "$s ancora fermo da $(_mon_for) min (riavvii sospesi)"
    fi
    return 0
  fi
  if _mon_late; then
    MON_SEEN+=("$id")
    log "vps-monitor: $s non attivo, riavvio rimandato al prossimo giro (tempo del giro finito)"
    return 0
  fi
  log "vps-monitor: $s non attivo, lo riavvio"
  restarts="$(jq -c --argjson n "$MON_NOW_S" '. + [$n]' <<<"$restarts")"
  _mon_st --arg id "$id" --argjson x "$(_mon_svc_extra "$s" "$restarts" false)" \
    '.checks[$id] = ((.checks[$id] // {} | if type == "object" then . else {} end) + $x)'
  mon_state_save "$MON_ST" || log "vps-monitor: stato non salvato"
  timeout "$MON_RESTART_TIMEOUT" systemctl restart "$s" >>"$VPS_LOG" 2>&1 || true
  if systemctl is-active --quiet "$s"; then
    _mon_level "$id" ok "$(_mon_svc_extra "$s" "$restarts" false)"
    if [[ "$MON_EV" == up ]]; then
      _mon_say up "$s riavviato, di nuovo attivo (fermo per $(_mon_mins "$MON_DUR") min)"
    else
      _mon_say warn "$s era fermo, riavviato"
    fi
  else
    _mon_level "$id" down "$(_mon_svc_extra "$s" "$restarts" false)"
    case "$MON_EV" in
      new) _mon_say down "$s fermo, riavvio non riuscito" ;;
      remind) _mon_say down "$s ancora fermo da $(_mon_for) min, riavvio non riuscito" ;;
    esac
  fi
}

mon_check_services() {
  local s
  while IFS= read -r s; do
    _mon_service "$s"
  done < <(mon_services)
}

# ---------------------------------------------------------------- risorse

# _mon_over ID SOPRA — contatore dei giri consecutivi oltre soglia.
_mon_over() {
  local o
  o="$(jq -r '.over // 0 | if type == "number" then . else 0 end' <<<"$(_mon_check_get "$1")" 2>/dev/null)" || o=0
  if [[ "$2" == 1 ]]; then printf '%s' $((o + 1)); else printf 0; fi
}

mon_check_resources() {
  local pct lvl tot av over mins l1 cpu lim
  # Disco: uso di / subito, senza contatore.
  pct="$(df -P / 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')" || pct=""
  if [[ "$pct" =~ ^[0-9]+$ ]]; then
    lvl=ok
    if ((pct >= $(_mon_th disk_crit_pct))); then
      lvl=down
    elif ((pct >= $(_mon_th disk_warn_pct))); then
      lvl=warn
    fi
    _mon_level disk "$lvl" "$(jq -nc --argjson p "$pct" '{kind: "disk", label: "disco /", value: $p}')"
    case "$MON_EV" in
      new | remind) _mon_say "$lvl" "disco al $pct%" ;;
      up) _mon_say up "disco di nuovo al $pct%" ;;
    esac
  fi
  # RAM: MemAvailable sotto mem_avail_pct per mem_minutes giri di fila.
  tot="$(awk '/^MemTotal:/ { print $2 }' "$MON_PROC/meminfo" 2>/dev/null)" || tot=""
  av="$(awk '/^MemAvailable:/ { print $2 }' "$MON_PROC/meminfo" 2>/dev/null)" || av=""
  if [[ "$tot" =~ ^[0-9]+$ && "$av" =~ ^[0-9]+$ ]] && ((tot > 0)); then
    pct=$((av * 100 / tot))
    over="$(_mon_over mem $((pct < $(_mon_th mem_avail_pct))))"
    mins="$(_mon_th mem_minutes)"
    lvl=ok
    if ((over >= mins)); then lvl=warn; fi
    _mon_level mem "$lvl" "$(jq -nc --argjson p "$pct" --argjson o "$over" '{kind: "mem", label: "RAM disponibile", value: $p, over: $o}')"
    case "$MON_EV" in
      new | remind) _mon_say warn "RAM disponibile al $pct% da $over min" ;;
      up) _mon_say up "RAM di nuovo disponibile al $pct%" ;;
    esac
  fi
  # Carico a 1 minuto oltre load_factor × CPU per load_minutes giri di fila.
  l1="$(awk '{ print $1 }' "$MON_PROC/loadavg" 2>/dev/null)" || l1=""
  cpu="$(nproc 2>/dev/null)" || cpu=1
  if ! [[ "$cpu" =~ ^[0-9]+$ ]] || ((cpu == 0)); then cpu=1; fi
  if [[ "$l1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    lim=$((cpu * $(_mon_th load_factor)))
    over="$(_mon_over load "$(awk -v l="$l1" -v m="$lim" 'BEGIN { print (l > m) ? 1 : 0 }')")"
    mins="$(_mon_th load_minutes)"
    lvl=ok
    if ((over >= mins)); then lvl=warn; fi
    _mon_level load "$lvl" "$(jq -nc --arg v "$l1" --argjson o "$over" '{kind: "load", label: "carico", value: ($v | tonumber), over: $o}')"
    case "$MON_EV" in
      new | remind) _mon_say warn "carico a $l1 ($cpu CPU) da $over min" ;;
      up) _mon_say up "carico di nuovo normale ($l1)" ;;
    esac
  fi
}

# ---------------------------------------------------------------- SSH e fail2ban

# mon_check_ssh — un avviso per ogni accesso SSH dal giro precedente
# (cursore = ora del giro precedente; si contano le righe con cursore <= ora < adesso).
mon_check_ssh() {
  local cur out line ts n=0
  # Solo le righe scritte da sshd stesso (sshd o sshd-session di OpenSSH ≥ 9.8):
  # un nome utente inventato dentro un'altra riga non deve generare avvisi.
  local re=' sshd(-session)?\[[0-9]+\]: Accepted ([a-z-]+(/[a-z]+)?) for ([^ ]+) from ([0-9a-fA-F:.]+) port [0-9]+'
  cur="$(jq -r '.cursor.ssh // empty' <<<"$MON_ST")" || cur=""
  if ! [[ "$cur" =~ ^[0-9]+$ ]] || ((cur > MON_NOW_S || MON_NOW_S - cur > 86400)); then
    cur=$((MON_NOW_S - 60))
  fi
  out="$(journalctl -u ssh --since "@$cur" -o short-unix --no-pager 2>/dev/null)" || out=""
  while IFS= read -r line; do
    ts="${line%% *}"
    ts="${ts%%.*}"
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    ((ts >= cur && ts < MON_NOW_S)) || continue
    [[ "$line" =~ $re ]] || continue
    n=$((n + 1))
    if ((n <= MON_SSH_MAX)); then
      _mon_say ssh "accesso SSH di ${BASH_REMATCH[4]} da ${BASH_REMATCH[5]} (${BASH_REMATCH[2]})"
    fi
  done <<<"$out"
  if ((n > MON_SSH_MAX)); then
    _mon_say ssh "altri $((n - MON_SSH_MAX)) accessi SSH dall'ultimo controllo"
  fi
  _mon_st --argjson n "$MON_NOW_S" '.cursor.ssh = $n'
}

# mon_check_f2b — numero di Ban negli ultimi f2b_minutes (ora locale, come il log).
mon_check_f2b() {
  local mins lim from n lvl
  [[ -r "$MON_F2B_LOG" ]] || return 0
  mins="$(_mon_th f2b_minutes)"
  lim="$(_mon_th f2b_bans)"
  from="$(date -d "@$((MON_NOW_S - mins * 60))" '+%F %T')"
  n="$(tail -n 20000 "$MON_F2B_LOG" | awk -v f="$from" 'substr($0, 1, 19) >= f && /\] Ban / { c++ } END { print c + 0 }')" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  lvl=ok
  if ((n >= lim)); then lvl=warn; fi
  _mon_level f2b "$lvl" "$(jq -nc --argjson v "$n" '{kind: "f2b", label: "fail2ban", value: $v}')"
  case "$MON_EV" in
    new | remind) _mon_say warn "fail2ban: $n IP bloccati negli ultimi $mins min" ;;
    up) _mon_say up "fail2ban: blocchi di nuovo sotto soglia" ;;
  esac
}

# ---------------------------------------------------------------- ogni 6 ore

# mon_check_periodic — certificati e token Cloudflare, al più ogni 6 ore.
# Ritorna 0 se ha controllato (i controlli cert:/cf_token vanno allora
# ripuliti come gli altri), 1 se non era ancora il momento.
mon_check_periodic() {
  local last f dom end e days lvl cd out err
  last="$(jq -r '.cursor.periodic // empty' <<<"$MON_ST")" || last=""
  if [[ "$last" =~ ^[0-9]+$ ]] && ((last <= MON_NOW_S && MON_NOW_S - last < MON_PERIODIC_S)); then
    return 1
  fi
  # Oltre il tempo del giro si rimanda al giro dopo. Il cursore si salva prima
  # dei controlli: un giro fermato a metà non li fa ripartire ogni minuto.
  if _mon_late; then return 1; fi
  _mon_st --argjson n "$MON_NOW_S" '.cursor.periodic = $n'
  mon_state_save "$MON_ST" || log "vps-monitor: stato non salvato"
  cd="$(_mon_th cert_days)"
  for f in "$MON_LE_LIVE"/*/cert.pem; do
    [[ -f "$f" ]] || continue
    dom="$(basename "$(dirname "$f")")"
    end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null)" || continue
    e="$(date -d "${end#notAfter=}" +%s 2>/dev/null)" || continue
    days=$(((e - MON_NOW_S) / 86400))
    lvl=ok
    if ((e <= MON_NOW_S)); then
      lvl=down
    elif ((days < cd)); then
      lvl=warn
    fi
    _mon_level "cert:$dom" "$lvl" "$(jq -nc --arg l "$dom" --argjson d "$days" '{kind: "cert", label: $l, days: $d}')"
    case "$MON_EV:$lvl" in
      new:down | remind:down) _mon_say down "il certificato di $dom è scaduto" ;;
      new:warn | remind:warn) _mon_say warn "il certificato di $dom scade tra $days giorni" ;;
      up:*) _mon_say up "il certificato di $dom è stato rinnovato" ;;
    esac
  done
  if [[ "$(jq -r '.cloudflare.enabled == true' "$(manifest_path)" 2>/dev/null)" == true ]]; then
    out="$(timeout 10 "$VPS_OPT/bin/vps-cf-token" test 2>/dev/null)" || true
    if [[ "$(jq -r '.ok == true' <<<"$out" 2>/dev/null)" == true ]]; then
      lvl=ok err=""
    else
      lvl=down
      err="$(jq -r '.error // empty' <<<"$out" 2>/dev/null)" || err=""
      if [[ -z "$err" ]]; then err="nessuna risposta"; fi
    fi
    _mon_level cf_token "$lvl" '{"kind":"cf_token","label":"token Cloudflare"}'
    case "$MON_EV" in
      new | remind) _mon_say down "il token Cloudflare non funziona: $err" ;;
      up) _mon_say up "il token Cloudflare funziona di nuovo" ;;
    esac
  fi
  mon_state_save "$MON_ST" || log "vps-monitor: stato non salvato"
  return 0
}

# ---------------------------------------------------------------- riepilogo

# mon_check_summary — alle 9 (Europe/Rome), una volta al giorno, solo se c'è
# qualcosa da dire: aggiornamenti, riavvio richiesto, avvisi delle ultime 24 ore.
mon_check_summary() {
  local day list upg sec na txt
  local -a parts=()
  [[ "$(TZ=Europe/Rome date -d "@$MON_NOW_S" +%H)" == 09 ]] || return 0
  day="$(TZ=Europe/Rome date -d "@$MON_NOW_S" +%F)"
  [[ "$(jq -r '.summary_day // ""' <<<"$MON_ST")" != "$day" ]] || return 0
  if _mon_late; then return 0; fi
  _mon_st --arg d "$day" '.summary_day = $d'
  list="$(apt list --upgradable 2>/dev/null | grep -F 'upgradable from' || true)"
  upg=0 sec=0
  if [[ -n "$list" ]]; then
    upg="$(grep -c . <<<"$list")"
    sec="$(grep -cF -- '-security' <<<"$list" || true)"
  fi
  if ((upg > 0)); then
    if ((upg == 1)); then txt="1 aggiornamento"; else txt="$upg aggiornamenti"; fi
    if ((sec > 0)); then txt+=" ($sec di sicurezza)"; fi
    parts+=("$txt")
  fi
  if [[ -e "$MON_REBOOT_FILE" ]]; then parts+=("riavvio richiesto"); fi
  na="$(jq --argjson n "$MON_NOW_S" '[.alerts[] | select(type == "object" and (.at | type) == "number" and .at > $n - 86400)] | length' <<<"$MON_ST" 2>/dev/null)" || na=0
  if ((na == 1)); then
    parts+=("1 avviso nelle ultime 24 ore")
  elif ((na > 1)); then
    parts+=("$na avvisi nelle ultime 24 ore")
  fi
  ((${#parts[@]})) || return 0
  txt="${parts[0]}"
  for ((na = 1; na < ${#parts[@]}; na++)); do txt+=", ${parts[$na]}"; done
  _mon_say summary "riepilogo — $txt"
}

# ---------------------------------------------------------------- il giro

# mon_telegram_ok CONFIG — token e chat impostati.
mon_telegram_ok() {
  [[ "$(jq -r '(.telegram.bot_token // "") != "" and (.telegram.chat_id // "") != ""' <<<"$1")" == true ]]
}

# mon_run — un giro completo (spec §2.3). L'ora si può iniettare con MON_NOW
# (test); sotto sudo la variabile è tolta. Messaggi: tutti accodati (se
# Telegram è configurato) e poi la coda è svuotata dal più vecchio, così
# l'ordine resta quello degli eventi; massimo 10 invii e non oltre 44 s
# dall'inizio del giro (systemd lo ferma a 55).
mon_run() {
  local start hc periodic=no m seen
  start="$(date +%s)"
  MON_NOW_S="${MON_NOW:-$start}"
  MON_DEADLINE=$((start + MON_ROUND_S))
  MON_CFG="$(mon_config_load)"
  [[ "$(jq -r '.enabled == true' <<<"$MON_CFG")" == true ]] || return 0
  MON_TH="$(jq -c '.thresholds' <<<"$MON_CFG")"
  MON_ST="$(mon_state_load)"
  MON_MSGS=() MON_ALERTS=() MON_SEEN=()

  mon_check_urls
  mon_check_services
  mon_check_resources
  mon_check_ssh
  mon_check_f2b
  if mon_check_periodic; then periodic=yes; fi
  mon_check_summary

  # Controlli non più presenti (indirizzo tolto, servizio rimosso...) via
  # dallo stato; cert:/cf_token restano se il controllo ogni 6 ore non è girato.
  seen="$(printf '%s\n' "${MON_SEEN[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  _mon_st --argjson seen "$seen" --arg p "$periodic" '.checks |= with_entries(select(
      .key as $k | ($seen | index($k)) != null
      or ($p == "no" and (($k | startswith("cert:")) or $k == "cf_token"))))'
  _mon_st --argjson n "$MON_NOW_S" --argjson a "$(printf '%s\n' "${MON_ALERTS[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
      .alerts = ((.alerts + ($a | map({at: $n, text: .})))
        | map(select(type == "object" and (.at | type) == "number" and .at > $n - 86400)) | .[-200:])
      | .last_run = $n'

  if mon_telegram_ok "$MON_CFG"; then
    for m in "${MON_MSGS[@]}"; do
      mon_enqueue "$m" || log "vps-monitor: messaggio non accodato"
    done
  fi
  mon_state_save "$MON_ST" || log "vps-monitor: stato non salvato"

  # Healthchecks prima della coda: un Telegram lento non deve far saltare il
  # segnale "la VPS è viva".
  hc="$(jq -r '.healthchecks_url // ""' <<<"$MON_CFG")"
  if [[ -n "$hc" ]]; then
    curl -q -fsS --globoff --max-time 10 -o /dev/null "$hc" >/dev/null 2>&1 || log "vps-monitor: ping a Healthchecks.io non riuscito"
  fi
  if mon_telegram_ok "$MON_CFG"; then
    mon_flush_queue 10 $((start + 44))
  fi
  return 0
}

# ---------------------------------------------------------------- status

# mon_status_json — risposta di `vps-monitor status` (spec §2.6). Mai il token.
mon_status_json() {
  local cfg st q=0
  cfg="$(mon_config_load)"
  st="$(mon_state_load)"
  if [[ -d "$MON_QUEUE" ]]; then
    q="$(find "$MON_QUEUE" -maxdepth 1 -type f -name '[0-9]*' | wc -l)"
  fi
  jq -nc --argjson c "$cfg" --argjson s "$st" --argjson n "$(date +%s)" --argjson q "$q" '
    def iso: if type == "number" then (floor | todate) else null end;
    def num: if type == "number" then . else null end;
    {ok: true,
     enabled: ($c.enabled == true),
     telegram_configured: (($c.telegram.bot_token // "") != "" and ($c.telegram.chat_id // "") != ""),
     healthchecks: (($c.healthchecks_url // "") != ""),
     last_run: ($s.last_run | iso),
     checks: [$s.checks | to_entries[] | .key as $id | (.value | if type == "object" then . else {} end) as $v
       | {id: $id, kind: ($v.kind // ($id | split(":")[0])), label: ($v.label // $id),
          state: (if $v.state == "warn" or $v.state == "down" then $v.state else "ok" end),
          since: ($v.since | iso), code: ($v.code | num), time_ms: ($v.time_ms | num)}],
     alerts: [$s.alerts[] | select(type == "object" and (.at | type) == "number" and .at > $n - 86400)
       | {at: (.at | iso), text: (.text | tostring)}],
     urls: [$c.urls[]? | {url, keyword}],
     thresholds: $c.thresholds,
     queued: $q}'
}
