setup() {
  load test_helper
  # Cartelle di vps-monitor nel tmp del test (calcolate al caricamento delle librerie).
  export MON_DIR="$BATS_TEST_TMPDIR/mon" MON_STATE_DIR="$BATS_TEST_TMPDIR/mon-state"
  export SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
  setup_common
  mkdir -p "$SYSTEMD_DIR"
  make_stub systemctl 'echo "$*" >>"$BATS_TEST_TMPDIR/systemctl.calls"'
  VPS_ROOT="$REPO_ROOT"
  # Mai toccare /etc, /opt/vps/sites ecc. veri: tutto nel tmp del test.
  export SUDOERS_D="$BATS_TEST_TMPDIR/sudoers.d" CRON_D="$BATS_TEST_TMPDIR/cron.d"
  export SITES_DIR="$BATS_TEST_TMPDIR/sites" SITES_BACKUPS="$BATS_TEST_TMPDIR/backups/sites" SITES_WWW="$BATS_TEST_TMPDIR/www"
  mkdir -p "$SUDOERS_D" "$CRON_D" "$SITES_WWW"
  make_stub visudo 'exit 0'
  make_stub dpkg 'exit 0'
  # Niente rete né Redis veri: le due funzioni di sistema annotano soltanto la chiamata.
  wpcli_install() { echo wpcli >>"$BATS_TEST_TMPDIR/sys.calls"; }
  redis_acl_setup() { echo acl >>"$BATS_TEST_TMPDIR/sys.calls"; }
}

@test "opt_tools_only rifiuta una macchina mai installata" {
  run opt_tools_only
  [ "$status" -eq 1 ]
  [[ "$output" == *"mai installata"* ]]
}

@test "opt_tools_only ricopia gli script e conserva il manifest" {
  jq -n '{installer_version:"1.0.3", admin_user:"manu", panel:{domain:"p.test", path:"/var/www/p.test", version:"2.1.0"}}' >"$VPS_OPT/manifest.json"
  opt_tools_only
  [ -x "$VPS_OPT/bin/vps-panel-install" ]
  [ -x "$VPS_OPT/bin/vps-panel-update" ]
  [ -f "$VPS_OPT/lib/panel_deploy.sh" ]
  [ -f "$VPS_OPT/templates/github-known-hosts" ]
  [ "$(jq -r .installer_version "$VPS_OPT/manifest.json")" = "$VPS_INSTALLER_VERSION" ]
  [ "$(jq -r .admin_user "$VPS_OPT/manifest.json")" = manu ]
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 2.1.0 ]
}

@test "opt_install_files mette vps-panel-install e vps-panel-update nel PATH di sudo" {
  opt_install_files
  local t
  for t in vps-panel-install vps-panel-update; do
    [ -L "$VPS_SBIN/$t" ]
    [ "$(readlink "$VPS_SBIN/$t")" = "$VPS_OPT/bin/$t" ]
    [ -x "$VPS_SBIN/$t" ]
  done
  # idempotente: un secondo giro non fallisce e non annida link
  opt_install_files
  [ "$(readlink "$VPS_SBIN/vps-panel-install")" = "$VPS_OPT/bin/vps-panel-install" ]
}

@test "install.sh e run.sh conoscono --tools-only" {
  grep -q -- '--tools-only' "$REPO_ROOT/install.sh"
  grep -q -- '--tools-only' "$REPO_ROOT/run.sh"
}

sys_setup() {
  jq -n '{panel:{domain:"panel.miosito.it"}, cloudflare:{enabled:true}}' >"$VPS_OPT/manifest.json"
}

@test "opt_system_files: sudoers con vps-site, cron con _prune, cartelle e manutenzione" {
  sys_setup
  opt_system_files
  grep -q '/opt/vps/bin/vps-site' "$SUDOERS_D/vps-panel"
  [ "$(stat -c %a "$SUDOERS_D/vps-panel")" = 440 ]
  grep -q 'vps-site _prune' "$CRON_D/vps"
  [ "$(stat -c %a "$SITES_DIR")" = 750 ]
  [ "$(stat -c %a "$SITES_BACKUPS")" = 700 ]
  grep -q 'manutenzione' "$SITES_WWW/_maintenance/_maintenance.html"
}

