bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
}

@test "fm_path_check accetta i percorsi validi e stampa l'area" {
  local p area
  while IFS='|' read -r p area; do
    run fm_path_check "$p"
    [ "$status" -eq 0 ]
    [ "$output" = "$area" ]
  done <<'LISTA'
public|public
public/a b/c'd.php|public
public/-x|public
public/è.txt|public
public/.htaccess|public
logs|logs
logs/access.log|logs
logs/php|logsphp
logs/php/error.log|logsphp
wp-config.php|wpconfig
|root
LISTA
}

@test "fm_path_check rifiuta i percorsi non ammessi" {
  local p long
  for p in /etc/passwd /public public/../x public/./x ../x . .. public/.. tmp tmp/x public// public/ public/a//b \
    config.php wp-config.php/x logs/a/b logs/a/b/c logsx logs/../public wp-config.phpx PUBLIC/x $'public/a\nb' $'public/a\tb' $'public/a\x7fb' $'public/a\rb'; do
    run fm_path_check "$p"
    [ "$status" -eq 1 ] || { echo "accettato: $p"; false; }
  done
  # nome di 255 byte sì, 256 no (byte, non caratteri: "è" ne pesa 2)
  long="$(printf 'a%.0s' {1..255})"
  run fm_path_check "public/$long"
  [ "$status" -eq 0 ]
  run fm_path_check "public/${long}a"
  [ "$status" -eq 1 ]
  long="$(printf 'è%.0s' {1..128})"
  run fm_path_check "public/$long"
  [ "$status" -eq 1 ]
  long="$(printf 'è%.0s' {1..127})"
  run fm_path_check "public/$long"
  [ "$status" -eq 0 ]
}

