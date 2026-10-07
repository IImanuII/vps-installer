# shellcheck shell=bash
# Repository APT esterni con chiavi verificate tramite fingerprint fissati.

gpg_primary_fprs() {
  local gh
  gh="$(mktemp -d)"
  gpg --homedir "$gh" --batch --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }' || true
  rm -rf "$gh"
}

# gpg_keyring_install SRC DEST FPR... — installa il keyring solo se tutte le
# chiavi primarie contenute in SRC sono tra i fingerprint attesi.
gpg_keyring_install() {
  local src="$1" dest="$2" fprs f gh
  shift 2
  fprs="$(gpg_primary_fprs "$src")"
  [[ -n "$fprs" ]] || die "Nessuna chiave GPG valida in $src"
  while read -r f; do
    in_list "$f" "$@" || die "Chiave GPG non attesa per $(basename "$dest"): $f"
  done <<<"$fprs"
  if grep -q -- '-----BEGIN PGP' "$src"; then
    gh="$(mktemp -d)"
    gpg --homedir "$gh" --batch --yes --dearmor -o "$dest.tmp" "$src"
    rm -rf "$gh"
  else
    cp "$src" "$dest.tmp"
  fi
  # Verifica i byte effettivamente installati, non solo la sorgente.
  fprs="$(gpg_primary_fprs "$dest.tmp")"
  if [[ -z "$fprs" ]]; then
    rm -f "$dest.tmp"
    die "Keyring prodotto senza chiavi valide per $(basename "$dest")"
  fi
  while read -r f; do
    if ! in_list "$f" "$@"; then
      rm -f "$dest.tmp"
      die "Chiave GPG non attesa nel keyring prodotto per $(basename "$dest"): $f"
    fi
  done <<<"$fprs"
  chmod 644 "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
}

# apt_add_repo NOME KEYRING "deb [signed-by=KEYRING] URL SUITE COMPONENTI"
apt_add_repo() {
  printf '%s\n' "$3" | write_file "/etc/apt/sources.list.d/$1.list" 644 root:root
  apt-get update -q -o DPkg::Lock::Timeout=300 >>"$VPS_LOG" 2>&1
}
