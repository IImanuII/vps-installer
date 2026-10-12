setup() {
  load test_helper
  setup_common
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