@test "fm_path_check: limite di 4096 byte sul percorso intero" {
  local seg p
  seg="$(printf 'a%.0s' {1..200})"
  p="public"
  while ((${#p} + 201 <= 4096)); do p+="/$seg"; done
  p+="/"
  while ((${#p} < 4096)); do p+="b"; done
  [ "${#p}" -eq 4096 ]
  run fm_path_check "$p"
  [ "$status" -eq 0 ]
  run fm_path_check "${p}b"
  [ "$status" -eq 1 ]
}

@test "fm_writable: solo sotto public/, non public stesso" {
  run fm_writable public/x
  [ "$status" -eq 0 ]
  run fm_writable public/a/b
  [ "$status" -eq 0 ]
  for p in public logs/x logs logs/php/x wp-config.php "" tmp/x /etc/x public/../x; do
    run fm_writable "$p"
    [ "$status" -eq 1 ] || { echo "scrivibile: $p"; false; }
  done
}

@test "fm_site_check: sito attivo o disattivato, altro errore" {
  site_reg_new blog.miosito.it php no no
  run fm_site_check blog.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"stato"* ]]
  site_reg_update blog.miosito.it '.state = "active"'
  run fm_site_check blog.miosito.it
  [ "$status" -eq 0 ]
  [ "$output" = "site_blog_miosito_it $SITES_WWW/blog.miosito.it" ]
  site_reg_update blog.miosito.it '.state = "disabled"'
  run fm_site_check blog.miosito.it
  [ "$status" -eq 0 ]
  for s in creating deleting error installing; do
    site_reg_update blog.miosito.it '.state = $s' --arg s "$s"
    run fm_site_check blog.miosito.it
    [ "$status" -eq 1 ]
  done
}

@test "fm_site_check: sito inesistente o dominio non valido" {
  run fm_site_check altro.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"non trovato"* ]]
  for d in "" "../x" "a/b.it" "Blog.it" $'a.it\nb'; do
    run fm_site_check "$d"
    [ "$status" -eq 1 ]
  done
}

@test "fm_as_site: runuser con utente del sito, env -i, PATH fisso, cartella e umask" {
  local root="$BATS_TEST_TMPDIR/radice"
  mkdir -p "$root/tmp"
  cat >"$BATS_TEST_TMPDIR/runuser-fm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/args"
shift 3
exec "$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/runuser-fm"
  FM_RUNUSER="$BATS_TEST_TMPDIR/runuser-fm"
  run fm_as_site site_x "$root" sh -c 'pwd; umask; printf "%s|%s|%s\n" "$PATH" "$HOME" "$LC_ALL"; env | wc -l'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$root" ]
  [ "${lines[1]}" = "0002" ]
  [ "${lines[2]}" = "/usr/bin:/bin|$root/tmp|C" ]
  [ "${lines[3]}" -le 5 ]
  [ "$(sed -n 1,2p "$BATS_TEST_TMPDIR/args" | paste -sd' ')" = "-u site_x" ]
  [ "$(sed -n 3,4p "$BATS_TEST_TMPDIR/args" | paste -sd' ')" = "-- env" ]
  grep -qx -- '-i' "$BATS_TEST_TMPDIR/args"
  grep -qx 'PATH=/usr/bin:/bin' "$BATS_TEST_TMPDIR/args"
}

@test "fm_as_site: stdin e stdout passano, il codice d'uscita torna indietro" {
  local root="$BATS_TEST_TMPDIR/radice"
  mkdir -p "$root"
  FM_RUNUSER=runuser
  out="$(printf 'ciao\n' | fm_as_site site_x "$root" cat)"
  [ "$out" = ciao ]
  rc=0
  fm_as_site site_x "$root" sh -c 'exit 7' || rc=$?
  [ "$rc" -eq 7 ]
  grep -q '^runuser -u site_x' "$CALLS"
}

@test "fm_as_site: argomenti con spazi, apostrofi e - iniziale restano interi" {
  local root="$BATS_TEST_TMPDIR/radice"
  mkdir -p "$root"
  FM_RUNUSER=runuser
  out="$(fm_as_site site_x "$root" printf '%s\n' "a b" "c'd" -x)"
  [ "$out" = "$(printf 'a b\nc'"'"'d\n-x')" ]
}

@test "fm_as_site: rifiuta slug o radice non validi" {
  run fm_as_site "" /tmp true
  [ "$status" -ne 0 ]
  run fm_as_site root /tmp true
  [ "$status" -ne 0 ]
  run fm_as_site site_x /nonesiste/zzz true
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------- vps-files

mk_fm_site() {
  site_reg_new blog.miosito.it php no no
  site_reg_update blog.miosito.it '.state = "active"'
  R="$SITES_WWW/blog.miosito.it"
  mkdir -p "$R/public" "$R/logs/php" "$R/tmp"
  SECRET="$BATS_TEST_TMPDIR/segreto"
  printf 'SEGRETO-ALTRO-SITO\n' >"$SECRET"
}

# vf ARGOMENTI... — vps-files con stderr scartato (bats lo mescolerebbe al JSON).
vf() { bash "$REPO_ROOT/tools/vps-files" "$@" 2>/dev/null; }

# nessuna chiamata a runuser registrata: root ha fatto tutto da sé
no_runuser() { [ ! -s "$CALLS" ] || ! grep -q '^runuser' "$CALLS"; }

@test "fm_path_check: sotto logs/ solo voci dirette, logs/php e sotto ammessi" {
  run fm_path_check logs/a/b
  [ "$status" -eq 1 ]
  run fm_path_check logs/a/b/c
  [ "$status" -eq 1 ]
  run fm_path_check logs/php/a/b
  [ "$status" -eq 0 ]
  [ "$output" = logsphp ]
  run fm_path_check logs/file.log
  [ "$output" = logs ]
}

@test "vps-files list public: tipi giusti, link non seguito" {
  mk_fm_site
  printf 'ciao' >"$R/public/a.txt"
  mkdir "$R/public/cartella"
  ln -s "$SECRET" "$R/public/collegamento"
  run vf list blog.miosito.it public
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
  [ "$(jq -r .path <<<"$output")" = public ]
  [ "$(jq -r .writable <<<"$output")" = true ]
  [ "$(jq -r '.entries | length' <<<"$output")" -eq 3 ]
  [ "$(jq -r '.entries[] | select(.name=="a.txt") | .type' <<<"$output")" = file ]
  [ "$(jq -r '.entries[] | select(.name=="a.txt") | .size' <<<"$output")" = 4 ]
  [ "$(jq -r '.entries[] | select(.name=="cartella") | .type' <<<"$output")" = dir ]
  [ "$(jq -r '.entries[] | select(.name=="collegamento") | .type' <<<"$output")" = link ]
  # dimensione del link = lunghezza del percorso di destinazione, non del file
  [ "$(jq -r '.entries[] | select(.name=="collegamento") | .size' <<<"$output")" = "${#SECRET}" ]
  [[ "$(jq -r '.entries[] | select(.name=="a.txt") | .perms' <<<"$output")" == -rw* ]]
  [[ "$(jq -r '.entries[] | select(.name=="a.txt") | .mtime' <<<"$output")" =~ ^[0-9]+\.[0-9]{9}$ ]]
  [[ "$output" != *SEGRETO* ]]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files list: sottocartella, un link a cartella non si apre" {
  mk_fm_site
  mkdir -p "$R/public/d" "$BATS_TEST_TMPDIR/fuori"
  : >"$BATS_TEST_TMPDIR/fuori/dentro"
  : >"$R/public/d/x"
  : >"$R/public/a.txt"
  ln -s "$BATS_TEST_TMPDIR/fuori" "$R/public/lnk"
  run vf list blog.miosito.it public/d
  [ "$(jq -r '.entries[0].name' <<<"$output")" = x ]
  [ "$(jq -r .path <<<"$output")" = public/d ]
  for p in public/lnk public/a.txt public/nonesiste; do
    run vf list blog.miosito.it "$p"
    [ "$status" -eq 1 ] || { echo "accettato: $p"; false; }
    [ "$(jq -r .ok <<<"$output")" = false ]
  done
}

@test "vps-files list radice: voci virtuali public, logs e wp-config.php" {
  mk_fm_site
  run vf list blog.miosito.it ''
  [ "$status" -eq 0 ]
  [ "$(jq -r .writable <<<"$output")" = false ]
  [ "$(jq -r '[.entries[].name] | join(",")' <<<"$output")" = "logs,public" ]
  printf '<?php\n' >"$R/wp-config.php"
  printf 'altro' >"$R/config.php"
  run vf list blog.miosito.it ''
  [ "$(jq -r '[.entries[].name] | sort | join(",")' <<<"$output")" = "logs,public,wp-config.php" ]
  [ "$(jq -r '.entries[] | select(.name=="public") | .type' <<<"$output")" = dir ]
  [ "$(jq -r '.entries[] | select(.name=="logs") | .type' <<<"$output")" = dir ]
  [ "$(jq -r '.entries[] | select(.name=="wp-config.php") | .type' <<<"$output")" = file ]
  # public e logs ci sono sempre, anche se la cartella manca
  rm -r "${R:?}/logs" "${R:?}/public" "${R:?}/wp-config.php"
  run vf list blog.miosito.it ''
  [ "$(jq -r '[.entries[].name] | sort | join(",")' <<<"$output")" = "logs,public" ]
}

@test "vps-files list: aree e siti non ammessi" {
  mk_fm_site
  for p in tmp tmp/x config.php /etc public/../x public/ logs/a/b $'public/a\nb'; do
    run vf list blog.miosito.it "$p"
    [ "$status" -eq 1 ] || { echo "accettato: $p"; false; }
    [ "$(jq -r .ok <<<"$output")" = false ]
  done
  run vf list altro.miosito.it public
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"non trovato"* ]]
  run vf list blog.miosito.it
  [ "$status" -eq 1 ]
  run vf boh blog.miosito.it public
  [ "$status" -eq 1 ]
  site_reg_update blog.miosito.it '.state = "creating"'
  run vf list blog.miosito.it public
  [ "$status" -eq 1 ]
}

@test "vps-files list logs: voci dirette come root, logs/php come utente del sito" {
  mk_fm_site
  printf 'riga\n' >"$R/logs/access.log"
  ln -s "$SECRET" "$R/logs/collegamento"
  run vf list blog.miosito.it logs
  [ "$status" -eq 0 ]
  [ "$(jq -r .writable <<<"$output")" = false ]
  [ "$(jq -r '[.entries[].name] | sort | join(",")' <<<"$output")" = "access.log,collegamento,php" ]
  [ "$(jq -r '.entries[] | select(.name=="collegamento") | .type' <<<"$output")" = link ]
  no_runuser
  : >"$R/logs/php/error.log"
  run vf list blog.miosito.it logs/php
  [ "$(jq -r '.entries[0].name' <<<"$output")" = error.log ]
  [ "$(jq -r .writable <<<"$output")" = false ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
  # una sottocartella di logs/ diversa da php non si apre (come root)
  mkdir "$R/logs/altra"
  run vf list blog.miosito.it logs/altra
  [ "$status" -eq 1 ]
}

@test "vps-files list: nomi con spazi, apostrofi, - iniziale, a capo, unicode e byte non UTF-8" {
  mk_fm_site
  : >"$R/public/a b"
  : >"$R/public/c'd"
  : >"$R/public/-x"
  : >"$R/public/è.txt"
  : >"$R/public/$(printf 'riga\nnuova')"
  : >"$R/public/$(printf 'rot\377to')"
  run vf list blog.miosito.it public
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.entries | length' <<<"$output")" -eq 6 ]
  jq -e '.entries[] | select(.name == "a b")' <<<"$output" >/dev/null
  jq -e '.entries[] | select(.name == "c'"'"'d")' <<<"$output" >/dev/null
  jq -e '.entries[] | select(.name == "-x")' <<<"$output" >/dev/null
  jq -e '.entries[] | select(.name == "è.txt")' <<<"$output" >/dev/null
  jq -e '.entries[] | select(.name == "riga\nnuova")' <<<"$output" >/dev/null
}

@test "vps-files read: contenuto identico byte per byte, nome con - iniziale" {
  mk_fm_site
  printf 'a\r\n\xef\xbb\xbfb\0c' >"$R/public/-x"
  run bash -c "bash '$REPO_ROOT/tools/vps-files' read blog.miosito.it public/-x 2>/dev/null | od -An -tx1 | tr -d ' \n'"
  [ "$status" -eq 0 ]
  [ "$output" = "610d0aefbbbf620063" ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files read: un link non si legge, la destinazione non compare mai" {
  mk_fm_site
  ln -s "$SECRET" "$R/public/collegamento"
  run bash -c "bash '$REPO_ROOT/tools/vps-files' read blog.miosito.it public/collegamento 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" != *SEGRETO* ]]
  [ "$(jq -r .ok <<<"$output")" = false ]
  for p in public public/nonesiste '' tmp/x; do
    run vf read blog.miosito.it "$p"
    [ "$status" -eq 1 ] || { echo "letto: $p"; false; }
    [ "$(jq -r .ok <<<"$output")" = false ]
  done
}

@test "vps-files read logs: file diretto come root, link rifiutato, logs/php come utente del sito" {
  mk_fm_site
  printf 'GET /\n' >"$R/logs/access.log"
  ln -s "$SECRET" "$R/logs/collegamento"
  mkdir "$R/logs/cartella"
  run vf read blog.miosito.it logs/access.log
  [ "$status" -eq 0 ]
  [ "$output" = "GET /" ]
  no_runuser
  run bash -c "bash '$REPO_ROOT/tools/vps-files' read blog.miosito.it logs/collegamento 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" != *SEGRETO* ]]
  run vf read blog.miosito.it logs/cartella
  [ "$status" -eq 1 ]
  run vf read blog.miosito.it logs/a/b
  [ "$status" -eq 1 ]
  printf 'errore\n' >"$R/logs/php/error.log"
  run vf read blog.miosito.it logs/php/error.log
  [ "$output" = errore ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files read wp-config.php: come utente del sito" {
  mk_fm_site
  printf '<?php // config\n' >"$R/wp-config.php"
  run vf read blog.miosito.it wp-config.php
  [ "$status" -eq 0 ]
  [ "$output" = "<?php // config" ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files stat: tipo, dimensione, data e testo" {
  mk_fm_site
  printf 'ciao è\n' >"$R/public/t.txt"
  run vf stat blog.miosito.it public/t.txt
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
  [ "$(jq -r .type <<<"$output")" = file ]
  [ "$(jq -r .size <<<"$output")" = 8 ]
  [ "$(jq -r .text <<<"$output")" = true ]
  [ "$(jq -r .mtime <<<"$output")" = "$(stat -c %.9Y "$R/public/t.txt")" ]
  : >"$R/public/vuoto"
  run vf stat blog.miosito.it public/vuoto
  [ "$(jq -r .text <<<"$output")" = true ]
  mkdir "$R/public/d"
  run vf stat blog.miosito.it public/d
  [ "$(jq -r .type <<<"$output")" = dir ]
  [ "$(jq -r .text <<<"$output")" = false ]
  ln -s "$SECRET" "$R/public/lnk"
  run vf stat blog.miosito.it public/lnk
  [ "$(jq -r .type <<<"$output")" = link ]
  [ "$(jq -r .text <<<"$output")" = false ]
  run vf stat blog.miosito.it public/nonesiste
  [ "$status" -eq 1 ]
  run vf stat blog.miosito.it ''
  [ "$(jq -r .type <<<"$output")" = dir ]
}

@test "vps-files stat: NUL, UTF-8 non valido e oltre 2 MB non sono testo" {
  mk_fm_site
  printf 'ab\0cd' >"$R/public/nul"
  printf 'ab\377cd' >"$R/public/latin"
  head -c 2097152 /dev/zero | tr '\0' a >"$R/public/giusto"
  head -c 2097153 /dev/zero | tr '\0' a >"$R/public/grande"
  { head -c 9000 /dev/zero | tr '\0' a; printf 'x\0y'; } >"$R/public/nul-tardi"
  for f in nul latin grande; do
    run vf stat blog.miosito.it "public/$f"
    [ "$status" -eq 0 ]
    [ "$(jq -r .text <<<"$output")" = false ] || { echo "testo: $f"; false; }
  done
  run vf stat blog.miosito.it public/giusto
  [ "$(jq -r .text <<<"$output")" = true ]
  [ "$(jq -r .size <<<"$output")" = 2097152 ]
  # il NUL dopo i primi 8 KB non conta
  run vf stat blog.miosito.it public/nul-tardi
  [ "$(jq -r .size <<<"$output")" = 9003 ]
  [ "$(jq -r .text <<<"$output")" = true ]
}

@test "vps-files stat logs e wp-config.php" {
  mk_fm_site
  printf 'riga\n' >"$R/logs/access.log"
  ln -s "$SECRET" "$R/logs/lnk"
  printf '<?php\n' >"$R/wp-config.php"
  run vf stat blog.miosito.it logs/access.log
  [ "$(jq -r .text <<<"$output")" = true ]
  [ "$(jq -r .size <<<"$output")" = 5 ]
  run vf stat blog.miosito.it logs/lnk
  [ "$(jq -r .type <<<"$output")" = link ]
  [ "$(jq -r .text <<<"$output")" = false ]
  no_runuser
  run vf stat blog.miosito.it wp-config.php
  [ "$(jq -r .text <<<"$output")" = true ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

# ------------------------------------------------- rinforzi (revisione Task 2)

@test "vps-files list/stat: fifo e socket sono type other, read li rifiuta" {
  mk_fm_site
  mkfifo "$R/public/coda"
  run timeout 20 bash "$REPO_ROOT/tools/vps-files" list blog.miosito.it public
  [ "$status" -eq 0 ]
  [ "$(jq -r '.entries[] | select(.name=="coda") | .type' <<<"$output" 2>/dev/null)" = other ]
  run timeout 20 bash "$REPO_ROOT/tools/vps-files" stat blog.miosito.it public/coda
  [ "$(jq -r .type <<<"$output" 2>/dev/null)" = other ]
  [ "$(jq -r .text <<<"$output" 2>/dev/null)" = false ]
  run timeout 20 bash "$REPO_ROOT/tools/vps-files" read blog.miosito.it public/coda
  [ "$status" -eq 1 ]
}

@test "vps-files: letture come utente del sito sotto timeout (10 s testo, 120 s read)" {
  mk_fm_site
  printf 'ciao\n' >"$R/public/t.txt"
  make_stub timeout 'echo "timeout $1" >>"$CALLS"; shift; exec "$@"'
  run vf stat blog.miosito.it public/t.txt
  [ "$(jq -r .text <<<"$output")" = true ]
  grep -qx 'timeout 10' "$CALLS"
  run vf read blog.miosito.it public/t.txt
  [ "$output" = ciao ]
  grep -qx 'timeout 120' "$CALLS"
}

@test "vps-files list: oltre 10.000 voci taglia e segnala truncated" {
  mk_fm_site
  mkdir "$R/public/molti"
  (cd "$R/public/molti" && seq 1 10001 | xargs touch)
  run vf list blog.miosito.it public/molti
  [ "$status" -eq 0 ]
  [ "$(jq -r '.entries | length' <<<"$output")" -eq 10000 ]
  [ "$(jq -r .truncated <<<"$output")" = true ]
  rm "$R/public/molti/10001"
  run vf list blog.miosito.it public/molti
  [ "$(jq -r '.entries | length' <<<"$output")" -eq 10000 ]
  [ "$(jq -r .truncated <<<"$output")" = false ]
}

@test "vps-files list: cartella non leggibile dal sito -> errore, non lista vuota" {
  mk_fm_site
  mkdir "$R/public/chiusa"
  : >"$R/public/chiusa/x"
  chmod -R a+rwX "$BATS_TEST_TMPDIR"
  chmod a+x "$BATS_TEST_TMPDIR" /tmp 2>/dev/null || true
  cat >"$BATS_TEST_TMPDIR/runuser-nobody" <<'STUB'
#!/usr/bin/env bash
shift 3
while [[ "$1" == env || "$1" == -i || "$1" == *=* ]]; do shift; done
exec /usr/sbin/runuser -u nobody -- "$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/runuser-nobody"
  chmod 000 "$R/public/chiusa"
  FM_RUNUSER="$BATS_TEST_TMPDIR/runuser-nobody" run vf list blog.miosito.it public/chiusa
  chmod 755 "$R/public/chiusa"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"non leggibile"* ]]
}

@test "vps-files: nomi non UTF-8 elencati con raw false, ogni comando li rifiuta" {
  mk_fm_site
  : >"$R/public/ok"
  : >"$R/public/$(printf 'rot\377to')"
  run vf list blog.miosito.it public
  [ "$(jq -r '.entries[] | select(.name=="ok") | .raw' <<<"$output")" = true ]
  [ "$(jq -r '[.entries[] | select(.raw == false)] | length' <<<"$output")" -eq 1 ]
  bad="public/$(printf 'rot\377to')"
  for c in list stat read mkdir write; do
    run vf "$c" blog.miosito.it "$bad" </dev/null
    [ "$status" -eq 1 ] || { echo "accettato: $c"; false; }
  done
  run vf delete blog.miosito.it -- "$bad"
  [ "$status" -eq 1 ]
  run vf rename blog.miosito.it public/ok "$(printf 'x\377')"
  [ "$status" -eq 1 ]
  [ -e "$R/public/$(printf 'rot\377to')" ]
}

# --------------------------------------------------------------- scritture

fsize() { stat -c %s "$1"; }

@test "vps-files write: file nuovo, byte per byte, risposta con mtime e size" {
  mk_fm_site
  printf '\xef\xbb\xbfa\r\nb\0c' >"$BATS_TEST_TMPDIR/in"
  run vf write blog.miosito.it "public/nuovo file" <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
  [ "$(jq -r .size <<<"$output")" = 9 ]
  [ "$(jq -r .mtime <<<"$output")" = "$(stat -c %.9Y "$R/public/nuovo file")" ]
  cmp "$BATS_TEST_TMPDIR/in" "$R/public/nuovo file"
  [ "$(stat -c %a "$R/public/nuovo file")" = 664 ]
  [ "$(ls -A "$R/public" | wc -l)" -eq 1 ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files write: file esistente senza --overwrite -> conflitto, file intatto" {
  mk_fm_site
  printf 'vecchio' >"$R/public/a.txt"
  run vf write blog.miosito.it public/a.txt <<<"nuovo"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "esiste già" ]
  [ "$(jq -r '.conflicts | join(",")' <<<"$output")" = public/a.txt ]
  [ "$(cat "$R/public/a.txt")" = vecchio ]
  printf 'nuovo' | vf write blog.miosito.it public/a.txt --overwrite >/dev/null
  [ "$(cat "$R/public/a.txt")" = nuovo ]
  [ "$(ls -A "$R/public" | wc -l)" -eq 1 ]
}

@test "vps-files write: --if-mtime/--if-size vecchi -> changed, file intatto" {
  mk_fm_site
  printf 'v1' >"$R/public/a.txt"
  m="$(stat -c %.9Y "$R/public/a.txt")"
  run vf write blog.miosito.it public/a.txt --overwrite --if-mtime 1000.000000000 --if-size 2 <<<"x"
  [ "$status" -eq 1 ]
  [ "$(jq -r .changed <<<"$output")" = true ]
  [ "$(jq -r .error <<<"$output")" = "il file è cambiato" ]
  run vf write blog.miosito.it public/a.txt --overwrite --if-mtime "$m" --if-size 99 <<<"x"
  [ "$(jq -r .changed <<<"$output")" = true ]
  [ "$(cat "$R/public/a.txt")" = v1 ]
  run vf write blog.miosito.it public/a.txt --if-mtime "$m" --if-size 2 <<<"v2"
  [ "$status" -eq 0 ]
  [ "$(cat "$R/public/a.txt")" = v2 ]
  # file sparito: cambiato
  rm "$R/public/a.txt"
  run vf write blog.miosito.it public/a.txt --if-mtime "$m" --if-size 2 <<<"v3"
  [ "$(jq -r .changed <<<"$output")" = true ]
  [ ! -e "$R/public/a.txt" ]
  [ "$(ls -A "$R/public" | wc -l)" -eq 0 ]
  # opzioni incomplete o malformate
  run vf write blog.miosito.it public/a.txt --if-mtime "$m" <<<"x"
  [ "$status" -eq 1 ]
  run vf write blog.miosito.it public/a.txt --if-mtime abc --if-size 1 <<<"x"
  [ "$status" -eq 1 ]
}

@test "vps-files write: 10 MB esatti sì, 10 MB + 1 no e nulla scritto" {
  mk_fm_site
  head -c 10485760 /dev/zero >"$BATS_TEST_TMPDIR/dieci"
  run vf write blog.miosito.it public/dieci <"$BATS_TEST_TMPDIR/dieci"
  [ "$status" -eq 0 ]
  [ "$(fsize "$R/public/dieci")" -eq 10485760 ]
  head -c 10485761 /dev/zero >"$BATS_TEST_TMPDIR/troppo"
  run vf write blog.miosito.it public/troppo <"$BATS_TEST_TMPDIR/troppo"
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -e "$R/public/troppo" ]
  run vf write blog.miosito.it public/dieci --overwrite <"$BATS_TEST_TMPDIR/troppo"
  [ "$status" -eq 1 ]
  [ "$(fsize "$R/public/dieci")" -eq 10485760 ]
  [ "$(ls -A "$R/public" | wc -l)" -eq 1 ]
}

@test "vps-files scritture: aree e destinazioni non ammesse" {
  mk_fm_site
  mkdir "$R/public/d"
  ln -s "$SECRET" "$R/public/lnk"
  ln -s "$BATS_TEST_TMPDIR" "$R/public/dlnk"
  printf 'x' >"$R/wp-config.php"
  for p in logs/x wp-config.php public tmp/x public/nonesiste/x public/dlnk/x public/lnk public/d; do
    run vf write blog.miosito.it "$p" --overwrite <<<"zzz"
    [ "$status" -eq 1 ] || { echo "write accettato: $p"; false; }
  done
  [ "$(cat "$R/wp-config.php")" = x ]
  [ "$(cat "$SECRET")" = SEGRETO-ALTRO-SITO ]
  [ ! -e "$BATS_TEST_TMPDIR/x" ]
  for p in logs/x wp-config.php public tmp/x public/nonesiste/x public/dlnk/x public/d; do
    run vf mkdir blog.miosito.it "$p"
    [ "$status" -eq 1 ] || { echo "mkdir accettato: $p"; false; }
  done
  run vf delete blog.miosito.it -- public/dlnk/x
  [ "$status" -eq 1 ]
  run vf rename blog.miosito.it wp-config.php altro
  [ "$status" -eq 1 ]
}

@test "vps-files mkdir: crea la cartella, esistente -> conflitto" {
  mk_fm_site
  run vf mkdir blog.miosito.it "public/nuova cartella"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ -d "$R/public/nuova cartella" ]
  [ "$(stat -c %a "$R/public/nuova cartella")" = 775 ]
  run vf mkdir blog.miosito.it "public/nuova cartella"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conflicts[0]' <<<"$output")" = "public/nuova cartella" ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files rename: apostrofo, spazi, - iniziale; con / o conflitto rifiutato" {
  mk_fm_site
  : >"$R/public/a b"
  : >"$R/public/altro"
  run vf rename blog.miosito.it "public/a b" "l'altro -x è"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ -e "$R/public/l'altro -x è" ]
  [ ! -e "$R/public/a b" ]
  for n in "x/y" "../x" ".." "." "" "$(printf 'a\nb')" "$(printf 'r\377')"; do
    run vf rename blog.miosito.it "public/altro" "$n"
    [ "$status" -eq 1 ] || { echo "accettato: $n"; false; }
  done
  [ -e "$R/public/altro" ]
  run vf rename blog.miosito.it "public/altro" "l'altro -x è"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conflicts[0]' <<<"$output")" = "public/l'altro -x è" ]
  run vf rename blog.miosito.it public/nonesiste nuovo
  [ "$status" -eq 1 ]
  mkdir "$R/public/d"
  : >"$R/public/d/f"
  run vf rename blog.miosito.it public/d/f g
  [ -e "$R/public/d/g" ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files move: un conflitto su due elementi -> nulla spostato" {
  mk_fm_site
  mkdir "$R/public/dest"
  : >"$R/public/a"
  : >"$R/public/b"
  : >"$R/public/dest/b"
  run vf move blog.miosito.it public/dest -- public/a public/b
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conflicts | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.conflicts[0]' <<<"$output")" = public/dest/b ]
  [ -e "$R/public/a" ]
  [ -e "$R/public/b" ]
  [ ! -e "$R/public/dest/a" ]
  run vf move blog.miosito.it public/dest --overwrite -- public/a public/b
  [ "$status" -eq 0 ]
  [ -e "$R/public/dest/a" ]
  [ -e "$R/public/dest/b" ]
  [ ! -e "$R/public/a" ]
  [ ! -e "$R/public/b" ]
}

