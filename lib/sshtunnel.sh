# shellcheck shell=bash
# Libreria dell'accesso SSH dal browser: validazione, stato e configurazione di sshd.
# Richiede lib/common.sh e lib/validate.sh.
#
# ATTENZIONE per chi chiama st_enable / st_add_user / st_remove_user / st_set_sudo /
# st_set_host / st_disable:
# vanno SEMPRE usate in un condizionale (`if ! st_x ...; then json_err "$ST_ERR"; fi`).
# Fuori da un `if`, errexit o la trap ERR del chiamante interromperebbero la
# funzione a metà, saltando l'annullamento (_st_rollback) e lasciando risorse
# su Cloudflare o file di sshd senza stato che le descriva.

# run.sh carica lib/*.sh in ordine alfabetico: qui common.sh non è ancora stato letto.
: "${VPS_OPT:=/opt/vps}"
: "${SSHD_CONFIG_D:=/etc/ssh/sshd_config.d}"
: "${SSH_CF_CA:=/etc/ssh/vps-cf-ca.pub}"
: "${SSH_CF_PRINCIPALS:=/etc/ssh/vps-cf-principals}"
: "${SUDOERS_D:=/etc/sudoers.d}"
: "${LINGER_D:=/var/lib/systemd/linger}"
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

# st_valid_name NOME — nome utente Linux ammesso: stessa regola della Plancia
# (^[a-z_][a-z0-9_.-]{0,31}$, senza punto finale). Finisce in percorsi e in
# sshd_config, quindi niente scorciatoie.
st_valid_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_.-]{0,31}$ && "$1" != *. ]]
}

