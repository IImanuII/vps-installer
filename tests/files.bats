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
  # runuser vero verso nobody: serve root (in CI i test girano come utente normale)
  [[ $EUID -eq 0 ]] || skip "serve root"
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

@test "vps-files copy: un solo budget di 120 s per tutta l'operazione" {
  mk_fm_site
  mkdir "$R/public/dest"
  : >"$R/public/a"
  make_stub timeout 'echo "timeout $1" >>"$CALLS"; sleep 2; shift; exec "$@"'
  run vf copy blog.miosito.it public/dest -- public/a
  [ "$status" -eq 0 ]
  mapfile -t tt < <(grep '^timeout ' "$CALLS" | cut -d' ' -f2)
  [ "${#tt[@]}" -eq 4 ]
  [ "${tt[0]}" -eq 120 ]
  # ogni passo riceve quanto avanza: mai il vecchio 60/60/120/120 a catena
  [ "${tt[1]}" -le 118 ] && [ "${tt[2]}" -le 116 ] && [ "${tt[3]}" -le 114 ]
  [ "${tt[3]}" -ge 100 ]
}

# ---------------------------------------------------------------- zip, unzip, download-zip

# mkz USCITA "nome|modo|dim[|reali]"... — zip fatto a mano (anche malevolo), vedi tests/mkzip.pl
mkz() { perl "$REPO_ROOT/tests/mkzip.pl" "$@"; }

need_zip() {
  command -v zip >/dev/null && command -v unzip >/dev/null && command -v zipinfo >/dev/null || skip "servono zip e unzip"
}

# nulla è stato scritto: né in public/dest né temporanei in tmp/
nothing_written() {
  [ "$(ls -A "$R/public/dest" | wc -l)" -eq 0 ] || { ls -A "$R/public/dest"; false; }
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ] || { ls -A "$R/tmp"; false; }
}

@test "vps-files unzip: archivi malevoli rifiutati prima di estrarre, nulla scritto" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  local z="$R/public/m.zip" i args=()
  # nome|modo|dimensione dichiarata[|byte reali]
  mkz "$z" "../evil|100644|3"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; [ "$(jq -r .ok <<<"$output")" = false ]; nothing_written
  mkz "$z" "a/../../evil|100644|3"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; nothing_written
  mkz "$z" "/etc/x|100644|3"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; nothing_written
  mkz "$z" 'a\b|100644|3'
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; nothing_written
  mkz "$z" "ok|100644|3" "link|120777|11"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; [[ "$output" == *collegament* ]]; nothing_written
  mkz "$z" "fifo|10644|0"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; nothing_written
  # voce dichiarata 11 MB
  mkz "$z" "grande|100644|11534336|0"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; [[ "$output" == *"10 MB"* ]]; nothing_written
  # 21 voci da 10 MB dichiarati = 210 MB
  args=()
  for i in $(seq 1 21); do args+=("f$i|100644|10485760|0"); done
  mkz "$z" "${args[@]}"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; [[ "$output" == *"200 MB"* ]]; nothing_written
  # 10.001 voci
  args=()
  for i in $(seq 1 10001); do args+=("f$i|100644|0"); done
  mkz "$z" "${args[@]}"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; [[ "$output" == *"10.000"* ]]; nothing_written
  # non è uno zip
  printf 'ciao' >"$z"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]; nothing_written
  # nome con a capo: unzip toglie il controllo dal nome; comunque nessun file con caratteri di controllo
  mkz "$z" $'a\nb|100644|3'
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 0 ]
  [ -e "$R/public/dest/ab" ] || { ls -A "$R/public/dest"; false; }
  [ -z "$(find "$R/public/dest" -name '*[[:cntrl:]]*')" ]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
  [ ! -e "$R/evil" ] && [ ! -e "$R/public/evil" ]
}

@test "vps-files unzip: intestazione che mente (11 MB reali, 100 dichiarati) -> nessun file oltre 10 MB" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  mkz "$R/public/m.zip" "bomba|100644|100|11534336"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
  [ "$(find "$R/public/dest" -type f -size +10485760c | wc -l)" -eq 0 ]
}