@test "vps-files move/copy: destinazioni e origini incoerenti rifiutate" {
  mk_fm_site
  mkdir -p "$R/public/d/sub"
  : >"$R/public/f"
  for c in move copy; do
    run vf "$c" blog.miosito.it public/d/sub -- public/d
    [ "$status" -eq 1 ] || { echo "$c dentro se stessa"; false; }
    run vf "$c" blog.miosito.it public -- public/f
    [ "$status" -eq 1 ] || { echo "$c stessa cartella"; false; }
    run vf "$c" blog.miosito.it public/f -- public/d
    [ "$status" -eq 1 ]
    run vf "$c" blog.miosito.it public/d -- public
    [ "$status" -eq 1 ]
    run vf "$c" blog.miosito.it logs -- public/f
    [ "$status" -eq 1 ]
    run vf "$c" blog.miosito.it public/d -- public/nonesiste
    [ "$status" -eq 1 ]
    run vf "$c" blog.miosito.it public/d -- public/f public/d/sub
    [ "$status" -eq 1 ]
    run vf "$c" blog.miosito.it public/d
    [ "$status" -eq 1 ]
    run vf "$c" blog.miosito.it public/d --
    [ "$status" -eq 1 ]
  done
  [ -e "$R/public/f" ]
  [ -d "$R/public/d/sub" ]
}

