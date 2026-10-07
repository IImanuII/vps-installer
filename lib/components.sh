# shellcheck shell=bash
# Componenti scelti nella procedura guidata e loro dipendenze.

components_from_selection() {
  local item
  WANT_NGINX=no WANT_PHP=no WANT_MARIADB=no WANT_REDIS=no WANT_CERTBOT=no WANT_PMA=no
  while read -r item; do
    case "$item" in
      nginx) WANT_NGINX=yes ;;
      php) WANT_PHP=yes ;;
      mariadb) WANT_MARIADB=yes ;;
      redis) WANT_REDIS=yes ;;
      certbot) WANT_CERTBOT=yes ;;
      pma) WANT_PMA=yes ;;
    esac
  done <<<"$1"
}

components_allow_panel() {
  is_yes "${WANT_NGINX:-}" && is_yes "${WANT_PHP:-}" && is_yes "${WANT_MARIADB:-}" && is_yes "${WANT_CERTBOT:-}"
}

resolve_components() {
  COMPONENT_NOTES=""
  if is_yes "${PANEL_ENABLED:-}" && ! components_allow_panel; then
    PANEL_ENABLED=no
    COMPONENT_NOTES+="Pannello disattivato: richiede Nginx, PHP, MariaDB e Certbot."$'\n'
  fi
  if is_yes "${WANT_PMA:-}" && ! is_yes "${PANEL_ENABLED:-}"; then
    WANT_PMA=no
    COMPONENT_NOTES+="phpMyAdmin disattivato: viene servito solo sul dominio del pannello."$'\n'
  fi
  COMPONENT_NOTES="${COMPONENT_NOTES%$'\n'}"
}

components_summary() {
  local out=()
  is_yes "${WANT_NGINX:-}" && out+=(Nginx)
  is_yes "${WANT_PHP:-}" && out+=("PHP $PHP_VERSION")
  is_yes "${WANT_MARIADB:-}" && out+=(MariaDB)
  is_yes "${WANT_REDIS:-}" && out+=(Redis)
  is_yes "${WANT_CERTBOT:-}" && out+=(Certbot)
  is_yes "${WANT_PMA:-}" && out+=(phpMyAdmin)
  if ((${#out[@]} == 0)); then
    echo "nessuno"
  else
    local IFS=', '
    echo "${out[*]}"
  fi
}
