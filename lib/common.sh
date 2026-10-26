# shellcheck shell=bash
# Funzioni comuni a installer e script wrapper.

: "${VPS_ROOT:=/root/vps-installer}"
: "${VPS_LOG:=/var/log/vps-installer.log}"
: "${VPS_STATE:=$VPS_ROOT/state}"
: "${VPS_ANSWERS:=$VPS_ROOT/answers.env}"
: "${VPS_OPT:=/opt/vps}"
: "${VPS_TEMPLATES:=$VPS_ROOT/templates}"
: "${NGINX_SNIPPETS:=/etc/nginx/snippets}"
# shellcheck disable=SC2034  # usate dai file che includono common.sh
VPS_INSTALLER_VERSION="1.7.3"
# shellcheck disable=SC2034
PHP_VERSION="8.4"

log() {
  local line
  line="[$(date '+%F %T')] $*"
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >>"$VPS_LOG" 2>/dev/null || true
}

die() {
  log "ERRORE: $*"
  exit 1
}

on_error() {
  local rc=$?
  log "ERRORE (exit $rc) in ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND}"
  exit "$rc"
}

enable_error_trap() {
  set -Eeuo pipefail
  trap on_error ERR
}

state_done() {
  [[ -f "$VPS_STATE" ]] && grep -qxF -- "$1" "$VPS_STATE"
}

state_mark() {
  if [[ -d "$(dirname "$VPS_STATE")" ]]; then
    printf '%s\n' "$1" >>"$VPS_STATE"
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    "$@" >>"$VPS_LOG" 2>&1
}

