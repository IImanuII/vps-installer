bats_require_minimum_version 1.5.0

# vps-status: aggiornamenti (python3-apt finto), live e traffico dei siti.

setup() {
  load test_helper
  setup_common
  export VPS_LIB="$REPO_ROOT/lib"
  T="$REPO_ROOT/tools"
  export VS_DIR="$BATS_TEST_TMPDIR/stats"
  export VS_DPKG_STATUS="$BATS_TEST_TMPDIR/dpkg-status" VS_APT_LISTS="$BATS_TEST_TMPDIR/lists"
  export VS_UU_LOG="$BATS_TEST_TMPDIR/uu.log" VS_UPDATE_STAMP="$BATS_TEST_TMPDIR/stamp"
  export VS_OS_RELEASE="$BATS_TEST_TMPDIR/os-release"
  # Le date dei timer e dei log sono ora italiana: il runner della CI è in UTC.
  export TZ=Europe/Rome
  touch "$VS_DPKG_STATUS"
  mkdir -p "$VS_APT_LISTS"
  printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$VS_OS_RELEASE"
  make_stub systemctl 'case "$*" in
    *"apt-daily.timer -p NextElapseUSecRealtime"*) echo "Mon 2026-11-23 18:27:03 CET" ;;
    *"apt-daily-upgrade.timer -p NextElapseUSecRealtime"*) echo "Tue 2026-11-24 06:27:47 CET" ;;
    *"apt-daily.timer -p LastTriggerUSec"*) echo "Mon 2026-11-23 06:11:17 CET" ;;
    *) echo active ;;
  esac'
  # Moduli python3-apt finti: leggono pacchetti e configurazione da file JSON.
  export PYTHONPATH="$BATS_TEST_TMPDIR/py"
  mkdir -p "$PYTHONPATH"
  cat >"$PYTHONPATH/apt_pkg.py" <<'PY'
import json, os
_cfg = json.load(open(os.environ["FAKE_APT_CFG"]))
def init():
    pass
class _Config:
    def value_list(self, k):
        return _cfg.get(k, [])
    def find(self, k, d=""):
        return _cfg.get(k, d)
    def find_b(self, k, d=False):
        return _cfg.get(k, d)
config = _Config()
PY
  cat >"$PYTHONPATH/apt.py" <<'PY'
import json, os
from types import SimpleNamespace as NS
VUOTA = dict(origin="", label="", codename="", archive="", component="", site="")
def Cache():
    out = []
    for p in json.load(open(os.environ["FAKE_APT_PKGS"])):
        origini = [NS(**{**VUOTA, **o}) for o in p["origins"]]
        out.append(NS(name=p["name"], is_upgradable=p.get("up", True), installed=NS(version=p["from"]),
                      candidate=NS(version=p["to"], origins=origini)))
    return out
PY
  export FAKE_APT_CFG="$BATS_TEST_TMPDIR/cfg.json" FAKE_APT_PKGS="$BATS_TEST_TMPDIR/pkgs.json"
  cat >"$FAKE_APT_CFG" <<'JSON'
{"Unattended-Upgrade::Origins-Pattern": [
   "origin=Debian,codename=${distro_codename}-security,label=Debian-Security",
   "origin=cloudflared,codename=any"],
 "Unattended-Upgrade::Automatic-Reboot": true,
 "Unattended-Upgrade::Automatic-Reboot-Time": "04:00"}
JSON
  cat >"$FAKE_APT_PKGS" <<'JSON'
[{"name": "openssl", "from": "3.5.1", "to": "3.5.2", "origins": [{"origin": "Debian", "codename": "trixie-security", "label": "Debian-Security"}]},
 {"name": "php8.4-fpm", "from": "8.4.28-1", "to": "8.4.28-3", "origins": [{"origin": "deb.sury.org", "codename": "trixie", "site": "packages.sury.org"}]},
 {"name": "cloudflared", "from": "2026.11.1", "to": "2026.11.2", "origins": [{"origin": "cloudflared", "codename": "any"}]},
 {"name": "bash", "from": "5.2", "to": "5.2", "up": false, "origins": []}]
JSON
  cat >"$VS_UU_LOG" <<'LOG'
