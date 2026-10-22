bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load sites_helper
  setup_common
  sites_test_setup
  export BK_BACKUPS="$BATS_TEST_TMPDIR/bk" BK_LOCK_DIR="$BATS_TEST_TMPDIR/locks" BK_DIR="$BATS_TEST_TMPDIR/bkcfg"
  mkdir -p "$BK_LOCK_DIR"
  # shellcheck disable=SC2016
  make_stub mariadb-dump 'echo "-- dump $*"; exit "${STUB_RC_mariadb_dump:-0}"'
}

# mk_site DOMINIO DB(yes|no) — sito attivo con file di prova.
mk_site() {
  local d="$1" root
  site_reg_new "$d" php no "$2"
  site_reg_update "$d" '.state = "active"'
  root="$SITES_WWW/$d"
  mkdir -p "$root/public" "$root/logs" "$root/tmp"
  echo '<?php echo 1;' >"$root/public/a b.php"
  echo x >"$root/public/-x"
  echo 'segreto-log' >"$root/logs/access.log"
  echo 'tmp-file' >"$root/tmp/sess"
  printf '<?php // wp-config\n' >"$root/wp-config.php"
}

# arc_from_files DIR OUT — impacchetta DIR/files.tar.gz in un archivio con manifest coerente.
arc_from_files() {
  local dir="$1" out="$2" sha
  sha="$(sha256sum "$dir/files.tar.gz" | cut -d' ' -f1)"
  jq -n --arg s "$sha" '{domain:"x.it", sha256:{files:$s, db:null}}' >"$dir/manifest.json"
  tar -czf "$out" -C "$dir" manifest.json files.tar.gz
}

@test "bk_archive: manifest, file del sito, link conservato, niente logs/ tmp/" {
  mk_site blog.miosito.it yes
  ln -s /etc/shadow "$SITES_WWW/blog.miosito.it/public/l"
  run bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/out.tar.gz" ]
  run bk_manifest "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
  [ "$(jq -r .domain <<<"$output")" = blog.miosito.it ]
  [ "$(jq -r .type <<<"$output")" = php ]
  [ "$(jq -r .slug <<<"$output")" = site_blog_miosito_it ]
  [ "$(jq -r .db <<<"$output")" = true ]
  [ "$(jq -r .installer_version <<<"$output")" = "$VPS_INSTALLER_VERSION" ]
  [[ "$(jq -r .sha256.files <<<"$output")" =~ ^[0-9a-f]{64}$ ]]
  [[ "$(jq -r .sha256.db <<<"$output")" =~ ^[0-9a-f]{64}$ ]]
  local w="$BATS_TEST_TMPDIR/x"
  mkdir -p "$w"
  tar -xzf "$BATS_TEST_TMPDIR/out.tar.gz" -C "$w"
  [ -f "$w/db.sql.gz" ]
  run tar -tvzf "$w/files.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"public/a b.php"* ]]
  [[ "$output" == *"public/-x"* ]]
  [[ "$output" == *"wp-config.php"* ]]
  [[ "$output" =~ l[rwx-]{9}.*public/l\ -\>\ /etc/shadow ]]
  [[ "$output" != *"logs/"* ]]
  [[ "$output" != *"tmp/"* ]]
  # il contenuto della destinazione del link non c'è
  run tar -xzOf "$w/files.tar.gz" public/l
  [ "$status" -ne 0 ] || [[ "$output" != *root:* ]]
  # niente temporanei rimasti
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "bk_archive: nomi non ASCII sopravvivono" {
  mk_site blog.miosito.it no
  echo y >"$SITES_WWW/blog.miosito.it/public/è ü.txt"
  run bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
  mkdir -p "$BATS_TEST_TMPDIR/x"
  tar -xzf "$BATS_TEST_TMPDIR/out.tar.gz" -C "$BATS_TEST_TMPDIR/x"
  run env LC_ALL=C.UTF-8 tar -tzf "$BATS_TEST_TMPDIR/x/files.tar.gz"
  [[ "$output" == *"public/è ü.txt"* ]]
}

@test "bk_archive: sito senza database, niente db.sql.gz" {
  mk_site blog.miosito.it no
  run bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
  run tar -tzf "$BATS_TEST_TMPDIR/out.tar.gz"
  [[ "$output" == *manifest.json* ]]
  [[ "$output" != *db.sql.gz* ]]
  run bk_manifest "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$(jq -r .sha256.db <<<"$output")" = null ]
}

@test "bk_archive: sito senza wp-config.php né public/ non fallisce" {
  mk_site blog.miosito.it no
  rm -f "$SITES_WWW/blog.miosito.it/wp-config.php"
  rm -rf "$SITES_WWW/blog.miosito.it/public"
  run bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
}