rand_secret() {
  local n="${1:-32}" out=""
  while ((${#out} < n)); do
    out+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:n}"
}

own() {
  if [[ "${VPS_NO_CHOWN:-}" != 1 ]]; then
    chown "$@"
  fi
}

# write_file PATH MODE OWNER:GROUP — contenuto da stdin, sostituzione atomica.
write_file() {
  local path="$1" mode="$2" owner="$3" tmp
  tmp="$(mktemp "$(dirname "$path")/.tmp.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  own "$owner" "$tmp"
  mv -f "$tmp" "$path"
}

is_yes() {
  [[ "${1:-}" == "yes" ]]
}

trim() {
  local s="${1//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# env_get FILE KEY — valore di KEY=... in un file .env (vuoto se assente).
env_get() {
  [[ -f "$1" ]] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

# env_merge FILE MODE OWNER:GROUP — righe KEY=VALUE da stdin: sostituisce quelle
# chiavi in FILE (al loro posto), aggiunge in fondo le nuove e conserva tutto il resto.
env_merge() {
  local file="$1" mode="$2" owner="$3" new merged
  new="$(cat)"
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "$new" | write_file "$file" "$mode" "$owner"
    return
  fi
  merged="$(ENV_MERGE_NEW="$new" awk '
    BEGIN {
      n = split(ENVIRON["ENV_MERGE_NEW"], lines, "\n")
      for (i = 1; i <= n; i++) {
        k = lines[i]
        if (index(k, "=") < 2) continue
        sub(/=.*/, "", k)
        val[k] = lines[i]
        order[++m] = k
      }
    }
    {
      k = ""
      if (index($0, "=") > 1) { k = $0; sub(/=.*/, "", k) }
      if (k != "" && (k in val)) {
        if (!(k in done)) print val[k]
        done[k] = 1
      } else {
        print
      }
    }
    END {
      for (i = 1; i <= m; i++) if (!(order[i] in done)) { print val[order[i]]; done[order[i]] = 1 }
    }' "$file")" || return 1
  printf '%s\n' "$merged" | write_file "$file" "$mode" "$owner"
}

# as_panel [-t SEC] CMD... — come utente panel con ambiente pulito (PD_AS_PANEL=0
# solo nei test). Il .env sta in una cartella del pannello: root non vi legge né
# scrive per percorso, perché panel potrebbe sostituire cartelle e file con link
# tra un controllo e l'uso. Regole per ogni chiamante:
#  - nessun descrittore oltre 0-2 arriva a panel (lock, log, {fd} di root): qui si
#    chiudono tutti;
#  - lo stdin è quello del chiamante: le letture lo reindirizzano da /dev/null;
#  - il limite di tempo (-t) è di root, fuori dal processo di panel: `timeout -k 2`
#    attorno a runuser, così panel non può ignorarlo.
as_panel() {
  local secs="" path="${PMA_AS_PANEL_PATH:-/usr/bin:/bin}"
  local -a cmd=()
  if [[ "${1-}" == -t ]]; then secs="$2"; shift 2; fi
  if [[ -n "$secs" ]]; then cmd+=(timeout -k 2 "$secs"); fi
  if [[ "${PD_AS_PANEL:-1}" != 0 ]]; then cmd+=(runuser -u panel --); fi
  (
    local f n
    for f in /proc/self/fd/*; do
      n="${f##*/}"
      if [[ "$n" =~ ^[0-9]+$ ]] && ((n > 2)); then eval "exec $n>&-" 2>/dev/null || true; fi
    done
    exec "${cmd[@]}" env -i "PATH=$path" LC_ALL=C "$@"
  )
}

# panel_env_check DIR FILE — cartella vera (non link) di panel:panel; il file, se
# c'è, vero e di panel:panel. Solo un controllo di buon senso: lettura e scrittura
# vere avvengono comunque come panel. Il motivo del rifiuto va nel log.
panel_env_check() {
  local want="${PD_PANEL_OWNER:-panel:panel}"
  if [[ -d "$1" && ! -L "$1" && "$(stat -c '%U:%G' "$1")" == "$want" ]] \
    && { [[ ! -e "$2" && ! -L "$2" ]] || [[ -f "$2" && ! -L "$2" && "$(stat -c '%U:%G' "$2")" == "$want" ]]; }; then
    return 0
  fi
  log "ERRORE: $1 o $2 non è un vero file/cartella di panel:panel (link o altro proprietario): non lo tocco"
  return 1
}

# env_get_as_panel FILE KEY — come env_get, ma letto da panel e con un limite di
# tempo (un FIFO al posto del file non deve bloccare root). Un errore di lettura è
# un errore: chi chiama non deve scambiarlo per "chiave assente".
env_get_as_panel() {
  as_panel -t 5 awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" </dev/null
}

# env_merge_as_panel DIR FILE — righe KEY=VALUE da stdin, unite a FILE (in DIR) da
# panel: file temporaneo nella stessa cartella + mv, permessi del file com'erano
# (600 se nuovo). Valori solo su stdin; stderr di panel registrato da root, troncato.
env_merge_as_panel() {
  local err
  panel_env_check "$1" "$2" || return 1
  if ! err="$(as_panel -t 30 sh -c '
      umask 077
      nuove="$(cat)"
      d=$1; f=$2
      t="$(mktemp "$d/.tmp.XXXXXX")" || exit 1
      trap "rm -f \"$t\"" EXIT
      if [ -e "$f" ]; then src=$f; else src=/dev/null; fi
      NUOVE=$nuove awk '\''
        BEGIN {
          n = split(ENVIRON["NUOVE"], righe, "\n")
          for (i = 1; i <= n; i++) {
            k = righe[i]
            if (index(k, "=") < 2) continue
            sub(/=.*/, "", k)
            val[k] = righe[i]; ordine[++m] = k
          }
        }
        {
          k = ""
          if (index($0, "=") > 1) { k = $0; sub(/=.*/, "", k) }
          if (k != "" && (k in val)) { if (!(k in fatto)) print val[k]; fatto[k] = 1 } else print
        }
        END { for (i = 1; i <= m; i++) if (!(ordine[i] in fatto)) { print val[ordine[i]]; fatto[ordine[i]] = 1 } }
      '\'' "$src" >"$t" || exit 1
      if [ -e "$f" ]; then chmod --reference="$f" "$t" || exit 1; else chmod 600 "$t" || exit 1; fi
      mv -f "$t" "$f" || exit 1' sh "$1" "$2" 2>&1 >/dev/null)"; then
    # output di panel: niente a capo né caratteri di controllo (righe finte nel log)
    err="$(printf '%s' "$err" | tr -c '[:print:]' ' ')"
    log "scrittura di $2 non riuscita: ${err:0:300}"
    return 1
  fi
}
