#!/usr/bin/env bash
# End-to-end di WordPress con vps-site in WSL (root): Nginx, PHP-FPM 8.4,
# MariaDB, Redis con utenti ACL e WP-CLI veri; WordPress e plugin scaricati
# davvero da wordpress.org (serve internet). Cloudflare, certbot e systemd-run
# finti. Può installare con apt-get i pacchetti che mancano e lascia i servizi
# in esecuzione; redis.conf torna identico a prima (anche dopo un errore).
# Uso (da Windows, via PowerShell):
#   wsl -d Debian -- sudo bash /mnt/c/.../vps-installer/tests/e2e/wp-e2e.sh
set -Eeuo pipefail
src="$(cd "$(dirname "$0")/../.." && pwd)"
((EUID == 0)) || { echo "Serve root: sudo bash $0" >&2; exit 2; }

nuovi=0
for p in nginx php8.4-fpm php8.4-cli mariadb-server acl openssl jq gettext-base redis-server \
  php8.4-redis php8.4-mysql php8.4-gd php8.4-intl php8.4-mbstring php8.4-xml php8.4-zip php8.4-curl; do
  if ! dpkg -s "$p" >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p" >/dev/null
    nuovi=1
  fi
done

work="$(mktemp -d /tmp/wp-e2e.XXXXXX)"
chmod 755 "$work"
D1=blog.e2etest.it
D2=vuoto.e2etest.it
ADMIN=e2eadmin
DBPASS='Password-e2e-1234567'
DBPASS2='Password-e2e-nuova-890'
WPPASS='Admin-e2e-Pass-98765'
LOGIN1=accesso-e2e
LOGIN2=entra-e2e
REDIS_CONF=/etc/redis/redis.conf
REDIS_BAK="$work/redis.conf.orig"
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
  # Redis com'era: redis.conf identico, file ACL di prova tolto, riavvio. Senza
  # questo il Redis di WSL resterebbe con l'utente default spento.
  if [[ -f "$REDIS_BAK" ]]; then
    cp -p "$REDIS_BAK" "$REDIS_CONF"
    rm -f "$REDIS_ACL_FILE"
    /usr/bin/systemctl restart redis-server >/dev/null 2>&1
    cmp -s "$REDIS_BAK" "$REDIS_CONF" || echo "ATTENZIONE: $REDIS_CONF non ripristinato" >&2
    # Le chiavi dei siti di prova (dopo un errore a metà la delete non le ha tolte).
    redis-cli EVAL "local c = '0' repeat local r = redis.call('SCAN', c, 'MATCH', ARGV[1]) c = r[1] for _, k in ipairs(r[2]) do redis.call('UNLINK', k) end until c == '0'" \
      0 'site_*_e2etest_it:*' >/dev/null 2>&1
  fi
  [[ -z "$made_admin" ]] || userdel -r "$ADMIN" 2>/dev/null
  for f in "${created[@]}"; do rm -f "$f"; done
  [[ -z "$made_maint" ]] || rmdir /var/www/_maintenance 2>/dev/null
  nginx -t >/dev/null 2>&1 && /usr/bin/systemctl reload nginx 2>/dev/null
  /usr/bin/systemctl reload php8.4-fpm >/dev/null 2>&1
  rm -rf "$work"
}
# Il file ACL non sta nella cartella di prova: redis-server ha PrivateTmp e non
# vedrebbe /tmp. /etc/redis è leggibile da Redis e il file si toglie nel cleanup.
export REDIS_ACL_FILE=/etc/redis/users-e2e.acl
[[ ! -e "$REDIS_ACL_FILE" ]] || { echo "$REDIS_ACL_FILE esiste già: lo lascio stare" >&2; exit 2; }
cp -p "$REDIS_CONF" "$REDIS_BAK"
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
  f=/etc/nginx/conf.d/00-wp-e2e.conf
  printf '%s\n' 'log_format main '"'"'$remote_addr [$time_local] "$request" $status'"'"';' \
    'limit_req_zone $binary_remote_addr zone=req_limit_per_ip:1m rate=50r/s;' >"$f"
  created+=("$f")
fi

