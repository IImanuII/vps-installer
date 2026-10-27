# shellcheck shell=bash
# Libreria dell'accesso SSH dal browser: validazione, stato e configurazione di sshd.
# Richiede lib/common.sh e lib/validate.sh.

# run.sh carica lib/*.sh in ordine alfabetico: qui common.sh non è ancora stato letto.
: "${VPS_OPT:=/opt/vps}"
: "${SSHD_CONFIG_D:=/etc/ssh/sshd_config.d}"
: "${SSH_CF_CA:=/etc/ssh/vps-cf-ca.pub}"
: "${SSH_CF_PRINCIPALS:=/etc/ssh/vps-cf-principals}"
: "${SSHTUNNEL_STATE:=$VPS_OPT/ssh-tunnel.json}"
: "${SSHTUNNEL_ENV:=$VPS_OPT/secrets/cf-tunnel.env}"

ST_DROPIN="20-vps-cfaccess.conf"

# st_valid_label L — etichetta DNS singola.
st_valid_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# st_random_label — "ssh-" + 6 caratteri [a-z0-9]: un nome non indovinabile.
st_random_label() {
  # Quantità limitata letta prima: "tr </dev/urandom | head" muore per SIGPIPE
  # (141) sotto "set -o pipefail" e abortirebbe il chiamante.
  local s=""
  while ((${#s} < 6)); do
    s+="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9')"
  done
  printf 'ssh-%s\n' "${s:0:6}"
}

# st_parse_emails "a@x.it, B@y.it" — email minuscole, senza duplicati, una per riga.
# 1 se sono 0 o più di 5, o se una non è valida (o supera 254 caratteri).
st_parse_emails() {
  local raw="$1" item e x seen items=() out=()
  # read -a spezza sulla virgola senza espandere glob (es. "*").
  IFS=, read -ra items <<<"$raw" || true
  for item in "${items[@]}"; do
    e="$(trim "$item")"
    e="${e,,}"
    [[ -n "$e" ]] || continue
    ((${#e} <= 254)) && valid_email "$e" || return 1
    seen=0
    for x in "${out[@]}"; do [[ "$x" == "$e" ]] && seen=1; done
    ((seen)) || out+=("$e")
  done
  ((${#out[@]} >= 1 && ${#out[@]} <= 5)) || return 1
  printf '%s\n' "${out[@]}"
}

# st_principals EMAIL... — il principal del certificato è la parte prima della @;
# due email con lo stesso prefisso danno un solo principal.
st_principals() {
  local e p x seen out=()
  for e in "$@"; do
    p="${e%%@*}"
    p="${p,,}"
    seen=0
    for x in "${out[@]}"; do [[ "$x" == "$p" ]] && seen=1; done
    ((seen)) || out+=("$p")
  done
  ((${#out[@]} == 0)) || printf '%s\n' "${out[@]}"
}

# st_state_get CAMPO — valore nel JSON di stato (vuoto se manca il file o il campo).
st_state_get() {
  [[ -f "$SSHTUNNEL_STATE" ]] || return 0
  jq -r --arg k "$1" '.[$k] // empty' "$SSHTUNNEL_STATE" 2>/dev/null || true
}

# st_state_write JSON — scrittura atomica, 600 root: dice cosa è attivo, mai segreti.
st_state_write() {
  mkdir -p "$(dirname "$SSHTUNNEL_STATE")"
  printf '%s\n' "$1" | write_file "$SSHTUNNEL_STATE" 600 root:root
}

# st_sshd_test — "sshd -t" (sshd sta in /usr/sbin, non sempre nel PATH).
st_sshd_test() {
  local bin
  bin="$(command -v sshd || echo /usr/sbin/sshd)"
  "$bin" -t >/dev/null 2>&1
}

# st_sshd_files USER — i tre file toccati, uno per riga.
st_sshd_files() {
  printf '%s\n' "$SSHD_CONFIG_D/$ST_DROPIN" "$SSH_CF_CA" "$SSH_CF_PRINCIPALS/$1"
}

# st_sshd_snapshot DIR USER — copia i file che esistono; "N.none" per quelli assenti.
st_sshd_snapshot() {
  local dir="$1" f i=0
  while IFS= read -r f; do
    if [[ -e "$f" ]]; then cp -p "$f" "$dir/$i"; else : >"$dir/$i.none"; fi
    i=$((i + 1))
  done < <(st_sshd_files "$2")
}

# st_sshd_restore DIR USER — rimette i file com'erano (o li toglie se non c'erano).
st_sshd_restore() {
  local dir="$1" f i=0
  while IFS= read -r f; do
    # Un file che non si ripristina non deve impedire di provare gli altri.
    if [[ -e "$dir/$i.none" ]]; then
      rm -f "$f" || log "ripristino: impossibile togliere $f"
    else
      cp -p "$dir/$i" "$f" || log "ripristino: impossibile ripristinare $f"
    fi
    i=$((i + 1))
  done < <(st_sshd_files "$2")
}

# st_sshd_apply USER CA_PUBKEY PRINCIPAL... — sshd si fida della CA per USER.
# Se "sshd -t" fallisce tutto torna com'era e sshd non viene ricaricato.
st_sshd_apply() {
  local user="$1" ca="$2" snap p n=0
  shift 2
  # L'utente finisce in un percorso; senza principal sshd rifiuterebbe tutti.
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  for p in "$@"; do [[ -n "$p" ]] && n=$((n + 1)); done
  ((n >= 1)) || return 1
  snap="$(mktemp -d)" || return 1
  st_sshd_snapshot "$snap" "$user"
  # Gruppo in un "if": un'unica scrittura fallita porta al ripristino, non a
  # un'uscita a metà per "set -e" con file mezzi scritti e snapshot orfano.
  # sshd legge i file come root, ma la cartella deve essere attraversabile.
  if {
    mkdir -p "$SSHD_CONFIG_D" "$SSH_CF_PRINCIPALS" "$(dirname "$SSH_CF_CA")" &&
      chmod 755 "$SSH_CF_PRINCIPALS" &&
      printf '%s\n' "$ca" | write_file "$SSH_CF_CA" 644 root:root &&
      printf '%s\n' "$@" | write_file "$SSH_CF_PRINCIPALS/$user" 644 root:root &&
      write_file "$SSHD_CONFIG_D/$ST_DROPIN" 644 root:root <"$VPS_TEMPLATES/sshd-20-vps-cfaccess.conf"
  } && st_sshd_test; then
    rm -rf "$snap"
    systemctl reload ssh
    return
  fi
  st_sshd_restore "$snap" "$user"
  rm -rf "$snap"
  log "scrittura o "sshd -t" falliti: ripristinata la configurazione di prima."
  return 1
}

# st_sshd_remove USER — toglie drop-in, CA e principal di USER; poi test e reload.
st_sshd_remove() {
  local f
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  while IFS= read -r f; do rm -f "$f"; done < <(st_sshd_files "$1")
  st_sshd_test || {
    log "sshd -t fallisce dopo la rimozione: controllare la configurazione."
    return 1
  }
  systemctl reload ssh
}

# ---------------------------------------------------------------------------
# Cloudflare: tunnel, app Access, CA dei certificati brevi, DNS.
#
# Verificato sulla documentazione Cloudflare il 2026-10-27:
# - Terminale nel browser: solo app Access self-hosted pubbliche, solo hostname
#   (niente path), policy solo Allow/Block; nessun limite di piano indicato. In
#   API è la variante "BrowserSSHApplication", type:"ssh", di
#   POST /accounts/{acc}/access/apps (domain, session_duration, allowed_idps,
#   auto_redirect_to_identity, app_launcher_visible, policies); PUT
#   /accounts/{acc}/access/apps/{id} con lo stesso corpo la aggiorna.
#   https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/browser-rendering/
#   https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/applications/methods/create/
# - Policy: quelle legate a una sola app ("legacy") non si possono più aggiungere
#   alle app nuove. Si crea una policy riutilizzabile
#   POST /accounts/{acc}/access/policies {name, decision:"allow",
#   include:[{email:{email}}]} → result.id, la si collega all'app con
#   policies:[{id, precedence:1}] e si cambiano le email con
#   PUT /accounts/{acc}/access/policies/{id} (name, decision, include).
#   https://developers.cloudflare.com/cloudflare-one/access-controls/policies/policy-management/
#   https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/policies/methods/create/
#   https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/policies/methods/update/
# - CA dei certificati brevi dell'app: POST /accounts/{acc}/access/apps/{id}/ca,
#   senza corpo → result.public_key; permesso "Access: Apps and Policies Write"
#   (già nell'elenco CF_PERMS_TEXT). Principal del certificato = parte
#   dell'email prima della @. È documentata come "legacy", ma è quella indicata
#   per il terminale nel browser; "Access for Infrastructure" vuole il client WARP.
#   https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/applications/subresources/cas/methods/create/
#   https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/short-lived-certificates-legacy/
# - Tunnel: DELETE /accounts/{acc}/cfd_tunnel/{id} vuole un tunnel senza
#   connessioni attive (nessun parametro "cascade" documentato): prima si ferma
#   cloudflared, poi DELETE .../cfd_tunnel/{id}/connections le toglie tutte.
#   Un tunnel cancellato può ancora rispondere a GET con "deleted_at".
#   https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/methods/delete/
#   https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/connections/methods/delete/
# - cloudflared: repository apt "deb [signed-by=…] https://pkg.cloudflare.com/cloudflared
#   any main", chiave https://pkg.cloudflare.com/cloudflare-main.gpg
#   ("CloudFlare Software Packaging 2025", fingerprint primario sotto).
#   https://pkg.cloudflare.com/index.html

: "${SYSTEMD_DIR:=/etc/systemd/system}"
: "${APT_SOURCES_D:=/etc/apt/sources.list.d}"
: "${CLOUDFLARED_KEYRING:=/usr/share/keyrings/cloudflare-main.gpg}"
ST_UNIT="vps-cloudflared"
CLOUDFLARED_KEY_FPRS=(CC94B39C77AE7342A68B89628A682D308D4E5E73)
ST_UNDO=()

# _st_manifest FILTRO — campo del manifest (vuoto se manca).
_st_manifest() {
  jq -r "$1 // empty" "$(manifest_path)" 2>/dev/null || true
}

# _st_token — CF_API_TOKEN dal file 600 se non è già impostato.
_st_token() {
  [[ -n "${CF_API_TOKEN:-}" ]] || CF_API_TOKEN="$(cf_token_from_ini 2>/dev/null || true)"
  [[ -n "${CF_API_TOKEN:-}" ]] || {
    ST_ERR="token Cloudflare mancante"
    return 1
  }
}

# _st_cf_context — Cloudflare attivo, token, zona e account: ST_ZONE, ST_ZONE_ID, ST_ACC.
_st_cf_context() {
  local rc=0
  [[ "$(_st_manifest .cloudflare.enabled)" == true ]] || {
    ST_ERR="Cloudflare non è attivo su questa VPS"
    return 1
  }
  ST_ZONE="$(_st_manifest .cloudflare.zone)"
  [[ -n "$ST_ZONE" ]] || {
    ST_ERR="zona Cloudflare assente nel manifest"
    return 1
  }
  _st_token || return 1
  ST_ZONE_ID="$(cf_zone_id "$ST_ZONE")" || rc=$?
  case "$rc" in
    0) ;;
    1) ST_ERR="la zona $ST_ZONE non è visibile su Cloudflare con questo token" ;;
    *) ST_ERR="Cloudflare non risponde" ;;
  esac
  ((rc == 0)) || return 1
  ST_ACC="$(cf_account_id "$ST_ZONE_ID")" || {
    ST_ERR="impossibile leggere l'account Cloudflare della zona $ST_ZONE"
    return 1
  }
}

# _st_req METODO PERCORSO [DATI] — chiamata API: corpo in ST_BODY, codice HTTP
# in ST_CODE (000 se Cloudflare non risponde). 0 solo con success:true.
_st_req() {
  local out
  ST_BODY="" ST_CODE=000
  out="$(cf_api_code "$@")" || return 1
  if [[ "$out" == *$'\n'* ]]; then
    ST_CODE="${out##*$'\n'}"
    ST_BODY="${out%$'\n'*}"
  else
    ST_CODE="$out"
  fi
  jq -e '.success == true' >/dev/null 2>&1 <<<"$ST_BODY"
}

# _st_gone — l'ultima chiamata ha trovato la risorsa già assente.
_st_gone() {
  [[ "$ST_CODE" == 404 ]]
}

# _st_fail MESSAGGIO — ST_ERR col motivo di Cloudflare (mai il corpo intero:
# la risposta di creazione del tunnel contiene il suo token).
_st_fail() {
  local why
  why="$(cf_api_error "$ST_BODY")"
  if [[ -z "$why" && "$ST_CODE" == 000 ]]; then why="Cloudflare non risponde"; fi
  ST_ERR="$1${why:+: $why}"
  log "accesso SSH: $ST_ERR"
}

# _st_del PERCORSO — DELETE; 0 anche se la risorsa non c'era più.
_st_del() {
  _st_req DELETE "$1" || _st_gone
}

# Annullamento: ogni passo riuscito aggiunge il comando che lo disfa; al primo
# errore si eseguono all'indietro. Gli argomenti sono id e nomi DNS (niente
# spazi), quindi una riga per comando basta.
_st_undo_push() {
  ST_UNDO+=("$*")
}

_st_rollback() {
  local i a
  for ((i = ${#ST_UNDO[@]} - 1; i >= 0; i--)); do
    read -ra a <<<"${ST_UNDO[i]}"
    "${a[@]}" || log "accesso SSH: annullamento non riuscito: ${ST_UNDO[i]}"
  done
  ST_UNDO=()
}

_st_rm_dns() {
  _st_del "/zones/$1/dns_records/$2"
}

# _st_rm_app ACC APP — prima la CA (non serve più a niente), poi l'app.
_st_rm_app() {
  _st_del "/accounts/$1/access/apps/$2/ca" || log "accesso SSH: CA dell'app $2 non cancellata"
  _st_del "/accounts/$1/access/apps/$2"
}

_st_rm_policy() {
  _st_del "/accounts/$1/access/policies/$2"
}

# _st_rm_tunnel ACC TUNNEL — Cloudflare non cancella un tunnel con connessioni
# attive: si tolgono prima (cloudflared deve essere già fermo).
_st_rm_tunnel() {
  _st_del "/accounts/$1/cfd_tunnel/$2/connections" || log "accesso SSH: connessioni del tunnel $2 non pulite"
  _st_del "/accounts/$1/cfd_tunnel/$2"
}

# _st_ingress_body PORTA HOST... — ogni host verso sshd; il resto 404.
_st_ingress_body() {
  local port="$1"
  shift
  jq -nc --arg port "$port" \
    '{config: {ingress: ([$ARGS.positional[] | {hostname: ., service: ("ssh://localhost:" + $port)}]
      + [{service: "http_status:404"}])}}' --args "$@"
}

_st_put_ingress() {
  local acc="$1" tid="$2"
  shift 2
  _st_req PUT "/accounts/$acc/cfd_tunnel/$tid/configurations" "$(_st_ingress_body "$@")"
}

# _st_app_body HOST OTP_ID POLICY_ID — app con terminale SSH nel browser,
# sessione di un'ora, solo codice via email (niente schermata di scelta).
_st_app_body() {
  jq -nc --arg h "$1" --arg o "$2" --arg p "$3" \
    '{name: ("SSH " + $h), type: "ssh", domain: $h, session_duration: "1h",
      allowed_idps: [$o], auto_redirect_to_identity: true, app_launcher_visible: false,
      policies: [{id: $p, precedence: 1}]}'
}

_st_put_app() {
  _st_req PUT "/accounts/$1/access/apps/$2" "$(_st_app_body "$3" "$4" "$5")"
}

# _st_policy_body HOST EMAIL... — consenti solo queste email.
_st_policy_body() {
  local host="$1"
  shift
  jq -nc --arg h "$host" \
    '{name: ("vps-ssh " + $h), decision: "allow",
      include: [$ARGS.positional[] | {email: {email: .}}]}' --args "$@"
}

_st_put_policy() {
  local acc="$1" pid="$2"
  shift 2
  _st_req PUT "/accounts/$acc/access/policies/$pid" "$(_st_policy_body "$@")"
}

# _st_cname_body HOST TUNNEL — il nome verso il tunnel, proxato.
_st_cname_body() {
  jq -nc --arg n "$1" --arg c "$2.cfargotunnel.com" \
    '{type: "CNAME", name: $n, content: $c, ttl: 1, proxied: true}'
}

# _st_service_install — unità cloudflared col token del tunnel in ST_TUNNEL_TOKEN.
# Il token va nel file env con printf (builtin): mai tra gli argomenti di un processo.
_st_service_install() {
  install -d -m 700 "$(dirname "$SSHTUNNEL_ENV")" &&
    printf 'TUNNEL_TOKEN=%s\n' "$ST_TUNNEL_TOKEN" | write_file "$SSHTUNNEL_ENV" 600 root:root &&
    mkdir -p "$SYSTEMD_DIR" &&
    write_file "$SYSTEMD_DIR/$ST_UNIT.service" 644 root:root <"$VPS_TEMPLATES/vps-cloudflared.service" &&
    systemctl daemon-reload >>"$VPS_LOG" 2>&1 &&
    systemctl enable --now "$ST_UNIT" >>"$VPS_LOG" 2>&1
}

# _st_service_remove — ferma e toglie unità e token; il pacchetto resta.
_st_service_remove() {
  systemctl disable --now "$ST_UNIT" >>"$VPS_LOG" 2>&1 || true
  rm -f "${SYSTEMD_DIR:?}/${ST_UNIT:?}.service" "${SSHTUNNEL_ENV:?}"
  systemctl daemon-reload >>"$VPS_LOG" 2>&1 || true
}

# st_cloudflared_install — cloudflared dal repository apt di Cloudflare, con la
# chiave verificata sul fingerprint fissato. 1 con ST_ERR se non riesce.
st_cloudflared_install() {
  local tmp list="$APT_SOURCES_D/cloudflared.list"
  command -v cloudflared >/dev/null 2>&1 && return 0
  log "accesso SSH: installo cloudflared dal repository di Cloudflare"
  tmp="$(mktemp)"
  if ! curl -fsS --max-time 30 -o "$tmp" https://pkg.cloudflare.com/cloudflare-main.gpg >>"$VPS_LOG" 2>&1; then
    rm -f "${tmp:?}"
    ST_ERR="impossibile scaricare la chiave del repository di Cloudflare"
    log "accesso SSH: $ST_ERR"
    return 1
  fi
  mkdir -p "$(dirname "$CLOUDFLARED_KEYRING")" "$APT_SOURCES_D"
  # gpg_keyring_install termina con die: in una subshell l'errore resta qui
  # (e il JSON che die stampa dentro uno strumento non finisce sullo stdout).
  if ! (gpg_keyring_install "$tmp" "$CLOUDFLARED_KEYRING" "${CLOUDFLARED_KEY_FPRS[@]}") >/dev/null; then
    rm -f "${tmp:?}"
    ST_ERR="la chiave del repository di Cloudflare non è quella attesa"
    log "accesso SSH: $ST_ERR"
    return 1
  fi
  rm -f "${tmp:?}"
  printf 'deb [signed-by=%s] https://pkg.cloudflare.com/cloudflared any main\n' "$CLOUDFLARED_KEYRING" \
    | write_file "$list" 644 root:root
  if apt-get update -q -o DPkg::Lock::Timeout=300 >>"$VPS_LOG" 2>&1 \
    && apt_install cloudflared && command -v cloudflared >/dev/null 2>&1; then
    return 0
  fi
  # Un repository che non funziona romperebbe ogni "apt-get update" successivo.
  rm -f "${list:?}"
  ST_ERR="installazione di cloudflared non riuscita (dettagli in $VPS_LOG)"
  log "accesso SSH: $ST_ERR"
  return 1
}

# st_host_free HOST — 0 se il nome è libero; 1 con ST_REASON se è il dominio (o
# il www.) di un sito registrato o se la zona ha già un record con quel nome;
# 2 con ST_ERR se Cloudflare non risponde.
st_host_free() {
  local host="$1" f resp
  ST_REASON=""
  for f in "${SITES_DIR:-$VPS_OPT/sites}"/*.json; do
    [[ -f "$f" ]] || continue
    if jq -e --arg h "$host" '.domain == $h or (.www == true and ("www." + .domain) == $h)' \
      >/dev/null 2>&1 "$f"; then
      ST_REASON="usato da un sito"
      return 1
    fi
  done
  if [[ -z "${ST_ZONE_ID:-}" ]]; then
    _st_cf_context || return 2
  fi
  resp="$(cf_list_records "$ST_ZONE_ID" "$host")" || {
    ST_ERR="impossibile leggere i record DNS di $host"
    return 2
  }
  if jq -e '(.result | length) > 0' >/dev/null 2>&1 <<<"$resp"; then
    ST_REASON="esiste già un record DNS"
    return 1
  fi
}

# _st_emails EMAIL... — in ST_EMAILS le email normalizzate (1–5, valide).
_st_emails() {
  local list
  list="$(
    IFS=,
    st_parse_emails "$*"
  )" || {
    ST_ERR="email non valide: da 1 a 5, separate da virgola"
    return 1
  }
  mapfile -t ST_EMAILS <<<"$list"
}

# _st_check_free HOST — st_host_free con ST_ERR pronto per l'utente.
_st_check_free() {
  local rc=0
  st_host_free "$1" || rc=$?
  if ((rc == 1)); then
    ST_ERR="il nome $1 non è libero: $ST_REASON"
  fi
  return "$rc"
}

# st_enable LABEL EMAIL... — attiva l'accesso SSH dal browser su LABEL.<zona>.
# L'ordine garantisce che il nome entri nel DNS solo quando l'app Access che lo
# protegge esiste già; al primo errore si annulla quanto fatto (tranne il
# One-time PIN, che appartiene all'organizzazione Zero Trust).
st_enable() {
  local label="$1" host user port missing rc=0 otp tid pid aid ca did state
  local -a principals
  shift
  ST_ERR="" ST_UNDO=()
  st_valid_label "$label" || {
    ST_ERR="nome non valido"
    return 1
  }
  _st_emails "$@" || return 1
  [[ ! -f "$SSHTUNNEL_STATE" ]] || {
    ST_ERR="l'accesso SSH è già attivo"
    return 1
  }
  _st_cf_context || return 1
  user="$(_st_manifest .admin_user)"
  port="$(_st_manifest .ssh_port)"
  [[ -n "$user" && "$port" =~ ^[0-9]+$ ]] || {
    ST_ERR="manifest incompleto (admin_user, ssh_port)"
    return 1
  }
  host="$label.$ST_ZONE"

  missing="$(cf_check_ssh_perms "$ST_ACC")" || rc=$?
  if ((rc == 2)); then
    ST_ERR="Cloudflare non risponde"
    return 1
  elif ((rc == 1)); then
    ST_ERR="al token Cloudflare mancano dei permessi: $(paste -sd ' ' <<<"$missing")"
    return 1
  fi
  cf_zerotrust_enabled "$ST_ACC" || {
    ST_ERR="Zero Trust non è attivo sull'account Cloudflare"
    return 1
  }
  _st_check_free "$host" || return 1

  # Codice via email: se l'organizzazione non ce l'ha, lo si accende.
  _st_req GET "/accounts/$ST_ACC/access/identity_providers" || {
    _st_fail "impossibile leggere i metodi di accesso di Zero Trust"
    return 1
  }
  otp="$(jq -r '[.result[]? | select(.type == "onetimepin")][0].id // empty' <<<"$ST_BODY")"
  if [[ -z "$otp" ]]; then
    _st_req POST "/accounts/$ST_ACC/access/identity_providers" \
      '{"name":"One-time PIN","type":"onetimepin","config":{}}' || {
      _st_fail "impossibile attivare il codice via email (One-time PIN)"
      return 1
    }
    otp="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
    log "accesso SSH: attivato il metodo One-time PIN su Zero Trust"
  fi

  st_cloudflared_install || return 1

  # Tunnel gestito da Cloudflare: il suo token resta solo in memoria e nel file env.
  _st_req POST "/accounts/$ST_ACC/cfd_tunnel" \
    "$(jq -nc --arg n "vps-$(hostname -s 2>/dev/null || hostname)" '{name: $n, config_src: "cloudflare"}')" || {
    _st_fail "creazione del tunnel non riuscita"
    return 1
  }
  tid="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  ST_TUNNEL_TOKEN="$(jq -r '.result.token // empty' <<<"$ST_BODY")"
  ST_BODY=""
  [[ -n "$tid" ]] || {
    ST_ERR="Cloudflare non ha restituito l'id del tunnel"
    return 1
  }
  _st_undo_push _st_rm_tunnel "$ST_ACC" "$tid"
  if [[ -z "$ST_TUNNEL_TOKEN" ]] && _st_req GET "/accounts/$ST_ACC/cfd_tunnel/$tid/token"; then
    ST_TUNNEL_TOKEN="$(jq -r '.result // empty' <<<"$ST_BODY")"
    ST_BODY=""
  fi
  if [[ -z "$ST_TUNNEL_TOKEN" ]]; then
    ST_ERR="Cloudflare non ha restituito il token del tunnel"
    _st_rollback
    return 1
  fi
  if ! _st_put_ingress "$ST_ACC" "$tid" "$port" "$host"; then
    _st_fail "configurazione del tunnel non riuscita"
    ST_TUNNEL_TOKEN=""
    _st_rollback
    return 1
  fi
  _st_undo_push _st_service_remove
  if ! _st_service_install; then
    ST_TUNNEL_TOKEN=""
    ST_ERR="avvio di cloudflared non riuscito (dettagli in $VPS_LOG)"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi
  ST_TUNNEL_TOKEN=""

  # Policy e app Access: da qui il nome, quando entrerà nel DNS, è protetto.
  if ! _st_req POST "/accounts/$ST_ACC/access/policies" "$(_st_policy_body "$host" "${ST_EMAILS[@]}")"; then
    _st_fail "creazione della policy Access non riuscita"
    _st_rollback
    return 1
  fi
  pid="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  _st_undo_push _st_rm_policy "$ST_ACC" "$pid"
  if ! _st_req POST "/accounts/$ST_ACC/access/apps" "$(_st_app_body "$host" "$otp" "$pid")"; then
    _st_fail "creazione dell'app Access non riuscita"
    _st_rollback
    return 1
  fi
  aid="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  _st_undo_push _st_rm_app "$ST_ACC" "$aid"

  # CA dell'app e sshd che se ne fida per l'utente dell'installazione.
  if ! _st_req POST "/accounts/$ST_ACC/access/apps/$aid/ca"; then
    _st_fail "creazione della CA dei certificati SSH non riuscita"
    _st_rollback
    return 1
  fi
  ca="$(jq -r '.result.public_key // empty' <<<"$ST_BODY")"
  mapfile -t principals < <(st_principals "${ST_EMAILS[@]}")
  if [[ -z "$ca" ]] || ! st_sshd_apply "$user" "$ca" "${principals[@]}"; then
    ST_ERR="configurazione di sshd non riuscita: sshd è rimasto com'era"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi
  _st_undo_push st_sshd_remove "$user"

  # Solo ora il nome entra nel DNS.
  if ! _st_req POST "/zones/$ST_ZONE_ID/dns_records" "$(_st_cname_body "$host" "$tid")"; then
    _st_fail "creazione del record DNS di $host non riuscita"
    _st_rollback
    return 1
  fi
  did="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  _st_undo_push _st_rm_dns "$ST_ZONE_ID" "$did"

  state="$(jq -n --arg host "$host" --arg label "$label" --arg acc "$ST_ACC" --arg zone "$ST_ZONE_ID" \
    --arg tid "$tid" --arg aid "$aid" --arg pid "$pid" --arg did "$did" --arg otp "$otp" \
    --arg user "$user" --arg at "$(date -u +%FT%TZ)" \
    '{host: $host, label: $label, account_id: $acc, zone_id: $zone, tunnel_id: $tid, app_id: $aid,
      policy_id: $pid, dns_id: $did, otp_id: $otp, emails: $ARGS.positional, user: $user,
      enabled_at: $at}' --args "${ST_EMAILS[@]}")"
  if ! st_state_write "$state"; then
    ST_ERR="impossibile scrivere lo stato dell'accesso SSH"
    _st_rollback
    return 1
  fi
  ST_UNDO=()
  log "accesso SSH attivato su $host (${#ST_EMAILS[@]} email)"
}

# _st_require_state — lo stato in ST_S (1 con ST_ERR se l'accesso non è attivo).
_st_require_state() {
  if [[ -f "$SSHTUNNEL_STATE" ]] && ST_S="$(cat "$SSHTUNNEL_STATE")"; then
    return 0
  fi
  ST_ERR="l'accesso SSH non è attivo"
  return 1
}

# st_set_emails EMAIL... — nuova policy Access e nuovi principal di sshd. Se sshd
# rifiuta la configurazione, la policy torna com'era.
st_set_emails() {
  local acc pid host user ca
  local -a old principals
  ST_ERR=""
  _st_emails "$@" || return 1
  _st_require_state || return 1
  _st_token || return 1
  acc="$(jq -r .account_id <<<"$ST_S")"
  pid="$(jq -r .policy_id <<<"$ST_S")"
  host="$(jq -r .host <<<"$ST_S")"
  user="$(jq -r .user <<<"$ST_S")"
  mapfile -t old < <(jq -r '.emails[]?' <<<"$ST_S")
  ca="$(head -n 1 "$SSH_CF_CA" 2>/dev/null || true)"
  [[ -n "$ca" ]] || {
    ST_ERR="CA di Cloudflare assente in sshd: disattivare e riattivare l'accesso"
    return 1
  }
  _st_put_policy "$acc" "$pid" "$host" "${ST_EMAILS[@]}" || {
    _st_fail "aggiornamento della policy Access non riuscito"
    return 1
  }
  mapfile -t principals < <(st_principals "${ST_EMAILS[@]}")
  if ! st_sshd_apply "$user" "$ca" "${principals[@]}"; then
    ST_ERR="configurazione di sshd non riuscita: email e sshd rimasti com'erano"
    log "accesso SSH: $ST_ERR"
    _st_put_policy "$acc" "$pid" "$host" "${old[@]}" || log "accesso SSH: policy Access non ripristinata"
    return 1
  fi
  st_state_write "$(jq '.emails = $ARGS.positional' --args "${ST_EMAILS[@]}" <<<"$ST_S")" || {
    ST_ERR="impossibile aggiornare lo stato dell'accesso SSH"
    return 1
  }
  log "accesso SSH: email autorizzate aggiornate (${#ST_EMAILS[@]})"
}

# st_set_host LABEL — sposta l'accesso su LABEL.<zona>. Il vecchio nome esce
# dall'ingresso del tunnel prima che l'app Access lo lasci: altrimenti, finché il
# suo CNAME esiste, porterebbe a sshd senza Access (e da localhost, che
# fail2ban non banna). Il nuovo nome entra nel DNS solo dopo l'app.
st_set_host() {
  local label="$1" acc tid aid pid otp zid old new did old_did port
  ST_ERR="" ST_UNDO=()
  st_valid_label "$label" || {
    ST_ERR="nome non valido"
    return 1
  }
  _st_require_state || return 1
  _st_token || return 1
  ST_ZONE="$(_st_manifest .cloudflare.zone)"
  port="$(_st_manifest .ssh_port)"
  acc="$(jq -r .account_id <<<"$ST_S")"
  tid="$(jq -r .tunnel_id <<<"$ST_S")"
  aid="$(jq -r .app_id <<<"$ST_S")"
  pid="$(jq -r .policy_id <<<"$ST_S")"
  otp="$(jq -r .otp_id <<<"$ST_S")"
  zid="$(jq -r .zone_id <<<"$ST_S")"
  old="$(jq -r .host <<<"$ST_S")"
  old_did="$(jq -r .dns_id <<<"$ST_S")"
  new="$label.$ST_ZONE"
  [[ "$new" != "$old" ]] || {
    ST_ERR="$new è già il nome dell'accesso SSH"
    return 1
  }
  ST_ZONE_ID="$zid"
  _st_check_free "$new" || return 1

  if ! _st_put_ingress "$acc" "$tid" "$port" "$new"; then
    _st_fail "configurazione del tunnel non riuscita"
    return 1
  fi
  _st_undo_push _st_put_ingress "$acc" "$tid" "$port" "$old"
  if ! _st_put_app "$acc" "$aid" "$new" "$otp" "$pid"; then
    _st_fail "aggiornamento dell'app Access non riuscito"
    _st_rollback
    return 1
  fi
  _st_undo_push _st_put_app "$acc" "$aid" "$old" "$otp" "$pid"
  if ! _st_req POST "/zones/$zid/dns_records" "$(_st_cname_body "$new" "$tid")"; then
    _st_fail "creazione del record DNS di $new non riuscita"
    _st_rollback
    return 1
  fi
  did="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  ST_UNDO=()
  # Il vecchio record ormai porta al 404 del tunnel: se non si cancella, lo si
  # segnala e basta.
  _st_rm_dns "$zid" "$old_did" || log "ATTENZIONE: accesso SSH: record DNS di $old non cancellato, va tolto a mano"
  st_state_write "$(jq --arg h "$new" --arg l "$label" --arg d "$did" \
    '.host = $h | .label = $l | .dns_id = $d' <<<"$ST_S")" || {
    ST_ERR="impossibile aggiornare lo stato dell'accesso SSH"
    return 1
  }
  log "accesso SSH: nome cambiato da $old a $new"
}

# st_disable — toglie DNS, app (con CA e policy), servizio, tunnel, sshd e stato.
# Il servizio si ferma prima del tunnel perché Cloudflare non cancella un tunnel
# connesso. Un pezzo già assente si salta; al primo errore vero ci si ferma e lo
# stato resta, così un nuovo tentativo riparte da dove si era arrivati.
st_disable() {
  local acc zid tid aid pid did user
  ST_ERR=""
  if [[ ! -f "$SSHTUNNEL_STATE" ]]; then
    _st_service_remove
    return 0
  fi
  _st_require_state || return 1
  _st_token || return 1
  acc="$(jq -r '.account_id // empty' <<<"$ST_S")"
  zid="$(jq -r '.zone_id // empty' <<<"$ST_S")"
  tid="$(jq -r '.tunnel_id // empty' <<<"$ST_S")"
  aid="$(jq -r '.app_id // empty' <<<"$ST_S")"
  pid="$(jq -r '.policy_id // empty' <<<"$ST_S")"
  did="$(jq -r '.dns_id // empty' <<<"$ST_S")"
  user="$(jq -r '.user // empty' <<<"$ST_S")"
  if [[ -n "$did" ]] && ! _st_rm_dns "$zid" "$did"; then
    _st_fail "cancellazione del record DNS non riuscita"
    return 1
  fi
  if [[ -n "$aid" ]] && ! _st_rm_app "$acc" "$aid"; then
    _st_fail "cancellazione dell'app Access non riuscita"
    return 1
  fi
  if [[ -n "$pid" ]] && ! _st_rm_policy "$acc" "$pid"; then
    _st_fail "cancellazione della policy Access non riuscita"
    return 1
  fi
  _st_service_remove
  if [[ -n "$tid" ]] && ! _st_rm_tunnel "$acc" "$tid"; then
    _st_fail "cancellazione del tunnel non riuscita"
    return 1
  fi
  if [[ -n "$user" ]] && ! st_sshd_remove "$user"; then
    ST_ERR="rimozione della configurazione di sshd non riuscita"
    return 1
  fi
  rm -f "${SSHTUNNEL_STATE:?}"
  log "accesso SSH disattivato"
}

# st_status_json — stato completo per la Plancia, senza segreti. Con Cloudflare
# spento solo {ok:true, cloudflare:false}; se Cloudflare non risponde
# {ok:false, error} e 1. drift elenca i pezzi registrati ma spariti.
st_status_json() {
  local missing rc=0 zt=false otp=false enabled=false service=missing cver="" tstatus=""
  local host="" emails="[]" user zid did aid tid
  local -a drift=()
  if [[ "$(_st_manifest .cloudflare.enabled)" != true ]]; then
    printf '{"ok":true,"cloudflare":false}\n'
    return 0
  fi
  if ! _st_cf_context; then
    jq -nc --arg e "$ST_ERR" '{ok: false, error: $e}'
    return 1
  fi
  missing="$(cf_check_ssh_perms "$ST_ACC")" || rc=$?
  if ((rc == 2)); then
    jq -nc '{ok: false, error: "Cloudflare non risponde"}'
    return 1
  fi
  if cf_zerotrust_enabled "$ST_ACC"; then zt=true; fi
  if _st_req GET "/accounts/$ST_ACC/access/identity_providers" \
    && jq -e 'any(.result[]?; .type == "onetimepin")' >/dev/null 2>&1 <<<"$ST_BODY"; then
    otp=true
  fi
  if [[ -f "$SYSTEMD_DIR/$ST_UNIT.service" ]]; then
    service=inactive
    if systemctl is-active --quiet "$ST_UNIT" 2>/dev/null; then service=active; fi
  fi
  if command -v cloudflared >/dev/null 2>&1; then
    cver="$(cloudflared --version 2>/dev/null | awk '{print $3; exit}' || true)"
  fi
  user="$(_st_manifest .admin_user)"
  if _st_require_state; then
    enabled=true
    host="$(jq -r '.host // empty' <<<"$ST_S")"
    emails="$(jq -c '.emails // []' <<<"$ST_S")"
    user="$(jq -r --arg u "$user" '.user // $u' <<<"$ST_S")"
    zid="$(jq -r '.zone_id // empty' <<<"$ST_S")"
    did="$(jq -r '.dns_id // empty' <<<"$ST_S")"
    aid="$(jq -r '.app_id // empty' <<<"$ST_S")"
    tid="$(jq -r '.tunnel_id // empty' <<<"$ST_S")"
    # Solo un 404 vuol dire "sparito": un errore di permesso non dice nulla.
    if ! _st_req GET "/zones/$zid/dns_records/$did" && _st_gone; then drift+=(dns); fi
    if ! _st_req GET "/accounts/$ST_ACC/access/apps/$aid" && _st_gone; then drift+=(app); fi
    if _st_req GET "/accounts/$ST_ACC/cfd_tunnel/$tid"; then
      if jq -e '.result.deleted_at // empty' >/dev/null 2>&1 <<<"$ST_BODY"; then
        drift+=(tunnel)
      else
        tstatus="$(jq -r '.result.status // empty' <<<"$ST_BODY")"
      fi
    elif _st_gone; then
      drift+=(tunnel)
    fi
    if [[ "$service" == missing ]]; then drift+=(service); fi
  fi
  ST_ERR=""
  jq -nc --arg zone "$ST_ZONE" --arg missing "$missing" --argjson zt "$zt" --argjson otp "$otp" \
    --argjson enabled "$enabled" --arg host "$host" --argjson emails "$emails" --arg user "$user" \
    --arg service "$service" --arg cver "$cver" --arg ts "$tstatus" \
    '($missing | split("\n")) as $m
    | {ok: true, cloudflare: true, zone: $zone,
       perms: {tunnel: ($m | index("tunnel") == null), access: ($m | index("access") == null),
               idp: ($m | index("idp") == null)},
       zerotrust: $zt, otp: $otp, enabled: $enabled,
       host: (if $host == "" then null else $host end), emails: $emails, user: $user,
       service: $service, cloudflared_version: (if $cver == "" then null else $cver end),
       tunnel_status: (if $ts == "" then null else $ts end), drift: $ARGS.positional}' \
    --args "${drift[@]}"
}