@test "vps-files copy: cartella con un link, il link resta link" {
  mk_fm_site
  mkdir -p "$R/public/src/sub" "$R/public/dest"
  printf 'dentro' >"$R/public/src/sub/f"
  ln -s "$SECRET" "$R/public/src/lnk"
  run vf copy blog.miosito.it public/dest -- public/src
  [ "$status" -eq 0 ]
  [ -L "$R/public/dest/src/lnk" ]
  [ "$(readlink "$R/public/dest/src/lnk")" = "$SECRET" ]
  [ "$(cat "$R/public/dest/src/sub/f")" = dentro ]
  [ -e "$R/public/src/sub/f" ]
  run vf copy blog.miosito.it public/dest -- public/src
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conflicts[0]' <<<"$output")" = public/dest/src ]
  run vf copy blog.miosito.it public/dest --overwrite -- public/src
  [ "$status" -eq 0 ]
  [ -L "$R/public/dest/src/lnk" ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
}

@test "vps-files copy: oltre 200 MB rifiutato, nulla copiato" {
  mk_fm_site
  mkdir "$R/public/dest"
  truncate -s 209715201 "$R/public/grande"
  run vf copy blog.miosito.it public/dest -- public/grande
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -e "$R/public/dest/grande" ]
  truncate -s 209715200 "$R/public/grande"
  run vf copy blog.miosito.it public/dest -- public/grande
  [ "$status" -eq 0 ]
  [ -e "$R/public/dest/grande" ]
}

