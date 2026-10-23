#!/usr/bin/env bash
# End-to-end di vps-backup in WSL (root): un sito vero creato con vps-site (utente, ACL,
# PHP-FPM, Nginx e MariaDB veri), il giro con rclone vero su un remote locale
# (`type = local`) al posto di Drive, la conservazione (4 giri, 3 copie), il ripristino di
# database, file e tutto con la copia di sicurezza, l'archivio del sito eliminato e il sito
# ricreato dall'archivio locale e dalla copia su "Drive". Cloudflare, certbot, systemd e
# Telegram finti (come site-e2e.sh). Può installare con apt-get nginx, php8.4-fpm,
# mariadb-server, acl e rclone se mancano; rclone lo toglie alla fine se l'ha messo lui.
# Uso (da Windows, via PowerShell):
#   wsl -d Debian -u root -- bash /mnt/c/.../vps-installer/tests/e2e/backup-e2e.sh
set -Eeuo pipefail
src="$(cd "$(dirname "$0")/../.." && pwd)"
((EUID == 0)) || { echo "Serve root: sudo bash $0" >&2; exit 2; }

work="$(mktemp -d /tmp/backup-e2e.XXXXXX)"
chmod 755 "$work"
D1=e2etest.it
ADMIN=e2eadmin
PASS='Password-e2e-1234567'
PASS2='Password-nuova-7654321'
PANELDB=e2epanel
created=()
made_maint=
made_admin=
made_rclone=

fail() {
  echo "E2E FALLITO: $*" >&2
  [[ ! -f "${VPS_LOG:-}" ]] || { echo "--- ultime righe di $VPS_LOG" >&2; tail -n 40 "$VPS_LOG" >&2; }
  exit 1
}

cleanup() {
  set +e
  cd /
  rm -f "/etc/nginx/conf.d/$D1.conf" "/etc/php/8.4/fpm/pool.d/site_${D1//./_}.conf"
  /usr/bin/systemctl reload php8.4-fpm >/dev/null 2>&1
  pkill -u "site_${D1//./_}" 2>/dev/null
  sleep 1
  userdel "site_${D1//./_}" 2>/dev/null
  groupdel "site_${D1//./_}" 2>/dev/null
  mariadb -e "DROP DATABASE IF EXISTS \`site_${D1//./_}\`; DROP DATABASE IF EXISTS \`site_${D1//./_}__ripristino\`; DROP DATABASE IF EXISTS \`$PANELDB\`;
    DROP USER IF EXISTS 'site_${D1//./_}'@'localhost'; DROP USER IF EXISTS 'site_${D1//./_}_r'@'localhost';" 2>/dev/null
  rm -rf "/etc/letsencrypt/live/$D1"
  [[ -z "$made_admin" ]] || userdel -r "$ADMIN" 2>/dev/null
  for f in "${created[@]}"; do rm -f "$f"; done
  [[ -z "$made_maint" ]] || rmdir /var/www/_maintenance 2>/dev/null
  nginx -t >/dev/null 2>&1 && /usr/bin/systemctl reload nginx 2>/dev/null
  /usr/bin/systemctl reload php8.4-fpm >/dev/null 2>&1
  [[ -z "$made_rclone" ]] || DEBIAN_FRONTEND=noninteractive apt-get purge -y -q rclone >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

for p in nginx php8.4-fpm mariadb-server acl openssl jq gettext-base rclone; do
  if ! dpkg -s "$p" >/dev/null 2>&1; then
    [[ "$p" != rclone ]] || made_rclone=1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p" >/dev/null
  fi
done

# Pezzi di Nginx che sulla VPS mette l'installer.
mkdir -p /etc/nginx/snippets
for s in ssl-params security-headers acme; do
  f="/etc/nginx/snippets/$s.conf"
  if [[ ! -e "$f" ]]; then
    case "$s" in
      ssl-params) echo 'ssl_protocols TLSv1.2 TLSv1.3;' >"$f" ;;
      security-headers) echo 'add_header X-Content-Type-Options nosniff always;' >"$f" ;;
      acme) echo 'location ^~ /.well-known/acme-challenge/ { root /var/www/_acme; }' >"$f" ;;
    esac
    created+=("$f")
  fi