2026-11-22 06:20:01,100 INFO Packages that will be upgraded: tzdata
2026-11-22 06:20:30,100 INFO All upgrades installed
2026-11-23 06:32:40,831 INFO Packages that will be upgraded: base-files libc6 openssl
2026-11-23 06:34:31,234 INFO All upgrades installed
LOG
}

@test "vps-status: pacchetti aggiornabili con origine e installazione automatica" {
  run bash "$T/vps-status"
  [ "$status" -eq 0 ]
  u="$(jq -c .updates <<<"$output")"
  [ "$(jq -r .upgradable <<<"$u")" = 3 ]
  # prima quelli da installare a mano
  [ "$(jq -r '.packages[0].name' <<<"$u")" = php8.4-fpm ]
  [ "$(jq -r '.packages[] | select(.name=="php8.4-fpm") | .auto' <<<"$u")" = false ]
  [ "$(jq -r '.packages[] | select(.name=="php8.4-fpm") | .origin' <<<"$u")" = deb.sury.org ]
  [ "$(jq -r '.packages[] | select(.name=="openssl") | .auto' <<<"$u")" = true ]
  [ "$(jq -r '.packages[] | select(.name=="openssl") | .origin' <<<"$u")" = Debian-Security ]
  [ "$(jq -r '.packages[] | select(.name=="cloudflared") | .auto' <<<"$u")" = true ]
  [ "$(jq -r '.packages[] | select(.name=="openssl") | .from + ">" + .to' <<<"$u")" = "3.5.1>3.5.2" ]
  [ "$(jq -r .auto_reboot <<<"$u")" = true ]
  [ "$(jq -r .reboot_time <<<"$u")" = 04:00 ]
  [ "$(jq -r .last_install.count <<<"$u")" = 3 ]
  [[ "$(jq -r .last_install.at <<<"$u")" == 2026-11-23T06:34:31* ]]
  [[ "$(jq -r .next_install <<<"$u")" == 2026-11-24T06:27:47* ]]
  [[ "$(jq -r .next_check <<<"$u")" == 2026-11-23T18:27:03* ]]
  # senza il file di apt periodic vale l'ultimo giro del timer
  [[ "$(jq -r .checked_at <<<"$u")" == 2026-11-23T06:11:17* ]]
  [ "$(jq -r .cpus <<<"$output")" -ge 1 ]
}

@test "vps-status: l'elenco degli aggiornamenti resta in cache finché dpkg non cambia" {
  run bash "$T/vps-status"
  [ "$(jq -r .updates.upgradable <<<"$output")" = 3 ]
  [ "$(stat -c %a "$VS_DIR/updates.json")" = 600 ]
  echo '[]' >"$FAKE_APT_PKGS"
  touch -d '-1 minute' "$VS_DPKG_STATUS" "$VS_APT_LISTS" "$VS_UU_LOG"
  run bash "$T/vps-status"
  [ "$(jq -r .updates.upgradable <<<"$output")" = 3 ]
  touch -d '+1 minute' "$VS_DPKG_STATUS"
  run bash "$T/vps-status"
  [ "$(jq -r .updates.upgradable <<<"$output")" = 0 ]
}

@test "vps-status: senza python3-apt conta con apt in inglese e lo dice" {
  export VS_PY=false
  make_stub apt '[ "${LC_ALL:-}" = C ] || { echo "Elenco in corso..."; echo "x/stable 2 amd64 [aggiornabile da: 1]"; exit 0; }
    printf "Listing...\nnginx/stable 1.28 amd64 [upgradable from: 1.27]\n"'
  run bash "$T/vps-status"
  [ "$status" -eq 0 ]
  [ "$(jq -r .updates.upgradable <<<"$output")" = 1 ]
  [ "$(jq -r .updates.packages <<<"$output")" = null ]
  [ -n "$(jq -r .updates.error <<<"$output")" ]
}

@test "vps-status live: CPU, RAM e carico" {
  export VS_LIVE_SLEEP=0
  run bash "$T/vps-status" live
  [ "$status" -eq 0 ]
  jq -e '.ok and .cpu_pct >= 0 and .cpu_pct <= 100 and .cpus >= 1 and .memory.total > 0 and (.load | length) == 3' <<<"$output"
}

@test "vps-status: sotto-comando sconosciuto" {
  run bash "$T/vps-status" boh
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
}

