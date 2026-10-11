#!/usr/bin/env bash
# End-to-end di vps-panel-install / vps-panel-update con la Plancia vera, in WSL.
# Uso: sudo bash tests/e2e/panel-e2e.sh /mnt/c/.../vps-panel
# Serve: root, MariaDB in esecuzione, php (8.4, pdo_mysql), git. Il repository
# di Plancia deve avere il tag v2.1.0. Lascia la macchina come l'ha trovata.
set -Eeuo pipefail
((EUID == 0)) || { echo "Esegui con sudo" >&2; exit 1; }
SRC="$(readlink -f "${1:?percorso del repository vps-panel}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$(mktemp -d /tmp/plancia-e2e.XXXXXX)"
DB=plancia_e2e
DBPASS="$(openssl rand -hex 16)"
PORT=8199
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  mariadb -e "DROP DATABASE IF EXISTS \`$DB\`; DROP USER IF EXISTS '$DB'@'localhost';" || true
  rm -rf "$W"
}
trap cleanup EXIT

fail() { echo "E2E FALLITO: $*" >&2; exit 1; }
check() { local m="$1"; shift; "$@" || fail "$m"; }

service mariadb status >/dev/null 2>&1 || service mariadb start >/dev/null
# Il repository sorgente è dell'utente Windows, non di root: senza questo git
# rifiuta di leggerlo ("dubious ownership"). Vale anche per i processi figli.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
git -C "$SRC" rev-parse -q --verify refs/tags/v2.1.0 >/dev/null || fail "manca il tag v2.1.0 in $SRC"

# Repository "remoto": solo v2.1.0, come GitHub al primo deploy.
git clone -q --bare --no-local "$SRC" "$W/repo.git"
git -C "$W/repo.git" for-each-ref --format='%(refname)' refs/tags | { grep -vx refs/tags/v2.1.0 || true; } \
  | xargs -r -n1 git -C "$W/repo.git" update-ref -d
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid

# Radice del pannello come la lascia l'installer.
P="$W/panel"
mkdir -p "$P/config" "$P/public" "$P/logs" "$P/storage/sessions" "$P/storage/tmp" "$W/opt" "$W/bin"
echo segnaposto >"$P/public/index.html"
printf 'DB_HOST=localhost\nDB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\nDBADMIN_USER=x\nDBADMIN_PASS=y\n' "$DB" "$DB" "$DBPASS" >"$P/config/.env"
mariadb -e "CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER '$DB'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL ON \`$DB\`.* TO '$DB'@'localhost';"
jq -n --arg p "$P" '{installer_version:"1.1.0", panel:{domain:"panel.e2e", path:$p}}' >"$W/opt/manifest.json"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/systemctl"
chmod +x "$W/bin/systemctl"

# opcache spento: in produzione lo azzera il reload di PHP-FPM (qui stubbato).
E2E_PUBLIC="$P/public" php -d opcache.enable=0 -d opcache.enable_cli=0 -S 127.0.0.1:$PORT "$HERE/tests/e2e/router.php" >"$W/server.log" 2>&1 &
SERVER_PID=$!
sleep 1

run_tool() {
  env -u SUDO_USER PATH="$W/bin:$PATH" VPS_OPT="$W/opt" VPS_LIB="$HERE/lib" VPS_TEMPLATES="$HERE/templates" \
    VPS_LOG="$W/tools.log" PANEL_REPO="$W/repo.git" PD_AS_PANEL=0 VPS_NO_CHOWN=1 PD_SKIP_TELEGRAM_CHECK=1 \
    PD_HEALTH_URL="http://127.0.0.1:$PORT/health" PD_CURL_RESOLVE="" PD_HEALTH_SLEEP=1 \
    PD_BACKUPS="$W/backups" PD_CRON="$W/cron-vps-panel" PD_LOCK="$W/update.lock" PD_PHP=php \
    bash "$HERE/tools/$1" "${@:2}"
}
tag_of() { git --git-dir="$W/opt/panel.git" describe --tags --exact-match; }
q() { mariadb -N -B -e "$1" "$DB"; }

