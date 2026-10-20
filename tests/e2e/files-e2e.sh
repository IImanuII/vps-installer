#!/usr/bin/env bash
# End-to-end di vps-files in WSL (root): un sito vero creato con le librerie di
# vps-site (utente, ACL, cartelle) e il file manager che lavora come l'utente del
# sito con runuser vero. Cloudflare, certbot e systemd finti (come site-e2e.sh).
# Può installare con apt-get nginx, acl, zip e unzip se mancano; zip e unzip li
# toglie alla fine se li ha messi lui. Il resto lo rimette com'era.
# Uso (da Windows, via PowerShell):
#   wsl -d Debian -- sudo bash /mnt/c/.../vps-installer/tests/e2e/files-e2e.sh
set -Eeuo pipefail
src="$(cd "$(dirname "$0")/../.." && pwd)"
((EUID == 0)) || { echo "Serve root: sudo bash $0" >&2; exit 2; }

made_zip=
for p in nginx acl openssl jq gettext-base zip unzip; do
  if ! dpkg -s "$p" >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p" >/dev/null
    case "$p" in zip | unzip) made_zip="$made_zip $p" ;; esac
  fi
done

work="$(mktemp -d /tmp/files-e2e.XXXXXX)"
chmod 755 "$work"
# Il sito con --www è il dominio principale della zona: dalla v1.2.1 il www si
# aggiunge solo lì (Cloudflare non ha un certificato per www.blog.zona).
D1=e2etest.it
D2=vetrina.e2etest.it
ADMIN=e2eadmin
created=()
made_maint=
made_admin=

fail() {
  echo "E2E FALLITO: $*" >&2
  # La cartella di prova sparisce nel cleanup: il registro degli strumenti si mostra qui.
  [[ ! -f "${VPS_LOG:-}" ]] || { echo "--- ultime righe di $VPS_LOG" >&2; tail -n 40 "$VPS_LOG" >&2; }
  exit 1
}

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
  # shellcheck disable=SC2086 # elenco di pacchetti separati da spazi
  [[ -z "$made_zip" ]] || DEBIAN_FRONTEND=noninteractive apt-get purge -y -q $made_zip >/dev/null 2>&1
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

vf() { bash "$src/tools/vps-files" "$@"; }
# vf_ok ...: il comando deve rispondere {"ok":true...}
vf_ok() { local o; o="$(vf "$@")" || fail "vps-files $*: $o"; jq -e '.ok == true' <<<"$o" >/dev/null || fail "vps-files $*: $o"; }
# vf_no ...: il comando deve fallire con {"ok":false...}; stampa la risposta
vf_no() { local o rc=0; o="$(vf "$@")" || rc=$?; ((rc != 0)) || fail "vps-files $* doveva fallire: $o"; jq -e '.ok == false' <<<"$o" >/dev/null || fail "vps-files $*: risposta non JSON di errore: $o"; printf '%s' "$o"; }
owner() { [[ "$(stat -c '%U:%G' "$1")" == "$2:$2" ]] || fail "$1: proprietario $(stat -c '%U:%G' "$1"), atteso $2:$2"; }

echo "== crea $D1 (statico)"
vs create "$D1" --type static | jq -e '.ok' >/dev/null || fail "create $D1"
r="$SITES_WWW/$D1"
s="site_${D1//./_}"

echo "== list, write, read, rename, mkdir"
vf list "$D1" public | jq -e '.ok and .writable and (.entries | map(.name) | index("index.html"))' >/dev/null || fail "list public"
vf list "$D1" "" | jq -e '.ok and (.entries | map(.name) | contains(["public", "logs"]))' >/dev/null || fail "list radice"
printf 'ciao\n' | vf write "$D1" public/nota.txt | jq -e '.ok and .size == 5' >/dev/null || fail "write"
owner "$r/public/nota.txt" "$s"
[[ "$(stat -c %a "$r/public/nota.txt")" == 664 ]] || fail "permessi di nota.txt"
[[ "$(vf read "$D1" public/nota.txt)" == ciao ]] || fail "read"
vf stat "$D1" public/nota.txt | jq -e '.ok and .text and .size == 5' >/dev/null || fail "stat"
vf_no write "$D1" public/nota.txt <<<"x" | jq -e '.conflicts[0] == "public/nota.txt"' >/dev/null || fail "write su esistente senza conflitto"
vf_ok rename "$D1" public/nota.txt "nota 2.txt"
[[ -e "$r/public/nota 2.txt" && ! -e "$r/public/nota.txt" ]] || fail "rename"
vf_ok mkdir "$D1" public/dir
owner "$r/public/dir" "$s"
printf 'a' | vf_ok write "$D1" public/dir/a.txt
owner "$r/public/dir/a.txt" "$s"
vf_no write "$D1" logs/x <<<"x" >/dev/null
vf_no write "$D1" tmp/x <<<"x" >/dev/null
vf_no read "$D1" ../etc/passwd >/dev/null