@test "vps-files unzip: valido, qui e in cartella; permessi sani, nessun temporaneo" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  mkz "$R/public/t.zip" "tema/|40755|0" "tema/style.css|100644|0|=body{}" "tema/js/|40700|0" "tema/js/a b.js|100755|0|=alert(1)" "-x|104777|0|=u"
  run vf unzip blog.miosito.it public/t.zip public
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ "$(cat "$R/public/tema/style.css")" = "body{}" ]
  [ "$(cat "$R/public/tema/js/a b.js")" = "alert(1)" ]
  [ -d "$R/public/tema/js" ]
  [ "$(stat -c %a "$R/public/-x")" -lt 1000 ]
  [ "$(stat -c %a "$R/public/tema/js")" = 775 ]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
  rm -rf "$R/public/tema" "$R/public/-x"
  run vf unzip blog.miosito.it public/t.zip public/dest
  [ "$status" -eq 0 ]
  [ "$(cat "$R/public/dest/tema/style.css")" = "body{}" ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
  grep -q 'files unzip blog.miosito.it public/t.zip public/dest' "$VPS_LOG"
}

@test "vps-files unzip: conflitto -> elenco e nulla toccato; --overwrite sovrascrive" {
  need_zip
  mk_fm_site
  mkdir -p "$R/public/dest/tema"
  printf 'vecchio' >"$R/public/dest/tema/style.css"
  printf 'mio' >"$R/public/dest/tema/mio.txt"
  mkz "$R/public/t.zip" "tema/|40755|0" "tema/style.css|100644|0|=nuovo" "tema/nuovo.txt|100644|0|=n"
  run vf unzip blog.miosito.it public/t.zip public/dest
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ "$(jq -r '.conflicts | join(",")' <<<"$output")" = "public/dest/tema/style.css" ]
  [ "$(cat "$R/public/dest/tema/style.css")" = vecchio ]
  [ ! -e "$R/public/dest/tema/nuovo.txt" ]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
  run vf unzip blog.miosito.it public/t.zip public/dest --overwrite
  [ "$status" -eq 0 ]
  [ "$(cat "$R/public/dest/tema/style.css")" = nuovo ]
  [ "$(cat "$R/public/dest/tema/nuovo.txt")" = n ]
  [ "$(cat "$R/public/dest/tema/mio.txt")" = mio ]
}

@test "vps-files unzip: file dove c'è una cartella o cartella dove c'è un collegamento -> conflitto, con --overwrite errore" {
  need_zip
  mk_fm_site
  mkdir -p "$R/public/dest/d"
  ln -s "$BATS_TEST_TMPDIR" "$R/public/dest/lnk"
  mkz "$R/public/t.zip" "d|100644|0|=f" "lnk/|40755|0" "lnk/x|100644|0|=x"
  run vf unzip blog.miosito.it public/t.zip public/dest
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conflicts | length' <<<"$output")" -ge 2 ]
  run vf unzip blog.miosito.it public/t.zip public/dest --overwrite
  [ "$status" -eq 1 ]
  [ -d "$R/public/dest/d" ]
  [ -L "$R/public/dest/lnk" ]
  [ ! -e "$BATS_TEST_TMPDIR/x" ]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
}

@test "vps-files unzip: archivio e destinazione non ammessi" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  mkz "$R/public/t.zip" "a|100644|0|=a"
  ln -s "$R/public/t.zip" "$R/public/lnk.zip"
  ln -s "$BATS_TEST_TMPDIR" "$R/public/dlnk"
  printf 'x' >"$R/public/file"
  for a in "public/nonesiste.zip public/dest" "public/lnk.zip public/dest" "logs/x public/dest" "public/dest public/dest" \
    "public/t.zip public/nonesiste" "public/t.zip public/dlnk" "public/t.zip public/file" "public/t.zip logs" "public/t.zip tmp" "public/t.zip ../x"; do
    # shellcheck disable=SC2086
    run vf unzip blog.miosito.it $a
    [ "$status" -eq 1 ] || { echo "accettato: $a"; false; }
  done
  [ "$(ls -A "$R/public/dest" | wc -l)" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/a" ]
  run vf unzip blog.miosito.it public/t.zip public/dest --zzz
  [ "$status" -eq 1 ]
}

