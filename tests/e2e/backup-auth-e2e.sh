#!/usr/bin/env bash
# End-to-end del collegamento a Drive senza rclone sul PC (vps-backup auth-start,
# auth-finish, auth-cancel) in WSL con systemd, come root: rclone, curl e systemd veri.
# Google è finto solo nell'ultimo passo: l'indirizzo del token (RCLONE_DRIVE_TOKEN_URL, via
# BK_AUTH_EXTRA) punta a un piccolo server locale che risponde sempre con un token di
# prova, e le prove su Drive (mkdir/rcat/deletefile) sono saltate da un involucro di rclone.
# Si controlla: l'indirizzo di Google vero e lo scope drive.file, il listener solo su
# 127.0.0.1, niente segreti negli argomenti né nel journal, state sbagliato, access_denied,
# annullo, pulizia di unità e file. Può installare rclone con apt-get se manca (e lo toglie).
# Uso: wsl -d Debian -u root -- bash /mnt/c/.../vps-installer/tests/e2e/backup-auth-e2e.sh
set -Eeuo pipefail
src="$(cd "$(dirname "$0")/../.." && pwd)"
((EUID == 0)) || { echo "Serve root: sudo bash $0" >&2; exit 2; }

work="$(mktemp -d /tmp/backup-auth-e2e.XXXXXX)"
chmod 755 "$work"
made_rclone=
made_ipt=
fw_chain=
mock=

fail() {
  echo "E2E FALLITO: $*" >&2
  [[ ! -f "$work/tools.log" ]] || tail -n 20 "$work/tools.log" >&2
  exit 1
}

cleanup() {
  set +e
  /usr/bin/systemctl stop vps-backup-auth.service >/dev/null 2>&1
  [[ -z "$mock" ]] || kill "$mock" 2>/dev/null
  if [[ -n "$fw_chain" ]]; then
    iptables -D OUTPUT -j ufw-before-output 2>/dev/null
    iptables -F ufw-before-output 2>/dev/null
    iptables -X ufw-before-output 2>/dev/null
  fi
  [[ -z "$made_ipt" ]] || DEBIAN_FRONTEND=noninteractive apt-get purge -y -q iptables >/dev/null 2>&1
  [[ -z "$made_rclone" ]] || DEBIAN_FRONTEND=noninteractive apt-get purge -y -q rclone >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

for p in rclone curl jq perl iptables util-linux; do
  dpkg -s "$p" >/dev/null 2>&1 && continue
  [[ "$p" != rclone ]] || made_rclone=1
  [[ "$p" != iptables ]] || made_ipt=1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p" >/dev/null
done
ss -ltn | grep -q ':53682 ' && fail "la porta 53682 è già in uso"

# Server del token finto.
cat >"$work/mock.pl" <<'PERL'
use IO::Socket::INET;
my $s = IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>53901,Listen=>5,ReuseAddr=>1) or die;
local $SIG{ALRM}=sub{exit 0}; alarm 300;
while (my $c = $s->accept) {
  my $req=''; while (<$c>) { $req.=$_; last if $_ eq "\r\n"; }
  my ($len)=$req=~/Content-Length: (\d+)/i; my $body=''; read($c,$body,$len) if $len;
  my $j='{"access_token":"ya29.MOCKACCESS","token_type":"Bearer","refresh_token":"1//MOCKREFRESH","expires_in":3599}';
  print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($j)."\r\nConnection: close\r\n\r\n$j"; close $c;
}
PERL
perl "$work/mock.pl" &
mock=$!

# Involucro di rclone: le prove su Drive riescono, il resto è rclone vero.
cat >"$work/rclone-w" <<'WRAP'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    rcat) cat >/dev/null; exit 0 ;;
    mkdir | deletefile) exit 0 ;;
  esac
done
exec /usr/bin/rclone "$@"
WRAP
chmod +x "$work/rclone-w"
printf 'RCLONE_DRIVE_TOKEN_URL=http://127.0.0.1:53901/token\n' >"$work/extra.env"

unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
export VPS_OPT="$work/opt" VPS_LIB="$src/lib" VPS_LOG="$work/tools.log" VPS_TEMPLATES="$src/templates"
export BK_DIR="$work/opt/backup" BK_LOCK_DIR="$work/locks" SYSTEMD_DIR="$work/systemd"
export BK_AUTH_RCLONE=/usr/bin/rclone BK_UFW_DIR="$work/ufw"
export BK_RCLONE="$work/rclone-w --config $work/opt/secrets/rclone.conf" BK_AUTH_EXTRA="$work/extra.env"
mkdir -p "$VPS_OPT/secrets" "$BK_LOCK_DIR" "$SYSTEMD_DIR" "$BK_UFW_DIR"
: >"$VPS_LOG"
vb() { bash "$src/tools/vps-backup" "$@"; }

