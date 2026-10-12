# shellcheck shell=bash
# WP-CLI: ultima release ufficiale, verificata con lo SHA-512 pubblicato.

: "${WP_BIN:=/usr/local/bin/wp}"
: "${WPCLI_API:=https://api.github.com/repos/wp-cli/wp-cli/releases/latest}"

# wpcli_install — installa o aggiorna WP-CLI. Il file vecchio resta intatto se
# download o verifica falliscono; la sostituzione è atomica (install su .new + mv).
wpcli_install() {
  local rel phar_url sha_url tmp want got
  rel="$(curl -fsSL --max-time 30 "$WPCLI_API")" || { log "WP-CLI: release non leggibile"; return 1; }
  phar_url="$(jq -r '.assets[] | select(.name | test("^wp-cli-[0-9.]+\\.phar$")) | .browser_download_url' <<<"$rel")"
  sha_url="$(jq -r '.assets[] | select(.name | test("^wp-cli-[0-9.]+\\.phar\\.sha512$")) | .browser_download_url' <<<"$rel")"
  [[ -n "$phar_url" && -n "$sha_url" ]] || { log "WP-CLI: file della release non trovati"; return 1; }
  tmp="$(mktemp)"
  if ! curl -fsSL --max-time 120 -o "$tmp" "$phar_url"; then
    rm -f "$tmp"; log "WP-CLI: download non riuscito"; return 1
  fi
  want="$(curl -fsSL --max-time 30 "$sha_url" | awk '{print $1}')"
  got="$(sha512sum "$tmp" | awk '{print $1}')"
  if [[ -z "$want" || "$want" != "$got" ]]; then
    rm -f "$tmp"; log "WP-CLI: SHA-512 non corrisponde, non installato"; return 1
  fi
  if ! install -m 755 "$tmp" "$WP_BIN.new" || ! mv -f "$WP_BIN.new" "$WP_BIN"; then
    rm -f "$tmp" "$WP_BIN.new"; log "WP-CLI: installazione non riuscita"; return 1
  fi
  rm -f "$tmp"
  log "WP-CLI installato: $(jq -r .tag_name <<<"$rel")"
}