@test "vps-files zip: cartella e file, riaperto con unzip; collegamenti memorizzati come tali" {
  need_zip
  mk_fm_site
  mkdir -p "$R/public/sito/sub" "$R/public/altro"
  printf 'uno' >"$R/public/sito/a b.txt"
  printf 'due' >"$R/public/sito/sub/-x"
  printf 'tre' >"$R/public/altro/[y]*.txt"
  ln -s "$SECRET" "$R/public/sito/lnk"
  run vf zip blog.miosito.it public/out.zip -- public/sito public/altro/'[y]*.txt'
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  unzip -tq "$R/public/out.zip"
  run zipinfo -1 "$R/public/out.zip"
  [[ "$output" == *"sito/a b.txt"* ]]
  [[ "$output" == *"sito/sub/-x"* ]]
  [[ "$output" == *"[y]*.txt"* ]]
  run zipinfo -s "$R/public/out.zip"
  [[ "$output" == *"lrwx"*"sito/lnk"* ]]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
  grep -q 'files zip blog.miosito.it public/out.zip public/sito' "$VPS_LOG"
  run ! grep -aq SEGRETO-ALTRO-SITO "$R/public/out.zip"
  # esiste già -> conflitto, file intatto
  cp "$R/public/out.zip" "$BATS_TEST_TMPDIR/prima.zip"
  run vf zip blog.miosito.it public/out.zip -- public/sito
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conflicts[0]' <<<"$output")" = public/out.zip ]
  cmp "$R/public/out.zip" "$BATS_TEST_TMPDIR/prima.zip"
}

@test "vps-files zip: percorsi e destinazioni non ammessi, oltre 200 MB rifiutato, nulla creato" {
  need_zip
  mk_fm_site
  mkdir -p "$R/public/sito"
  ln -s "$BATS_TEST_TMPDIR" "$R/public/dlnk"
  for a in "logs/o.zip -- public/sito" "public/o.txt -- public/sito" "public/o.zip -- logs" "public/o.zip -- wp-config.php" "public/o.zip -- public/nonesiste" \
    "public/dlnk/o.zip -- public/sito" "public/nonesiste/o.zip -- public/sito" "public -- public/sito" "public/o.zip -- public/dlnk/x" "public/o.zip -- ../x" "public/o.zip public/sito"; do
    # shellcheck disable=SC2086
    run vf zip blog.miosito.it $a
    [ "$status" -eq 1 ] || { echo "accettato: $a"; false; }
  done
  [ ! -e "$R/public/o.zip" ] && [ ! -e "$BATS_TEST_TMPDIR/o.zip" ]
  truncate -s 209715201 "$R/public/sito/grosso"
  run vf zip blog.miosito.it public/o.zip -- public/sito
  [ "$status" -eq 1 ]
  [[ "$output" == *"200 MB"* ]]
  [ ! -e "$R/public/o.zip" ]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
}

@test "vps-files download-zip: zip valido su stdout, collegamenti non letti, tetto 200 MB" {
  need_zip
  mk_fm_site
  mkdir -p "$R/public/sito/sub"
  printf 'uno' >"$R/public/sito/a.txt"
  printf 'due' >"$R/public/sito/sub/-b"
  ln -s "$SECRET" "$R/public/sito/lnk"
  bash "$REPO_ROOT/tools/vps-files" download-zip blog.miosito.it public/sito >"$BATS_TEST_TMPDIR/dl.zip" 2>/dev/null
  unzip -tq "$BATS_TEST_TMPDIR/dl.zip"
  run zipinfo -s "$BATS_TEST_TMPDIR/dl.zip"
  [[ "$output" == *"sito/a.txt"* ]]
  [[ "$output" == *"sito/sub/-b"* ]]
  [[ "$output" == *"lrwx"*"sito/lnk"* ]]
  run ! grep -aq SEGRETO-ALTRO-SITO "$BATS_TEST_TMPDIR/dl.zip"
  grep -q '^runuser -u site_blog_miosito_it' "$CALLS"
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
  bash "$REPO_ROOT/tools/vps-files" download-zip blog.miosito.it public >"$BATS_TEST_TMPDIR/dl2.zip" 2>/dev/null
  unzip -tq "$BATS_TEST_TMPDIR/dl2.zip"
  for p in logs wp-config.php public/nonesiste ../x public/sito/lnk; do
    run vf download-zip blog.miosito.it "$p"
    [ "$status" -eq 1 ] || { echo "accettato: $p"; false; }
    [ "$(jq -r .ok <<<"$output")" = false ]
  done
  truncate -s 209715201 "$R/public/sito/grosso"
  run vf download-zip blog.miosito.it public/sito
  [ "$status" -eq 1 ]
  [[ "$output" == *"200 MB"* ]]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
}