echo "== firewall: regola generata da bk_firewall_install, controllata e applicata davvero con iptables"
printf '*filter
:ufw-before-output - [0:0]
-A ufw-before-output -o lo -j ACCEPT
COMMIT
' >"$BK_UFW_DIR/before.rules"
printf '*filter
:ufw6-before-output - [0:0]
-A ufw6-before-output -o lo -j ACCEPT
COMMIT
' >"$BK_UFW_DIR/before6.rules"
# shellcheck disable=SC1090
(for l in "$src"/lib/*.sh; do source "$l"; done; bk_firewall_install) || fail "bk_firewall_install"
grep -q -- '--dport 53682 -m owner ! --uid-owner 0 -j REJECT' "$BK_UFW_DIR/before.rules" || fail "regola v4 assente"
grep -q -- 'ufw6-before-output 1' "$BK_UFW_DIR/before6.rules" || fail "regola v6 assente"
iptables-restore --test <"$BK_UFW_DIR/before.rules" || fail "iptables-restore non accetta before.rules"
iptables-restore -n <"$BK_UFW_DIR/before.rules" || fail "iptables-restore"
fw_chain=1
iptables -I OUTPUT 1 -j ufw-before-output

echo "== auth-start con client id e secret propri"
res="$(printf 'e2e-id.apps.googleusercontent.com\nE2E-SECRET-xyz\n' | vb auth-start)" || fail "auth-start: $res"
jq -e '.ok == true and (.url | startswith("https://accounts.google.com/")) and (.expires | test("Z$"))' <<<"$res" >/dev/null || fail "risposta: $res"
url="$(jq -r .url <<<"$res")"
[[ "$url" == *"client_id=e2e-id.apps.googleusercontent.com"* ]] || fail "client id non usato: $url"
[[ "$url" == *"scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file"* ]] || fail "scope non drive.file: $url"
[[ "$url" == *"redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2F"* ]] || fail "redirect inatteso: $url"
[[ "$url" != *E2E-SECRET* ]] || fail "il secret è nell'indirizzo di Google"
echo "   URL: ${url%%\?*}?…"
systemctl is-active --quiet vps-backup-auth.service || fail "unità non attiva"
ss -ltn | grep ':53682 ' | grep -q '127.0.0.1:53682' || fail "listener non su 127.0.0.1: $(ss -ltn | grep 53682)"
vb status | jq -e '.auth.pending == true and (.auth.expires | test("Z$"))' >/dev/null || fail "status auth"
[[ "$(stat -c %a "$BK_DIR/auth")" == 700 ]] || fail "permessi della cartella"
[[ "$(stat -c %a "$BK_DIR/auth/env")" == 600 ]] || fail "permessi di env"
if pgrep -f "[E]2E-SECRET|[e]2e-id.apps" >/dev/null; then fail "client id/secret negli argomenti di un processo"; fi
if systemctl show vps-backup-auth.service -p Environment -p ExecStart | grep -F E2E-SECRET >/dev/null; then fail "secret nelle proprietà dell'unità"; fi
systemctl show vps-backup-auth.service -p RuntimeMaxUSec | grep -q '15min' || fail "RuntimeMaxSec: $(systemctl show vps-backup-auth.service -p RuntimeMaxUSec)"
state="$(jq -r .state "$BK_DIR/auth/meta.json")"
mainpid="$(systemctl show -p MainPID --value vps-backup-auth.service)"
[[ "$(ps -o user= -p "$mainpid")" != root ]] || fail "rclone gira come root: DynamicUser non attivo"
echo "   rclone gira come: $(ps -o user= -p "$mainpid")"
[[ "$(readlink -f "/proc/$mainpid/exe")" == /usr/bin/rclone ]] || fail "exe di rclone: $(readlink -f "/proc/$mainpid/exe")"

echo "== solo root può connettersi alla porta (firewall), root passa"
curl -s -o /dev/null --max-time 5 "http://127.0.0.1:53682/auth?state=$state" || fail "root non riesce a connettersi (non dovrebbe esser bloccato)"
if setpriv --reuid=nobody --regid=nogroup --clear-groups curl -s -o /dev/null --max-time 5 "http://127.0.0.1:53682/?state=FALSO&code=x"; then
  fail "un utente non root riesce a connettersi alla porta 53682"
fi
systemctl is-active --quiet vps-backup-auth.service || fail "l'unità è morta per un tentativo bloccato"

echo "== indirizzi sbagliati: rifiutati, l'autorizzazione resta"
for u in "http://127.0.0.1:53682/?state=ALTRO&code=abc" "http://evil:53682/?state=$state&code=abc" "http://127.0.0.1:53682/?state=$state"; do
  res="$(printf '%s\n' "$u" | vb auth-finish)" && fail "accettato: $u"
  jq -e '.ok == false' <<<"$res" >/dev/null || fail "risposta: $res"
done
systemctl is-active --quiet vps-backup-auth.service || fail "l'unità è morta dopo indirizzi rifiutati"

echo "== caso buono: code consegnato a rclone, token a bk_connect, niente segreti in giro"
res="$(printf 'http://127.0.0.1:53682/?state=%s&code=4%%2F0AbC_d-e.f~g&scope=https://www.googleapis.com/auth/drive.file\n' "$state" | vb auth-finish)" || fail "auth-finish: $res"
jq -e '.ok == true and (.folder | length > 0)' <<<"$res" >/dev/null || fail "risposta: $res"
conf="$VPS_OPT/secrets/rclone.conf"
[[ "$(stat -c %a "$conf")" == 600 ]] || fail "permessi di rclone.conf"
grep -qx 'scope = drive.file' "$conf" || fail "scope nel file"
grep -qx 'client_id = e2e-id.apps.googleusercontent.com' "$conf" || fail "client_id nel file"
grep -qx 'client_secret = E2E-SECRET-xyz' "$conf" || fail "client_secret nel file"
grep -q '"refresh_token":"1//MOCKREFRESH"' "$conf" || fail "token nel file: $(sed 's/ya29[^"]*/***/' "$conf")"
[[ ! -e "$BK_DIR/auth" ]] || fail "cartella delle autorizzazioni rimasta"
systemctl is-active --quiet vps-backup-auth.service && fail "unità ancora attiva"
ss -ltn | grep -q ':53682 ' && fail "porta ancora in ascolto"
if journalctl -u vps-backup-auth.service --no-pager 2>/dev/null | grep -E 'MOCK|E2E-SECRET|0AbC'; then fail "segreti nel journal"; fi
if grep -rE 'MOCK|E2E-SECRET|0AbC' "$VPS_LOG" "$BK_DIR" 2>/dev/null; then fail "segreti nel registro o nella cartella del backup"; fi
vb status | jq -e '.connected == true and .auth.pending == false' >/dev/null || fail "status dopo il collegamento"

echo "== auth-cancel"
res="$(vb auth-start </dev/null)" || fail "auth-start 2: $res"
systemctl is-active --quiet vps-backup-auth.service || fail "unità 2 non attiva"
vb auth-cancel | jq -e '.ok == true' >/dev/null || fail "auth-cancel"
[[ ! -e "$BK_DIR/auth" ]] || fail "cartella rimasta dopo l'annullo"
systemctl is-active --quiet vps-backup-auth.service && fail "unità attiva dopo l'annullo"
sleep 1
ss -ltn | grep -q ':53682 ' && fail "porta aperta dopo l'annullo"

echo "== access_denied"
vb auth-start </dev/null >/dev/null || fail "auth-start 3"
state="$(jq -r .state "$BK_DIR/auth/meta.json")"
res="$(printf 'http://127.0.0.1:53682/?error=access_denied&state=%s\n' "$state" | vb auth-finish)" && fail "access_denied accettato"
jq -e '.ok == false and (.error | test("negato"))' <<<"$res" >/dev/null || fail "messaggio: $res"
[[ ! -e "$BK_DIR/auth" ]] || fail "cartella rimasta dopo access_denied"
systemctl is-active --quiet vps-backup-auth.service && fail "unità attiva dopo access_denied"

echo "== state sbagliato mandato da root al listener: rclone si ferma, auth-finish dice di ricominciare"
vb auth-start </dev/null >/dev/null || fail "auth-start 4"
state="$(jq -r .state "$BK_DIR/auth/meta.json")"
curl -s -o /dev/null "http://127.0.0.1:53682/?state=FALSO&code=x" || true
sleep 1
vb status | jq -e '.auth.pending == false' >/dev/null || fail "status dopo lo state falso"
res="$(printf 'http://127.0.0.1:53682/?state=%s&code=abc\n' "$state" | vb auth-finish)" && fail "auth-finish dopo rclone morto"
jq -e '.ok == false and (.error | test("ricomincia"))' <<<"$res" >/dev/null || fail "messaggio: $res"
[[ ! -e "$BK_DIR/auth" ]] || fail "cartella rimasta"

echo "== porta occupata da un altro processo: auth-start rifiuta"
(perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>53682,Listen=>1,ReuseAddr=>1) or die; sleep 20' &)
sleep 1
res="$(vb auth-start </dev/null)" && fail "auth-start con la porta occupata"
jq -e '.ok == false and (.error | test("occupata da un altro processo"))' <<<"$res" >/dev/null || fail "messaggio: $res"
[[ ! -e "$BK_DIR/auth" ]] || fail "cartella rimasta"
pkill -f 'LocalPort=>53682' || true

echo "E2E BACKUP AUTH OK"
