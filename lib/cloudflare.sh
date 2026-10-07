# shellcheck shell=bash
# API Cloudflare. Il token sta in $CF_API_TOKEN e arriva a curl tramite un
# file header temporaneo (600), così non compare mai tra gli argomenti (ps).

: "${CF_API:=https://api.cloudflare.com/client/v4}"

cf_api() {
  local method="$1" path="$2" data="${3:-}" hdr rc=0
  [[ -n "${CF_API_TOKEN:-}" ]] || die "Token Cloudflare mancante"
  hdr="$(mktemp)"
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" >"$hdr"
  local args=(-sS --max-time 30 -X "$method" -H @"$hdr" -H 'Content-Type: application/json')
  if [[ -n "$data" ]]; then
    args+=(--data "$data")
  fi
  curl "${args[@]}" "$CF_API$path" || rc=$?
  rm -f "$hdr"
  return "$rc"
}

# cf_find_zone DOMINIO → "ZONE_ID ZONE_NAME"
cf_find_zone() {
  local cand resp id
  while read -r cand; do
    resp="$(cf_api GET "/zones?name=$cand&status=active")" || return 1
    id="$(jq -r '.result[0].id // empty' <<<"$resp" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      printf '%s %s\n' "$id" "$cand"
      return 0
    fi
  done < <(domain_suffixes "$1")
  return 1
}

# cf_upsert_record ZONE_ID TIPO NOME CONTENUTO — record proxato.
#   Un CNAME già presente con lo stesso nome viene lasciato com'è (creato a mano):
#   avviso nel log e si prosegue. Un record dello stesso tipo già corretto non
#   viene toccato; con contenuto diverso viene aggiornato.
cf_upsert_record() {
  local zone="$1" type="$2" name="$3" content="$4" body resp existing id
  resp="$(cf_api GET "/zones/$zone/dns_records?name=$name")"
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$resp"; then
    log "Cloudflare: impossibile leggere i record DNS di $name: $(jq -c '.errors // empty' <<<"$resp" 2>/dev/null || true)"
    return 1
  fi
  if jq -e '[.result[] | select(.type == "CNAME")] | length > 0' >/dev/null <<<"$resp"; then
    log "ATTENZIONE: Cloudflare: $name ha già un record CNAME, lo lascio invariato (verifica che porti a questa VPS)."
    return 0
  fi
  existing="$(jq -c --arg t "$type" '[.result[] | select(.type == $t)][0] // empty' <<<"$resp")"
  if [[ -n "$existing" ]] \
    && jq -e --arg c "$content" '.content == $c and .proxied == true' >/dev/null <<<"$existing"; then
    log "Cloudflare: record $type $name già corretto"
    return 0
  fi
  id="$(jq -r '.id // empty' <<<"${existing:-null}")"
  body="$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" \
    '{type: $t, name: $n, content: $c, ttl: 1, proxied: true}')"
  if [[ -n "$id" ]]; then
    resp="$(cf_api PUT "/zones/$zone/dns_records/$id" "$body")"
  else
    resp="$(cf_api POST "/zones/$zone/dns_records" "$body")"
  fi
  if ! jq -e '.success == true' >/dev/null <<<"$resp"; then
    log "Cloudflare: record $type $name non salvato: $(jq -c '.errors' <<<"$resp")"
    return 1
  fi
}

cf_token_from_ini() {
  sed -n 's/^dns_cloudflare_api_token *= *//p' "${1:-$VPS_OPT/secrets/cloudflare.ini}"
}

# cf_write_ini TOKEN — credenziali per certbot (dns-cloudflare), 600 root.
cf_write_ini() {
  install -d -m 700 "$VPS_OPT/secrets"
  printf 'dns_cloudflare_api_token = %s\n' "$1" \
    | write_file "$VPS_OPT/secrets/cloudflare.ini" 600 root:root
}