@test "vps-files download-zip: archivio oltre 200 MB (cresciuto dopo il controllo) -> errore e nessun temporaneo" {
  mk_fm_site
  mkdir -p "$R/public/sito"
  # zip finto che scrive un archivio di 200 MB + 1: il tetto sull'archivio scatta comunque
  make_stub zip 'head -c 209715201 /dev/zero >"$5"'
  run vf download-zip blog.miosito.it public/sito
  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
}

@test "vps-files copy: scadenza durante --overwrite -> nessuna copia parziale rimasta" {
  mk_fm_site
  mkdir -p "$R/public/dest/src" "$R/public/src"
  printf 'vecchio' >"$R/public/dest/src/f"
  printf 'nuovo' >"$R/public/src/f"
  make_stub timeout 'shift; exec /usr/bin/timeout 1 "$@"'
  make_stub cp 'c="${!#}"; mkdir -p "$c"; : >"$c/parziale"; sleep 5'
  run vf copy blog.miosito.it public/dest --overwrite -- public/src
  [ "$status" -eq 1 ]
  [ "$(cat "$R/public/dest/src/f")" = vecchio ]
  [ "$(ls -A "$R/public/dest" | wc -l)" -eq 1 ]
}

@test "vps-files unzip: bomba deflate che dichiara poco -> fermata durante l'estrazione, nulla rimasto" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  local args=() i
  # 30 voci da 10 MB di zeri (299 KB compressi) che dichiarano 100 byte: 300 MB veri
  for i in $(seq 1 30); do args+=("b$i|100644|100|z10000000"); done
  mkz "$R/public/m.zip" "${args[@]}"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]
  [[ "$output" == *"200 MB"* ]]
  nothing_written
  # una voce sola da 11 MB veri, dichiarata 100
  mkz "$R/public/m.zip" "b|100644|100|z11000000"
  run vf unzip blog.miosito.it public/m.zip public/dest
  [ "$status" -eq 1 ]
  [[ "$output" == *"10 MB"* ]]
  nothing_written
}

# 1 se una voce dell'archivio ha il bit 11 (UTF-8) nelle intestazioni centrali
zflag() {
  perl -e 'open F, "<:raw", $ARGV[0] or die; local $/; $_ = <F>; my ($i, $r) = (0, 0); while (($i = index($_, "PK\x01\x02", $i)) >= 0) { $r = 1 if unpack("v", substr($_, $i + 8, 2)) & 0x800; $i += 4 } print $r' "$1"
}

@test "vps-files zip/unzip: nomi non ASCII, andata e ritorno e flag UTF-8" {
  need_zip
  mk_fm_site
  mkdir -p "$R/public/u" "$R/public/dest"
  printf 'x' >"$R/public/u/caffè perché.txt"
  run vf zip blog.miosito.it public/u.zip -- public/u
  [ "$status" -eq 0 ]
  [ "$(zflag "$R/public/u.zip")" = 1 ] || { zipinfo -v "$R/public/u.zip" | head -30; false; }
  run vf unzip blog.miosito.it public/u.zip public/dest
  [ "$status" -eq 0 ]
  [ -e "$R/public/dest/u/caffè perché.txt" ] || { ls -A "$R/public/dest/u"; false; }
  bash "$REPO_ROOT/tools/vps-files" download-zip blog.miosito.it public/u >"$BATS_TEST_TMPDIR/d.zip" 2>/dev/null
  [ "$(zflag "$BATS_TEST_TMPDIR/d.zip")" = 1 ] || { zipinfo -v "$BATS_TEST_TMPDIR/d.zip" | head -30; false; }
  # archivio di un altro strumento, con il flag UTF-8
  rm -rf "$R/public/dest/"*
  mkz "$R/public/x.zip" "è/|40755|0|0|u" "è/perché ☃.txt|100644|3|=ciao|u"
  run vf unzip blog.miosito.it public/x.zip public/dest
  [ "$status" -eq 0 ]
  [ "$(cat "$R/public/dest/è/perché ☃.txt")" = ciao ]
}