@test "vps-files delete: public rifiutato, due percorsi ok, link tolto senza toccare la destinazione" {
  mk_fm_site
  mkdir -p "$R/public/a/x"
  : >"$R/public/b"
  : >"$R/public/-opzione"
  : >"$R/public/ri ga"
  ln -s "$SECRET" "$R/public/lnk"
  run vf delete blog.miosito.it -- public
  [ "$status" -eq 1 ]
  run vf delete blog.miosito.it -- public/b public
  [ "$status" -eq 1 ]
  [ -e "$R/public/b" ]
  for p in logs/php wp-config.php tmp /etc ""; do
    run vf delete blog.miosito.it -- "$p"
    [ "$status" -eq 1 ] || { echo "accettato: $p"; false; }
  done
  run vf delete blog.miosito.it -- public/a public/b
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ ! -e "$R/public/a" ]
  [ ! -e "$R/public/b" ]
  run vf delete blog.miosito.it -- public/-opzione "public/ri ga" public/lnk
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$R/public")" ]
  [ "$(cat "$SECRET")" = SEGRETO-ALTRO-SITO ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
  run vf delete blog.miosito.it public/x
  [ "$status" -eq 1 ]
  run vf delete blog.miosito.it --
  [ "$status" -eq 1 ]
}

@test "vps-files scritture: registro con comando, sito e percorsi, mai i contenuti" {
  mk_fm_site
  printf 'CONTENUTO-RISERVATO' | vf write blog.miosito.it public/a.txt >/dev/null
  vf delete blog.miosito.it -- public/a.txt >/dev/null
  grep -q 'files write blog.miosito.it .*public/a.txt' "$VPS_LOG"
  grep -q 'files delete blog.miosito.it .*public/a.txt' "$VPS_LOG"
  run grep -q RISERVATO "$VPS_LOG"
  [ "$status" -eq 1 ]
}

