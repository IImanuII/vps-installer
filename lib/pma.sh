# shellcheck shell=bash
# phpMyAdmin: ultima versione upstream, verificata con SHA256 e firma GPG.

: "${PMA_DIR:=$VPS_OPT/phpmyadmin}"
: "${HTPASSWD_PMA:=/etc/nginx/.htpasswd-pma}"
: "${PMA_BASE_URL:=https://files.phpmyadmin.net}"
# Fingerprint dei firmatari delle release (https://docs.phpmyadmin.net, "Verifying phpMyAdmin releases").
# shellcheck disable=SC2034
PMA_SIGNER_FPRS=(3D06A59ECE730EB71B511C17CE752F178259BD92)

pma_latest_version() {
  local v
  v="$(curl -fsS --max-time 30 https://www.phpmyadmin.net/home_page/version.json | jq -r '.version' 2>/dev/null)" || return 1
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

pma_installed_version() {
  local f
  for f in "$PMA_DIR/libraries/classes/Version.php" "$PMA_DIR/src/Version.php"; do
    if [[ -f "$f" ]]; then
      sed -nE "s/.*VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'.*/\1/p" "$f" | head -n 1
      return 0
    fi
  done
}

# Vuoto (exit 0) se config.inc.php non esiste ancora (prima installazione).
pma_controlpass_from_config() {
  [[ -f "$PMA_DIR/config.inc.php" ]] || return 0
  sed -nE "s/.*\['controlpass'\] = '([A-Za-z0-9]+)'.*/\1/p" "$PMA_DIR/config.inc.php" | head -n 1
}

# pma_verify_sig FILE ASC KEYRING — 0 se firmato da uno dei PMA_SIGNER_FPRS.
pma_verify_sig() {
  local gh status f
  gh="$(mktemp -d)"
  gpg --homedir "$gh" --batch --quiet --import "$3" 2>>"$VPS_LOG" || true
  status="$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$2" "$1" 2>>"$VPS_LOG" || true)"
  rm -rf "$gh"
  grep -qE '^\[GNUPG:\] (REVKEYSIG|EXPKEYSIG|BADSIG) ' <<<"$status" && return 1
  grep -qE '^\[GNUPG:\] GOODSIG ' <<<"$status" || return 1
  # Ultimo campo di VALIDSIG = fingerprint della chiave primaria.
  local primary
  primary="$(awk '$1=="[GNUPG:]" && $2=="VALIDSIG" {print $NF; exit}' <<<"$status")"
  [[ -n "$primary" ]] || return 1
  for f in "${PMA_SIGNER_FPRS[@]}"; do
    [[ -n "$f" && "$f" == "$primary" ]] && return 0
  done
  return 1
}

# pma_fetch VERSIONE WORKDIR — scarica, verifica, estrae; stampa la cartella estratta.
pma_fetch() {
  local v="$1" w="$2" base f
  base="$PMA_BASE_URL/phpMyAdmin/$v"
  f="phpMyAdmin-$v-all-languages.tar.xz"
  log "phpMyAdmin: scarico la versione $v"
  curl -fsS --max-time 300 -o "$w/$f" "$base/$f" || die "phpMyAdmin $v: download dell'archivio non riuscito"
  curl -fsS --max-time 30 -o "$w/$f.asc" "$base/$f.asc" || die "phpMyAdmin $v: download della firma non riuscito"
  curl -fsS --max-time 30 -o "$w/$f.sha256" "$base/$f.sha256" || die "phpMyAdmin $v: download dello SHA256 non riuscito"
  curl -fsS --max-time 30 -o "$w/keyring" "$PMA_BASE_URL/phpmyadmin.keyring" || die "phpMyAdmin $v: download del keyring non riuscito"
  (cd "$w" && sha256sum -c --status "$f.sha256") || die "phpMyAdmin $v: SHA256 non valido"
  pma_verify_sig "$w/$f" "$w/$f.asc" "$w/keyring" || die "phpMyAdmin $v: firma GPG non valida"
  tar -xJf "$w/$f" -C "$w" || die "phpMyAdmin $v: estrazione non riuscita"
  printf '%s\n' "$w/phpMyAdmin-$v-all-languages"
}

# pma_install_tree SRC — sostituisce PMA_DIR conservando config.inc.php.
pma_install_tree() {
  local src="$1" old="$PMA_DIR.old"
  # Recupero da un'interruzione precedente: non perdere l'unica copia.
  if [[ ! -d "$PMA_DIR" && -d "$old" ]]; then
    mv "$old" "$PMA_DIR"
  fi
  if [[ -f "$PMA_DIR/config.inc.php" ]]; then
    cp -p "$PMA_DIR/config.inc.php" "$src/config.inc.php"
  fi
  rm -rf "$src/setup" "$src/examples" "$old"
  own -R "root:$(manifest_group)" "$src"
  find "$src" -type d -exec chmod 750 {} +
  find "$src" -type f -exec chmod 640 {} +
  if [[ -d "$PMA_DIR" ]]; then
    mv "$PMA_DIR" "$old"
  fi
  mv "$src" "$PMA_DIR"
  rm -rf "$old"
}

pma_update_to() {
  local v="$1" work src
  work="$(mktemp -d "$VPS_OPT/.pma.XXXXXX")"
  if ! src="$(pma_fetch "$v" "$work")"; then
    rm -rf "$work"
    die "phpMyAdmin $v: aggiornamento non riuscito (dettagli in $VPS_LOG)"
  fi
  pma_install_tree "$src"
  rm -rf "$work"
}