@test "opt_system_files senza pannello né Cloudflare toglie sudoers e cron" {
  sys_setup
  echo x >"$SUDOERS_D/vps-panel"
  echo x >"$CRON_D/vps"
  jq -n '{panel:null, cloudflare:{enabled:false}}' >"$VPS_OPT/manifest.json"
  opt_system_files
  [ ! -e "$SUDOERS_D/vps-panel" ]
  [ ! -e "$CRON_D/vps" ]
}

@test "opt_system_files: sudoers non valido non viene installato" {
  sys_setup
  make_stub visudo 'exit 1'
  run opt_system_files
  [ "$status" -ne 0 ]
  [ ! -e "$SUDOERS_D/vps-panel" ]
}

@test "opt_system_files installa acl se manca" {
  sys_setup
  make_stub dpkg 'exit 1'
  make_stub apt-get 'echo "apt-get $*" >>"$BATS_TEST_TMPDIR/apt.calls"'
  opt_system_files
  grep -q 'install .* acl' "$BATS_TEST_TMPDIR/apt.calls"
}

@test "opt_tools_only aggiorna anche sudoers e cron" {
  sys_setup
  declare -f opt_tools_only | grep -q opt_system_files
}

@test "sudoers del pannello: ogni script in tools/ chiamabile dal pannello è elencato" {
  grep -q '/opt/vps/bin/vps-site' "$REPO_ROOT/templates/sudoers-vps-panel"
}

@test "opt_system_files chiama wpcli_install e, con Redis, redis_acl_setup" {
  jq -n '{panel:null, cloudflare:{enabled:false}, components:{redis:true}}' >"$VPS_OPT/manifest.json"
  opt_system_files
  grep -qx wpcli "$BATS_TEST_TMPDIR/sys.calls"
  grep -qx acl "$BATS_TEST_TMPDIR/sys.calls"
}

@test "opt_system_files senza Redis non chiama redis_acl_setup" {
  jq -n '{panel:null, cloudflare:{enabled:false}, components:{redis:false}}' >"$VPS_OPT/manifest.json"
  opt_system_files
  grep -qx wpcli "$BATS_TEST_TMPDIR/sys.calls"
  ! grep -qx acl "$BATS_TEST_TMPDIR/sys.calls"
}

@test "opt_system_files: WP-CLI non installato non ferma il resto" {
  jq -n '{panel:null, cloudflare:{enabled:false}, components:{redis:true}}' >"$VPS_OPT/manifest.json"
  wpcli_install() { return 1; }
  run opt_system_files
  [ "$status" -eq 0 ]
  [[ "$output" == *"WP-CLI non installato"* ]]
}

@test "opt_system_files: redis_acl_setup che fallisce non ferma --tools-only" {
  jq -n '{panel:null, cloudflare:{enabled:false}, components:{redis:true}}' >"$VPS_OPT/manifest.json"
  redis_acl_setup() { return 1; }
  run opt_system_files
  [ "$status" -eq 0 ]
  [[ "$output" == *"Redis con utenti ACL non configurato"* ]]
}