# Comandi finti, prima nel PATH.
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
# Solo l'API Cloudflare è finta (zona e2etest.it, nessun record esistente):
# WP-CLI e le sue verifiche si scaricano davvero.
cf=""
for a in "$@"; do [[ "$a" == https://api.cloudflare.com/* ]] && cf=1; done
[[ -n "$cf" ]] || exec /usr/bin/curl "$@"
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
# Nginx, PHP-FPM e Redis veri; le unità dei lavori (finti) non sono mai attive.
case "$1 $2" in
  "reload nginx") /usr/bin/systemctl reload nginx ;;
  "reload php8.4-fpm") /usr/bin/systemctl reload php8.4-fpm ;;
  "restart redis-server") /usr/bin/systemctl restart redis-server ;;
  "is-active "*) [[ "$*" == *redis-server* ]] && exec /usr/bin/systemctl "$@"; exit 3 ;;
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
export REDIS_CONF REDIS_ADMIN_SECRET="$work/opt/secrets/redis-admin"
export CRON_D="$work/cron.d" WP_BIN="$work/wpcli/wp"
mkdir -p "$VPS_OPT/secrets" "$SITES_WWW" "$LOGROTATE_D" "$CRON_D" "$work/wpcli"
chmod 755 "$work/wpcli"
printf 'dns_cloudflare_api_token = %s\n' "$(printf 'a%.0s' {1..40})" >"$VPS_OPT/secrets/cloudflare.ini"
id "$ADMIN" >/dev/null 2>&1 || { useradd -m "$ADMIN" && made_admin=1; }
jq -n --arg a "$ADMIN" '{installer_version:"1.4.0", admin_user:$a, ipv4:"127.0.0.1", ipv6:null,
  components:{redis:true}, cloudflare:{enabled:true, zone:"e2etest.it"}, panel:{domain:"panel.e2etest.it"}}' \
  >"$VPS_OPT/manifest.json"

/usr/bin/systemctl start mariadb >/dev/null 2>&1 || true
# Estensioni PHP appena installate: le carica solo un riavvio del master.
if ((nuovi)); then
  /usr/bin/systemctl restart php8.4-fpm >/dev/null 2>&1 || true
else
  /usr/bin/systemctl start php8.4-fpm >/dev/null 2>&1 || true
fi
/usr/bin/systemctl start nginx >/dev/null 2>&1 || true
/usr/bin/systemctl start redis-server >/dev/null 2>&1 || true

vs() { bash "$src/tools/vps-site" "$@"; }
# vlib FUNZIONE ARG... — una funzione delle librerie, con l'ambiente di prova.
vlib() {
  # shellcheck disable=SC1090
  bash -c 'for l in "$VPS_LIB"/*.sh; do source "$l"; done; "$@"' vlib "$@"
}
# Il curl vero: nel PATH c'è quello finto di Cloudflare. Le risposte si
# confrontano in [[ ]], mai con `| grep -q`: con pipefail grep che esce subito
# fa morire curl di SIGPIPE e il controllo fallisce a caso.
get() { /usr/bin/curl -sk --max-time 30 --resolve "$1:443:127.0.0.1" "${@:3}" "https://$1$2"; }
code_of() { get "$1" "$2" -o /dev/null -w '%{http_code}'; }
# Il reload di Nginx è asincrono (HUP): attende che l'URL risponda col codice atteso.
wait_code() {
  local c
  for _ in {1..40}; do
    c="$(code_of "$1" "$2")"
    [[ "$c" == "$3" ]] && return 0
    sleep 0.25
  done
  return 1
}
want() { # PERCORSO "utente:gruppo modo"
  local got
  got="$(stat -c '%U:%G %a' "$1")"
  [[ "$got" == "$2" ]] || fail "$1: atteso $2, trovato $got"
}

