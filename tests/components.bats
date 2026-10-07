setup() {
  load test_helper
  setup_common
}

@test "components_from_selection imposta le variabili" {
  components_from_selection $'nginx\nphp\ncertbot'
  [ "$WANT_NGINX" = yes ]; [ "$WANT_PHP" = yes ]; [ "$WANT_CERTBOT" = yes ]
  [ "$WANT_MARIADB" = no ]; [ "$WANT_REDIS" = no ]; [ "$WANT_PMA" = no ]
}

@test "il pannello richiede nginx, php, mariadb e certbot" {
  components_from_selection $'nginx\nphp\nmariadb\ncertbot'
  components_allow_panel
  components_from_selection $'nginx\nphp\nmariadb'
  run components_allow_panel
  [ "$status" -ne 0 ]
}

@test "resolve_components disattiva pannello e phpMyAdmin se mancano dipendenze" {
  components_from_selection $'nginx\nphp\npma'
  PANEL_ENABLED=yes
  resolve_components
  [ "$PANEL_ENABLED" = no ]
  [ "$WANT_PMA" = no ]
  [[ "$COMPONENT_NOTES" == *"Pannello disattivato"* ]]
  [[ "$COMPONENT_NOTES" == *"phpMyAdmin disattivato"* ]]
}

@test "resolve_components non tocca una selezione coerente" {
  components_from_selection $'nginx\nphp\nmariadb\ncertbot\npma'
  PANEL_ENABLED=yes
  resolve_components
  [ "$PANEL_ENABLED" = yes ]
  [ "$WANT_PMA" = yes ]
  [ -z "$COMPONENT_NOTES" ]
}
