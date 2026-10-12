#!/usr/bin/env bash
# End-to-end di vps-site in WSL (root): utenti, ACL, PHP-FPM, Nginx e MariaDB
# veri; Cloudflare, certbot e systemd finti. Può installare con apt-get nginx,
# php8.4-fpm, mariadb-server e acl se mancano, e lascia i servizi in esecuzione;
# il resto lo rimette com'era.
# Uso (da Windows, via PowerShell):
#   wsl -d Debian -- sudo bash /mnt/c/.../vps-installer/tests/e2e/site-e2e.sh
set -Eeuo pipefail
src="$(cd "$(dirname "$0")/../.." && pwd)"
((EUID == 0)) || { echo "Serve root: sudo bash $0" >&2; exit 2; }

for p in nginx php8.4-fpm mariadb-server acl openssl jq gettext-base; do
  dpkg -s "$p" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p" >/dev/null
done

work="$(mktemp -d /tmp/site-e2e.XXXXXX)"
chmod 755 "$work"
D1=blog.e2etest.it
D2=vetrina.e2etest.it
ADMIN=e2eadmin
PASS='Password-e2e-1234567'
created=()
made_maint=
made_admin=

fail() { echo "E2E FALLITO: $*" >&2; exit 1; }

cleanup() {
  set +e
  # Prima togliamo i pool e ricarichiamo PHP-FPM: finché i suoi processi
  # girano come utente del sito, userdel si rifiuta.
  for d in "$D1" "$D2"; do
    rm -f "/etc/nginx/conf.d/$d.conf" "/etc/php/8.4/fpm/pool.d/site_${d//./_}.conf"
  done
  /usr/bin/systemctl reload php8.4-fpm >/dev/null 2>&1
  for d in "$D1" "$D2"; do
    pkill -u "site_${d//./_}" 2>/dev/null
  done
  sleep 1
  for d in "$D1" "$D2"; do
    userdel "site_${d//./_}" 2>/dev/null; groupdel "site_${d//./_}" 2>/dev/null
    mariadb -e "DROP DATABASE IF EXISTS \`site_${d//./_}\`; DROP USER IF EXISTS 'site_${d//./_}'@'localhost';" 2>/dev/null
    rm -rf "/etc/letsencrypt/live/$d"
  done
  [[ -z "$made_admin" ]] || userdel -r "$ADMIN" 2>/dev/null
  for f in "${created[@]}"; do rm -f "$f"; done
  [[ -z "$made_maint" ]] || rmdir /var/www/_maintenance 2>/dev/null
  nginx -t >/dev/null 2>&1 && /usr/bin/systemctl reload nginx 2>/dev/null
  /usr/bin/systemctl reload php8.4-fpm >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

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
  f=/etc/nginx/conf.d/00-site-e2e.conf
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
# systemd finto: il lavoro gira subito, in primo piano. Il systemd vero non
# passa al lavoro i descrittori dei lucchetti: li chiudiamo anche qui.
exec 7>&- 8>&- 9>&-
while [[ "$1" == --* ]]; do [[ "$1" == --unit ]] && shift; shift; done
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

# Lanciato con sudo: senza questo vps-site userebbe /opt/vps invece della cartella di prova.
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
export VPS_SITE_SELF="$src/tools/vps-site"
mkdir -p "$VPS_OPT/secrets" "$SITES_WWW" "$LOGROTATE_D"
printf 'dns_cloudflare_api_token = %s\n' "$(printf 'a%.0s' {1..40})" >"$VPS_OPT/secrets/cloudflare.ini"
id "$ADMIN" >/dev/null 2>&1 || { useradd -m "$ADMIN" && made_admin=1; }
jq -n --arg a "$ADMIN" '{installer_version:"1.2.0", admin_user:$a, ipv4:"127.0.0.1", ipv6:null,
  cloudflare:{enabled:true, zone:"e2etest.it"}, panel:{domain:"panel.e2etest.it"}}' >"$VPS_OPT/manifest.json"

/usr/bin/systemctl start mariadb >/dev/null 2>&1 || true
/usr/bin/systemctl start php8.4-fpm >/dev/null 2>&1 || true
/usr/bin/systemctl start nginx >/dev/null 2>&1 || true

vs() { bash "$src/tools/vps-site" "$@"; }
# Il curl vero: nel PATH c'è quello finto di Cloudflare.
get() { /usr/bin/curl -sk --resolve "$1:443:127.0.0.1" "${@:2}" "https://$1/"; }
# Il reload di Nginx è asincrono (HUP): attende che il sito risponda col codice atteso.
wait_code() {
  local c
  for _ in {1..20}; do
    c="$(get "$1" -o /dev/null -w '%{http_code}')"
    [[ "$c" == "$2" ]] && return 0
    sleep 0.25
  done
  return 1
}

echo "== crea $D1 (PHP, www, DB)"
res="$(printf '%s\n' "$PASS" | vs create "$D1" --type php --www --db)" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "create $D1: $res"
[[ "$(vs show "$D1" | jq -r .site.state)" == active ]] || fail "$D1 non attivo: $(vs show "$D1" | jq -c .site.job)"
r="$SITES_WWW/$D1"
s="site_${D1//./_}"
sudo -u "$ADMIN" sh -c "printf '<?php echo \"uid=\" . getmyuid() . \" \" . posix_geteuid();' >'$r/public/index.php'" \
  || fail "l'admin non scrive in public/"