# st_parse_user EMAIL — email normalizzata (trim, minuscola, valida, ≤ 254).
st_parse_user() {
  local e
  e="$(trim "$1")"
  e="${e,,}"
  ((${#e} <= 254)) && valid_email "$e" || return 1
  printf '%s\n' "$e"
}

# st_user_name EMAIL — Cloudflare accede con utente = prefisso dell'email (e
# principal uguale): da qui il nome dell'utente Linux. 1 se non è un nome valido.
st_user_name() {
  local e
  e="$(st_parse_user "$1")" || return 1
  st_valid_name "${e%%@*}" || return 1
  printf '%s\n' "${e%%@*}"
}

# st_user_ours NOME — 0 se esiste ed è stato creato da noi (GECOS vps-ssh-tunnel),
# 1 se non esiste, 2 se esiste ma è di qualcun altro: quest'ultimo non si tocca mai.
# Il GECOS lo può cambiare l'utente stesso (chfn): rc 0 da solo NON prova che
# l'utente sia nostro, chi chiama deve controllare anche che sia nello stato.
st_user_ours() {
  local line
  line="$(getent passwd "$1" 2>/dev/null)" || return 1
  [[ -n "$line" ]] || return 1
  [[ "$(cut -d: -f5 <<<"$line")" == vps-ssh-tunnel ]] || return 2
}

# st_user_create NOME — utente senza password né chiavi: si entra solo col
# certificato breve di Cloudflare. Se un passo fallisce non resta nulla.
st_user_create() {
  st_valid_name "$1" || return 1
  # Un utente già presente non si tocca (nemmeno per ripulire un fallimento).
  local rc=0
  st_user_ours "$1" || rc=$?
  ((rc == 1)) || return 1
  if ! useradd -m -s /bin/bash -c vps-ssh-tunnel "$1"; then
    # useradd può uscire con errore dopo aver scritto l'account (es. home non
    # creabile): se ora esiste con il nostro GECOS l'abbiamo creato noi, va tolto.
    if st_user_ours "$1"; then userdel -r "$1" || log "ATTENZIONE: utente $1 creato a metà e non rimosso"; fi
    return 1
  fi
  # '*' impedisce il login con password ma non "blocca" l'account (con '!' sshd
  # rifiuterebbe anche il certificato).
  if ! usermod -p '*' "$1"; then
    userdel -r "$1" || log "ATTENZIONE: utente $1 creato a metà e non rimosso"
    return 1
  fi
}

# st_user_delete NOME — elimina l'utente e tutto ciò che ha lasciato. Rifiuta
# (rc 2) un utente che non abbiamo creato noi; se non esiste è già fatto.
# Il file principal si toglie PRIMA di fermare i processi: un certificato ancora
# valido non deve poter riaprire una sessione durante l'attesa. Se poi
# l'eliminazione si interrompe il principal NON viene rimesso qui (l'utente è
# comunque in uscita, e rimetterlo riaprirebbe la porta): chi decide di tenere
# l'utente (remove-user che annulla) riapplica sshd, che lo riscrive.
st_user_delete() {
  local name="$1" rc=0 urc=0 id
  st_valid_name "$name" || return 1
  st_user_ours "$name" || rc=$?
  case "$rc" in
    2) return 2 ;;
    1)
      rm -f "${SUDOERS_D:?}/vps-ssh-$name" "$SSH_CF_PRINCIPALS/$name"
      return 0
      ;;
  esac
  rm -f "${SSH_CF_PRINCIPALS:?}/$name"
  # Prima si fermano sessioni e processi, altrimenti userdel si rifiuta o
  # lascia cose in giro. I comandi possono "fallire" se non c'è nulla da fare.
  # Il linger lascerebbe un file in /var/lib/systemd/linger che un futuro
  # utente con lo stesso nome erediterebbe.
  loginctl disable-linger "$name" 2>/dev/null || true
  rm -f "${LINGER_D:?}/$name"
  loginctl terminate-user "$name" 2>/dev/null || true
  pkill -KILL -u "$name" || true
  # Il kill è asincrono: userdel con processi ancora vivi si rifiuta (come in site_user_remove).
  for _ in {1..50}; do
    pgrep -u "$name" >/dev/null 2>&1 || break
    pkill -KILL -u "$name" 2>/dev/null || true
    sleep 0.1
  done
  crontab -r -u "$name" 2>/dev/null || true
  # Lavori at: l'ultimo campo di atq è l'utente.
  while IFS= read -r id; do
    if [[ -n "$id" ]]; then atrm "$id" || true; fi
  done < <(atq 2>/dev/null | awk -v u="$name" '$NF == u { print $1 }')
  # Un file di sua proprietà in /tmp resterebbe orfano e un UID riusato lo erediterebbe.
  find /tmp /var/tmp /dev/shm -xdev -user "$name" -delete 2>/dev/null || true
  userdel -r "$name" || urc=$?
  # Solo l'uscita 8 di userdel è "utente in uso": -f serve a quello e non a
  # coprire altri errori (home non rimovibile, file di sistema bloccato...).
  if ((urc == 8)); then
    log "utente $name ancora in uso: userdel -f"
    urc=0
    userdel -f -r "$name" || urc=$?
  fi
  if ((urc != 0)); then
    # userdel può uscire con errore dopo aver tolto l'account (es. spool di posta):
    # se l'account non c'è più, un sudoers NOPASSWD rimasto passerebbe a un futuro
    # utente con lo stesso nome. Se c'è ancora, sudoers e stato restano coerenti.
    rc=0
    st_user_ours "$name" || rc=$?
    ((rc == 1)) || return 1
    log "ATTENZIONE: userdel di $name ha dato errore ma l'account non c'è più"
  fi
  rm -f "${SUDOERS_D:?}/vps-ssh-$name" "$SSH_CF_PRINCIPALS/$name"
}

# st_sudo_set NOME true|false — sudo senza password per NOME. Il file si scrive
# in temporaneo e si sposta solo se visudo lo approva: un sudoers rotto
# bloccherebbe sudo per tutti.
st_sudo_set() {
  local name="$1" f tmp rc
  st_valid_name "$name" || return 1
  f="${SUDOERS_D:?}/vps-ssh-$name"
  if [[ "$2" == true ]]; then
    # Mai sudo a un utente che non è nostro (root, utente dell'installazione, siti).
    rc=0
    st_user_ours "$name" || rc=$?
    if ((rc == 2)); then
      log "sudo: l'utente $name non è stato creato dall'accesso SSH: rifiutato."
      return 1
    fi
  fi
  case "$2" in
    false)
      rm -f "$f"
      return 0
      ;;
    true) ;;
    *) return 1 ;;
  esac
  mkdir -p "$SUDOERS_D" || return 1
  # Il nome inizia con un punto: sudo ignora i file con il punto, quindi il
  # temporaneo non è mai attivo prima della validazione.
  tmp="$(mktemp "$SUDOERS_D/.vps-ssh.XXXXXX")" || return 1
  if ! { printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$name" >"$tmp" &&
    chmod 440 "$tmp" && own root:root "$tmp" &&
    visudo -cf "$tmp" >/dev/null && mv -f "$tmp" "$f"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# st_sshd_files NOME... — i file toccati, uno per riga: drop-in, CA, i principal
# dei NOME e quelli già presenti nella cartella (da togliere se non più in elenco).
st_sshd_files() {
  local f n
  printf '%s\n' "$SSHD_CONFIG_D/$ST_DROPIN" "$SSH_CF_CA"
  {
    for n in "$@"; do printf '%s\n' "$SSH_CF_PRINCIPALS/$n"; done
    for f in "$SSH_CF_PRINCIPALS"/*; do [[ -e "$f" ]] && printf '%s\n' "$f"; done
  } | sort -u
  return 0
}

# st_sshd_snapshot DIR NOME... — copia i file che esistono; "N.none" per quelli
# assenti. L'elenco va in DIR/list: il ripristino usa quello, non ne calcola uno nuovo.
st_sshd_snapshot() {
  local dir="$1" f i=0
  shift
  st_sshd_files "$@" >"$dir/list" || return 1
  while IFS= read -r f; do
    # Senza una copia fedele il ripristino non sarebbe possibile: meglio fermarsi.
    if [[ -e "$f" ]]; then cp -p "$f" "$dir/$i" || return 1; else : >"$dir/$i.none" || return 1; fi
    i=$((i + 1))
  done <"$dir/list"
}

# st_sshd_restore DIR — rimette i file com'erano (o li toglie se non c'erano).
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
  done <"$dir/list"
}

# st_sshd_conf NOME... — il drop-in: intestazione fissa (template) più, in fondo,
# AllowUsers e il Match. Match per ultimo perché tutto ciò che lo segue sarebbe
# condizionale. L'utente dell'installazione non compare: il suo AllowUsers è nel
# file dell'installer (le righe AllowUsers si sommano) e le sue chiavi restano valide.
st_sshd_conf() {
  local names="$*" csv
  csv="$(IFS=,; printf '%s' "$*")"
  cat "$VPS_TEMPLATES/sshd-20-vps-cfaccess.conf"
  printf 'AllowUsers %s\n' "$names"
  printf 'Match User %s\n    AuthorizedKeysFile none\n' "$csv"
}

# _st_sshd_write CA NOME... — scrive CA, principal, drop-in e toglie i principal
# di chi non è più in elenco. Funzione a parte: ogni errore è un return 1 e il
# chiamante ripristina, senza uscite a metà.
_st_sshd_write() {
  local ca="$1" p f
  shift
  mkdir -p "$SSHD_CONFIG_D" "$SSH_CF_PRINCIPALS" "$(dirname "$SSH_CF_CA")" || return 1
  # sshd legge i file come root, ma la cartella deve essere attraversabile.
  chmod 755 "$SSH_CF_PRINCIPALS" || return 1
  printf '%s\n' "$ca" | write_file "$SSH_CF_CA" 644 root:root || return 1
  for p in "$@"; do
    printf '%s\n' "$p" | write_file "$SSH_CF_PRINCIPALS/$p" 644 root:root || return 1
  done
  # Principal di utenti non più in elenco: sshd darebbe loro ancora accesso.
  for f in "$SSH_CF_PRINCIPALS"/*; do
    [[ -e "$f" ]] || continue
    [[ " $* " == *" ${f##*/} "* ]] || rm -f "$f" || return 1
  done
  st_sshd_conf "$@" | write_file "$SSHD_CONFIG_D/$ST_DROPIN" 644 root:root
}

# st_sshd_apply CA_PUBKEY NOME... — sshd si fida della CA per questi utenti, ognuno
# con il proprio principal; i principal di altri nomi vengono tolti.
# Se "sshd -t" fallisce tutto torna com'era e sshd non viene ricaricato.
st_sshd_apply() {
  local ca="$1" snap p rc names=()
  shift
  for p in "$@"; do
    # I nomi finiscono in percorsi e nella configurazione di sshd.
    st_valid_name "$p" || return 1
    # Match User + AuthorizedKeysFile none toglierebbe le chiavi a un utente
    # estraneo (root, l'utente dell'installazione): mai, prima di ogni scrittura.
    rc=0
    st_user_ours "$p" || rc=$?
    if ((rc == 2)); then
      log "sshd: l'utente $p esiste già e non è stato creato dall'accesso SSH: rifiutato."
      return 1
    fi
    names+=("$p")
  done
  # Senza utenti sshd rifiuterebbe tutti.
  ((${#names[@]} >= 1)) || return 1
  snap="$(mktemp -d)" || return 1
  # Prima di scrivere qualunque cosa: se lo snapshot non è completo si esce
  # senza aver toccato sshd.
  if ! st_sshd_snapshot "$snap" "${names[@]}"; then
    rm -rf "$snap"
    log "snapshot della configurazione di sshd non riuscito: nulla è stato modificato."
    return 1
  fi
  if _st_sshd_write "$ca" "${names[@]}" && st_sshd_test; then
    if systemctl reload ssh; then
      rm -rf "$snap"
      return 0
    fi
    # sshd -t era a posto ma il reload no: i file nuovi non devono restare su
    # disco (al prossimo riavvio sshd partirebbe con una configurazione mai provata).
    st_sshd_restore "$snap"
    rm -rf "$snap"
    systemctl reload ssh || log "ripristino: anche il reload di sshd con la configurazione di prima è fallito"
    log "reload di sshd fallito: ripristinata la configurazione di prima."
    return 1
  fi
  st_sshd_restore "$snap"
  rm -rf "$snap"
  log "scrittura o \"sshd -t\" falliti: ripristinata la configurazione di prima."
  return 1
}

# st_sshd_remove NOME... — toglie drop-in, CA e i principal dei NOME; poi test e reload.
st_sshd_remove() {
  local n
  (($# >= 1)) || return 1
  for n in "$@"; do st_valid_name "$n" || return 1; done
  rm -f "$SSHD_CONFIG_D/$ST_DROPIN" "$SSH_CF_CA"
  for n in "$@"; do rm -f "$SSH_CF_PRINCIPALS/$n"; done
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
# Hook di apt: dopo ogni aggiornamento di cloudflared (anche automatico) il
# servizio riparte, altrimenti resterebbe in memoria il binario vecchio.
: "${APT_CONF_D:=/etc/apt/apt.conf.d}"
: "${CLOUDFLARED_BIN:=/usr/bin/cloudflared}"
ST_UNIT="vps-cloudflared"
ST_APT_HOOK="90vps-cloudflared"
CLOUDFLARED_KEY_FPRS=(CC94B39C77AE7342A68B89628A682D308D4E5E73)
ST_UNDO=()
# Nome utente dell'ultima operazione riuscita: lo legge tools/vps-ssh-tunnel.
export ST_USER=""

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

# _st_manifest_ctx — Cloudflare attivo, zona e porta SSH dal manifest, senza
# chiamate di rete: ST_ZONE, ST_PORT. Usato da set-host prima di toccare Cloudflare.
_st_manifest_ctx() {
  [[ "$(_st_manifest .cloudflare.enabled)" == true ]] || {
    ST_ERR="Cloudflare non è attivo su questa VPS"
    return 1
  }
  ST_ZONE="$(_st_manifest .cloudflare.zone)"
  [[ -n "$ST_ZONE" ]] || {
    ST_ERR="zona Cloudflare assente nel manifest"
    return 1
  }
  ST_PORT="$(_st_manifest .ssh_port)"
  [[ "$ST_PORT" =~ ^[0-9]+$ ]] || {
    ST_ERR="manifest incompleto (ssh_port)"
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
  local i a failed=0
  for ((i = ${#ST_UNDO[@]} - 1; i >= 0; i--)); do
    read -ra a <<<"${ST_UNDO[i]}"
    "${a[@]}" || {
      failed=1
      log "accesso SSH: annullamento non riuscito: ${ST_UNDO[i]}"
    }
  done
  ST_UNDO=()
  # L'utente deve sapere che su Cloudflare può essere rimasto qualcosa.
  if ((failed)); then ST_ERR+=" (annullamento incompleto: controlla Cloudflare, dettagli nel log)"; fi
  return 0
}

_st_rm_dns() {
  _st_del "/zones/$1/dns_records/$2"
}

# _st_rm_dns_orphans ZONE HOST TUNNEL — se la creazione del CNAME è fallita ma
# Cloudflare l'aveva registrata (risposta persa), il nome punterebbe a un tunnel
# che sta per sparire: si tolgono i record di HOST che portano a quel tunnel,
# e solo quelli.
_st_rm_dns_orphans() {
  local resp id
  resp="$(cf_list_records "$1" "$2")" || {
    log "accesso SSH: impossibile cercare record DNS residui di $2"
    return 0
  }
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    _st_rm_dns "$1" "$id" || log "ATTENZIONE: accesso SSH: record DNS $id di $2 non cancellato"
  done < <(jq -r --arg c "$3.cfargotunnel.com" '.result[]? | select(.content == $c) | .id' <<<"$resp")
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
    mkdir -p "$APT_CONF_D" &&
    write_file "$APT_CONF_D/$ST_APT_HOOK" 644 root:root <"$VPS_TEMPLATES/apt-90vps-cloudflared" &&
    systemctl daemon-reload >>"$VPS_LOG" 2>&1 &&
    systemctl enable --now "$ST_UNIT" >>"$VPS_LOG" 2>&1 &&
    # Un servizio che parte e subito cade (token rifiutato, rete) non è un successo.
    systemctl is-active --quiet "$ST_UNIT" >>"$VPS_LOG" 2>&1
}

# _st_service_remove — ferma e toglie unità e token; il pacchetto resta.
_st_service_remove() {
  systemctl disable --now "$ST_UNIT" >>"$VPS_LOG" 2>&1 || true
  rm -f "${SYSTEMD_DIR:?}/${ST_UNIT:?}.service" "${SSHTUNNEL_ENV:?}" "${APT_CONF_D:?}/${ST_APT_HOOK:?}"
  systemctl daemon-reload >>"$VPS_LOG" 2>&1 || true
}

# st_cloudflared_install — cloudflared dal repository apt di Cloudflare, con la
# chiave verificata sul fingerprint fissato. 1 con ST_ERR se non riesce.
st_cloudflared_install() {
  local tmp list="$APT_SOURCES_D/cloudflared.list"
  # Il file unit usa il percorso fisso: un cloudflared altrove nel PATH non basta.
  [[ -x "$CLOUDFLARED_BIN" ]] && return 0
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
    && apt_install cloudflared && [[ -x "$CLOUDFLARED_BIN" ]]; then
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

# _st_person EMAIL — ST_PEMAIL (email normalizzata) e ST_PNAME (nome utente Linux
# ricavato) o 1 con ST_ERR. Stessa regola della Plancia: mai accettare per fiducia.
_st_person() {
  ST_PEMAIL="$(st_parse_user "$1")" || {
    ST_ERR="email non valida"
    return 1
  }
  ST_PNAME="$(st_user_name "$ST_PEMAIL")" || {
    ST_ERR="il nome utente ricavato da $ST_PEMAIL non è valido (minuscole, cifre, _ . -, al massimo 32 caratteri, non inizia con una cifra)"
    return 1
  }
}

# _st_name_available NOME — 0 se sulla VPS non esiste nessun utente con quel nome.
# Anche un utente con il nostro GECOS ma fuori dallo stato non è "nostro" (il GECOS
# lo può cambiare chi ci entra con chfn): si rifiuta, mai riusarlo.
_st_name_available() {
  local rc=0
  st_user_ours "$1" || rc=$?
  if ((rc == 1)); then return 0; fi
  ST_ERR="l'utente $1 esiste già sulla VPS e non è stato creato dall'accesso SSH"
  return 1
}

# _st_sshd_reapply NOME... — rimette sshd con questi utenti usando la CA già
# installata. La CA contiene spazi e non passerebbe da _st_undo_push, quindi si
# rilegge dal file: serve sia al flusso normale sia all'annullamento.
_st_sshd_reapply() {
  local ca
  ca="$(head -n 1 "$SSH_CF_CA" 2>/dev/null || true)"
  [[ -n "$ca" ]] || return 1
  st_sshd_apply "$ca" "$@"
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

# st_enable LABEL EMAIL SUDO — attiva l'accesso SSH dal browser su LABEL.<zona>,
# con un utente Linux per quell'email (SUDO = true|false).
# L'ordine garantisce che il nome entri nel DNS solo quando l'app Access che lo
# protegge esiste già; al primo errore si annulla quanto fatto (tranne il
# One-time PIN, che appartiene all'organizzazione Zero Trust).
st_enable() {
  local label="$1" sudo="${3:-}" host name email port missing rc=0 otp tid pid aid ca did state
  ST_ERR="" ST_UNDO=() ST_USER=""
  st_valid_label "$label" || {
    ST_ERR="nome non valido"
    return 1
  }
  [[ "$sudo" == true || "$sudo" == false ]] || {
    ST_ERR="sudo deve essere true o false"
    return 1
  }
  _st_person "${2:-}" || return 1
  email="$ST_PEMAIL"
  name="$ST_PNAME"
  [[ ! -f "$SSHTUNNEL_STATE" ]] || {
    ST_ERR="l'accesso SSH è già attivo"
    return 1
  }
  _st_name_available "$name" || return 1
  _st_cf_context || return 1
  port="$(_st_manifest .ssh_port)"
  [[ "$port" =~ ^[0-9]+$ ]] || {
    ST_ERR="manifest incompleto (ssh_port)"
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
  rc=0
  cf_zerotrust_enabled "$ST_ACC" || rc=$?
  if ((rc == 2)); then
    ST_ERR="al token Cloudflare mancano dei permessi: idp"
    return 1
  elif ((rc != 0)); then
    ST_ERR="Zero Trust non è attivo sull'account Cloudflare"
    return 1
  fi
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

  # L'utente nasce prima di sshd e di tutto ciò che sta su Cloudflare: ogni passo
  # che segue, se fallisce, lo elimina con il resto (pila di annullamento).
  if ! st_user_create "$name"; then
    ST_ERR="creazione dell'utente $name non riuscita"
    log "accesso SSH: $ST_ERR"
    return 1
  fi
  _st_undo_push st_user_delete "$name"
  if ! st_sudo_set "$name" "$sudo"; then
    ST_ERR="configurazione di sudo per $name non riuscita"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi

  # Tunnel gestito da Cloudflare: il suo token resta solo in memoria e nel file env.
  _st_req POST "/accounts/$ST_ACC/cfd_tunnel" \
    "$(jq -nc --arg n "vps-$(hostname -s 2>/dev/null || hostname)-$label" '{name: $n, config_src: "cloudflare"}')" || {
    _st_fail "creazione del tunnel non riuscita"
    _st_rollback
    return 1
  }
  tid="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  ST_TUNNEL_TOKEN="$(jq -r '.result.token // empty' <<<"$ST_BODY")"
  ST_BODY=""
  [[ -n "$tid" ]] || {
    ST_ERR="Cloudflare non ha restituito l'id del tunnel"
    _st_rollback
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
  if ! _st_req POST "/accounts/$ST_ACC/access/policies" "$(_st_policy_body "$host" "$email")"; then
    _st_fail "creazione della policy Access non riuscita"
    _st_rollback
    return 1
  fi
  pid="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  if [[ -z "$pid" ]]; then
    ST_ERR="Cloudflare non ha restituito l'id della policy Access"
    _st_rollback
    return 1
  fi
  _st_undo_push _st_rm_policy "$ST_ACC" "$pid"
  if ! _st_req POST "/accounts/$ST_ACC/access/apps" "$(_st_app_body "$host" "$otp" "$pid")"; then
    _st_fail "creazione dell'app Access non riuscita"
    _st_rollback
    return 1
  fi
  aid="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  if [[ -z "$aid" ]]; then
    ST_ERR="Cloudflare non ha restituito l'id dell'app Access"
    _st_rollback
    return 1
  fi
  _st_undo_push _st_rm_app "$ST_ACC" "$aid"

  # CA dell'app e sshd che se ne fida per l'utente dell'installazione.
  if ! _st_req POST "/accounts/$ST_ACC/access/apps/$aid/ca"; then
    _st_fail "creazione della CA dei certificati SSH non riuscita"
    _st_rollback
    return 1
  fi
  ca="$(jq -r '.result.public_key // empty' <<<"$ST_BODY")"
  if [[ -z "$ca" ]] || ! st_sshd_apply "$ca" "$name"; then
    ST_ERR="configurazione di sshd non riuscita: sshd è rimasto com'era"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi
  _st_undo_push st_sshd_remove "$name"

  # Solo ora il nome entra nel DNS.
  if ! _st_req POST "/zones/$ST_ZONE_ID/dns_records" "$(_st_cname_body "$host" "$tid")"; then
    _st_fail "creazione del record DNS di $host non riuscita"
    _st_rm_dns_orphans "$ST_ZONE_ID" "$host" "$tid"
    _st_rollback
    return 1
  fi
  did="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  if [[ -z "$did" ]]; then
    ST_ERR="Cloudflare non ha restituito l'id del record DNS"
    _st_rm_dns_orphans "$ST_ZONE_ID" "$host" "$tid"
    _st_rollback
    return 1
  fi
  _st_undo_push _st_rm_dns "$ST_ZONE_ID" "$did"

  state="$(jq -n --arg host "$host" --arg label "$label" --arg acc "$ST_ACC" --arg zone "$ST_ZONE_ID" \
    --arg tid "$tid" --arg aid "$aid" --arg pid "$pid" --arg did "$did" --arg otp "$otp" \
    --arg email "$email" --arg name "$name" --argjson sudo "$sudo" --arg at "$(date -u +%FT%TZ)" \
    '{host: $host, label: $label, account_id: $acc, zone_id: $zone, tunnel_id: $tid, app_id: $aid,
      policy_id: $pid, dns_id: $did, otp_id: $otp, users: [{email: $email, user: $name, sudo: $sudo}],
      enabled_at: $at}')"
  if ! st_state_write "$state"; then
    ST_ERR="impossibile scrivere lo stato dell'accesso SSH"
    _st_rollback
    return 1
  fi
  ST_UNDO=()
  ST_USER="$name"
  log "accesso SSH attivato su $host (1 persona)"
}

# _st_require_state — lo stato in ST_S (1 con ST_ERR se l'accesso non è attivo).
_st_require_state() {
  if [[ -f "$SSHTUNNEL_STATE" ]] && ST_S="$(cat "$SSHTUNNEL_STATE")"; then
    return 0
  fi
  ST_ERR="l'accesso SSH non è attivo"
  return 1
}

# _st_users_state — richiede lo stato nuovo (con "users"): ST_S, ST_ACC_ID, ST_PID,
# ST_HOST. Uno stato 1.10.0 (solo "emails") non si gestisce: va disattivato e riattivato.
_st_users_state() {
  _st_require_state || return 1
  jq -e '(.users | type) == "array"' >/dev/null 2>&1 <<<"$ST_S" || {
    ST_ERR="l'accesso SSH è di una versione precedente (senza utenti): disattivalo e attivalo di nuovo"
    return 1
  }
  _st_token || return 1
  ST_ACC_ID="$(jq -r '.account_id // empty' <<<"$ST_S")"
  ST_PID="$(jq -r '.policy_id // empty' <<<"$ST_S")"
  ST_HOST="$(jq -r '.host // empty' <<<"$ST_S")"
  [[ -n "$ST_ACC_ID" && -n "$ST_PID" && -n "$ST_HOST" ]] || {
    ST_ERR="stato dell'accesso SSH incompleto"
    return 1
  }
}

# st_add_user EMAIL SUDO — nuova persona: utente Linux, (sudoers), principal e sshd e,
# PER ULTIMA, l'email nella policy Access. Così non esiste un'email autorizzata
# senza un utente pronto; se un passo fallisce si annulla tutto, utente compreso.
st_add_user() {
  local sudo="${2:-}" email name n
  local -a emails names
  ST_ERR="" ST_UNDO=() ST_USER=""
  [[ "$sudo" == true || "$sudo" == false ]] || {
    ST_ERR="sudo deve essere true o false"
    return 1
  }
  _st_person "${1:-}" || return 1
  email="$ST_PEMAIL"
  name="$ST_PNAME"
  _st_users_state || return 1
  mapfile -t emails < <(jq -r '.users[].email' <<<"$ST_S")
  mapfile -t names < <(jq -r '.users[].user' <<<"$ST_S")
  for n in "${names[@]}"; do
    if [[ "$n" == "$name" ]]; then
      ST_ERR="c'è già una persona con il nome utente $name"
      return 1
    fi
  done
  ((${#names[@]} < 5)) || {
    ST_ERR="massimo 5 persone"
    return 1
  }
  _st_name_available "$name" || return 1
  [[ -s "$SSH_CF_CA" ]] || {
    ST_ERR="CA di Cloudflare assente in sshd: disattivare e riattivare l'accesso"
    return 1
  }

  if ! st_user_create "$name"; then
    ST_ERR="creazione dell'utente $name non riuscita"
    log "accesso SSH: $ST_ERR"
    return 1
  fi
  _st_undo_push st_user_delete "$name"
  if ! st_sudo_set "$name" "$sudo"; then
    ST_ERR="configurazione di sudo per $name non riuscita"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi
  # st_sshd_apply si rimette a posto da solo se fallisce; l'annullamento serve
  # solo se un passo SUCCESSIVO fallisce.
  if ! _st_sshd_reapply "${names[@]}" "$name"; then
    ST_ERR="configurazione di sshd non riuscita: sshd è rimasto com'era"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi
  _st_undo_push _st_sshd_reapply "${names[@]}"
  # Per ultima: da qui Cloudflare lascia entrare l'email.
  if ! _st_put_policy "$ST_ACC_ID" "$ST_PID" "$ST_HOST" "${emails[@]}" "$email"; then
    _st_fail "aggiornamento della policy Access non riuscito"
    _st_rollback
    return 1
  fi
  _st_undo_push _st_put_policy "$ST_ACC_ID" "$ST_PID" "$ST_HOST" "${emails[@]}"
  if ! st_state_write "$(jq --arg e "$email" --arg u "$name" --argjson s "$sudo" \
    '.users += [{email: $e, user: $u, sudo: $s}]' <<<"$ST_S")"; then
    ST_ERR="impossibile aggiornare lo stato dell'accesso SSH"
    _st_rollback
    return 1
  fi
  ST_UNDO=()
  ST_USER="$name"
  log "accesso SSH: aggiunto l'utente $name (sudo: $sudo)"
}

# st_remove_user EMAIL — l'email esce PRIMA dalla policy Access (nessun nuovo
# accesso); se Cloudflare non risponde non si tocca nient'altro. Poi sshd e
# l'eliminazione dell'utente; se questa non riesce si rimettono policy e sshd.
st_remove_user() {
  local email name entry rc=0
  local -a keep_emails keep_names all_names all_emails
  ST_ERR="" ST_UNDO=() ST_USER=""
  _st_person "${1:-}" || return 1
  email="$ST_PEMAIL"
  _st_users_state || return 1
  entry="$(jq -c --arg e "$email" '.users[] | select(.email == $e)' <<<"$ST_S")"
  [[ -n "$entry" ]] || {
    ST_ERR="$email non è tra le persone autorizzate"
    return 1
  }
  name="$(jq -r .user <<<"$entry")"
  st_valid_name "$name" || {
    ST_ERR="stato dell'accesso SSH non valido"
    return 1
  }
  (($(jq '.users | length' <<<"$ST_S") > 1)) || {
    ST_ERR="l'ultima persona non si può eliminare: per togliere tutto usa Disattiva"
    return 1
  }
  # Un utente con quel nome che non è nostro (cambiato a mano dopo l'attivazione)
  # non si elimina mai.
  st_user_ours "$name" || rc=$?
  if ((rc == 2)); then
    ST_ERR="l'utente $name esiste sulla VPS ma non è stato creato dall'accesso SSH: non lo tocco"
    return 1
  fi
  mapfile -t all_emails < <(jq -r '.users[].email' <<<"$ST_S")
  mapfile -t all_names < <(jq -r '.users[].user' <<<"$ST_S")
  mapfile -t keep_emails < <(jq -r --arg e "$email" '.users[] | select(.email != $e) | .email' <<<"$ST_S")
  mapfile -t keep_names < <(jq -r --arg e "$email" '.users[] | select(.email != $e) | .user' <<<"$ST_S")

  if ! _st_put_policy "$ST_ACC_ID" "$ST_PID" "$ST_HOST" "${keep_emails[@]}"; then
    _st_fail "aggiornamento della policy Access non riuscito: nulla è stato modificato"
    return 1
  fi
  _st_undo_push _st_put_policy "$ST_ACC_ID" "$ST_PID" "$ST_HOST" "${all_emails[@]}"
  if ! _st_sshd_reapply "${keep_names[@]}"; then
    ST_ERR="configurazione di sshd non riuscita: policy e sshd rimasti com'erano"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi
  _st_undo_push _st_sshd_reapply "${all_names[@]}"
  rc=0
  st_user_delete "$name" || rc=$?
  if ((rc != 0)); then
    ST_ERR="eliminazione dell'utente $name non riuscita: ripristinato l'accesso di prima (dettagli nel log)"
    log "accesso SSH: $ST_ERR"
    _st_rollback
    return 1
  fi
  ST_UNDO=()
  # L'utente non c'è più: se lo stato non si scrive non c'è nulla da annullare,
  # solo da dire (status segnalerà la differenza).
  if ! st_state_write "$(jq --arg e "$email" '.users |= map(select(.email != $e))' <<<"$ST_S")"; then
    ST_ERR="l'utente $name è stato eliminato ma lo stato dell'accesso SSH non si è aggiornato"
    return 1
  fi
  ST_USER="$name"
  log "accesso SSH: eliminato l'utente $name"
}

# st_set_sudo EMAIL SUDO — scrive o toglie il sudoers di quella persona.
st_set_sudo() {
  local sudo="${2:-}" email name entry old rc=0
  ST_ERR="" ST_USER=""
  [[ "$sudo" == true || "$sudo" == false ]] || {
    ST_ERR="sudo deve essere true o false"
    return 1
  }
  _st_person "${1:-}" || return 1
  email="$ST_PEMAIL"
  _st_require_state || return 1
  jq -e '(.users | type) == "array"' >/dev/null 2>&1 <<<"$ST_S" || {
    ST_ERR="l'accesso SSH è di una versione precedente (senza utenti): disattivalo e attivalo di nuovo"
    return 1
  }
  entry="$(jq -c --arg e "$email" '.users[] | select(.email == $e)' <<<"$ST_S")"
  [[ -n "$entry" ]] || {
    ST_ERR="$email non è tra le persone autorizzate"
    return 1
  }
  name="$(jq -r .user <<<"$entry")"
  old="$(jq -r '.sudo' <<<"$entry")"
  st_valid_name "$name" || {
    ST_ERR="stato dell'accesso SSH non valido"
    return 1
  }
  # sudo solo a un utente che è nello stato E ha il nostro GECOS.
  st_user_ours "$name" || rc=$?
  if ((rc != 0)); then
    ST_ERR="l'utente $name non esiste più o non è stato creato dall'accesso SSH: sudo non modificato"
    return 1
  fi
  if ! st_sudo_set "$name" "$sudo"; then
    ST_ERR="configurazione di sudo per $name non riuscita"
    return 1
  fi
  if ! st_state_write "$(jq --arg e "$email" --argjson s "$sudo" \
    '.users |= map(if .email == $e then .sudo = $s else . end)' <<<"$ST_S")"; then
    # Stato e sudoers devono dire la stessa cosa: si rimette quello di prima.
    st_sudo_set "$name" "$old" || log "ATTENZIONE: sudo di $name non ripristinato"
    ST_ERR="impossibile aggiornare lo stato dell'accesso SSH"
    return 1
  fi
  ST_USER="$name"
  log "accesso SSH: sudo di $name = $sudo"
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
  _st_manifest_ctx || return 1
  _st_token || return 1
  port="$ST_PORT"
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
    # La risposta può essersi persa con il record già creato: toglierlo prima che il tunnel resti com'era.
    _st_rm_dns_orphans "$zid" "$new" "$tid"
    _st_rollback
    return 1
  fi
  did="$(jq -r '.result.id // empty' <<<"$ST_BODY")"
  if [[ -z "$did" ]]; then
    ST_ERR="Cloudflare non ha restituito l'id del record DNS"
    _st_rm_dns_orphans "$zid" "$new" "$tid"
    _st_rollback
    return 1
  fi
  ST_UNDO=()
  # Il vecchio record ormai porta al 404 del tunnel: se non si cancella, il suo
  # id resta nello stato (stale_dns_ids) e st_disable lo toglie.
  if _st_rm_dns "$zid" "$old_did"; then
    old_did=""
  else
    log "ATTENZIONE: accesso SSH: record DNS di $old non cancellato, sarà tolto alla disattivazione"
  fi
  st_state_write "$(jq --arg h "$new" --arg l "$label" --arg d "$did" --arg o "$old_did" \
    '.host = $h | .label = $l | .dns_id = $d
     | .stale_dns_ids = ((.stale_dns_ids // []) + (if $o == "" then [] else [$o] end))' <<<"$ST_S")" || {
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
  local acc zid tid aid pid did u rc
  local -a names users
  local pname
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
  if [[ -n "$did" ]] && ! _st_rm_dns "$zid" "$did"; then
    _st_fail "cancellazione del record DNS non riuscita"
    return 1
  fi
  # CNAME di nomi precedenti che set-host non era riuscito a cancellare.
  while IFS= read -r did; do
    [[ -n "$did" ]] || continue
    if ! _st_rm_dns "$zid" "$did"; then
      _st_fail "cancellazione di un record DNS precedente non riuscita"
      return 1
    fi
  done < <(jq -r '.stale_dns_ids[]?' <<<"$ST_S")
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
  # Drop-in, CA e principal se ne vanno comunque. Gli utenti Linux sono solo quelli
  # in "users" dello stato (e con il nostro GECOS, lo controlla st_user_delete):
  # le email e l'utente di uno stato 1.10.0 servono soltanto a togliere i vecchi
  # principal, mai a eliminare utenti.
  names=()
  users=()
  while IFS= read -r pname; do
    if [[ -n "$pname" ]] && st_valid_name "$pname"; then
      names+=("$pname")
      users+=("$pname")
    fi
  done < <(jq -r '.users[]?.user' <<<"$ST_S")
  while IFS= read -r pname; do
    if [[ -n "$pname" ]] && st_valid_name "$pname"; then names+=("$pname"); fi
  done < <(jq -r '(.user // empty), (.emails[]? | split("@")[0] | ascii_downcase)' <<<"$ST_S")
  if ((${#names[@]})) && ! st_sshd_remove "${names[@]}"; then
    ST_ERR="rimozione della configurazione di sshd non riuscita"
    return 1
  fi
  for u in "${users[@]}"; do
    rc=0
    st_user_delete "$u" || rc=$?
    case "$rc" in
      0) ;;
      2) log "accesso SSH: l'utente $u non è stato creato dall'accesso SSH: lasciato com'è" ;;
      *)
        ST_ERR="eliminazione dell'utente $u non riuscita: riprova la disattivazione"
        return 1
        ;;
    esac
  done
  rm -f "${SSHTUNNEL_STATE:?}"
  log "accesso SSH disattivato"
}

# st_status_json — stato completo per la Plancia, senza segreti. Con Cloudflare
# spento solo {ok:true, cloudflare:false}; se Cloudflare non risponde
# {ok:false, error} e 1. drift elenca i pezzi registrati ma spariti.
st_status_json() {
  local missing rc=0 zt=false otp=false enabled=false service=missing cver="" tstatus=""
  local host="" ulist="[]" zid did aid tid pid app_gone=0 zrc u urc
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
  # rc 2 = al token manca il permesso di leggere l'organizzazione (lo stesso
  # degli Identity Providers): Zero Trust non è verificabile, quindi
  # zerotrust:false e idp tra i mancanti (senza duplicarlo).
  zrc=0
  cf_zerotrust_enabled "$ST_ACC" || zrc=$?
  if ((zrc == 0)); then
    zt=true
  elif ((zrc == 2)) && ! grep -qx idp <<<"$missing"; then
    missing="${missing:+$missing$'\n'}idp"
  fi
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
  if _st_require_state; then
    enabled=true
    host="$(jq -r '.host // empty' <<<"$ST_S")"
    ulist="$(jq -c '.users // []' <<<"$ST_S")"
    zid="$(jq -r '.zone_id // empty' <<<"$ST_S")"
    did="$(jq -r '.dns_id // empty' <<<"$ST_S")"
    aid="$(jq -r '.app_id // empty' <<<"$ST_S")"
    tid="$(jq -r '.tunnel_id // empty' <<<"$ST_S")"
    pid="$(jq -r '.policy_id // empty' <<<"$ST_S")"
    # Solo un 404 vuol dire "sparito": un errore di permesso non dice nulla.
    if ! _st_req GET "/zones/$zid/dns_records/$did" && _st_gone; then drift+=(dns); fi
    # App o policy sparite: per la Plancia è lo stesso guasto ("app").
    if ! _st_req GET "/accounts/$ST_ACC/access/apps/$aid" && _st_gone; then app_gone=1; fi
    if ! _st_req GET "/accounts/$ST_ACC/access/policies/$pid" && _st_gone; then app_gone=1; fi
    if ((app_gone)); then drift+=(app); fi
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
    # Stato 1.10.0 (senza "users") o utente dello stato sparito/non più nostro.
    if ! jq -e '(.users | type) == "array"' >/dev/null 2>&1 <<<"$ST_S"; then
      drift+=(users)
    else
      while IFS= read -r u; do
        urc=0
        st_user_ours "$u" || urc=$?
        if ((urc != 0)); then
          drift+=(users)
          break
        fi
      done < <(jq -r '.users[].user' <<<"$ST_S")
    fi
  fi
  ST_ERR=""
  jq -nc --arg zone "$ST_ZONE" --arg missing "$missing" --argjson zt "$zt" --argjson otp "$otp" \
    --argjson enabled "$enabled" --arg host "$host" --argjson users "$ulist" \
    --arg service "$service" --arg cver "$cver" --arg ts "$tstatus" \
    '($missing | split("\n")) as $m
    | {ok: true, cloudflare: true, zone: $zone,
       perms: {tunnel: ($m | index("tunnel") == null), access: ($m | index("access") == null),
               idp: ($m | index("idp") == null)},
       zerotrust: $zt, otp: $otp, enabled: $enabled,
       host: (if $host == "" then null else $host end), users: $users,
       service: $service, cloudflared_version: (if $cver == "" then null else $cver end),
       tunnel_status: (if $ts == "" then null else $ts end), drift: $ARGS.positional}' \
    --args "${drift[@]}"
}
