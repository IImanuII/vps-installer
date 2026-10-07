# shellcheck shell=bash
# Rendering dei template con envsubst, limitato alle variabili elencate.

# Variabili non presenti in ANSWER_VARS ma ammesse nei template.
# shellcheck disable=SC2034  # usata dai test e dai moduli
KNOWN_TEMPLATE_VARS=(
  PANEL_ROOT SSH_ALLOW_USERS PHP_VERSION VPS_OPT
  PMA_BLOWFISH PMA_CONTROL_PASS
  SMTP_TLS_STARTTLS SMTP_PASS_ESC
  SSH_IGNORE_IP
)

# render_template SRC DEST MODE OWNER:GROUP VAR...
render_template() {
  local src="$1" dest="$2" mode="$3" owner="$4" v shell_format=""
  shift 4
  [[ -f "$src" ]] || die "Template non trovato: $src"
  for v in "$@"; do
    [[ -v "$v" ]] || die "Variabile non definita per il template $(basename "$src"): $v"
    export "${v?}"
    shell_format+="\${$v} "
  done
  envsubst "$shell_format" <"$src" | write_file "$dest" "$mode" "$owner"
}

template_vars_in() {
  { grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "$1" || true; } | tr -d '${}' | sort -u
}