_siti_finti() {
  export SITES_DIR="$BATS_TEST_TMPDIR/sites" SITES_WWW="$BATS_TEST_TMPDIR/www"
  mkdir -p "$SITES_DIR"
  jq -n '{domain:"a.it", slug:"site_a_it", db:true, state:"active"}' >"$SITES_DIR/a.it.json"
  jq -n '{domain:"b.it", slug:"site_b_it", db:false, state:"disabled"}' >"$SITES_DIR/b.it.json"
  mkdir -p "$SITES_WWW/a.it/logs" "$SITES_WWW/a.it/public" "$SITES_WWW/b.it/public"
  printf '%1000s' x >"$SITES_WWW/a.it/public/index.php"
  # Adesso: 23/11/2026 17:30 ora italiana. Le 24 caselle vanno dalle 18:00 del 22 alle 17:59 del 23.
  export VS_NOW
  VS_NOW="$(date -d '2026-11-23T17:30:00+01:00' +%s)"
  l='1.2.3.4 - - [%s] "GET / HTTP/1.1" 200 10 "-" "ua"\n'
  # shellcheck disable=SC2059
  {
    printf "$l" '23/Nov/2026:17:05:00 +0100'
    printf "$l" '23/Nov/2026:16:20:00 +0000'
    printf "$l" '23/Nov/2026:16:59:59 +0100'
    printf "$l" '21/Nov/2026:10:00:00 +0100'
  } >"$SITES_WWW/a.it/logs/access.log"
  # shellcheck disable=SC2059
  {
    printf "$l" '22/Nov/2026:17:50:00 +0100'
    printf "$l" '22/Nov/2026:18:10:00 +0100'
    echo 'riga rovinata'
  } >"$SITES_WWW/a.it/logs/access.log.1"
  touch -d "@$VS_NOW" "$SITES_WWW/a.it/logs/access.log" "$SITES_WWW/a.it/logs/access.log.1"
  make_stub mariadb 'printf "site_a_it\t2048\nsite_b_it\t99\n"'
}

@test "vps-status traffic: richieste per ora delle ultime 24 ore, spazio e database" {
  _siti_finti
  run bash "$T/vps-status" traffic
  [ "$status" -eq 0 ]
  a="$(jq -c '.sites[] | select(.domain=="a.it")' <<<"$output")"
  [ "$(jq -r '.hits | length' <<<"$a")" = 24 ]
  [ "$(jq -r '.hits[23]' <<<"$a")" = 2 ]
  [ "$(jq -r '.hits[22]' <<<"$a")" = 1 ]
  [ "$(jq -r '.hits[0]' <<<"$a")" = 1 ]
  [ "$(jq -r .total <<<"$a")" = 4 ]
  [ "$(jq -r .disk_bytes <<<"$a")" = 1000 ]
  [ "$(jq -r .db_bytes <<<"$a")" = 2048 ]
  b="$(jq -c '.sites[] | select(.domain=="b.it")' <<<"$output")"
  [ "$(jq -r .total <<<"$b")" = 0 ]
  [ "$(jq -r .db_bytes <<<"$b")" = null ]
  [ "$(jq -r .state <<<"$b")" = disabled ]
  [ "$(jq -r '.hours | length' <<<"$output")" = 24 ]
}

@test "vps-status traffic: resta in cache per 5 minuti" {
  _siti_finti
  run bash "$T/vps-status" traffic
  [ "$(stat -c %a "$VS_DIR/traffic.json")" = 600 ]
  : >"$SITES_WWW/a.it/logs/access.log"
  run bash "$T/vps-status" traffic
  [ "$(jq -r '.sites[] | select(.domain=="a.it") | .total' <<<"$output")" = 4 ]
  export VS_TRAFFIC_TTL=0
  run bash "$T/vps-status" traffic
  [ "$(jq -r '.sites[] | select(.domain=="a.it") | .total' <<<"$output")" = 1 ]
}

@test "vps-status traffic: senza siti un elenco vuoto" {
  export SITES_DIR="$BATS_TEST_TMPDIR/vuota" SITES_WWW="$BATS_TEST_TMPDIR/www"
  make_stub mariadb 'exit 1'
  run bash "$T/vps-status" traffic
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sites | length' <<<"$output")" = 0 ]
}