echo "== install"
printf '%s\n' '123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' e2e_admin 424242 'E2e-Password-123!' 'E2e-Password-123!' \
  | run_tool vps-panel-install || fail "install"
check "tag dopo install" [ "$(tag_of)" = v2.1.0 ]
check "super_admin" [ "$(q "SELECT role FROM vp_users WHERE username='e2e_admin'")" = super_admin ]
check "APP_KEY unica" [ "$(grep -c '^APP_KEY=' "$P/config/.env")" -eq 1 ]
check "manifest" [ "$(jq -r .panel.version "$W/opt/manifest.json")" = 2.1.0 ]
check "segnaposto tolto" [ ! -e "$P/public/index.html" ]
check "nessun .git nella radice del pannello" [ ! -e "$P/.git" ]
check "health" [ "$(curl -sf "http://127.0.0.1:$PORT/health")" = OK ]
if run_tool vps-panel-install </dev/null; then fail "il secondo install doveva rifiutare"; fi

echo "== rilasci rotti e uno buono"
git clone -q "$W/repo.git" "$W/work"
git -C "$W/work" checkout -q -b rel v2.1.0
mk_tag() {  # mk_tag TAG FILE CONTENUTO
  mkdir -p "$(dirname "$W/work/$2")"
  printf '%s\n' "$3" >"$W/work/$2"
  git -C "$W/work" add -A && git -C "$W/work" commit -qm "$1" && git -C "$W/work" tag "$1"
}
mk_tag v2.1.1 public/rotto.php '<?php function (' 
git -C "$W/work" rm -q public/rotto.php && git -C "$W/work" commit -qm pulizia
mk_tag v2.1.2 public/index.php '<?php http_response_code(500);'
git -C "$W/work" checkout -q v2.1.0 -- public/index.php && git -C "$W/work" commit -qm ripristino
mk_tag v2.1.3 install/migrations/2.1.3.sql 'CREATE TABLE IF NOT EXISTS vp_e2e_probe (id INT); SELECT * FROM tabella_che_non_esiste;'
git -C "$W/work" rm -q install/migrations/2.1.3.sql && git -C "$W/work" commit -qm pulizia
mk_tag v2.2.0 install/migrations/2.2.0.sql 'CREATE TABLE IF NOT EXISTS vp_e2e_ok (id INT);'
git -C "$W/work" push -q origin --tags

for t in v2.1.1 v2.1.2 v2.1.3; do
  echo "== update --ref $t (deve tornare a v2.1.0)"
  rc=0
  run_tool vps-panel-update --ref "$t" || rc=$?
  check "$t: uscita 1 (era $rc)" [ "$rc" -eq 1 ]
  check "$t: codice tornato" [ "$(tag_of)" = v2.1.0 ]
  check "$t: health" [ "$(curl -sf "http://127.0.0.1:$PORT/health")" = OK ]
  check "$t: manifest" [ "$(jq -r .panel.version "$W/opt/manifest.json")" = 2.1.0 ]
done
check "migrazione fallita annullata" [ -z "$(q "SHOW TABLES LIKE 'vp_e2e_probe'")" ]
check "utente sopravvissuto ai ripristini" [ "$(q "SELECT COUNT(*) FROM vp_users WHERE username='e2e_admin'")" = 1 ]

echo "== update all'ultimo"
run_tool vps-panel-update || fail "update a v2.2.0"
check "tag v2.2.0" [ "$(tag_of)" = v2.2.0 ]
check "migrazione 2.2.0" [ -n "$(q "SHOW TABLES LIKE 'vp_e2e_ok'")" ]
check "manifest 2.2.0" [ "$(jq -r .panel.version "$W/opt/manifest.json")" = 2.2.0 ]
out="$(run_tool vps-panel-update)" || fail "secondo update"
check "già aggiornata" grep -q "Già aggiornata" <<<"$out"
check "backup tenuti al massimo 5" [ "$(find "$W/backups" -name '*.sql.gz' | wc -l)" -le 5 ]

echo "E2E OK"