echo "== WP-CLI e Redis con ACL dalle librerie"
vlib wpcli_install || fail "wpcli_install"
[[ -x "$WP_BIN" ]] || fail "WP-CLI non installato in $WP_BIN"
vlib redis_acl_setup || fail "redis_acl_setup: $(tail -n 5 "$VPS_LOG")"
[[ "$(jq -r '.components.redis_acl' "$VPS_OPT/manifest.json")" == true ]] || fail "components.redis_acl non impostato"
grep -qxF "aclfile $REDIS_ACL_FILE" "$REDIS_CONF" || fail "aclfile non in redis.conf"
# Seconda esecuzione: idempotente, niente riavvio, solo ACL LOAD.
vlib redis_acl_setup || fail "redis_acl_setup (seconda volta)"
[[ "$(grep -c '^aclfile ' "$REDIS_CONF")" == 1 ]] || fail "aclfile ripetuto in redis.conf"
# Cache limitata: se il redis.conf di WSL non ha maxmemory lo aggiunge la prima volta.
if ! grep -qE '^[[:space:]]*maxmemory[[:space:]]' "$REDIS_BAK"; then
  [[ "$(grep -cx 'maxmemory 256mb' "$REDIS_CONF")" == 1 ]] || fail "maxmemory 256mb non aggiunto una volta sola"
  mm="$(REDISCLI_AUTH="$(head -n 1 "$REDIS_ADMIN_SECRET")" redis-cli --no-auth-warning --user vps-admin CONFIG GET maxmemory-policy | tail -n 1)"
  echo "   maxmemory-policy: $mm"
  [[ "$mm" == allkeys-lru ]] || fail "maxmemory-policy: $mm"
fi

echo "== crea $D1 (WordPress)"
s1="site_${D1//./_}"
r1="$SITES_WWW/$D1"
res="$(printf '%s\n%s\n' "$DBPASS" "$WPPASS" | vs create "$D1" --type wordpress --title "Blog di prova" \
  --admin-user gestore --admin-email io@e2etest.it --login-path "$LOGIN1")" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "create $D1: $res"
st="$(vs show "$D1")"
[[ "$(jq -r .site.state <<<"$st")" == active ]] || fail "$D1 non attivo: $(jq -c .site.job <<<"$st"); log: $(tail -n 20 "$VPS_LOG")"
[[ "$(jq -r .site.type <<<"$st")" == wordpress ]] || fail "$D1 non è wordpress: $st"
[[ "$(jq -r .site.wordpress.login_path <<<"$st")" == "$LOGIN1" ]] || fail "login_path nel registro: $st"
[[ "$(jq -r .site.placeholder <<<"$st")" == false ]] || fail "placeholder dovrebbe essere false: $st"
[[ "$(vs list | jq -r --arg d "$D1" '.sites[] | select(.domain == $d) | .wordpress.login_path')" == "$LOGIN1" ]] \
  || fail "list senza wordpress.login_path"
[[ ! -e "$SITES_RUN/$s1.wppass" && ! -e "$SITES_RUN/$s1.wpargs" ]] || fail "file di passaggio di WordPress rimasti"

echo "== percorso di login, wp-login.php, xmlrpc.php"
wait_code "$D1" "/$LOGIN1/" 200 || fail "login su /$LOGIN1/: $(code_of "$D1" "/$LOGIN1/")"
[[ "$(get "$D1" "/$LOGIN1/")" == *user_login* ]] || fail "il login su /$LOGIN1/ non ha il modulo"
c="$(code_of "$D1" /wp-login.php)"
[[ "$c" == 404 ]] || fail "/wp-login.php: atteso 404, trovato $(get "$D1" /wp-login.php -o /dev/null -w '%{http_code} %{redirect_url}')"
c="$(code_of "$D1" /xmlrpc.php)"
[[ "$c" == 403 ]] || fail "/xmlrpc.php: atteso 403, trovato $c"
# Intestazioni del vhost WordPress: SAMEORIGIN (Customizer), mai DENY; file statici con cache.
hdr="$(get "$D1" / -D - -o /dev/null)"
[[ "$hdr" == *"x-frame-options: SAMEORIGIN"* && "$hdr" != *DENY* ]] || fail "X-Frame-Options del sito WordPress: $(grep -i x-frame <<<"$hdr")"
shdr="$(get "$D1" /wp-includes/css/dashicons.min.css -D - -o /dev/null)"
[[ "$shdr" == *"HTTP/2 200"* && "$shdr" == *"cache-control: max-age=2592000"* ]] || fail "file statico senza cache: $shdr"
# /wp-admin/ senza sessione: WPS Hide Login rimanda a /404; alla fine dei
# redirect deve esserci un 404, senza mai passare dal percorso di login.
wpadmin="$(get "$D1" /wp-admin/ -o /dev/null -w '%{http_code} %{redirect_url}')"
fine="$(get "$D1" /wp-admin/ -L --max-redirs 5 -o /dev/null -w '%{http_code} %{url_effective}')"
echo "   /wp-admin/ (non autenticato): $wpadmin -> $fine"
[[ "$wpadmin $fine" != *"$LOGIN1"* && "$wpadmin $fine" != *wp-login* ]] || fail "/wp-admin/ rivela il percorso di login: $wpadmin -> $fine"
[[ "$fine" == "404 "* ]] || fail "/wp-admin/ non finisce in un 404: $wpadmin -> $fine"
c="$(code_of "$D1" /)"
[[ "$c" == 200 ]] || fail "home di $D1: $c"

