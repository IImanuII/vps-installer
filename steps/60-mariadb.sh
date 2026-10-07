# shellcheck shell=bash
# MariaDB dal repository Debian, messa in sicurezza.

step_enabled() {
  is_yes "$WANT_MARIADB"
}

step_main() {
  log "MariaDB: installazione"
  apt_install mariadb-server mariadb-client
  install -m 644 "$VPS_TEMPLATES/mariadb-90-vps.cnf" /etc/mysql/mariadb.conf.d/90-vps.cnf
  systemctl enable mariadb >>"$VPS_LOG" 2>&1
  systemctl restart mariadb
  log "MariaDB: messa in sicurezza (root solo via unix_socket)"
  sql_secure_installation "$(hostname)" | mariadb
}