@test "bk_archive: dump che fallisce, 1, nessun file OUT né temporaneo" {
  mk_site blog.miosito.it yes
  STUB_RC_mariadb_dump=2 run bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/out.tar.gz" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "bk_archive: BK_ERR dice perché (dump, sito sconosciuto, wp-config collegamento)" {
  mk_site blog.miosito.it yes
  STUB_RC_mariadb_dump=2 bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/o" || true
  [[ "$BK_ERR" == *dump* ]]
  bk_archive nessuno.miosito.it "$BATS_TEST_TMPDIR/o" || true
  [[ "$BK_ERR" == *"non trovato"* ]]
  rm "$SITES_WWW/blog.miosito.it/wp-config.php"
  ln -s /etc/shadow "$SITES_WWW/blog.miosito.it/wp-config.php"
  bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/o" || true
  [[ "$BK_ERR" == *wp-config* ]]
  [ ! -e "$BATS_TEST_TMPDIR/o" ]
}

@test "bk_archive: public/ si legge come utente del sito (runuser)" {
  mk_site blog.miosito.it no
  run bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
  grep -q "^runuser -u site_blog_miosito_it" "$CALLS"
}

@test "bk_archive: file cambiato durante la lettura (tar 1) è accettato" {
  mk_site blog.miosito.it no
  # shellcheck disable=SC2016
  make_stub tar 'for a in "$@"; do [[ "$a" == "--warning=no-file-changed" ]] && { /usr/bin/tar "$@"; /usr/bin/true; exit 1; }; done; exec /usr/bin/tar "$@"'
  run bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/out.tar.gz" ]
}

@test "bk_verify: archivio buono passa" {
  mk_site blog.miosito.it yes
  mkdir -p "$SITES_WWW/blog.miosito.it/public/sub"
  ln -s ../a.php "$SITES_WWW/blog.miosito.it/public/sub/ok"
  ln -s ../../wp-config.php "$SITES_WWW/blog.miosito.it/public/sub/ok2"
  bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  run bk_verify "$BATS_TEST_TMPDIR/out.tar.gz"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "bk_verify: rifiuta percorso assoluto" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src"
  echo x >"$w/src/f"
  tar -czPf "$w/files.tar.gz" --transform='s,^f$,/abs/f,' -C "$w/src" f
  arc_from_files "$w" "$w/a.tar.gz"
  tar -tzPf "$w/files.tar.gz" | grep -q '^/abs/f$'
  bk_verify "$w/a.tar.gz" && false
  [[ "$BK_ERR" == *"/abs/f"* ]]
}

@test "bk_verify: rifiuta ../x" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src"
  echo x >"$w/src/f"
  tar -czPf "$w/files.tar.gz" --transform='s,^f$,public/../x,' -C "$w/src" f
  arc_from_files "$w" "$w/a.tar.gz"
  tar -tzPf "$w/files.tar.gz" | grep -q '\.\.'
  bk_verify "$w/a.tar.gz" && false
  [[ "$BK_ERR" == *".."* ]]
}

@test "bk_verify: rifiuta link che esce o assoluto, accetta quello interno" {
  local w="$BATS_TEST_TMPDIR/w" t
  for t in ../../altro /etc/shadow ../../../x; do
    rm -rf "$w"
    mkdir -p "$w/src/public"
    ln -s "$t" "$w/src/public/x"
    tar -czf "$w/files.tar.gz" -C "$w/src" public
    arc_from_files "$w" "$w/a.tar.gz"
    bk_verify "$w/a.tar.gz" && { echo "accettato: $t"; false; }
  done
  rm -rf "$w"
  mkdir -p "$w/src/public/d"
  ln -s ../../wp-config.php "$w/src/public/d/ok"
  ln -s d/../d "$w/src/public/ok2"
  tar -czf "$w/files.tar.gz" -C "$w/src" public
  arc_from_files "$w" "$w/a.tar.gz"
  run bk_verify "$w/a.tar.gz"
  [ "$status" -eq 0 ]
}

@test "bk_verify: rifiuta link con ' -> ' ambiguo nel nome o nella destinazione" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src/public"
  ln -s '../../x -> y' "$w/src/public/l"
  tar -czf "$w/files.tar.gz" -C "$w/src" public
  arc_from_files "$w" "$w/a.tar.gz"
  bk_verify "$w/a.tar.gz" && false
  rm -rf "$w"
  mkdir -p "$w/src/public"
  ln -s '/etc' "$w/src/public/a -> b"
  tar -czf "$w/files.tar.gz" -C "$w/src" public
  arc_from_files "$w" "$w/a.tar.gz"
  bk_verify "$w/a.tar.gz" && false
  true
}

@test "bk_verify: rifiuta hardlink verso fuori" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src"
  echo x >"$w/src/f"
  ln "$w/src/f" "$w/src/g"
  tar -czPf "$w/files.tar.gz" --transform='s,^f$,/etc/passwd,' -C "$w/src" f g
  arc_from_files "$w" "$w/a.tar.gz"
  bk_verify "$w/a.tar.gz" && false
  true
}

