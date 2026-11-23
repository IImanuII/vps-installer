# shellcheck shell=bash
# status.sh — dati della dashboard di Plancia per vps-status: aggiornamenti in
# sospeso (con python3-apt), CPU e RAM di adesso, traffico dei siti nelle ultime 24 ore.
# python3 e python3-apt ci sono sempre: li porta unattended-upgrades.

: "${VS_DIR:=$VPS_OPT/stats}"
: "${VS_PY:=python3}"
: "${VS_DPKG_STATUS:=/var/lib/dpkg/status}"
: "${VS_APT_LISTS:=/var/lib/apt/lists}"
: "${VS_UU_LOG:=/var/log/unattended-upgrades/unattended-upgrades.log}"
: "${VS_UPDATE_STAMP:=/var/lib/apt/periodic/update-success-stamp}"
: "${VS_OS_RELEASE:=/etc/os-release}"
: "${VS_TRAFFIC_TTL:=300}"
: "${VS_LIVE_SLEEP:=0.4}"

_vs_dir() {
  install -d -m 700 "$VS_DIR"
}

# _vs_updates_py — pacchetti aggiornabili, con l'origine e se unattended-upgrades li
# installa da solo; ultima installazione automatica dal suo log. Stampa JSON.
_vs_updates_py() {
  VS_UU_LOG="$VS_UU_LOG" VS_OS_RELEASE="$VS_OS_RELEASE" "$VS_PY" - <<'PY'
import datetime, fnmatch, json, os, re

import apt
import apt_pkg

apt_pkg.init()

os_rel = {}
try:
    with open(os.environ["VS_OS_RELEASE"], encoding="utf-8") as f:
        for riga in f:
            k, _, v = riga.strip().partition("=")
            os_rel[k] = v.strip('"')
except OSError:
    pass
codename = os_rel.get("VERSION_CODENAME", "")
distro_id = os_rel.get("ID", "debian").capitalize()

# Stesse chiavi di unattended-upgrades; i valori si confrontano con fnmatch.
CHIAVI = {"o": "origin", "origin": "origin", "l": "label", "label": "label",
          "n": "codename", "codename": "codename", "a": "archive", "archive": "archive",
          "suite": "archive", "c": "component", "component": "component", "site": "site"}


def regola(testo):
    testo = testo.replace("${distro_codename}", codename).replace("${distro_id}", distro_id)
    coppie = []
    for parte in testo.split(","):
        k, _, v = parte.partition("=")
        coppie.append((CHIAVI.get(k.strip()), v.strip()))
    return coppie


def combacia(origine, coppie):
    for chiave, valore in coppie:
        if chiave is None:
            return False
        if not fnmatch.fnmatchcase(getattr(origine, chiave, "") or "", valore):
            return False
    return True


regole = [regola(p) for p in apt_pkg.config.value_list("Unattended-Upgrade::Origins-Pattern")]

pacchetti = []
for p in apt.Cache():
    if not p.is_upgradable:
        continue
    cand = p.candidate
    origini = [o for o in cand.origins if (o.origin or o.site)]
    auto = any(combacia(o, r) for o in origini for r in regole)
    nome = ""
    if origini:
        o = origini[0]
        nome = o.label or o.origin or o.site
    pacchetti.append({"name": p.name, "from": p.installed.version if p.installed else "",
                      "to": cand.version, "origin": nome, "auto": auto})
pacchetti.sort(key=lambda x: (x["auto"], x["name"]))

# Ultima installazione automatica: l'ultima riga "Packages that will be upgraded"
# seguita da "All upgrades installed".
ultima = None
re_t = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ \w+ (.*)$")
try:
    conto = None
    with open(os.environ["VS_UU_LOG"], encoding="utf-8", errors="replace") as f:
        for riga in f:
            m = re_t.match(riga.rstrip("\n"))
            if not m:
                continue
            testo = m.group(2)
            if testo.startswith("Packages that will be upgraded:"):
                conto = len(testo.split(":", 1)[1].split())
            elif testo.startswith("All upgrades installed") and conto:
                quando = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").astimezone()
                ultima = {"at": quando.isoformat(timespec="seconds"), "count": conto}
                conto = None
except OSError:
    pass

reboot_time = apt_pkg.config.find("Unattended-Upgrade::Automatic-Reboot-Time", "now")
print(json.dumps({
    "packages": pacchetti,
    "auto_reboot": apt_pkg.config.find_b("Unattended-Upgrade::Automatic-Reboot", False),
    "reboot_time": reboot_time,
    "last_install": ultima,
}))
PY
}

