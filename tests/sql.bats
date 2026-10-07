setup() {
  load test_helper
  setup_common
}

@test "sql_quote raddoppia apici e backslash" {
  run sql_quote "a'b\\c"
  [ "$output" = "'a''b\\\\c'" ]
}

@test "sql_db_with_user è idempotente e quota la password" {
  run sql_db_with_user panel panel "x'y"
  [[ "$output" == *'CREATE DATABASE IF NOT EXISTS `panel`'* ]]
  [[ "$output" == *"CREATE USER IF NOT EXISTS 'panel'@'localhost' IDENTIFIED BY 'x''y';"* ]]
  [[ "$output" == *"ALTER USER 'panel'@'localhost' IDENTIFIED BY 'x''y';"* ]]
  [[ "$output" == *"GRANT ALL PRIVILEGES ON \`panel\`.* TO 'panel'@'localhost';"* ]]
}

@test "sql_db_with_user rifiuta nomi pericolosi" {
  run sql_db_with_user 'panel`; DROP' panel x
  [ "$status" -eq 1 ]
}

@test "sql_user_grant con wildcard dei siti" {
  run sql_user_grant panel_dbadmin pw 'ALL PRIVILEGES' '`site\_%`.*'
  [[ "$output" == *"GRANT ALL PRIVILEGES ON \`site\\_%\`.* TO 'panel_dbadmin'@'localhost';"* ]]
}

@test "sql_secure_installation" {
  run sql_secure_installation vps-01
  [[ "$output" == *"DROP USER IF EXISTS ''@'vps-01';"* ]]
  [[ "$output" == *'DROP DATABASE IF EXISTS `test`;'* ]]
  [[ "$output" == *"FLUSH PRIVILEGES;"* ]]
}
