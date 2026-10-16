#!/usr/bin/env bash
# End-to-end di vps-monitor in WSL (root): config, timer, giri, avvisi, coda.
# Telegram è finto (php -S su 127.0.0.1), systemctl è finto (registra soltanto),
# l'indirizzo sorvegliato non si risolve mai. Non tocca /etc, /opt né i servizi veri.
# Uso (da Windows, via PowerShell):
#   wsl -d Debian -- sudo bash /mnt/c/.../vps-installer/tests/e2e/monitor-e2e.sh
set -Eeuo pipefail
src="$(cd "$(dirname "$0")/../.." && pwd)"
((EUID == 0)) || { echo "Serve root: sudo bash $0" >&2; exit 2; }
for t in php jq curl flock; do command -v "$t" >/dev/null || { echo "Manca '$t'" >&2; exit 2; }; done

work="$(mktemp -d /tmp/monitor-e2e.XXXXXX)"
chmod 755 "$work"
php_pid=
URL='https://e2e-monitor.invalid/'
TOKEN='123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

fail() {
  echo "E2E FALLITO: $*" >&2
  [[ ! -f "$work/tg.log" ]] || { echo "--- Telegram finto" >&2; tail -n 20 "$work/tg.log" >&2; }
  [[ ! -f "${VPS_LOG:-}" ]] || { echo "--- ultime righe di $VPS_LOG" >&2; tail -n 20 "$VPS_LOG" >&2; }
  exit 1
}

stop_tg() {
  if [[ -n "$php_pid" ]]; then
    kill "$php_pid" 2>/dev/null || true
    wait "$php_pid" 2>/dev/null || true
    php_pid=
  fi
}
cleanup() {
  set +e
  stop_tg
  rm -rf "$work"
}
trap cleanup EXIT

# Telegram finto: salva il corpo di ogni POST e risponde {"ok":true}.
cat >"$work/router.php" <<'PHP'
<?php
$b = file_get_contents('php://input');
file_put_contents(getenv('TG_LOG'), $b . "\n" . json_encode($_POST, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n", FILE_APPEND);
header('Content-Type: application/json');
echo '{"ok":true}';
PHP
: >"$work/tg.log"
port=$((20000 + RANDOM % 20000))
start_tg() {
  TG_LOG="$work/tg.log" php -S "127.0.0.1:$port" "$work/router.php" >"$work/php.out" 2>&1 &
  php_pid=$!
  for _ in {1..40}; do
    /usr/bin/curl -s -o /dev/null "http://127.0.0.1:$port/" && return 0
    sleep 0.25
  done
  fail "il Telegram finto non parte: $(cat "$work/php.out")"
}

# systemctl finto: registra le chiamate; is-active risponde sempre "attivo",
# così nessun servizio vero viene riavviato.
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/systemctl" <<SH
#!/usr/bin/env bash
echo "\$*" >>"$work/systemctl.calls"
case "\$1" in
  is-active) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$bin/systemctl"
export PATH="$bin:$PATH"

# Come il timer: root senza SUDO_USER, con le variabili di prova.
unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
export VPS_OPT="$work/opt" VPS_LIB="$src/lib" VPS_TEMPLATES="$src/templates" VPS_LOG="$work/tools.log"
export MON_DIR="$work/mon" MON_STATE_DIR="$work/state" MON_LOCK="$work/mon.lock" SYSTEMD_DIR="$work/systemd"
export MON_LE_LIVE="$work/le" MON_F2B_LOG="$work/fail2ban.log" MON_REBOOT_FILE="$work/reboot-required"
export TELEGRAM_API="http://127.0.0.1:$port"
mkdir -p "$VPS_OPT" "$MON_DIR" "$MON_STATE_DIR" "$MON_LE_LIVE" "$SYSTEMD_DIR"
# Nessun componente: l'unico servizio sorvegliato (fail2ban) è finto "attivo".
jq -n '{installer_version:"1.5.0", components:{}}' >"$VPS_OPT/manifest.json"

vm() { bash "$src/tools/vps-monitor" "$@"; }
t0="$(date +%s)"
run() { MON_NOW="$1" vm _run || fail "_run ha restituito un errore"; }
sent() { grep -c 'e2e-monitor.invalid' "$work/tg.log" || true; }

start_tg

echo "== config: attiva il timer"
cfg="$(jq -n --arg t "$TOKEN" --arg u "$URL" \
  '{enabled:true, telegram:{bot_token:$t, chat_id:"42"}, urls:[{url:$u, keyword:""}]}')"
res="$(vm config <<<"$cfg")"
jq -e '.ok == true' <<<"$res" >/dev/null || fail "config: $res"
grep -qx 'enable --now vps-monitor.timer' "$work/systemctl.calls" || fail "timer non abilitato: $(cat "$work/systemctl.calls")"
[[ "$(stat -c '%a' "$MON_DIR/config.json")" == 600 ]] || fail "config.json non è 600"
if vm status | grep -q "$TOKEN"; then fail "status mostra il token"; fi

echo "== test: messaggio di prova"
vm test | jq -e '.ok == true' >/dev/null || fail "test Telegram"
grep -q 'messaggio di prova' "$work/tg.log" || fail "messaggio di prova non arrivato"

echo "== due giri: l'indirizzo risulta giù"
run "$t0"
(($(sent) == 0)) || fail "avviso al primo giro"
run $((t0 + 60))
(($(sent) >= 1)) || fail "nessun avviso dopo il secondo giro"
grep -q '🔴' "$work/tg.log" || fail "manca il testo 🔴"
st="$(vm status)"
jq -e --arg u "$URL" '.checks[] | select(.id == "url:" + $u) | .state == "down"' <<<"$st" >/dev/null || fail "stato non down: $st"
jq -e '.queued == 0' <<<"$st" >/dev/null || fail "coda non vuota: $st"
if grep -q "$TOKEN" <<<"$st"; then fail "status mostra il token"; fi

echo "== Telegram spento: il giro mette in coda"
stop_tg
n="$(sent)"
# Il promemoria arriva dopo remind_min (30 min): si salta avanti.
run $((t0 + 60 + 31 * 60))
st="$(vm status)"
jq -e '.queued >= 1' <<<"$st" >/dev/null || fail "niente in coda con Telegram spento: $st"
[[ "$(sent)" == "$n" ]] || fail "messaggi arrivati con Telegram spento"

echo "== Telegram riacceso: la coda si svuota"
start_tg
run $((t0 + 60 + 32 * 60))
st="$(vm status)"
jq -e '.queued == 0' <<<"$st" >/dev/null || fail "coda non svuotata: $st"
(($(sent) > n)) || fail "il messaggio in coda non è arrivato"

echo "== config spenta: il timer si ferma"
res="$(vm config <<<'{"enabled":false}')"
jq -e '.ok == true' <<<"$res" >/dev/null || fail "config off: $res"
grep -qx 'disable --now vps-monitor.timer' "$work/systemctl.calls" || fail "timer non disabilitato"

echo "E2E MONITOR OK"
