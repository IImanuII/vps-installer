# shellcheck shell=bash
# Rete: IP del server, controllo DNS, suffissi di dominio.

server_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

server_ipv6() {
  ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/deprecated/ { sub(/\/.*/, "", $2); print $2; exit }'
}

# dns_points_here DOMINIO IP — 0 se il dominio risolve (anche) all'IP indicato.
dns_points_here() {
  local ips
  ips="$(getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u)" || return 1
  grep -qxF -- "$2" <<<"$ips"
}

# domain_suffixes panel.miosito.it → panel.miosito.it, miosito.it
domain_suffixes() {
  local d="$1"
  while [[ "$d" == *.* ]]; do
    printf '%s\n' "$d"
    d="${d#*.}"
  done
}