echo "== niente PHP in uploads/"
sudo -u "$s1" sh -c "umask 002 && mkdir -p '$r1/public/wp-content/uploads' && echo '<?php echo 1;' >'$r1/public/wp-content/uploads/x.php'" \
  || fail "il sito non scrive in uploads/"
c="$(code_of "$D1" /wp-content/uploads/x.php)"
[[ "$c" == 403 ]] || fail "/wp-content/uploads/x.php: atteso 403, trovato $c"

echo "== Redis: cache del sito e isolamento"
out="$(vlib site_wp "$D1" redis status 2>&1)" || true
grep -q 'Status: Connected' <<<"$out" || fail "redis status: $out"
grep -q 'Drop-in: Valid' <<<"$out" || fail "drop-in di Redis non valido: $out"
echo "   $(grep -E '^(Client|Drop-in):' <<<"$out" | tr '\n' ' ')"
out="$(redis-cli PING 2>&1)" || true
echo "   default senza credenziali: $out"
[[ "$out" == *NOAUTH* || "$out" == *"uthentication"* || "$out" == *WRONGPASS* ]] || fail "Redis risponde a default senza credenziali: $out"
rpw="$(sed -n "s/^define( 'WP_REDIS_PASSWORD', '\(.*\)' );$/\1/p" "$r1/wp-config.php")"
[[ -n "$rpw" ]] || fail "password Redis non trovata in wp-config.php"
# redis-cli può uscire con 1 su una risposta di errore: conta il testo, non il codice.
rs() { REDISCLI_AUTH="$rpw" redis-cli --no-auth-warning --user "$s1" "$@" 2>&1 || true; }
[[ "$(rs SET "$s1:e2e" 1)" == OK ]] || fail "SET sul proprio prefisso"
[[ "$(rs GET "$s1:e2e")" == 1 ]] || fail "GET sul proprio prefisso"
out="$(rs SET altro:x 1)"
[[ "$out" == *NOPERM* ]] || fail "SET altro:x non rifiutato: $out"
out="$(rs GET site_altro_sito:x)"
[[ "$out" == *NOPERM* ]] || fail "GET di un altro sito non rifiutato: $out"
out="$(rs KEYS 'altro:*')"
echo "   KEYS altro:* come sito: ${out:-<vuoto>}"
[[ -z "$out" || "$out" == *NOPERM* ]] || fail "KEYS altro:* restituisce chiavi: $out"
# Comandi @dangerous/@admin (DEBUG no: Redis lo rifiuta comunque, con ERR).
# SCRIPT KILL/FLUSH e FUNCTION agiscono su tutto Redis: tolti anche quelli.
for cmd in "FLUSHALL" "FLUSHDB" "CONFIG GET maxmemory" "ACL LIST" "CLIENT LIST" "SCRIPT FLUSH" "SCRIPT KILL" "FUNCTION FLUSH" "FUNCTION LIST"; do
  # shellcheck disable=SC2086
  out="$(rs $cmd)"
  [[ "$out" == *NOPERM* ]] || fail "$cmd non rifiutato al sito: $out"
