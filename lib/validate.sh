# shellcheck shell=bash
# Validazione degli input. Ogni funzione restituisce 0 (valido) o 1, senza output.

RESERVED_USERS=(root debian panel www-data nginx mysql redis daemon bin sys nobody)

valid_domain() {
  local d="$1"
  ((${#d} >= 4 && ${#d} <= 253)) || return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_hostname() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  [[ "$u" != site_* ]] || return 1
  ! in_list "$u" "${RESERVED_USERS[@]}"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[1-9][0-9]{1,4}$ ]] || return 1
  if ((p == 22)); then
    return 0
  fi
  ((p >= 1024 && p <= 65535)) || return 1
  ! in_list "$p" 3306 6379 8080
}

valid_smtp_port() {
  in_list "$1" 25 465 587 2525
}

valid_line() {
  [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

valid_password() {
  valid_line "$1" && ((${#1} >= 12))
}

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_timezone() {
  [[ "$1" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ -f "${ZONEINFO_DIR:-/usr/share/zoneinfo}/$1" ]]
}

valid_locale() {
  [[ "$1" =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]]
}

valid_cf_token() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{30,200}$ ]]
}

valid_ssh_pubkey() {
  local key="$1" tmp info bits rc=0
  valid_line "$key" || return 1
  [[ "$key" != *"PRIVATE KEY"* ]] || return 1
  [[ "$key" =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] || return 1
  tmp="$(mktemp)"
  printf '%s\n' "$key" >"$tmp"
  info="$(ssh-keygen -l -f "$tmp" 2>/dev/null)" || rc=1
  rm -f "$tmp"
  ((rc == 0)) || return 1
  if [[ "$key" == ssh-rsa* ]]; then
    bits="${info%% *}"
    ((bits >= 2048)) || return 1
  fi
  return 0
}