@test "vps-files unzip: voce di Windows con attributo nascosto (FAT) accettata" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  mkz "$R/public/w.zip" "cartella/|40755|0|0|fat" "cartella/nascosto.txt|100644|3|=win|fat" "Thumbs.db|100644|2|=ab|fat"
  zipinfo -s "$R/public/w.zip" | grep -q -- '-rw-ah-' || zipinfo -s "$R/public/w.zip" >&3
  run vf unzip blog.miosito.it public/w.zip public/dest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$R/public/dest/cartella/nascosto.txt")" = win ]
  [ -e "$R/public/dest/Thumbs.db" ]
}

@test "vps-files unzip: voci cifrate rifiutate con messaggio chiaro" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  mkz "$R/public/e.zip" "ok|100644|3|=abc" "segreto|100644|3|=abc|enc"
  run vf unzip blog.miosito.it public/e.zip public/dest
  [ "$status" -eq 1 ]
  [[ "$output" == *cifrat* ]]
  nothing_written
}

@test "vps-files unzip: nome dell'archivio con caratteri jolly" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  mkz "$R/public/y[1]*.zip" "a.txt|100644|0|=ok"
  mkz "$R/public/y1.zip" "altro.txt|100644|0|=no"
  run vf unzip blog.miosito.it "public/y[1]*.zip" public/dest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$R/public/dest/a.txt")" = ok ]
  [ ! -e "$R/public/dest/altro.txt" ]
  [ "$(ls -A "$R/tmp" | wc -l)" -eq 0 ]
}

@test "vps-files unzip: nomi non UTF-8 (CP437) -> messaggio dedicato, nulla scritto" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest"
  mkz "$R/public/c.zip" $'caff\x8a.txt|100644|3'
  run vf unzip blog.miosito.it public/c.zip public/dest
  [ "$status" -eq 1 ]
  [[ "$output" == *"UTF-8"* ]] || { echo "$output"; false; }
  nothing_written
}

@test "vps-files unzip: temporanei vecchi di tmp/ spazzati, budget di 120 s in totale" {
  need_zip
  mk_fm_site
  mkdir "$R/public/dest" "$R/tmp/.vpsfiles-x.vecchio" "$R/tmp/.vpsfiles-x.nuovo" "$R/tmp/altro"
  touch -d '2 hours ago' "$R/tmp/.vpsfiles-x.vecchio"
  mkz "$R/public/t.zip" "a|100644|0|=a"
  make_stub timeout 'echo "timeout $1" >>"$CALLS"; shift; exec "$@"'
  run vf unzip blog.miosito.it public/t.zip public/dest
  [ "$status" -eq 0 ]
  [ ! -e "$R/tmp/.vpsfiles-x.vecchio" ]
  [ -e "$R/tmp/.vpsfiles-x.nuovo" ] && [ -e "$R/tmp/altro" ]
  local t1 t2
  t1="$(grep '^timeout ' "$CALLS" | sed -n 1p | cut -d' ' -f2)"
  t2="$(grep '^timeout ' "$CALLS" | sed -n 2p | cut -d' ' -f2)"
  [ "$t1" -le 120 ] && [ "$t2" -le 120 ] && [ "$t2" -ge 100 ]
  [ "$((t1 + 0))" -le 60 ]
}

# ------------------------------------------------------- correzioni (giro finale)

@test "vps-files write: temporanei .vpsfiles.* vecchi della cartella di destinazione spazzati, non ricorsivo" {
  mk_fm_site
  mkdir -p "$R/public/d/sub"
  : >"$R/public/d/.vpsfiles.VECCHIO"
  : >"$R/public/d/.vpsfiles.NUOVO"
  : >"$R/public/d/.vpsfiles-cp.VECCHIO"
  : >"$R/public/d/sub/.vpsfiles.VECCHIO"
  : >"$R/public/d/utente.txt"
  touch -d '2 hours ago' "$R/public/d/.vpsfiles.VECCHIO" "$R/public/d/.vpsfiles-cp.VECCHIO" "$R/public/d/sub/.vpsfiles.VECCHIO" "$R/public/d/utente.txt"
  printf 'x' | vf write blog.miosito.it public/d/a.txt >/dev/null
  [ ! -e "$R/public/d/.vpsfiles.VECCHIO" ]
  [ ! -e "$R/public/d/.vpsfiles-cp.VECCHIO" ]
  [ -e "$R/public/d/.vpsfiles.NUOVO" ]
  [ -e "$R/public/d/sub/.vpsfiles.VECCHIO" ]
  [ -e "$R/public/d/utente.txt" ]
}

