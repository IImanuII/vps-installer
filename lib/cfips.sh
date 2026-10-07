# shellcheck shell=bash
# IP di Cloudflare: real_ip di Nginx e regole UFW per 80/443.

: "${CF_IPS_URL:=https://www.cloudflare.com}"

cf_fetch_ips() {
  local v4 v6 out
  v4="$(curl -fsS --max-time 30 "$CF_IPS_URL/ips-v4")" || return 1
  v6="$(curl -fsS --max-time 30 "$CF_IPS_URL/ips-v6")" || return 1
  out="$(printf '%s\n%s\n' "$v4" "$v6" | grep -E '^[0-9a-fA-F:.]+/[0-9]{1,3}$' || true)"
  (($(grep -c . <<<"$out") >= 10)) || return 1
  printf '%s\n' "$out"
}

realip_snippet() {
  local c
  echo "# Generato da vps-cf-ips-update: non modificare a mano."
  while read -r c; do
    if [[ -n "$c" ]]; then
      printf 'set_real_ip_from %s;\n' "$c"
    fi
  done
  echo "real_ip_header CF-Connecting-IP;"
}

# ufw_stale_rules TAG VALIDE < "ufw status numbered"
ufw_stale_rules() {
  local tag="$1" valid="$2" n cidr
  sed -nE "s/^\[ *([0-9]+)\][^A-Z]*ALLOW IN +([^ ]+) .*# ${tag}\$/\1 \2/p" \
    | while read -r n cidr; do
      if ! grep -qxF -- "$cidr" <<<"$valid"; then
        echo "$n"
      fi
    done | sort -rn
}

cf_apply_ips() {
  local lock="$1" ips c n stale
  ips="$(cf_fetch_ips)" || die "Impossibile scaricare la lista degli IP Cloudflare"
  mkdir -p "$NGINX_SNIPPETS"
  realip_snippet <<<"$ips" | write_file "$NGINX_SNIPPETS/cloudflare-realip.conf" 644 root:root
  if is_yes "$lock"; then
    while read -r c; do
      ufw allow proto tcp from "$c" to any port 80,443 comment cloudflare >/dev/null
    done <<<"$ips"
    stale="$(ufw status numbered | ufw_stale_rules cloudflare "$ips")"
    for n in $stale; do
      ufw --force delete "$n" >/dev/null
    done
  fi
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    nginx -t >>"$VPS_LOG" 2>&1
    systemctl reload nginx
  fi
}
