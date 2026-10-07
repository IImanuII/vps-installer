# shellcheck shell=bash
# Generazione di SQL idempotente per MariaDB.

sql_quote() {
  # shellcheck disable=SC1003
  local s="$1" q="'" b='\'
  s="${s//"$b"/"$b$b"}"
  s="${s//"$q"/"$q$q"}"
  printf "'%s'" "$s"
}

sql_ident_ok() {
  [[ "$1" =~ ^[a-z][a-z0-9_]{0,63}$ ]]
}

# sql_db_with_user DB UTENTE PASSWORD
sql_db_with_user() {
  if ! sql_ident_ok "$1" || ! sql_ident_ok "$2"; then
    die "Nome di database o utente non valido: $1 / $2"
  fi
  printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$1"
  sql_user_grant "$2" "$3" "ALL PRIVILEGES" "\`$1\`.*"
}

# sql_user_grant UTENTE PASSWORD PRIVILEGI OGGETTO
sql_user_grant() {
  sql_ident_ok "$1" || die "Nome utente DB non valido: $1"
  printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED BY %s;\n" "$1" "$(sql_quote "$2")"
  printf "ALTER USER '%s'@'localhost' IDENTIFIED BY %s;\n" "$1" "$(sql_quote "$2")"
  printf "GRANT %s ON %s TO '%s'@'localhost';\n" "$3" "$4" "$1"
}

# sql_secure_installation HOSTNAME — equivalente di mysql_secure_installation.
sql_secure_installation() {
  printf "DROP USER IF EXISTS ''@'localhost';\n"
  printf "DROP USER IF EXISTS ''@%s;\n" "$(sql_quote "$1")"
  printf "DROP USER IF EXISTS 'root'@'%%';\n"
  printf 'DROP DATABASE IF EXISTS `test`;\n'
  printf "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\\\_%%';\n"
  printf 'FLUSH PRIVILEGES;\n'
}