done
if ! grep -rqs 'req_limit_per_ip' /etc/nginx/; then
  f=/etc/nginx/conf.d/00-backup-e2e.conf
  printf '%s\n' 'log_format main '"'"'$remote_addr [$time_local] "$request" $status'"'"';' \
    'limit_req_zone $binary_remote_addr zone=req_limit_per_ip:1m rate=50r/s;' >"$f"
  created+=("$f")
fi

# Comandi finti, prima nel PATH.
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
# API Cloudflare finta: zona e2etest.it, nessun record esistente.
m=GET url=""
while (($#)); do case "$1" in -X) m="$2"; shift 2 ;; --data | -H | --max-time) shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
case "$m $url" in
  "GET "*"/zones?status=active"*) echo '{"success":true,"result":[{"name":"e2etest.it"}],"result_info":{"total_pages":1}}' ;;
  "GET "*"/zones?name=e2etest.it"*) echo '{"success":true,"result":[{"id":"z1"}]}' ;;
  "GET "*"/zones?name="*) echo '{"success":true,"result":[]}' ;;
  "GET "*) echo '{"success":true,"result":[]}' ;;
  "POST "*) echo "{\"success\":true,\"result\":{\"id\":\"r$RANDOM\"}}" ;;
  *) echo '{"success":true,"result":{}}' ;;