@test "vps-files copy: spazza i temporanei vecchi della cartella di destinazione" {
  mk_fm_site
  mkdir -p "$R/public/dest"
  : >"$R/public/a"
  : >"$R/public/dest/.vpsfiles-cp.99999"
  : >"$R/public/dest/.vpsfiles.VECCHIO"
  touch -d '2 hours ago' "$R/public/dest/.vpsfiles-cp.99999" "$R/public/dest/.vpsfiles.VECCHIO"
  run vf copy blog.miosito.it public/dest --overwrite -- public/a
  [ "$status" -eq 0 ]
  [ -e "$R/public/dest/a" ]
  [ ! -e "$R/public/dest/.vpsfiles-cp.99999" ]
  [ ! -e "$R/public/dest/.vpsfiles.VECCHIO" ]
}

@test "vps-files: il registro riporta anche l'esito, ok o il messaggio di errore" {
  mk_fm_site
  printf 'x' | vf write blog.miosito.it public/a.txt >/dev/null
  grep -q 'files write blog.miosito.it public/a.txt totale=1 esito=ok$' "$VPS_LOG"
  run vf mkdir blog.miosito.it public/a.txt
  [ "$status" -eq 1 ]
  grep -q 'files mkdir blog.miosito.it public/a.txt totale=1 esito=errore .*esiste' "$VPS_LOG"
}

@test "vps-files: scritture rifiutate con 'ripristino in corso' mentre il lock del sito è preso; letture no" {
  mk_fm_site
  export BK_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$BK_LOCK_DIR"
  echo x >"$R/public/a.txt"
  exec {lk}>>"$BK_LOCK_DIR/vps-site.site_blog_miosito_it.lock"
  flock -n "$lk"
  run vf write blog.miosito.it public/n.txt <<<"x"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"ripristino in corso"* ]]
  local c
  for c in "mkdir blog.miosito.it public/d" "rename blog.miosito.it public/a.txt b.txt" "move blog.miosito.it public -- public/a.txt" \
    "copy blog.miosito.it public -- public/a.txt" "delete blog.miosito.it -- public/a.txt" "zip blog.miosito.it public/z.zip -- public/a.txt" \
    "unzip blog.miosito.it public/z.zip public"; do
    # shellcheck disable=SC2086
    run vf $c </dev/null
    [ "$status" -eq 1 ] || { echo "accettato: $c"; false; }
    [[ "$(jq -r .error <<<"$output")" == *"ripristino in corso"* ]] || { echo "messaggio: $c"; false; }
  done
  [ -f "$R/public/a.txt" ]
  [ ! -e "$R/public/n.txt" ]
  run vf list blog.miosito.it public
  [ "$status" -eq 0 ]
  run vf read blog.miosito.it public/a.txt
  [ "$status" -eq 0 ]
  exec {lk}>&-
  run vf write blog.miosito.it public/n.txt <<<"x"
  [ "$status" -eq 0 ]
}

@test "vps-files: un comando di scrittura tiene il lock condiviso del sito per tutta la sua durata" {
  mk_fm_site
  export BK_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$BK_LOCK_DIR"
  local lk="$BK_LOCK_DIR/vps-site.site_blog_miosito_it.lock" i held=no
  # lo stdin arriva dopo 3 secondi: il comando è in corso (e ha già preso il lock) nel frattempo
  { sleep 3; echo x; } | bash "$REPO_ROOT/tools/vps-files" write blog.miosito.it public/n.txt >/dev/null 2>&1 &
  pid=$!
  for i in {1..25}; do
    if ! flock -x -n "$lk" true 2>/dev/null; then held=si; break; fi
    sleep 0.1
  done
  [ "$held" = si ]
  # un ripristino (lock esclusivo) è rifiutato finché il comando non finisce
  run bk_site_lock site_blog_miosito_it
  [ "$status" -eq 1 ]
  wait "$pid"
  pid=""
  flock -x -n "$lk" true
  [ -f "$R/public/n.txt" ]
}
