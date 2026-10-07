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
VPS_INSTALLER_VERSION="1.0.3"
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
