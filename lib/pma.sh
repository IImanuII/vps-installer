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

pma_controlpass_from_config() {
  sed -nE "s/.*\['controlpass'\] = '([A-Za-z0-9]+)'.*/\1/p" "$PMA_DIR/config.inc.php" 2>/dev/null | head -n 1
}

# pma_verify_sig FILE ASC KEYRING — 0 se firmato da uno dei PMA_SIGNER_FPRS.
pma_verify_sig() {
  local gh status f
  gh="$(mktemp -d)"
  gpg --homedir "$gh" --batch --quiet --import "$3" 2>>"$VPS_LOG" || true
  status="$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$2" "$1" 2>>"$VPS_LOG" || true)"
  rm -rf "$gh"
  for f in "${PMA_SIGNER_FPRS[@]}"; do
    if grep -qE "^\[GNUPG:\] VALIDSIG .*\b$f\b" <<<"$status"; then
      return 0
    fi
  done
  return 1
}

# pma_fetch VERSIONE WORKDIR — scarica, verifica, estrae; stampa la cartella estratta.
pma_fetch() {
  local v="$1" w="$2" base f
  base="$PMA_BASE_URL/phpMyAdmin/$v"
  f="phpMyAdmin-$v-all-languages.tar.xz"
  log "phpMyAdmin: scarico la versione $v"
  curl -fsS --max-time 300 -o "$w/$f" "$base/$f"
  curl -fsS --max-time 30 -o "$w/$f.asc" "$base/$f.asc"
  curl -fsS --max-time 30 -o "$w/$f.sha256" "$base/$f.sha256"
  curl -fsS --max-time 30 -o "$w/keyring" "$PMA_BASE_URL/phpmyadmin.keyring"
  (cd "$w" && sha256sum -c --status "$f.sha256") || die "phpMyAdmin $v: SHA256 non valido"
  pma_verify_sig "$w/$f" "$w/$f.asc" "$w/keyring" || die "phpMyAdmin $v: firma GPG non valida"
  tar -xJf "$w/$f" -C "$w"
  printf '%s\n' "$w/phpMyAdmin-$v-all-languages"
}

# pma_install_tree SRC — sostituisce PMA_DIR conservando config.inc.php.
pma_install_tree() {
  local src="$1" old="$PMA_DIR.old"
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
  src="$(pma_fetch "$v" "$work")"
  pma_install_tree "$src"
  rm -rf "$work"
}

# pma_set_basic_auth UTENTE — password da stdin, hash bcrypt.
pma_set_basic_auth() {
  htpasswd -B -i -c "$HTPASSWD_PMA" "$1" >>"$VPS_LOG" 2>&1
  own root:www-data "$HTPASSWD_PMA"
  chmod 640 "$HTPASSWD_PMA"
}
