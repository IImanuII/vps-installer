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

# cf_list_records ZONE_ID NOME — risposta JSON con tutti i record del nome.
cf_list_records() {
  local resp
  resp="$(cf_api GET "/zones/$1/dns_records?name=$2")"
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$resp"; then
    log "Cloudflare: impossibile leggere i record DNS di $2: $(jq -c '.errors // empty' <<<"$resp" 2>/dev/null || true)"
    return 1
  fi
  printf '%s\n' "$resp"
}

# cf_dns_conflicts JSON IPV4 IPV6 — una riga per ogni record che impedisce al
# nome di puntare a questa VPS: CNAME, A/AAAA con un indirizzo diverso.
cf_dns_conflicts() {
  jq -r --arg v4 "$2" --arg v6 "$3" '
    .result[]
    | select(.type == "CNAME"
        or (.type == "A" and .content != $v4)
        or (.type == "AAAA" and .content != $v6))
    | "\(.type) \(.name) → \(.content)"' <<<"$1"
}

cf_delete_record() {
  local resp
  resp="$(cf_api DELETE "/zones/$1/dns_records/$2")"
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$resp"; then
    log "Cloudflare: record $2 non eliminato: $(jq -c '.errors // empty' <<<"$resp" 2>/dev/null || true)"
    return 1
  fi
}

# cf_remove_records ZONE_ID NOME TIPO — elimina tutti i record di quel tipo.
cf_remove_records() {
  local resp id
  resp="$(cf_list_records "$1" "$2")" || return 1
  for id in $(jq -r --arg t "$3" '.result[] | select(.type == $t) | .id' <<<"$resp"); do
    cf_delete_record "$1" "$id" || return 1
  done
}

# cf_upsert_record ZONE_ID TIPO NOME CONTENUTO [MODALITÀ] — record proxato.
#   keep:    un CNAME o un record dello stesso tipo con altro contenuto viene
#            lasciato com'è; la descrizione finisce in CF_DNS_KEPT.
#   replace: il CNAME viene eliminato, il record dello stesso tipo aggiornato.
#   vuota (risposte delle versioni ≤ 1.0.2): CNAME lasciato, record aggiornato.
#   Un record già corretto non viene mai riscritto.
cf_upsert_record() {
  local zone="$1" type="$2" name="$3" content="$4" mode="${5:-}" body resp existing id cname
  resp="$(cf_list_records "$zone" "$name")" || return 1
  cname="$(jq -c '[.result[] | select(.type == "CNAME")][0] // empty' <<<"$resp")"
  if [[ -n "$cname" ]]; then
    if [[ "$mode" == replace ]]; then
      log "Cloudflare: elimino il CNAME di $name (sostituito da $type verso questa VPS)"
      cf_delete_record "$zone" "$(jq -r '.id' <<<"$cname")" || return 1
    else
      CF_DNS_KEPT="CNAME → $(jq -r '.content' <<<"$cname")"
      log "ATTENZIONE: Cloudflare: $name ha già un record $CF_DNS_KEPT, lo lascio invariato (verifica che porti a questa VPS)."
      return 0
    fi
  fi
  existing="$(jq -c --arg t "$type" '[.result[] | select(.type == $t)][0] // empty' <<<"$resp")"
  if [[ -n "$existing" ]] \
    && jq -e --arg c "$content" '.content == $c and .proxied == true' >/dev/null <<<"$existing"; then
    log "Cloudflare: record $type $name già corretto"
    return 0
  fi
  if [[ -n "$existing" && "$mode" == keep ]] \
    && jq -e --arg c "$content" '.content != $c' >/dev/null <<<"$existing"; then
    CF_DNS_KEPT="$type → $(jq -r '.content' <<<"$existing")"
    log "ATTENZIONE: Cloudflare: $name ha già un record $CF_DNS_KEPT, lo lascio invariato (verifica che porti a questa VPS)."
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