# pma_set_basic_auth UTENTE — password da stdin, hash bcrypt.
pma_set_basic_auth() {
  (umask 027 && htpasswd -B -i -c "$HTPASSWD_PMA" "$1" >>"$VPS_LOG" 2>&1)
  own root:www-data "$HTPASSWD_PMA"
  chmod 640 "$HTPASSWD_PMA"
}

# _pma_dbadmin_alter PASSWORD — ALTER USER come root dal socket. L'SQL passa da
# stdin (la password non finisce mai negli argomenti di processo). Dell'output di
# mariadb, che negli errori può citare l'SQL, nel log va solo il codice ERROR NNNN.
_pma_dbadmin_alter() {
  local out rc=0 code
  out="$(printf "ALTER USER 'panel_dbadmin'@'localhost' IDENTIFIED BY %s;\n" "$(sql_quote "$1")" | mariadb 2>&1)" || rc=$?
  ((rc == 0)) && return 0
  code="$(printf '%s\n' "$out" | grep -oEm1 'ERROR [0-9]+( \([0-9A-Za-z]+\))?' || true)"
  log "mariadb (ALTER USER panel_dbadmin) non riuscito: ${code:-errore senza codice}"
  return 1
}

# _pma_as_panel CMD... — come utente panel con ambiente pulito (PD_AS_PANEL=0 solo
# nei test). Il .env sta in una cartella del pannello: root non vi scrive mai per
# percorso, perché panel potrebbe sostituire cartelle e file con link tra un
# controllo e l'uso.
_pma_as_panel() {
  local path="${PMA_AS_PANEL_PATH:-/usr/bin:/bin}"
  if [[ "${PD_AS_PANEL:-1}" == 0 ]]; then
    env -i "PATH=$path" LC_ALL=C "$@"
  else
    runuser -u panel -- env -i "PATH=$path" LC_ALL=C "$@"
  fi
}

# _pma_env_check DIR FILE — cartella e file veri (non link), di panel:panel. Solo un
# controllo di buon senso: la scrittura vera avviene comunque come panel.
_pma_env_check() {
  local want="${PD_PANEL_OWNER:-panel:panel}"
  [[ -d "$1" && ! -L "$1" && "$(stat -c '%U:%G' "$1")" == "$want" ]] || return 1
  [[ -f "$2" && ! -L "$2" && "$(stat -c '%U:%G' "$2")" == "$want" ]] || return 1
}

# pma_dbadmin_set PASSWORD — cambia la password di panel_dbadmin in MariaDB e
# DBADMIN_PASS nel .env del pannello (radice dal manifest). Valore scritto grezzo,
# come lo scrive l'installer; la riga viene aggiunta se manca. Il pannello non legge
# DBADMIN_* (Config::CHIAVI): nessun reload di PHP-FPM necessario.
pma_dbadmin_set() {
  local new="$1" m root dir env old
  m="$(manifest_path)"
  [[ -f "$m" ]] || die "Manifest $m mancante: la VPS non è stata preparata da vps-installer"
  root="$(jq -r '.panel.path // empty' "$m")"
  [[ -n "$root" ]] || die "Il manifest non ha un pannello (panel.path)"
  dir="$root/config"
  env="$dir/.env"
  _pma_env_check "$dir" "$env" \
    || die "$env mancante o non sicuro (deve essere un file vero di panel:panel in una cartella vera): password non cambiata"
  # stesso lock di vps-panel-update/install, che riscrivono questo .env
  exec 9>"${PD_LOCK:-/run/vps-panel-update.lock}" || die "Lock del pannello non apribile"
  flock -w "${VPS_PMA_LOCK_WAIT:-30}" 9 || die "Un aggiornamento del pannello è in corso: riprova tra poco"
  old="$(_pma_as_panel awk 'index($0, "DBADMIN_PASS=") == 1 { print substr($0, 14); exit }' "$env")" \
    || die "$env non leggibile: password non cambiata"
  _pma_dbadmin_alter "$new" || die "password di panel_dbadmin non cambiata (dettagli in $VPS_LOG)"
  # Tutto il resto (lettura, file temporaneo, mv) è di panel. La nuova password
  # arriva su stdin; il temporaneo, che contiene tutti i segreti, si toglie sempre.
  if ! printf '%s\n' "$new" | _pma_as_panel sh -c '
      umask 077
      IFS= read -r nuova || exit 1
      d=$1; f=$2
      t="$(mktemp "$d/.tmp.XXXXXX")" || exit 1
      trap "rm -f \"$t\"" EXIT
      NUOVA=$nuova awk '\''
        index($0, "DBADMIN_PASS=") == 1 { if (!fatto) print "DBADMIN_PASS=" ENVIRON["NUOVA"]; fatto = 1; next }
        { print }
        END { if (!fatto) print "DBADMIN_PASS=" ENVIRON["NUOVA"] }
      '\'' "$f" >"$t" || exit 1
      chmod --reference="$f" "$t" || exit 1
      mv -f "$t" "$f" || exit 1' sh "$dir" "$env" 2>>"$VPS_LOG"; then
    # .env invariato: MariaDB torna alla password che il .env ancora contiene
    if [[ -n "$old" ]] && _pma_dbadmin_alter "$old"; then
      die "$env non scrivibile: password di panel_dbadmin rimasta quella di prima"
    fi
    die "ATTENZIONE: password di panel_dbadmin cambiata in MariaDB ma $env non aggiornato"
  fi
}
