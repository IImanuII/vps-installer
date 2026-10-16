# Corpo del curl finto dei test di vps-monitor (vedi tool_env in monitor.bats).
# Argomenti annotati in $T/curl.args. Tre casi:
# - Telegram (-K -): stdin in $T/curl.stdin; con $T/tg.down esce 7; altrimenti
#   il testo inviato va in $T/sent e la risposta è $T/tg.resp (o ok:true);
# - controllo di un indirizzo (-w): risposta da $T/url.<chiave> "CODICE TEMPO CORPO"
#   (predefinita "200 0.100 OK"); "sleep N" dorme N secondi ed esce 28 (timeout);
# - altrimenti (ping di Healthchecks) l'indirizzo va in $T/pings.
T="$BATS_TEST_TMPDIR"
# una sola scrittura: i controlli in parallelo non si mescolano
args="$(printf '%s\n' "$@" ---)"
printf '%s\n' "$args" >>"$T/curl.args"
for a in "$@"; do
  if [[ "$a" == -K ]]; then
    cat >>"$T/curl.stdin"
    if [[ -f "$T/tg.down" ]]; then exit 7; fi
    for b in "$@"; do
      case "$b" in text=*) printf '%s\n' "${b#text=}" >>"$T/sent" ;; esac
    done
    if [[ -f "$T/tg.resp" ]]; then cat "$T/tg.resp"; else echo '{"ok":true,"result":{}}'; fi
    exit 0
  fi
done
url="${!#}"
w="" out="" prev=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    -w) w=1 ;;
  esac
  prev="$a"
done
if [[ -z "$w" ]]; then
  printf '%s\n' "$url" >>"$T/pings"
  exit 0
fi
key="$(printf '%s' "$url" | tr -c 'A-Za-z0-9' _)"
code=200 time=0.100 body=OK
if [[ -f "$T/url.$key" ]]; then read -r code time body <"$T/url.$key"; fi
if [[ "$code" == sleep ]]; then
  sleep "$time"
  exit 28
fi
printf '%s' "$body" >"$out"
printf '%s %s' "$code" "$time"