# ------------------------------------------------------- correzioni (giro 1)

@test "vps-files copy: i collegamenti fisici contano uno per uno nel tetto di 200 MB" {
  mk_fm_site
  mkdir -p "$R/public/src" "$R/public/dest"
  truncate -s 70M "$R/public/src/a"
  for i in 1 2 3; do ln "$R/public/src/a" "$R/public/src/h$i"; done
  run vf copy blog.miosito.it public/dest -- public/src
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -e "$R/public/dest/src" ]
}

@test "vps-files move/copy: controllo dei conflitti fallito -> errore, nulla fatto" {
  mk_fm_site
  mkdir "$R/public/dest"
  : >"$R/public/a"
  cat >"$BATS_TEST_TMPDIR/runuser-rotto" <<'STUB'
#!/usr/bin/env bash
shift 3
while [[ "$1" == env || "$1" == -i || "$1" == *=* ]]; do shift; done
case "$*" in *"for t; do"*) exit 5 ;; esac
exec "$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/runuser-rotto"
  for c in move copy; do
    FM_RUNUSER="$BATS_TEST_TMPDIR/runuser-rotto" run vf "$c" blog.miosito.it public/dest -- public/a
    [ "$status" -eq 1 ]
    [ "$(jq -r .ok <<<"$output")" = false ]
    [ ! -e "$R/public/dest/a" ]
  done
  [ -e "$R/public/a" ]
}

