#!/usr/bin/env bash
# Esegue shellcheck e bats. Da Windows: wsl -d Debian -- bash tests/run.sh
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in bats shellcheck jq envsubst ssh-keygen gpg; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Manca '$tool'. Installa: sudo apt-get install -y bats shellcheck jq gettext-base openssh-client gpg curl openssl rsync" >&2
    exit 2
  }
done

# Su /mnt/* (disco Windows) i permessi dei file non funzionano: copia in /tmp.
work="$src"
if [[ "$src" == /mnt/* ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  rsync -a --exclude .git "$src"/ "$work"/
fi
cd "$work"

mapfile -t files < <(find . -path ./.git -prune -o -type f \( -name '*.sh' -o -path './tools/vps-*' \) -print | sort)
if ((${#files[@]})); then
  shellcheck -x "${files[@]}"
fi

if (($#)); then
  bats "$@"
else
  bats tests
fi
