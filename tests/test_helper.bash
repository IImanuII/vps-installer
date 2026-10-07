# shellcheck shell=bash
# Helper comuni per i test bats.

setup_common() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  export VPS_ROOT="$BATS_TEST_TMPDIR/root"
  export VPS_LOG="$BATS_TEST_TMPDIR/test.log"
  export VPS_OPT="$BATS_TEST_TMPDIR/opt"
  export VPS_STATE="$VPS_ROOT/state"
  export VPS_ANSWERS="$VPS_ROOT/answers.env"
  export VPS_TEMPLATES="$REPO_ROOT/templates"
  export VPS_NO_CHOWN=1
  mkdir -p "$VPS_ROOT" "$VPS_OPT"
  local f
  shopt -s nullglob
  for f in "$REPO_ROOT"/lib/*.sh; do
    source "$f"
  done
  shopt -u nullglob
}

# make_stub NOME CORPO: crea un comando finto che sostituisce quello vero.
make_stub() {
  local dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$dir/$1"
  chmod +x "$dir/$1"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
  export PATH
}