@test "opt_system_files: unità di vps-monitor, cartelle 700, daemon-reload, timer non abilitato" {
  sys_setup
  opt_system_files
  [ "$(stat -c %a "$SYSTEMD_DIR/vps-monitor.service")" = 644 ]
  [ "$(stat -c %a "$SYSTEMD_DIR/vps-monitor.timer")" = 644 ]
  grep -qxF 'ExecStart=/opt/vps/bin/vps-monitor _run' "$SYSTEMD_DIR/vps-monitor.service"
  grep -qxF 'TimeoutStartSec=55' "$SYSTEMD_DIR/vps-monitor.service"
  grep -qxF 'OnCalendar=*:*:00' "$SYSTEMD_DIR/vps-monitor.timer"
  [ "$(stat -c %a "$MON_DIR")" = 700 ]
  [ "$(stat -c %a "$MON_STATE_DIR")" = 700 ]
  grep -qxF 'daemon-reload' "$BATS_TEST_TMPDIR/systemctl.calls"
  ! grep -q 'enable' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "opt_system_files: configurazione già attiva (aggiornamento) = timer abilitato" {
  sys_setup
  mkdir -p "$MON_DIR"
  echo '{"enabled":true}' >"$MON_DIR/config.json"
  opt_system_files
  grep -qxF 'enable --now vps-monitor.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "opt_panel_pool aggiunge /opt/vps/bin a open_basedir, una volta, e ricarica php-fpm" {
  jq -n '{components:{php:"8.4"}, panel:{path:"/var/www/p.test"}}' >"$VPS_OPT/manifest.json"
  export PANEL_POOL_FILE="$BATS_TEST_TMPDIR/panel.conf"
  printf '[panel]\nphp_admin_value[open_basedir] = /var/www/p.test/:%s/phpmyadmin/:%s/manifest.json\n' "$VPS_OPT" "$VPS_OPT" >"$PANEL_POOL_FILE"
  make_stub php-fpm8.4 'echo test >>"$BATS_TEST_TMPDIR/fpm.calls"'
  opt_panel_pool
  grep -qxF "php_admin_value[open_basedir] = /var/www/p.test/:$VPS_OPT/phpmyadmin/:$VPS_OPT/manifest.json:$VPS_OPT/bin/" "$PANEL_POOL_FILE"
  grep -qxF 'reload php8.4-fpm' "$BATS_TEST_TMPDIR/systemctl.calls"
  opt_panel_pool
  [ "$(grep -c '/bin/' "$PANEL_POOL_FILE")" -eq 1 ]
  [ "$(grep -c 'reload' "$BATS_TEST_TMPDIR/systemctl.calls")" -eq 1 ]
}

@test "opt_panel_pool: php-fpm -t fallito lascia il pool com'era; senza pannello non fa nulla" {
  jq -n '{components:{php:"8.4"}, panel:{path:"/var/www/p.test"}}' >"$VPS_OPT/manifest.json"
  export PANEL_POOL_FILE="$BATS_TEST_TMPDIR/panel.conf"
  printf '[panel]\nphp_admin_value[open_basedir] = /var/www/p.test/\n' >"$PANEL_POOL_FILE"
  cp "$PANEL_POOL_FILE" "$BATS_TEST_TMPDIR/prima"
  make_stub php-fpm8.4 'exit 1'
  opt_panel_pool
  cmp -s "$PANEL_POOL_FILE" "$BATS_TEST_TMPDIR/prima"
  jq -n '{components:{php:"8.4"}}' >"$VPS_OPT/manifest.json"
  make_stub php-fpm8.4 'exit 0'
  opt_panel_pool
  cmp -s "$PANEL_POOL_FILE" "$BATS_TEST_TMPDIR/prima"
}

@test "aggiornamenti automatici: anche nginx.org, aggiornati da --tools-only solo se la configurazione c'è già" {
  grep -qF '"origin=nginx,codename=${distro_codename}";' "$REPO_ROOT/templates/apt-52vps-unattended"
  jq -n '{installer_version:"1.5.2", admin_user:"manu"}' >"$VPS_OPT/manifest.json"
  export APT_CONF_D="$BATS_TEST_TMPDIR/apt.conf.d"
  mkdir -p "$APT_CONF_D"
  opt_system_files
  [ ! -e "$APT_CONF_D/52vps-unattended" ]
  echo vecchio >"$APT_CONF_D/52vps-unattended"
  opt_system_files
  grep -qF 'origin=nginx' "$APT_CONF_D/52vps-unattended"
}