# _vs_iso FILE — data di modifica in ISO 8601, vuoto se il file non c'è.
_vs_iso() {
  [[ -e "$1" ]] || return 0
  date -d "@$(stat -c %Y "$1")" -Iseconds
}

# _vs_timer TIMER PROPRIETÀ — data di un timer systemd in ISO 8601, vuoto se non c'è.
_vs_timer() {
  local v
  v="$(systemctl show "$1" -p "$2" --value 2>/dev/null || true)"
  [[ -n "$v" && "$v" != n/a && "$v" != 0 ]] || return 0
  date -d "$v" -Iseconds 2>/dev/null || true
}

# vs_updates_json — parte "updates" di vps-status. Il calcolo con apt costa un
# secondo: si tiene in cache finché dpkg, gli elenchi di apt e il log di
# unattended-upgrades non cambiano (e al massimo un'ora).
vs_updates_json() {
  local cache="$VS_DIR/updates.json" pkgjson="" errore="" f vecchia=0 reboot=false
  _vs_dir
  if [[ ! -s "$cache" ]] || [[ -n "$(find "$cache" -mmin +60 2>/dev/null)" ]]; then
    vecchia=1
  else
    for f in "$VS_DPKG_STATUS" "$VS_APT_LISTS" "$VS_UU_LOG"; do
      if [[ -e "$f" && "$f" -nt "$cache" ]]; then vecchia=1; fi
    done
  fi
  if ((vecchia)); then
    if pkgjson="$(_vs_updates_py 2>>"$VPS_LOG")" && jq -e '.packages | type == "array"' >/dev/null 2>&1 <<<"$pkgjson"; then
      printf '%s\n' "$pkgjson" | write_file "$cache" 600 root:root || true
    else
      log "vps-status: elenco degli aggiornamenti non letto con python3-apt" 2>/dev/null
      pkgjson=""
    fi
  else
    pkgjson="$(cat "$cache")"
  fi
  if [[ -z "$pkgjson" ]]; then
    # Senza python3-apt: solo il numero, con apt in inglese (in italiano scrive "aggiornabile da").
    local n
    n="$(LC_ALL=C apt list --upgradable 2>/dev/null | grep -c 'upgradable from' || true)"
    pkgjson="$(jq -nc --argjson n "${n:-0}" '{packages: null, count: $n, auto_reboot: false, reboot_time: null, last_install: null}')"
    errore="elenco dei pacchetti non disponibile"
  fi
  if [[ -f /var/run/reboot-required ]]; then reboot=true; fi
  jq -c --argjson reboot "$reboot" --arg err "$errore" \
    --arg checked "$(_vs_iso "$VS_UPDATE_STAMP")" \
    --arg last_check "$(_vs_timer apt-daily.timer LastTriggerUSec)" \
    --arg next_check "$(_vs_timer apt-daily.timer NextElapseUSecRealtime)" \
    --arg next_install "$(_vs_timer apt-daily-upgrade.timer NextElapseUSecRealtime)" '
    def nn: if . == "" then null else . end;
    {upgradable: (if .packages == null then .count else (.packages | length) end),
     reboot_required: $reboot,
     packages: .packages,
     checked_at: (($checked | nn) // ($last_check | nn)),
     next_check: ($next_check | nn), next_install: ($next_install | nn),
     auto_reboot: .auto_reboot, reboot_time: .reboot_time, last_install: .last_install}
    + (if $err == "" then {} else {error: $err} end)' <<<"$pkgjson"
}

# vs_live_json — CPU (due letture di /proc/stat), RAM e carico di adesso. Leggero:
# il pannello lo chiede ogni 5 secondi.
vs_live_json() {
  local _c u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2 mtotal mavail l1 l5 l15 _r
  read -r _c u1 n1 s1 i1 w1 q1 sq1 st1 _r </proc/stat
  sleep "$VS_LIVE_SLEEP"
  read -r _c u2 n2 s2 i2 w2 q2 sq2 st2 _r </proc/stat
  local tot=$(((u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2) - (u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1)))
  local idle=$(((i2 + w2) - (i1 + w1)))
  read -r mtotal mavail < <(free -b | awk '/^Mem:/ { print $2, $7 }')
  read -r l1 l5 l15 _r </proc/loadavg
  json_ok --argjson tot "$tot" --argjson idle "$idle" --argjson cpus "$(nproc)" \
    --argjson mtotal "$mtotal" --argjson mavail "$mavail" \
    --argjson l1 "$l1" --argjson l5 "$l5" --argjson l15 "$l15" '
    {ok: true, cpu_pct: (if $tot > 0 then ((($tot - $idle) * 1000 / $tot) | round) / 10 else 0 end),
     cpus: $cpus, memory: {total: $mtotal, available: $mavail}, load: [$l1, $l5, $l15]}'
}

# _vs_db_sizes — {"nome_db": byte} di tutti i database; {} se MariaDB non risponde.
_vs_db_sizes() {
  local out
  if out="$(mariadb -N -B -e 'SELECT table_schema, COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables GROUP BY table_schema' 2>>"$VPS_LOG")"; then
    jq -Rn '[inputs | split("\t") | select(length == 2) | {(.[0]): (.[1] | tonumber? // 0)}] | add // {}' <<<"$out"
  else
    echo '{}'
  fi
}

# _vs_traffic_py SITI DB — conta le richieste delle ultime 24 ore per ora dai log
# di accesso di ogni sito (access.log e access.log.1: la rotazione è settimanale).
_vs_traffic_py() {
  VS_SITES="$1" VS_DBS="$2" SITES_WWW="$SITES_WWW" VS_NOW="${VS_NOW:-}" "$VS_PY" - <<'PY'
import calendar, datetime, json, os, re, time

ora = int(os.environ.get("VS_NOW") or time.time())
fine = ora - ora % 3600            # inizio dell'ora corrente (i fusi italiani sono a ore intere)
inizio = fine - 23 * 3600
MESI = {m: i for i, m in enumerate(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
re_t = re.compile(r"\[(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})\]")
www = os.environ["SITES_WWW"]
dbs = json.loads(os.environ["VS_DBS"] or "{}")


def conta(cartella):
    ore = [0] * 24
    for nome in ("access.log.1", "access.log"):
        p = os.path.join(cartella, nome)
        try:
            if os.path.getmtime(p) < inizio:
                continue
            with open(p, encoding="utf-8", errors="replace") as f:
                for riga in f:
                    m = re_t.search(riga, 0, 120)
                    if not m:
                        continue
                    g, mese, a, h, mi, s, segno, oh, om = m.groups()
                    if mese not in MESI:
                        continue
                    t = calendar.timegm((int(a), MESI[mese], int(g), int(h), int(mi), int(s)))
                    t -= (1 if segno == "+" else -1) * (int(oh) * 3600 + int(om) * 60)
                    if inizio <= t < fine + 3600:
                        ore[(t - inizio) // 3600] += 1
        except OSError:
            continue
    return ore


def spazio(cartella):
    tot = 0
    for radice, _, files in os.walk(cartella):
        for n in files:
            try:
                tot += os.lstat(os.path.join(radice, n)).st_size
            except OSError:
                pass
    return tot


siti = []
for s in json.loads(os.environ["VS_SITES"]):
    radice = os.path.join(www, s["domain"])
    ore = conta(os.path.join(radice, "logs"))
    siti.append({"domain": s["domain"], "state": s.get("state") or "", "hits": ore, "total": sum(ore),
                 "disk_bytes": spazio(os.path.join(radice, "public")),
                 "db_bytes": dbs.get(s.get("slug") or "", 0) if s.get("db") else None})

ore_iso = [datetime.datetime.fromtimestamp(inizio + i * 3600).astimezone().isoformat(timespec="seconds") for i in range(24)]
print(json.dumps({"ok": True, "generated_at": datetime.datetime.fromtimestamp(ora).astimezone().isoformat(timespec="seconds"),
                  "hours": ore_iso, "sites": siti}))
PY
}

# vs_traffic_json — traffico dei siti, in cache per VS_TRAFFIC_TTL secondi.
vs_traffic_json() {
  local cache="$VS_DIR/traffic.json" siti out f
  _vs_dir
  if [[ -s "$cache" ]] && (($(date +%s) - $(stat -c %Y "$cache") < VS_TRAFFIC_TTL)); then
    cat "$cache"
    return
  fi
  siti='[]'
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    siti="$(jq -c --slurpfile s "$f" '. + [$s[0] | {domain, slug, db: (.db // false), state}]' <<<"$siti")"
  done
  out="$(_vs_traffic_py "$siti" "$(_vs_db_sizes)" 2>>"$VPS_LOG")" || json_err "traffico dei siti non letto (dettagli in $VPS_LOG)"
  printf '%s\n' "$out" | write_file "$cache" 600 root:root || true
  printf '%s\n' "$out"
}