@test "bk_verify: sha256 alterato" {
  mk_site blog.miosito.it yes
  bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w"
  tar -xzf "$BATS_TEST_TMPDIR/out.tar.gz" -C "$w"
  # manifest con checksum del db sbagliato
  jq '.sha256.db = "0000000000000000000000000000000000000000000000000000000000000000"' "$w/manifest.json" >"$w/m2" && mv "$w/m2" "$w/manifest.json"
  tar -czf "$w/bad.tar.gz" -C "$w" manifest.json files.tar.gz db.sql.gz
  bk_verify "$w/bad.tar.gz" && false
  [[ "$BK_ERR" == *db.sql.gz* ]]
  # files.tar.gz sostituito
  tar -xzf "$BATS_TEST_TMPDIR/out.tar.gz" -C "$w"
  echo extra >>"$w/files.tar.gz"
  tar -czf "$w/bad2.tar.gz" -C "$w" manifest.json files.tar.gz db.sql.gz
  bk_verify "$w/bad2.tar.gz" && false
  [[ "$BK_ERR" == *files.tar.gz* ]]
}

@test "bk_verify: voci estranee nell'archivio esterno" {
  mk_site blog.miosito.it no
  bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w"
  tar -xzf "$BATS_TEST_TMPDIR/out.tar.gz" -C "$w"
  echo e >"$w/extra"
  tar -czf "$w/bad.tar.gz" -C "$w" manifest.json files.tar.gz extra
  bk_verify "$w/bad.tar.gz" && false
  [[ "$BK_ERR" == *extra* ]]
  run bk_verify "$w/non-esiste.tar.gz"
  [ "$status" -eq 1 ]
}

@test "bk_keep_plan: 5 nomi, stampa i 2 più vecchi; 3 o meno, niente" {
  run bk_keep_plan s-20261003-0400.tar.gz s-20261001-0400.tar.gz s-20261005-0400.tar.gz s-20261002-0400.tar.gz s-20261004-0400.tar.gz
  [ "$status" -eq 0 ]
  [ "$output" = $'s-20261001-0400.tar.gz\ns-20261002-0400.tar.gz' ]
  run bk_keep_plan s-20261003-0400.tar.gz s-20261001-0400.tar.gz s-20261005-0400.tar.gz
  [ -z "$output" ]
  run bk_keep_plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # stessa data, ora diversa; un nome senza data non si tocca
  run bk_keep_plan a-20261001-2359.x a-20261002-0001.x a-20261002-0400.x a-20261001-0100.x strano.txt
  [ "$output" = a-20261001-0100.x ]
}

@test "bk_space_ok: soglia BYTES*2 + 512 MB" {
  # shellcheck disable=SC2016
  make_stub df 'printf "Filesystem 1B-blocks Used Available Capacity Mounted on\n/dev/x 9999999999999 1 %s 1%% /\n" "$FREE"'
  FREE=$((1000 * 2 + 536870912 + 1)) run bk_space_ok / 1000
  [ "$status" -eq 0 ]
  FREE=$((1000 * 2 + 536870912)) run bk_space_ok / 1000
  [ "$status" -eq 1 ]
  FREE=100 run bk_space_ok / 0
  [ "$status" -eq 1 ]
  FREE=100 run bk_space_ok / abc
  [ "$status" -eq 1 ]
}

@test "bk_space_ok: df vero su una cartella esistente" {
  run bk_space_ok "$BATS_TEST_TMPDIR" 1
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  run bk_space_ok "$BATS_TEST_TMPDIR" 99999999999999999
  [ "$status" -eq 1 ]
}

@test "bk_site_lock: il secondo sullo stesso slug fallisce, modo 600" {
  bk_site_lock site_blog
  [ "$(stat -c %a "$BK_LOCK_DIR/vps-site.site_blog.lock")" = 600 ]
  run bk_site_lock site_blog
  [ "$status" -eq 1 ]
  bk_site_lock site_altro
}

@test "bk_site_lock: tentativo fallito non rilascia il lock già tenuto" {
  bk_site_lock site_blog
  bk_site_lock site_blog && false
  ( bk_site_lock site_blog ) && false
  true
}

@test "bk_site_locked: vero finché un altro processo tiene il lock, poi no" {
  run bk_site_locked site_blog
  [ "$status" -eq 1 ]
  bk_site_lock site_blog
  run bk_site_locked site_blog
  [ "$status" -eq 0 ]
  # bk_site_locked non tiene nulla: dopo il rilascio il lock si può riprendere
  bk_site_unlock
  run bk_site_locked site_blog
  [ "$status" -eq 1 ]
  ( bk_site_lock site_blog )
}

@test "bk_site_lock: il lock dura quanto il processo" {
  ( bk_site_lock site_blog && sleep 2 ) &
  local pid=$!
  sleep 0.5
  run bk_site_locked site_blog
  [ "$status" -eq 0 ]
  wait "$pid"
  run bk_site_locked site_blog
  [ "$status" -eq 1 ]
}