sudo -u www-data touch "$r/public/x" 2>/dev/null && fail "www-data non deve scrivere in public/"
wait_code "$D1" 200 || true
out="$(get "$D1")"
[[ "$out" == *" $(id -u "$s")" ]] || fail "PHP non gira come $s: $out"
code="$(get "www.$D1" -o /dev/null -w '%{http_code} %{redirect_url}')"
[[ "$code" == "301 https://$D1/" ]] || fail "redirect www: $code"
mariadb -u "$s" -p"$PASS" -e 'SELECT 1' "$s" >/dev/null || fail "login DB del sito"

echo "== proprietari: radice, logs/ e db.env di root; il sito scrive solo dove serve"
want() { # PERCORSO "utente:gruppo modo"
  local got
  got="$(stat -c '%U:%G %a' "$1")"
  [[ "$got" == "$2" ]] || fail "$1: atteso $2, trovato $got"
}
want "$r" "root:$s 2750"
want "$r/logs" "root:$s 2750"
want "$r/logs/php" "$s:$s 2770"
want "$r/public" "$s:$s 2770"
want "$r/tmp" "$s:$s 2770"
want "$r/db.env" "root:$s 640"
want "$r/logs/access.log" "root:$s 644"
grep -qx "php_admin_value\[error_log\] = $r/logs/php/php-error.log" "/etc/php/8.4/fpm/pool.d/$s.conf" \
  || fail "error_log di PHP non in logs/php/"
sudo -u "$ADMIN" grep -qx "DB_USER=$s" "$r/db.env" || fail "l'admin non legge db.env"
sudo -u "$s" ln -s /etc/passwd "$r/logs/x" 2>/dev/null && fail "il sito non deve poter scrivere in logs/"
sudo -u "$s" touch "$r/x" 2>/dev/null && fail "il sito non deve poter scrivere nella radice"
sudo -u "$s" touch "$r/logs/php/prova.log" || fail "il sito deve poter scrivere in logs/php/"
rm -f "$r/logs/php/prova.log"

echo "== disattiva e riattiva"
vs disable "$D1" | jq -e '.state == "disabled"' >/dev/null || fail "disable"
wait_code "$D1" 503 || true
code="$(get "$D1" -o /dev/null -w '%{http_code}')"
[[ "$code" == 503 ]] || fail "manutenzione: $code"
out="$(get "$D1")"
[[ "$out" == *manutenzione* ]] || fail "pagina di manutenzione"
vs enable "$D1" | jq -e '.state == "active"' >/dev/null || fail "enable"
wait_code "$D1" 200 || fail "riattivato"

echo "== crea $D2 (statico)"
vs create "$D2" --type static | jq -e '.ok' >/dev/null || fail "create $D2"
wait_code "$D2" 200 || true
out="$(get "$D2")"
[[ "$out" == *"<h1>$D2</h1>"* ]] || fail "segnaposto di $D2"

echo "== elimina"
pool="/etc/php/8.4/fpm/pool.d/$s.conf"
rotf="$LOGROTATE_D/vps-site-$s"
[[ -n "$(mariadb -N -e "SHOW DATABASES LIKE '$s'")" ]] || fail "il DB $s non esiste prima di delete"
[[ "$(mariadb -N -e "SELECT COUNT(*) FROM mysql.user WHERE User='$s'")" == 1 ]] || fail "l'utente DB $s non esiste prima di delete"
[[ -e "$pool" && -e "$rotf" && -d "$r" ]] || fail "pool, logrotate o cartella di $D1 mancano prima di delete"
vs delete "$D1" | jq -e '.ok' >/dev/null || fail "delete $D1"
[[ "$(vs list | jq '.sites | length')" == 1 ]] || fail "registro di $D1 ancora presente"
ls "$SITES_BACKUPS/$D1"-*.tar.gz >/dev/null || fail "archivio file di $D1"
ls "$SITES_BACKUPS/$D1"-*.sql.gz >/dev/null || fail "dump di $D1"
id "$s" >/dev/null 2>&1 && fail "utente $s ancora presente"
[[ ! -e "/etc/nginx/conf.d/$D1.conf" ]] || fail "vhost di $D1 ancora presente"
[[ -z "$(mariadb -N -e "SHOW DATABASES LIKE '$s'")" ]] || fail "DB $s ancora presente"
[[ "$(mariadb -N -e "SELECT COUNT(*) FROM mysql.user WHERE User='$s'")" == 0 ]] || fail "utente DB $s ancora presente"
[[ ! -e "$pool" ]] || fail "pool di $D1 ancora presente"
[[ ! -e "/etc/letsencrypt/live/$D1" ]] || fail "certificato di $D1 ancora presente"
[[ ! -e "$r" ]] || fail "cartella di $D1 ancora presente"
[[ ! -e "$rotf" ]] || fail "logrotate di $D1 ancora presente"
tarf="$(compgen -G "$SITES_BACKUPS/$D1-*.tar.gz" | head -n1)"
lista="$(tar -tzf "$tarf")"
[[ "$lista" == *"$D1/public/index.php"* ]] || fail "index.php non è nell'archivio: $lista"
sqlf="$(compgen -G "$SITES_BACKUPS/$D1-*.sql.gz" | head -n1)"
dump="$(zcat "$sqlf")"
[[ "$dump" == *"$s"* ]] || fail "il dump non contiene il DB $s"
vs delete "$D2" | jq -e '.ok' >/dev/null || fail "delete $D2"
[[ "$(vs list | jq '.sites | length')" == 0 ]] || fail "siti rimasti"

echo "E2E SITI OK"
