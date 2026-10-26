# shellcheck shell=bash
# fail2ban: elenco dei ban per jail e sblocco di un IP (vps-f2b).

# f2b_valid_ip IP — un IPv4 (ottetti 0-255) o un IPv6 (cifre esadecimali e ':', eventuale
# IPv4 in coda). fail2ban banna indirizzi singoli: niente reti CIDR.
f2b_valid_ip() {
  local ip="$1" o
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[@]:1}"; do
      ((10#$o <= 255)) || return 1
    done
    return 0
  fi
  [[ ${#ip} -le 45 && "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
}

# f2b_jails — i nomi delle jail attive, uno per riga.
f2b_jails() {
  fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' '\n' | tr -d ' \t' | grep -E '^[A-Za-z0-9_-]+$' || true
}

# f2b_jail_json JAIL — {name, currently_failed, total_banned, banned:[{ip, until}]}.
# `until` e' la fine del ban ("AAAA-MM-GG HH:MM:SS", ora del server) o null se fail2ban
# non la dice (ban permanente o versione senza --with-time).
f2b_jail_json() {
  local j="$1" st failed total tempi
  st="$(fail2ban-client status "$j" 2>/dev/null)" || return 1
  failed="$(sed -n 's/.*Currently failed:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$st" | head -n 1)"
  total="$(sed -n 's/.*Total banned:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$st" | head -n 1)"
  tempi="$(fail2ban-client get "$j" banip --with-time 2>/dev/null || true)"
  sed -n 's/.*Banned IP list:[[:space:]]*//p' <<<"$st" | tr -s '[:blank:]' '\n' | while read -r ip; do
    f2b_valid_ip "$ip" || continue
    # Riga di --with-time: "IP <tab> inizio + durata = fine".
    printf '%s\t%s\n' "$ip" "$(awk -v ip="$ip" '$1 == ip { sub(/.*= */, ""); print; exit }' <<<"$tempi")"
  done | jq -R -s -c --arg n "$j" --arg f "${failed:-0}" --arg t "${total:-0}" '
    [split("\n")[] | select(. != "") | split("\t") |
      {ip: .[0], until: (if (.[1] // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$") then .[1] else null end)}]
    | {name: $n, currently_failed: ($f | tonumber), total_banned: ($t | tonumber), banned: .}'
}

# f2b_status — {ok, jails:[...]}; fail2ban fermo = errore.
f2b_status() {
  local j r out=()
  fail2ban-client ping >/dev/null 2>&1 || return 1
  while read -r j; do
    [[ -n "$j" ]] || continue
    r="$(f2b_jail_json "$j")" || return 1
    out+=("$r")
  done < <(f2b_jails)
  printf '%s\n' "${out[@]}" | jq -s -c '{ok: true, jails: [.[] | select(type == "object")]}'
}
