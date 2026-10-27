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