done
rs DEL "$s1:e2e" >/dev/null
apw="$(head -n 1 "$REDIS_ADMIN_SECRET")"
# admin_keys PREFISSO — le chiavi di un prefisso, viste da vps-admin (vede tutto).
admin_keys() { REDISCLI_AUTH="$apw" redis-cli --no-auth-warning --user vps-admin --scan --pattern "$1:*" 2>&1 || true; }
# Il drop-in scrive davvero sotto il prefisso del sito: dopo una pagina servita
# la cache non è vuota (ed è ciò che site_redis_purge dovrà togliere).
c="$(code_of "$D1" /)"
[[ "$c" == 200 ]] || fail "home di $D1 prima del controllo della cache: $c"
n="$(admin_keys "$s1" | grep -c . || true)"
echo "   chiavi sotto $s1:* dopo una pagina: $n"
((n > 0)) || fail "nessuna chiave sotto $s1:*: il drop-in non scrive nella cache del sito"
# Moduli (Redis 8 può averne di integrati): rispettano i pattern delle chiavi?
# Solo esplorazione per il report: un modulo assente non è un errore.
mods="$(REDISCLI_AUTH="$apw" redis-cli --no-auth-warning --user vps-admin MODULE LIST 2>&1)" || true
echo "   MODULE LIST: $(tr '\n' ' ' <<<"${mods:-<nessun modulo>}")"
# vectorset è integrato in Redis 8: deve rispettare il prefisso come ogni tipo.
out="$(rs VADD altro:v VALUES 2 0.1 0.2 e1)"
echo "   modulo vectorset: VADD altro:v -> $out"
if [[ "$mods" == *vectorset* ]]; then
  [[ "$out" == *NOPERM* ]] || fail "VADD su un prefisso altrui non rifiutato: $out"
  out="$(rs VADD "$s1:v" VALUES 2 0.1 0.2 e1)"
  echo "   modulo vectorset: VADD $s1:v -> $out"
  [[ "$out" == 1 ]] || fail "VADD sul proprio prefisso: $out"
  rs DEL "$s1:v" >/dev/null
fi
for probe in "JSON.SET altro:j \$ {}" "JSON.SET $s1:j \$ {}" "FT._LIST" \
  "FT.CREATE e2eidx ON HASH PREFIX 1 altro: SCHEMA t TEXT" "BF.ADD altro:bf x" "TS.CREATE altro:ts"; do
  # shellcheck disable=SC2086
  out="$(rs $probe | head -n 1)" || true
  echo "   modulo? $probe -> $out"
done

echo "== wp-config.php e cron"
want "$r1/wp-config.php" "root:$s1 640"
sudo -u "$s1" sh -c "echo x >>'$r1/wp-config.php'" 2>/dev/null && fail "il sito non deve poter scrivere wp-config.php"
cronf="$CRON_D/vps-site-$s1"
[[ -f "$cronf" ]] || fail "cron di $D1 mancante"
grep -q "^\*/5 \* \* \* \* $s1 $WP_BIN --path=$r1/public cron event run --due-now" "$cronf" || fail "cron di $D1: $(cat "$cronf")"
vlib site_wp "$D1" cron event run --due-now >/dev/null 2>&1 || fail "il comando del cron non gira come $s1"
grep -q "^user $s1 on " "$REDIS_ACL_FILE" || fail "utente Redis di $D1 non nel file ACL"

echo "== $D2: sito PHP con DB, poi wp-install"
s2="site_${D2//./_}"
r2="$SITES_WWW/$D2"
res="$(printf '%s\n' "$DBPASS" | vs create "$D2" --type php --db)" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "create $D2: $res"
st="$(vs show "$D2")"
[[ "$(jq -r .site.state <<<"$st")" == active ]] || fail "$D2 non attivo: $(jq -c .site.job <<<"$st")"
[[ "$(jq -r .site.placeholder <<<"$st")" == true ]] || fail "$D2 dovrebbe avere il segnaposto intatto"
res="$(printf '%s\n' "$WPPASS" | vs wp-install "$D2" --title "Sito vuoto" --admin-user gestore2 \
  --admin-email io2@e2etest.it --login-path "$LOGIN2")" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "wp-install $D2: $res"
st="$(vs show "$D2")"
[[ "$(jq -r .site.state <<<"$st")" == active ]] || fail "$D2 non attivo dopo wp-install: $(jq -c .site.job <<<"$st"); log: $(tail -n 20 "$VPS_LOG")"
[[ "$(jq -r .site.type <<<"$st")" == wordpress ]] || fail "$D2 non è wordpress: $st"
[[ "$(jq -r .site.job.step <<<"$st")" == "done" ]] || fail "lavoro wpinstall non concluso: $st"
wait_code "$D2" "/$LOGIN2/" 200 || fail "login su /$LOGIN2/: $(code_of "$D2" "/$LOGIN2/")"
[[ "$(get "$D2" "/$LOGIN2/")" == *user_login* ]] || fail "il login su /$LOGIN2/ non ha il modulo"
c="$(code_of "$D2" /wp-login.php)"
[[ "$c" == 404 ]] || fail "/wp-login.php di $D2: atteso 404, trovato $c"
want "$r2/wp-config.php" "root:$s2 640"
[[ -f "$CRON_D/vps-site-$s2" ]] || fail "cron di $D2 mancante"
out="$(vlib site_wp "$D2" redis status 2>&1)" || true
grep -q 'Status: Connected' <<<"$out" || fail "redis status di $D2: $out"
# I due siti non si vedono: l'utente di D1 non legge le chiavi di D2.
out="$(rs GET "$s2:x")"
[[ "$out" == *NOPERM* ]] || fail "$s1 legge le chiavi di $s2: $out"
# wp-install su un sito che è già WordPress: rifiutato.
res="$(printf '%s\n' "$WPPASS" | vs wp-install "$D2" --title "X" --admin-user gestore2 \
  --admin-email io2@e2etest.it --login-path "$LOGIN2")" || true
