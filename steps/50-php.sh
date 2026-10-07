# shellcheck shell=bash
# PHP 8.4 dal repository sury.

# shellcheck disable=SC2034
SURY_KEY_FPRS=(15058500A0235D97F5D10063B188E2B695BD4743)

step_enabled() {
  is_yes "$WANT_PHP"
}

step_main() {
  local keyring=/usr/share/keyrings/sury-php.gpg tmp p="php$PHP_VERSION"
  log "PHP: repository packages.sury.org"
  tmp="$(mktemp)"
  curl -fsS --max-time 30 -o "$tmp" https://packages.sury.org/php/apt.gpg
  gpg_keyring_install "$tmp" "$keyring" "${SURY_KEY_FPRS[@]}"
  rm -f "$tmp"
  apt_add_repo php "$keyring" "deb [signed-by=$keyring] https://packages.sury.org/php/ $(os_codename) main"

  log "PHP: installo PHP $PHP_VERSION"
  apt_install "$p-fpm" "$p-cli" "$p-common" "$p-mysql" "$p-xml" "$p-curl" "$p-gd" "$p-imagick" \
    "$p-intl" "$p-mbstring" "$p-opcache" "$p-redis" "$p-soap" "$p-zip"
  install -m 644 "$VPS_TEMPLATES/php-90-vps.ini" "/etc/php/$PHP_VERSION/fpm/conf.d/90-vps.ini"
  install -m 644 "$VPS_TEMPLATES/php-90-vps.ini" "/etc/php/$PHP_VERSION/cli/conf.d/90-vps.ini"
  "php-fpm$PHP_VERSION" -t >>"$VPS_LOG" 2>&1
  systemctl enable "$p-fpm" >>"$VPS_LOG" 2>&1
  systemctl restart "$p-fpm"
}
