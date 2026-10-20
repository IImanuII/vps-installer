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