echo "== zip, unzip, download-zip"
vf_ok zip "$D1" public/dir.zip -- public/dir "public/nota 2.txt"
owner "$r/public/dir.zip" "$s"
unzip -tq "$r/public/dir.zip" >/dev/null || fail "zip non valido"
vf_no zip "$D1" public/dir.zip -- public/dir | jq -e '.conflicts[0] == "public/dir.zip"' >/dev/null || fail "zip su esistente"
vf_ok mkdir "$D1" public/estratto
vf_ok unzip "$D1" public/dir.zip public/estratto
owner "$r/public/estratto/dir/a.txt" "$s"
[[ "$(cat "$r/public/estratto/dir/a.txt")" == a ]] || fail "contenuto estratto"
printf 'b' >"$work/b.txt"
vf_ok write "$D1" public/estratto/dir/a.txt --overwrite <"$work/b.txt"
vf_no unzip "$D1" public/dir.zip public/estratto | jq -e '.conflicts | index("public/estratto/dir/a.txt")' >/dev/null || fail "unzip senza conflitto"
[[ "$(cat "$r/public/estratto/dir/a.txt")" == b ]] || fail "unzip ha toccato un file in conflitto"
vf_ok unzip "$D1" public/dir.zip public/estratto --overwrite
[[ "$(cat "$r/public/estratto/dir/a.txt")" == a ]] || fail "unzip --overwrite"
vf download-zip "$D1" public/dir >"$work/d.zip" || fail "download-zip"
unzip -tq "$work/d.zip" >/dev/null || fail "download-zip non valido"
zipinfo -1 "$work/d.zip" | grep -qx 'dir/a.txt' || fail "download-zip: manca dir/a.txt"

echo "== archivi malevoli (zip-slip, link, voce da 11 MB)"
mal() { # NOME voci... : crea l'archivio come file del sito
  local n="$1"
  shift
  perl "$src/tests/mkzip.pl" "$work/$n" "$@"
  vf write "$D1" "public/$n" --overwrite <"$work/$n" | jq -e '.ok' >/dev/null || fail "write $n"
}
mal slip.zip "../evil|100644|3"
vf_no unzip "$D1" public/slip.zip public/estratto >/dev/null
mal abs.zip "/tmp/evil-e2e|100644|3"
vf_no unzip "$D1" public/abs.zip public/estratto >/dev/null
mal link.zip "ok|100644|3" "l|120777|11"
vf_no unzip "$D1" public/link.zip public/estratto >/dev/null
mal big.zip "grande|100644|11534336|0"
vf_no unzip "$D1" public/big.zip public/estratto >/dev/null
bomb=()
for i in $(seq 1 30); do bomb+=("b$i|100644|100|z10000000"); done
mal bomba.zip "${bomb[@]}"
vf_no unzip "$D1" public/bomba.zip public/estratto >/dev/null
[[ ! -e "$r/evil" && ! -e "$r/public/evil" && ! -e /tmp/evil-e2e && ! -e "$r/public/estratto/ok" && ! -e "$r/public/estratto/l" ]] || fail "gli archivi malevoli hanno scritto qualcosa"
[[ -z "$(ls -A "$r/tmp")" ]] || fail "temporanei rimasti in tmp/: $(ls -A "$r/tmp")"
[[ -z "$(find "$r/public/estratto" -type f -size +1000k)" ]] || fail "file grandi estratti"

echo "== collegamento verso /etc/shadow in public/"
sudo -u "$s" ln -s /etc/shadow "$r/public/sh"
sudo -u "$s" ln -s /etc "$r/public/etc"
o="$(vf_no read "$D1" public/sh)"
[[ "$o" != *root:* ]] || fail "read ha rivelato /etc/shadow"
vf_no read "$D1" public/etc/shadow >/dev/null
vf_no list "$D1" public/etc >/dev/null
vf_no write "$D1" public/sh --overwrite <<<"x" >/dev/null
o="$(vf list "$D1" public)"
jq -e '.entries[] | select(.name == "sh") | .type == "link" and .size == 11' <<<"$o" >/dev/null || fail "list: il link deve avere la dimensione del link, non del bersaglio"
[[ "$o" != *root:* ]] || fail "list ha rivelato /etc/shadow"
vf stat "$D1" public/sh | jq -e '.type == "link" and .text == false' >/dev/null || fail "stat del link"
vf download-zip "$D1" public >"$work/pub.zip" || fail "download-zip di public"
unzip -tq "$work/pub.zip" >/dev/null || fail "download-zip di public non valido"
! grep -aq 'root:' "$work/pub.zip" || fail "download-zip ha messo /etc/shadow nello zip"
zipinfo -s "$work/pub.zip" | grep -q '^l.* public/sh$' || fail "il link non è memorizzato come link"
vf_ok copy "$D1" public/estratto -- public/sh
[[ -L "$r/public/estratto/sh" ]] || fail "copy deve copiare il link come link"
vf_ok zip "$D1" public/tutto.zip -- public
o="$(vf_no unzip "$D1" public/tutto.zip public/estratto)"
[[ "$o" == *collegament* ]] || fail "unzip di un archivio con link: $o"

echo "== delete"
vf_ok delete "$D1" -- public/sh public/etc public/dir public/dir.zip public/estratto "public/nota 2.txt" public/slip.zip public/abs.zip public/link.zip public/big.zip public/bomba.zip public/tutto.zip
[[ ! -e "$r/public/dir" && ! -e "$r/public/estratto" && ! -L "$r/public/sh" ]] || fail "delete"
[[ -e /etc/shadow && -d /etc ]] || fail "delete ha toccato i bersagli dei link"
grep -q 'files zip' "$VPS_LOG" || fail "registro: manca files zip"
grep -q 'files unzip' "$VPS_LOG" || fail "registro: manca files unzip"

echo "== elimina"
vs delete "$D1" | jq -e '.ok' >/dev/null || fail "delete $D1"

echo "E2E FILES OK"