esac
EOF
cat >"$bin/certbot" <<'EOF'
#!/usr/bin/env bash
# certbot finto: certificato autofirmato per i nomi chiesti.
[[ "$1" == delete ]] && { shift; while (($#)); do [[ "$1" == --cert-name ]] && rm -rf "/etc/letsencrypt/live/$2"; shift; done; exit 0; }
name="" names=()
while (($#)); do case "$1" in --cert-name) name="$2"; shift 2 ;; -d) names+=("$2"); shift 2 ;; *) shift ;; esac; done
dir="/etc/letsencrypt/live/$name"
mkdir -p "$dir"
san="$(printf 'DNS:%s,' "${names[@]}")"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$name" -addext "subjectAltName=${san%,}" \
  -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" >/dev/null 2>&1
EOF
cat >"$bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
# systemd finto: il lavoro gira subito, in primo piano. Il systemd vero non passa al
# lavoro i descrittori dei lucchetti (li chiudiamo anche qui) e imposta l'ambiente
# di --setenv. Le altre opzioni (--unit, -p, ...) si ignorano.
exec 7>&- 8>&- 9>&-
while (($#)); do
  case "$1" in
    --setenv=*) export "${1#--setenv=}"; shift ;;
    --unit | -p) shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
bash "$@"
EOF
cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "reload nginx") /usr/bin/systemctl reload nginx ;;
  "reload php8.4-fpm") /usr/bin/systemctl reload php8.4-fpm ;;
  "is-active "*) exit 3 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$bin"/*
export PATH="$bin:$PATH"

# Lanciato con sudo: senza questo gli strumenti userebbero /opt/vps invece della cartella di prova.
unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
if [[ ! -e /var/www/_maintenance/_maintenance.html ]]; then
  [[ -d /var/www/_maintenance ]] || made_maint=1
  install -d -m 755 /var/www/_maintenance
  install -m 644 "$src/templates/maintenance.html" /var/www/_maintenance/_maintenance.html
  created+=(/var/www/_maintenance/_maintenance.html)
fi

export VPS_OPT="$work/opt" VPS_LIB="$src/lib" VPS_TEMPLATES="$src/templates" VPS_LOG="$work/tools.log"
export SITES_DIR="$work/opt/sites" SITES_WWW="$work/www" SITES_BACKUPS="$work/opt/backups/sites"
export SITES_RUN="$work/run" SITES_LOCK="$work/vps-site.lock" LOGROTATE_D="$work/logrotate.d"
export VPS_SITE_SELF="$src/tools/vps-site" VPS_BACKUP_SELF="$src/tools/vps-backup"
export BK_LOCK_DIR="$work/locks" SYSTEMD_DIR="$work/systemd" MON_CONFIG="$work/opt/monitor/config.json"
mkdir -p "$VPS_OPT/secrets" "$SITES_WWW" "$LOGROTATE_D" "$BK_LOCK_DIR" "$SYSTEMD_DIR" "$work/drive" "$work/panel/config"
printf 'dns_cloudflare_api_token = %s\n' "$(printf 'a%.0s' {1..40})" >"$VPS_OPT/secrets/cloudflare.ini"
id "$ADMIN" >/dev/null 2>&1 || { useradd -m "$ADMIN" && made_admin=1; }
jq -n --arg a "$ADMIN" --arg p "$work/panel" '{installer_version:"1.7.0", admin_user:$a, ipv4:"127.0.0.1", ipv6:null,
  cloudflare:{enabled:true, zone:"e2etest.it"}, panel:{domain:"panel.e2etest.it", path:$p}}' >"$VPS_OPT/manifest.json"
echo "DB_NAME=$PANELDB" >"$work/panel/config/.env"

/usr/bin/systemctl start mariadb >/dev/null 2>&1 || true
/usr/bin/systemctl start php8.4-fpm >/dev/null 2>&1 || true
/usr/bin/systemctl start nginx >/dev/null 2>&1 || true
mariadb -e "DROP DATABASE IF EXISTS \`$PANELDB\`; CREATE DATABASE \`$PANELDB\`; CREATE TABLE \`$PANELDB\`.t (id int); INSERT INTO \`$PANELDB\`.t VALUES (1);"

vs() { bash "$src/tools/vps-site" "$@"; }
vb() { bash "$src/tools/vps-backup" "$@"; }
# Drive finto: rclone vero con un remote locale; i percorsi di "gdrive:" sono relativi alla cartella corrente.
printf '[gdrive]\ntype = local\n' >"$VPS_OPT/secrets/rclone.conf"
chmod 600 "$VPS_OPT/secrets/rclone.conf"
cd "$work/drive"
DRIVE="$work/drive/E2E"

s="site_${D1//./_}"
r="$SITES_WWW/$D1"

echo "== crea $D1 (PHP, DB) e riempilo"
res="$(printf '%s\n' "$PASS" | vs create "$D1" --type php --db)" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "create $D1: $res"
[[ "$(vs show "$D1" | jq -r .site.state)" == active ]] || fail "$D1 non attivo: $(vs show "$D1" | jq -c .site.job)"
site_exec() { sudo -u "$s" sh -c "$1"; }
site_exec "printf 'versione-0' >'$r/public/ver.txt'; printf 'resta' >'$r/public/fisso.txt'; mkdir -p '$r/public/sub' && ln -s fisso.txt '$r/public/lnk'" \
  || fail "il sito non scrive in public/"
sql() { mariadb -u "$s" -p"$PASS" "$s" -N -e "$1"; }
sql "CREATE TABLE utenti (id int, nome varchar(20)); INSERT INTO utenti VALUES (1,'ana'),(2,'bo');"
sql "CREATE TABLE ordini (id int); INSERT INTO ordini VALUES (10);"
wpconf="wp-config-$D1"
printf '<?php // %s\n' "$wpconf" >"$r/wp-config.php"
chown "root:$s" "$r/wp-config.php"
chmod 640 "$r/wp-config.php"

echo "== configura il backup e controlla lo stato"
printf '{"enabled":true,"time":"04:00","folder":"E2E"}' | vb config | jq -e '.ok' >/dev/null || fail "config"
vb status | jq -e '.connected == true and .enabled == true and .folder == "E2E" and .time == "04:00"' >/dev/null || fail "status: $(vb status)"
[[ "$(cat "$SYSTEMD_DIR/vps-backup.timer.d/ora.conf")" == *"04:00:00"* ]] || fail "drop-in del timer"

echo "== 4 giri: si tengono le ultime 3 copie"
for i in 1 2 3 4; do
  site_exec "printf 'versione-$i' >'$r/public/ver.txt'"
  out="$(BK_NOW="2026100$i-0400" vb run)" || fail "run $i: $out"
  jq -e '.started == true' <<<"$out" >/dev/null || fail "run $i: $out"
  vb status | jq -e '.job == null and .interrupted == false and .last_run.ok == true and (.last_run.sites | length) == 1 and .last_run.sites[0].ok == true and .last_run.panel.ok == true' >/dev/null \
    || fail "stato dopo il giro $i: $(vb status)"
done
mapfile -t copie < <(ls "$DRIVE/$D1")
[[ ${#copie[@]} == 3 ]] || fail "copie di $D1 su Drive: ${copie[*]}"
[[ "${copie[0]}" == "$D1-20261002-0400.tar.gz" && "${copie[2]}" == "$D1-20261004-0400.tar.gz" ]] || fail "copie tenute: ${copie[*]}"
mapfile -t pann < <(ls "$DRIVE/_pannello")
[[ ${#pann[@]} == 3 ]] || fail "copie del pannello su Drive: ${pann[*]}"
vb list-remote | jq -e --arg d "$D1" '.sites[] | select(.domain == $d) | .present == true and (.copies | length) == 3 and .copies[0].name == "\($d)/\($d)-20261004-0400.tar.gz"' >/dev/null || fail "list-remote"
[[ -z "$(ls -A "$VPS_OPT/backups/tmp")" ]] || fail "temporanei rimasti in backups/tmp: $(ls -A "$VPS_OPT/backups/tmp")"
# l'archivio su Drive è nel formato nuovo e non contiene logs/ né tmp/
last="$DRIVE/$D1/$D1-20261004-0400.tar.gz"
[[ "$(tar -tzf "$last" | head -n1)" == manifest.json ]] || fail "manifest non primo membro"
tar -xzOf "$last" files.tar.gz | tar -tz | grep -qE '^(logs|tmp)(/|$)' && fail "logs/ o tmp/ nell'archivio"
tar -xzOf "$last" files.tar.gz | tar -tvz | grep -q 'lnk -> fisso.txt' || fail "il collegamento non è rimasto un collegamento"
tar -xzOf "$last" files.tar.gz | tar -xzO wp-config.php | grep -q "$wpconf" || fail "wp-config.php non è nell'archivio"

echo "== ripristino: file"
site_exec "printf 'rovinato' >'$r/public/ver.txt'; rm -f '$r/public/fisso.txt'; printf 'nuovo' >'$r/public/estraneo.txt'"
sql "DROP TABLE ordini; INSERT INTO utenti VALUES (3,'cy');"
out="$(vb restore "$D1" "$D1/$D1-20261004-0400.tar.gz" files)" || fail "restore files: $out"
jq -e '.started == true' <<<"$out" >/dev/null || fail "restore files: $out"
[[ "$(cat "$r/public/ver.txt")" == versione-4 ]] || fail "ver.txt dopo il ripristino dei file: $(cat "$r/public/ver.txt")"
[[ "$(cat "$r/public/fisso.txt")" == resta ]] || fail "fisso.txt non tornato"
[[ ! -e "$r/public/estraneo.txt" ]] || fail "estraneo.txt ancora presente"
[[ "$(stat -c '%U:%G' "$r/public/ver.txt")" == "$s:$s" ]] || fail "proprietario dei file ripristinati: $(stat -c '%U:%G' "$r/public/ver.txt")"
[[ "$(readlink "$r/public/lnk")" == fisso.txt ]] || fail "collegamento non ripristinato"
[[ "$(stat -c %a "$r/public")" == 2770 ]] || fail "permessi di public/: $(stat -c %a "$r/public")"
getfacl -p "$r/public" 2>/dev/null | grep -q 'user:www-data:r-x' || fail "ACL di www-data su public/ perse"
grep -q "$wpconf" "$r/wp-config.php" || fail "wp-config.php è stato toccato"
[[ "$(sql "SELECT COUNT(*) FROM utenti")" == 3 ]] || fail "il database non doveva cambiare con 'files'"
vb status | jq -e --arg d "$D1" '.last_restore.ok == true and .last_restore.mode == "files" and .last_restore.domain == $d and (.last_restore.safety | test("^e2etest"))' >/dev/null || fail "last_restore: $(vb status | jq -c .last_restore)"
safety1="$(vb status | jq -r .last_restore.safety)"
tar -xzOf "$VPS_OPT/backups/restore/$safety1" files.tar.gz | tar -xzO public/ver.txt | grep -qx rovinato || fail "la copia di sicurezza non ha lo stato di prima"
[[ -z "$(ls -A "$r/tmp")" ]] || fail "avanzi in tmp/ del sito: $(ls -A "$r/tmp")"

echo "== ripristino: database"
out="$(vb restore "$D1" "$D1/$D1-20261004-0400.tar.gz" db)" || fail "restore db: $out"
[[ "$(sql "SELECT COUNT(*) FROM utenti")" == 2 ]] || fail "utenti dopo il ripristino del db"
[[ "$(sql "SELECT COUNT(*) FROM ordini")" == 1 ]] || fail "ordini dopo il ripristino del db"
[[ "$(cat "$r/public/ver.txt")" == versione-4 ]] || fail "i file non dovevano cambiare con 'db'"
mariadb -u "$s" -p"$PASS" -e 'SELECT 1' "$s" >/dev/null || fail "la password del database è cambiata"
[[ -z "$(mariadb -N -e "SHOW DATABASES LIKE '${s}__ripristino'")" ]] || fail "database temporaneo rimasto"
[[ "$(mariadb -N -e "SELECT COUNT(*) FROM mysql.user WHERE User='${s}_r'")" == 0 ]] || fail "utente temporaneo rimasto"

echo "== ripristino: tutto (da una copia più vecchia)"
out="$(vb restore "$D1" "$D1/$D1-20261002-0400.tar.gz" all)" || fail "restore all: $out"
[[ "$(cat "$r/public/ver.txt")" == versione-2 ]] || fail "ver.txt dopo 'all': $(cat "$r/public/ver.txt")"
vb status | jq -e '.last_restore.ok == true and .last_restore.mode == "all"' >/dev/null || fail "last_restore all: $(vb status | jq -c .last_restore)"

echo "== ripristino da una copia locale (la copia di sicurezza) e copie locali"
out="$(vb list-local)" || fail "list-local"
jq -e '[.items[] | select(.kind == "restore" and .restorable == true)] | length >= 3' <<<"$out" >/dev/null || fail "copie di sicurezza in list-local: $out"
out="$(vb restore-local "restore/$safety1" files)" || fail "restore-local: $out"
[[ "$(cat "$r/public/ver.txt")" == rovinato ]] || fail "ver.txt dopo restore-local: $(cat "$r/public/ver.txt")"

echo "== un archivio manomesso è rifiutato prima di toccare il sito"
bad="$work/bad"
mkdir -p "$bad/x"
tar -xzf "$last" -C "$bad/x"
echo manomesso >>"$bad/x/files.tar.gz"
tar -czf "$DRIVE/$D1/$D1-20261005-0400.tar.gz" -C "$bad/x" manifest.json files.tar.gz db.sql.gz
before="$(cat "$r/public/ver.txt")"
vb restore "$D1" "$D1/$D1-20261005-0400.tar.gz" all >/dev/null || true
vb status | jq -e '.last_restore.ok == false and (.last_restore.error | length) > 0 and .last_restore.safety == null' >/dev/null || fail "archivio manomesso: $(vb status | jq -c .last_restore)"
[[ "$(cat "$r/public/ver.txt")" == "$before" ]] || fail "il sito è cambiato dopo un archivio manomesso"
rm -f "$DRIVE/$D1/$D1-20261005-0400.tar.gz"

echo "== elimina il sito: archivio nel formato nuovo; ricrea dall'archivio locale"
site_exec "printf 'versione-finale' >'$r/public/ver.txt'"
sql "INSERT INTO utenti VALUES (9,'zed')"
vs delete "$D1" | jq -e '.ok' >/dev/null || fail "delete"
[[ ! -e "$r" ]] || fail "cartella ancora presente"
arc="$(compgen -G "$SITES_BACKUPS/$D1-*.tar.gz" | head -n1)"
[[ -n "$arc" ]] || fail "archivio del sito eliminato mancante"
[[ "$(tar -tzf "$arc" | head -n1)" == manifest.json ]] || fail "archivio eliminato senza manifest"
vb list-local | jq -e --arg n "sites/$(basename "$arc")" '.items[] | select(.name == $n) | .restorable == true and .kind == "site"' >/dev/null || fail "list-local non lo vede ripristinabile"
res="$(printf '%s\n' "$PASS2" | vs create "$D1" --from-backup "sites/$(basename "$arc")")" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "create --from-backup: $res"
[[ "$(vs show "$D1" | jq -r '"\(.site.state) \(.site.type) \(.site.job.step) \(.site.job.error)"')" == "active php done null" ]] || fail "sito ricreato: $(vs show "$D1" | jq -c .site)"
[[ "$(cat "$r/public/ver.txt")" == versione-finale ]] || fail "file ricreati: $(cat "$r/public/ver.txt")"
[[ "$(readlink "$r/public/lnk")" == fisso.txt ]] || fail "collegamento ricreato"
mariadb -u "$s" -p"$PASS2" -e 'SELECT 1' "$s" >/dev/null || fail "la password nuova non funziona"
mariadb -u "$s" -p"$PASS" -e 'SELECT 1' "$s" >/dev/null 2>&1 && fail "la password vecchia funziona ancora"
[[ "$(mariadb -u "$s" -p"$PASS2" "$s" -N -e 'SELECT COUNT(*) FROM utenti')" == 3 ]] || fail "righe del database ricreato"
vb status | jq -e '.last_restore.ok == true and .last_restore.mode == "all"' >/dev/null || fail "last_restore ricreazione"
sudo -u "$s" touch "$r/public/prova" || fail "il sito non scrive in public/"
sudo -u "$s" touch "$r/x" 2>/dev/null && fail "il sito non deve scrivere nella radice"

echo "== elimina di nuovo e ricrea dalla copia su Drive (manifest letto da Drive)"
vs delete "$D1" | jq -e '.ok' >/dev/null || fail "delete 2"
res="$(printf '%s\n' "$PASS" | vs create "$D1" --from-backup "remote:$D1/$D1-20261004-0400.tar.gz")" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "create --from-backup remote: $res"
[[ "$(vs show "$D1" | jq -r '"\(.site.state) \(.site.job.step) \(.site.job.error)"')" == "active done null" ]] || fail "sito ricreato da Drive: $(vs show "$D1" | jq -c .site)"
[[ "$(cat "$r/public/ver.txt")" == versione-4 ]] || fail "file da Drive: $(cat "$r/public/ver.txt")"
[[ "$(mariadb -u "$s" -p"$PASS" "$s" -N -e 'SELECT COUNT(*) FROM utenti')" == 2 ]] || fail "righe da Drive"

echo "== dominio diverso dal manifest: rifiutato, nessun sito creato"
res="$(printf '%s\n' "$PASS" | vs create "altro.e2etest.it" --from-backup "remote:$D1/$D1-20261004-0400.tar.gz")" || true
jq -e '.ok == false' <<<"$res" >/dev/null || fail "dominio diverso accettato: $res"
[[ ! -e "$SITES_DIR/altro.e2etest.it.json" ]] || fail "registro creato per un dominio diverso"

echo "== niente avanzi"
[[ -z "$(ls -A "$VPS_OPT/backups/tmp")" ]] || fail "backups/tmp: $(ls -A "$VPS_OPT/backups/tmp")"
[[ -z "$(ls -A "$r/tmp")" ]] || fail "tmp/ del sito: $(ls -A "$r/tmp")"
[[ -z "$(mariadb -N -e "SHOW DATABASES LIKE '${s}__ripristino'")" ]] || fail "database temporaneo rimasto"
grep -qE 'ya29|refresh_token' "$VPS_LOG" && fail "un token è finito nel registro"

echo "E2E BACKUP OK"
