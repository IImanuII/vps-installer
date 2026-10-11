setup() {
  load test_helper
  setup_common
  VPS_ROOT="$REPO_ROOT"
}

@test "opt_tools_only rifiuta una macchina mai installata" {
  run opt_tools_only
  [ "$status" -eq 1 ]
  [[ "$output" == *"mai installata"* ]]
}

@test "opt_tools_only ricopia gli script e conserva il manifest" {
  jq -n '{installer_version:"1.0.3", admin_user:"manu", panel:{domain:"p.test", path:"/var/www/p.test", version:"2.1.0"}}' >"$VPS_OPT/manifest.json"
  opt_tools_only
  [ -x "$VPS_OPT/bin/vps-status" ]
  [ -f "$VPS_OPT/lib/panel_deploy.sh" ]
  [ -f "$VPS_OPT/templates/github-known-hosts" ]
  [ "$(jq -r .installer_version "$VPS_OPT/manifest.json")" = "$VPS_INSTALLER_VERSION" ]
  [ "$(jq -r .admin_user "$VPS_OPT/manifest.json")" = manu ]
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 2.1.0 ]
}

@test "install.sh e run.sh conoscono --tools-only" {
  grep -q -- '--tools-only' "$REPO_ROOT/install.sh"
  grep -q -- '--tools-only' "$REPO_ROOT/run.sh"
}