jq -e '.ok == false' <<<"$res" >/dev/null || fail "wp-install ripetuto non rifiutato: $res"

echo "== db-password su $D1"
res="$(printf '%s\n' "$DBPASS2" | vs db-password "$D1")" || true
jq -e '.ok' <<<"$res" >/dev/null || fail "db-password $D1: $res"
grep -qF "define( 'DB_PASSWORD', '$DBPASS2' );" "$r1/wp-config.php" || fail "wp-config.php non aggiornato"
want "$r1/wp-config.php" "root:$s1 640"
mariadb -u "$s1" -p"$DBPASS2" -e 'SELECT 1' "$s1" >/dev/null || fail "login DB con la password nuova"
c="$(code_of "$D1" /)"
[[ "$c" == 200 ]] || fail "home di $D1 dopo db-password: $c"
wait_code "$D1" "/$LOGIN1/" 200 || fail "login di $D1 dopo db-password"

echo "== elimina"
vs delete "$D1" | jq -e '.ok' >/dev/null || fail "delete $D1"
vs delete "$D2" | jq -e '.ok' >/dev/null || fail "delete $D2"
[[ "$(vs list | jq '.sites | length')" == 0 ]] || fail "siti rimasti: $(vs list)"
grep -q '^user site_' "$REDIS_ACL_FILE" && fail "righe ACL dei siti rimaste: $(cat "$REDIS_ACL_FILE")"
grep -q '^user vps-admin ' "$REDIS_ACL_FILE" || fail "utente vps-admin sparito dal file ACL"
out="$(rs PING)"
[[ "$out" != PONG ]] || fail "l'utente Redis di $D1 funziona ancora"
[[ ! -e "$CRON_D/vps-site-$s1" && ! -e "$CRON_D/vps-site-$s2" ]] || fail "cron rimasti"
for d in "$D1" "$D2"; do
  ls "$SITES_BACKUPS/$d"-*.tar.gz >/dev/null || fail "archivio file di $d"
  ls "$SITES_BACKUPS/$d"-*.sql.gz >/dev/null || fail "dump di $d"
  [[ ! -e "$SITES_WWW/$d" ]] || fail "cartella di $d ancora presente"
  id "site_${d//./_}" >/dev/null 2>&1 && fail "utente di $d ancora presente"
  # site_redis_purge: un sito ricreato con lo stesso dominio non deve trovare la cache di questo.
  left="$(admin_keys "site_${d//./_}")"
  [[ -z "$left" ]] || fail "chiavi Redis di $d rimaste dopo l'eliminazione: $(head -n 5 <<<"$left")"
done
tarf="$(compgen -G "$SITES_BACKUPS/$D1-*.tar.gz" | head -n1)"
[[ "$(tar -tzf "$tarf")" == *"$D1/wp-config.php"* ]] || fail "wp-config.php non è nell'archivio"
sqlf="$(compgen -G "$SITES_BACKUPS/$D1-*.sql.gz" | head -n1)"
[[ "$(zcat "$sqlf")" == *wp_options* ]] || fail "il dump non contiene le tabelle di WordPress"

# Le password non finiscono mai nel registro degli strumenti.
for v in WPPASS DBPASS DBPASS2; do
  ! grep -qF -- "${!v}" "$VPS_LOG" \
    || fail "$v è finita in $VPS_LOG: $(grep -nF -- "${!v}" "$VPS_LOG" | sed "s/${!v}/<$v>/g" | head -n 3)"
done

echo "E2E WORDPRESS OK"