@test "vps-files copy --overwrite: se la copia fallisce il vecchio resta, nessun temporaneo" {
  mk_fm_site
  mkdir -p "$R/public/dest/src" "$R/public/src"
  printf 'vecchio' >"$R/public/dest/src/f"
  printf 'nuovo' >"$R/public/src/f"
  make_stub cp 'exit 1'
  run vf copy blog.miosito.it public/dest --overwrite -- public/src
  [ "$status" -eq 1 ]
  [ "$(cat "$R/public/dest/src/f")" = vecchio ]
  [ "$(ls -A "$R/public/dest" | wc -l)" -eq 1 ]
}

@test "vps-files write: scadenza del timeout -> errore e nessun temporaneo" {
  mk_fm_site
  make_stub timeout 'shift; exec /usr/bin/timeout 1 "$@"'
  run bash -c "sleep 4 | bash '$REPO_ROOT/tools/vps-files' write blog.miosito.it public/lento 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -e "$R/public/lento" ]
  [ "$(ls -A "$R/public" | wc -l)" -eq 0 ]
}

@test "vps-files move: registro senza la destinazione nel totale, chiamata a runuser" {
  mk_fm_site
  mkdir "$R/public/dest"
  : >"$R/public/a"
  run vf move blog.miosito.it public/dest -- public/a
  [ "$status" -eq 0 ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
  grep -q 'files move verso public/dest blog.miosito.it public/a totale=1' "$VPS_LOG"
}
