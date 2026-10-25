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

# --- fix round 1 -------------------------------------------------------------

# fl_arc DIR — impacchetta DIR/src (cartella con public/...) come files.tar.gz con manifest del dominio x.it.
fl_arc() {
  local w="$1"
  tar -czf "$w/files.tar.gz" -C "$w/src" public
  arc_from_files "$w" "$w/a.tar.gz"
}

@test "lock: usa un descrittore allocato (non 6-9) e non ne perde" {
  local before after
  before="$(ls /proc/$$/fd | wc -l)"
  bk_site_lock site_blog
  [ -n "$BK_SITE_LOCK_FD" ]
  [ "$BK_SITE_LOCK_FD" -ge 10 ]
  [ ! -e /proc/$$/fd/6 ]
  run bk_site_locked site_blog
  [ "$status" -eq 0 ]
  bk_site_locked site_altro || true
  after="$(ls /proc/$$/fd | wc -l)"
  [ "$after" -eq $((before + 1)) ]
  bk_site_unlock
  after="$(ls /proc/$$/fd | wc -l)"
  [ "$after" -eq "$before" ]
}

@test "lock: slug non valido rifiutato; file non apribile = occupato" {
  run bk_site_lock '../x'
  [ "$status" -ne 0 ]
  run bk_site_lock ''
  [ "$status" -ne 0 ]
  run bk_site_locked 'a/b'
  [ "$status" -ne 0 ]
  ln -s "$BK_LOCK_DIR/vps-site.site_loop.lock" "$BK_LOCK_DIR/vps-site.site_loop.lock"
  run bk_site_locked site_loop
  [ "$status" -eq 0 ]
}

@test "bk_archive: utente del sito non raggiungibile (runuser 1) fallisce con messaggio" {
  mk_site blog.miosito.it no
  make_stub runuser-ko 'exit 1'
  FM_RUNUSER=runuser-ko bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz" && false
  [[ "$BK_ERR" == *public* ]]
  [ ! -e "$BATS_TEST_TMPDIR/out.tar.gz" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "bk_archive: un OUT preesistente non si cancella se il giro fallisce" {
  mk_site blog.miosito.it yes
  echo vecchia >"$BATS_TEST_TMPDIR/out.tar.gz"
  STUB_RC_mariadb_dump=2 bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz" && false
  [ "$(cat "$BATS_TEST_TMPDIR/out.tar.gz")" = vecchia ]
  [ ! -e "$BATS_TEST_TMPDIR/out.tar.gz.part" ]
}

@test "bk_archive: mariadb-dump con --routines --events" {
  mk_site blog.miosito.it yes
  make_stub mariadb-dump 'echo "mariadb-dump $*" >>"$CALLS"; echo "-- dump"'
  bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  grep -q "mariadb-dump --single-transaction --routines --events site_blog_miosito_it" "$CALLS"
}

@test "bk_archive: stderr del tar del sito sanificato nel registro" {
  mk_site blog.miosito.it no
  # shellcheck disable=SC2016
  make_stub runuser-ev 'printf "ev\033[31m\nFAKE-LINE\n" >&2; shift 3
if [[ "$1" == env ]]; then shift; while [[ "$1" == -i || "$1" == *=* ]]; do shift; done; fi
exec "$@"'
  FM_RUNUSER=runuser-ev bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  run ! grep -q $'\033' "$VPS_LOG"
  run ! grep -q '^FAKE-LINE' "$VPS_LOG"
  grep -q 'ev' "$VPS_LOG"
}

@test "bk_archive: link a /etc/shadow resta un link e nessun file contiene il contenuto" {
  mk_site blog.miosito.it no
  printf 'SENTINELLA-SEGRETA\n' >"$BATS_TEST_TMPDIR/segreto"
  ln -s "$BATS_TEST_TMPDIR/segreto" "$SITES_WWW/blog.miosito.it/public/l"
  bk_archive blog.miosito.it "$BATS_TEST_TMPDIR/out.tar.gz"
  local w="$BATS_TEST_TMPDIR/x"
  mkdir -p "$w/files"
  tar -xzf "$BATS_TEST_TMPDIR/out.tar.gz" -C "$w"
  run tar -tvzf "$w/files.tar.gz"
  [[ "$output" =~ (^|$'\n')l[rwx-]{9}.*public/l\ -\>\ "$BATS_TEST_TMPDIR"/segreto ]]
  tar -xzf "$w/files.tar.gz" -C "$w/files" --no-same-owner
  [ -L "$w/files/public/l" ]
  run ! grep -rq SENTINELLA-SEGRETA "$w/files" "$w/manifest.json"
}

@test "bk_verify: bypass della divisione centrale di ' -> ' (nome e destinazione)" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src/public"
  ln -s "$SITES_WWW/x.it/public/d -> e/../../../../../../etc/shadow" "$w/src/public/a -> b"
  fl_arc "$w"
  bk_verify "$w/a.tar.gz" && false
  true
}

@test "bk_verify: link assoluto solo dentro la radice del sito (dominio del manifest)" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src/public/d"
  ln -s "$SITES_WWW/x.it/public/d" "$w/src/public/ok"
  ln -s "$SITES_WWW/x.it/wp-config.php" "$w/src/public/ok2"
  fl_arc "$w"
  run bk_verify "$w/a.tar.gz"
  [ "$status" -eq 0 ]
  local t
  for t in "$SITES_WWW/altro.it/public" "$SITES_WWW/x.it/../altro.it/public" "$SITES_WWW/x.it.evil/public" /etc/shadow "$SITES_WWW/x.it/public/../../altro.it"; do
    rm -rf "$w/src"
    mkdir -p "$w/src/public"
    ln -s "$t" "$w/src/public/l"
    fl_arc "$w"
    bk_verify "$w/a.tar.gz" && { echo "accettato: $t"; false; }
  done
  true
}

@test "bk_verify: link a catena (up -> .. e up2 -> up/..) rifiutati" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src/public"
  ln -s .. "$w/src/public/up"
  ln -s up/.. "$w/src/public/up2"
  fl_arc "$w"
  bk_verify "$w/a.tar.gz" && false
  # un nome sotto un link dell'archivio
  rm -rf "$w/src"
  mkdir -p "$w/src/public"
  ln -s . "$w/src/public/self"
  echo x >"$w/src/zz"
  tar -czf "$w/files.tar.gz" -C "$w/src" public zz --transform='s,^zz$,public/self/zz,'
  arc_from_files "$w" "$w/a.tar.gz"
  bk_verify "$w/a.tar.gz" && false
  true
}

@test "bk_verify: solo file, cartelle, link e hardlink (fifo rifiutato)" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src/public"
  mkfifo "$w/src/public/ff"
  fl_arc "$w"
  bk_verify "$w/a.tar.gz" && false
  true
}

@test "bk_verify: nome del manifest che non è un dominio, sha256 non esadecimale" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src/public"
  echo x >"$w/src/public/f"
  tar -czf "$w/files.tar.gz" -C "$w/src" public
  jq -n '{domain:"x.it", sha256:{files:"ZZ", db:null}}' >"$w/manifest.json"
  tar -czf "$w/a.tar.gz" -C "$w" manifest.json files.tar.gz
  bk_verify "$w/a.tar.gz" && false
  arc_from_files "$w" "$w/b.tar.gz"
  jq '.domain = "../x"' "$w/manifest.json" >"$w/m2" && mv "$w/m2" "$w/manifest.json"
  tar -czf "$w/c.tar.gz" -C "$w" manifest.json files.tar.gz
  bk_verify "$w/c.tar.gz" && false
  run bk_verify "$w/b.tar.gz"
  [ "$status" -eq 0 ]
}

@test "bk_verify: nomi duplicati nell'archivio esterno" {
  local w="$BATS_TEST_TMPDIR/w"
  mkdir -p "$w/src/public"
  echo x >"$w/src/public/f"
  fl_arc "$w"
  tar -czf "$w/dup.tar.gz" --hard-dereference -C "$w" manifest.json files.tar.gz manifest.json
  bk_verify "$w/dup.tar.gz" && false
  [[ "$BK_ERR" == *duplicat* ]]
}

@test "bk_keep_plan: la data è l'ultima occorrenza nel nome" {
  run bk_keep_plan x-20990101-0000-20261001-0400.tgz x-20261002-0400.tgz x-20261003-0400.tgz x-20261004-0400.tgz
  [ "$output" = x-20990101-0000-20261001-0400.tgz ]
}

@test "bk_space_ok: BYTES enorme o oltre 2^50 rifiutato senza overflow" {
  run bk_space_ok "$BATS_TEST_TMPDIR" 1125899906842625
  [ "$status" -eq 1 ]
  run bk_space_ok "$BATS_TEST_TMPDIR" 99999999999999999999999
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# tools/vps-backup: collegamento a Drive, stato, configurazione, timer (Task 2)
# ---------------------------------------------------------------------------

# bk_tool_env — ambiente del tool: tutto nel tmp del test, rclone e systemctl finti.
# Stub di rclone: annota gli argomenti in rclone.calls e lo stdin di rcat in rcat.stdin;
# se esiste rclone.fail (contiene un sottocomando) quel sottocomando fallisce con
# il testo di rclone.msg su stderr; `about` stampa about.json se esiste, altrimenti fallisce.
bk_tool_env() {
  export SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
  export BK_CONFIG="$BK_DIR/config.json" BK_STATE="$BK_DIR/state.json"
  mkdir -p "$SYSTEMD_DIR" "$BK_DIR" "$VPS_OPT/secrets"
  T_TOOL="$REPO_ROOT/tools/vps-backup"
  # shellcheck disable=SC2016
  make_stub rclone 'T="$BATS_TEST_TMPDIR"
echo "$*" >>"$T/rclone.calls"
sub=""
for a in "$@"; do case "$a" in mkdir|rcat|deletefile|about) sub="$a";; esac; done
if [[ "$sub" == rcat ]]; then cat >"$T/rcat.stdin"; fi
if [[ -f "$T/rclone.fail" && "$(cat "$T/rclone.fail")" == "$sub" ]]; then cat "$T/rclone.msg" >&2; exit 1; fi
if [[ "$sub" == about ]]; then [[ -f "$T/about.json" ]] || exit 1; cat "$T/about.json"; fi
exit 0'
  # shellcheck disable=SC2016
  make_stub systemctl 'T="$BATS_TEST_TMPDIR"
echo "$*" >>"$T/systemctl.calls"
if [[ "$1" == is-active ]]; then
  if [[ -f "$T/unit.active" ]]; then echo active; exit 0; fi
  echo inactive; echo inactive; exit 3
fi
if [[ -n "${LOCKCHECK:-}" ]]; then if flock -n "$LOCKCHECK" -c true; then echo free >>"$T/lock.at.systemctl"; else echo held >>"$T/lock.at.systemctl"; fi; fi
if [[ -f "$T/fail.$1" ]]; then exit 1; fi
exit 0'
}

TOKEN_OK='{"access_token":"ya29.SEGRETO-ACCESSO","token_type":"Bearer","refresh_token":"1//SEGRETO-RINNOVO","expiry":"2026-10-23T12:00:00.123456789+02:00"}'

# bk_tool ARGS... — lancia il tool (stdin passa); l'uscita è in $output / $status.
bk_tool() {
  run --separate-stderr env VPS_OPT="$VPS_OPT" VPS_LIB="$REPO_ROOT/lib" VPS_LOG="$VPS_LOG" VPS_NO_CHOWN=1 \
    SYSTEMD_DIR="$SYSTEMD_DIR" BK_DIR="$BK_DIR" BK_LOCK_DIR="$BK_LOCK_DIR" PATH="$PATH" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    bash "$T_TOOL" "$@"
}

@test "vps-backup connect: rclone.conf 600 con scope drive.file, cartella creata, file di prova scritto e cancellato" {
  bk_tool_env
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -eq 0 ]
  jq -e --arg f "Plancia-$(hostname -s)" '.ok == true and .folder == $f' <<<"$output"
  c="$VPS_OPT/secrets/rclone.conf"
  [ "$(stat -c %a "$c")" = 600 ]
  grep -qxF '[gdrive]' "$c"
  grep -qxF 'type = drive' "$c"
  grep -qxF 'scope = drive.file' "$c"
  grep -q '^token = {.*"refresh_token":"1//SEGRETO-RINNOVO"' "$c"
  run ! grep -q client_id "$c"
  grep -q -- "--config $c mkdir gdrive:Plancia-" "$BATS_TEST_TMPDIR/rclone.calls"
  grep -q 'rcat gdrive:Plancia-.*/.plancia-test' "$BATS_TEST_TMPDIR/rclone.calls"
  grep -q 'deletefile gdrive:Plancia-.*/.plancia-test' "$BATS_TEST_TMPDIR/rclone.calls"
  [ -s "$BATS_TEST_TMPDIR/rcat.stdin" ]
  [ "$(ls -A "$VPS_OPT/secrets" | grep rclone)" = rclone.conf ]
}

@test "vps-backup connect: il token non compare né nell'output né nel log né negli argomenti" {
  bk_tool_env
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -eq 0 ]
  run ! grep -q 'SEGRETO' <<<"$output$stderr"
  run ! grep -q 'SEGRETO' "$VPS_LOG"
  run ! grep -q 'SEGRETO' "$BATS_TEST_TMPDIR/rclone.calls"
}

@test "vps-backup connect: client id e secret propri finiscono nel file" {
  bk_tool_env
  bk_tool connect < <(printf '%s\nmio-id.apps.googleusercontent.com\nGOCSPX-abc_DEF-123\n' "$TOKEN_OK")
  [ "$status" -eq 0 ]
  c="$VPS_OPT/secrets/rclone.conf"
  grep -qxF 'client_id = mio-id.apps.googleusercontent.com' "$c"
  grep -qxF 'client_secret = GOCSPX-abc_DEF-123' "$c"
  run ! grep -q 'GOCSPX' <<<"$output$stderr"
}

@test "vps-backup connect: client id senza secret, o con caratteri strani, è rifiutato" {
  bk_tool_env
  bk_tool connect < <(printf '%s\nsolo-id\n' "$TOKEN_OK")
  [ "$status" -ne 0 ]
  bk_tool connect < <(printf '%s\nid\nsec ret\n' "$TOKEN_OK")
  [ "$status" -ne 0 ]
  [ ! -e "$VPS_OPT/secrets/rclone.conf" ]
}

@test "vps-backup connect: token vuoto, non JSON o senza refresh_token = errore, nessun file" {
  bk_tool_env
  for t in '' 'non json' '[1,2]' '{"access_token":"a"}' '{"access_token":"","refresh_token":"r"}' '{"access_token":"a","refresh_token":5}' "$TOKEN_OK $TOKEN_OK"; do
    bk_tool connect <<<"$t"
    [ "$status" -ne 0 ]
    jq -e '.ok == false and (.error | length > 0)' <<<"$output"
    [ -z "$(ls -A "$VPS_OPT/secrets" | grep rclone || true)" ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/rclone.calls" ]
}

@test "vps-backup connect: Drive rifiuta = errore leggibile senza token, nessun file" {
  bk_tool_env
  echo mkdir >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "ERROR : login: Invalid token ya29.SEGRETO-ACCESSO 1//SEGRETO-RINNOVO" >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("Invalid token"))' <<<"$output"
  run ! grep -q 'SEGRETO' <<<"$output$stderr"
  run ! grep -q 'SEGRETO' "$VPS_LOG"
  [ -z "$(ls -A "$VPS_OPT/secrets" | grep rclone || true)" ]
}

@test "vps-backup connect: se il file di prova non si scrive, torna il rclone.conf di prima" {
  bk_tool_env
  echo vecchio >"$VPS_OPT/secrets/rclone.conf"
  chmod 600 "$VPS_OPT/secrets/rclone.conf"
  echo rcat >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "Drive pieno" >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  [ "$(cat "$VPS_OPT/secrets/rclone.conf")" = vecchio ]
  [ "$(ls -A "$VPS_OPT/secrets" | grep rclone)" = rclone.conf ]
}

@test "vps-backup connect: usa la cartella già configurata" {
  bk_tool_env
  echo '{"enabled":false,"time":"04:00","folder":"MieiBackup"}' >"$BK_CONFIG"
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -eq 0 ]
  jq -e '.folder == "MieiBackup"' <<<"$output"
  grep -q 'mkdir gdrive:MieiBackup$' "$BATS_TEST_TMPDIR/rclone.calls"
}

@test "vps-backup disconnect: toglie rclone.conf, spegne il timer, la configurazione resta ma disattivata" {
  bk_tool_env
  echo x >"$VPS_OPT/secrets/rclone.conf"
  echo '{"enabled":true,"time":"03:30","folder":"F"}' >"$BK_CONFIG"
  bk_tool disconnect
  [ "$status" -eq 0 ]
  jq -e '.ok == true' <<<"$output"
  [ ! -e "$VPS_OPT/secrets/rclone.conf" ]
  grep -qxF 'disable --now vps-backup.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
  jq -e '.enabled == false and .time == "03:30" and .folder == "F"' "$BK_CONFIG"
  # già scollegato: non è un errore
  bk_tool disconnect
  [ "$status" -eq 0 ]
}

@test "vps-backup config: scrive config.json 600, drop-in del timer, abilita il timer" {
  bk_tool_env
  echo x >"$VPS_OPT/secrets/rclone.conf"
  bk_tool config <<<'{"enabled":true,"time":"02:15","folder":"Backup-vps_1.x"}'
  [ "$status" -eq 0 ]
  jq -e '.ok == true' <<<"$output"
  [ "$(stat -c %a "$BK_CONFIG")" = 600 ]
  jq -e '. == {enabled:true,time:"02:15",folder:"Backup-vps_1.x"}' "$BK_CONFIG"
  d="$SYSTEMD_DIR/vps-backup.timer.d/ora.conf"
  [ "$(cat "$d")" = "$(printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 02:15:00')" ]
  grep -qxF 'daemon-reload' "$BATS_TEST_TMPDIR/systemctl.calls"
  grep -qxF 'enable --now vps-backup.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "vps-backup config: enabled false spegne il timer; folder omesso = quello attuale" {
  bk_tool_env
  echo '{"enabled":true,"time":"04:00","folder":"Cart"}' >"$BK_CONFIG"
  bk_tool config <<<'{"enabled":false,"time":"05:00"}'
  [ "$status" -eq 0 ]
  jq -e '.enabled == false and .time == "05:00" and .folder == "Cart"' "$BK_CONFIG"
  grep -qxF 'disable --now vps-backup.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
  grep -q 'OnCalendar=\*-\*-\* 05:00:00' "$SYSTEMD_DIR/vps-backup.timer.d/ora.conf"
}

@test "vps-backup config: ora o cartella non valide, o Drive non collegato = errore, nulla scritto" {
  bk_tool_env
  echo x >"$VPS_OPT/secrets/rclone.conf"
  for j in '{"enabled":true,"time":"25:00","folder":"a"}' '{"enabled":true,"time":"4:00","folder":"a"}' \
    '{"enabled":true,"time":"12:60","folder":"a"}' '{"enabled":true,"time":"04:00","folder":"../x"}' \
    '{"enabled":true,"time":"04:00","folder":"a/b"}' '{"enabled":true,"time":"04:00","folder":".."}' \
    '{"enabled":true,"time":"04:00","folder":""}' '{"enabled":true,"time":"04:00","folder":5}' \
    '{"enabled":"si","time":"04:00","folder":"a"}' '{"time":"04:00"}' 'non json' '[]'; do
    bk_tool config <<<"$j"
    [ "$status" -ne 0 ]
    jq -e '.ok == false' <<<"$output"
  done
  [ ! -e "$BK_CONFIG" ]
  [ ! -e "$SYSTEMD_DIR/vps-backup.timer.d" ]
  rm "$VPS_OPT/secrets/rclone.conf"
  bk_tool config <<<'{"enabled":true,"time":"04:00","folder":"a"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"non collegato"* ]]
  [ ! -e "$BK_CONFIG" ]
}

@test "vps-backup config: timer che non parte = errore con saved true" {
  bk_tool_env
  echo x >"$VPS_OPT/secrets/rclone.conf"
  touch "$BATS_TEST_TMPDIR/fail.enable"
  bk_tool config <<<'{"enabled":true,"time":"04:00","folder":"a"}'
  [ "$status" -ne 0 ]
  jq -e '.ok == false and .saved == true' <<<"$output"
  [ -f "$BK_CONFIG" ]
}

@test "vps-backup status: prima del primo giro, non collegato, valori predefiniti" {
  bk_tool_env
  bk_tool status
  [ "$status" -eq 0 ]
  jq -e --arg f "Plancia-$(hostname -s)" '. == {ok:true,connected:false,folder:$f,enabled:false,time:"04:00",job:null,interrupted:false,interrupted_job:null,last_run:null,last_restore:null,drive:null,auth:{pending:false,expires:null}}' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/rclone.calls" ]
}

@test "vps-backup status: collegato, spazio di Drive, ultimo giro e lavoro dallo stato" {
  bk_tool_env
  echo x >"$VPS_OPT/secrets/rclone.conf"
  echo '{"enabled":true,"time":"03:00","folder":"Cart"}' >"$BK_CONFIG"
  echo '{"used":1234,"total":16106127360,"free":5}' >"$BATS_TEST_TMPDIR/about.json"
  cat >"$BK_STATE" <<'J'
{"job":{"op":"run","step":"archivio","domain":"a.it","started_at":"2026-10-23T04:00:01+02:00"},
 "last_run":{"started_at":"s","finished_at":"f","ok":false,"sites":[{"domain":"a.it","ok":false,"error":"x","size":0}]}}
J
  # il job si mostra solo se un giro tiene davvero il lock globale
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  bk_tool status
  exec {gl}>&-
  [ "$status" -eq 0 ]
  jq -e '.connected == true and .enabled == true and .time == "03:00" and .folder == "Cart"
    and .drive == {used:1234,total:16106127360} and .job.op == "run" and .job.domain == "a.it"
    and .last_run.ok == false and .last_run.sites[0].domain == "a.it"' <<<"$output"
}

@test "vps-backup status: Drive che non risponde = drive null, non un errore" {
  bk_tool_env
  echo x >"$VPS_OPT/secrets/rclone.conf"
  bk_tool status
  [ "$status" -eq 0 ]
  jq -e '.ok == true and .connected == true and .drive == null' <<<"$output"
}

@test "vps-backup status: config.json o state.json rovinati = predefiniti" {
  bk_tool_env
  echo 'garbage' >"$BK_CONFIG"
  echo '[1]' >"$BK_STATE"
  bk_tool status
  [ "$status" -eq 0 ]
  jq -e '.time == "04:00" and .enabled == false and .job == null and .last_run == null' <<<"$output"
}

@test "vps-backup: comando sconosciuto o assente = errore d'uso" {
  bk_tool_env
  bk_tool
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | startswith("uso:"))' <<<"$output"
  bk_tool run
  [ "$status" -ne 0 ]
  jq -e '.ok == false' <<<"$output"
}

@test "vps-backup _run con SUDO_USER (o via systemd) è rifiutato prima di caricare le librerie" {
  run env SUDO_USER=panel bash "$REPO_ROOT/tools/vps-backup" _run
  [ "$status" -eq 1 ]
  [ "$output" = '{"ok":false,"error":"comando interno"}' ]
  run env VPS_BACKUP_VIA_SYSTEMD=1 bash "$REPO_ROOT/tools/vps-backup" _run
  [ "$status" -eq 1 ]
  [ "$output" = '{"ok":false,"error":"comando interno"}' ]
  run env SUDO_USER=panel bash "$REPO_ROOT/tools/vps-backup" _restore x
  [ "$status" -eq 1 ]
  [ "$output" = '{"ok":false,"error":"comando interno"}' ]
}

@test "vps-backup sotto sudo si rilancia con systemd-run, stdin e codice d'uscita compresi" {
  # shellcheck disable=SC2016
  make_stub systemd-run 'echo "systemd-run $*" >>"$BATS_TEST_TMPDIR/calls"; cat >"$BATS_TEST_TMPDIR/stdin"; echo "{\"ok\":true,\"interno\":true}"; exit 7'
  run bash -c "printf 'dati-segreti\n' | SUDO_USER=panel bash '$REPO_ROOT/tools/vps-backup' connect"
  [ "$status" -eq 7 ]
  [ "$output" = '{"ok":true,"interno":true}' ]
  grep -qx 'systemd-run --wait --pipe --collect --quiet --service-type=exec --setenv=VPS_BACKUP_VIA_SYSTEMD=1 /opt/vps/bin/vps-backup connect' "$BATS_TEST_TMPDIR/calls"
  [ "$(cat "$BATS_TEST_TMPDIR/stdin")" = dati-segreti ]
}

@test "sudoers del pannello elenca vps-backup" {
  grep -q '/opt/vps/bin/vps-backup' "$REPO_ROOT/templates/sudoers-vps-panel"
}

@test "unità systemd di vps-backup: service oneshot con _run, timer Persistent alle 04:00" {
  grep -qxF 'Type=oneshot' "$REPO_ROOT/templates/vps-backup.service"
  grep -qxF 'ExecStart=/opt/vps/bin/vps-backup _run' "$REPO_ROOT/templates/vps-backup.service"
  grep -qxF 'OnCalendar=*-*-* 04:00:00' "$REPO_ROOT/templates/vps-backup.timer"
  grep -qxF 'Persistent=true' "$REPO_ROOT/templates/vps-backup.timer"
  grep -qxF 'WantedBy=timers.target' "$REPO_ROOT/templates/vps-backup.timer"
}

# --- fix round 1 -------------------------------------------------------------

@test "vps-backup connect: mktemp che fallisce = errore, rclone.conf di prima intatto" {
  bk_tool_env
  echo vecchio >"$VPS_OPT/secrets/rclone.conf"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\ncase "$1" in "%s"/*) exit 1;; esac\nexec /usr/bin/mktemp "$@"\n' "$VPS_OPT/secrets" >"$BATS_TEST_TMPDIR/bin/mktemp"
  chmod +x "$BATS_TEST_TMPDIR/bin/mktemp"
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("nulla è cambiato"))' <<<"$output"
  [ "$(cat "$VPS_OPT/secrets/rclone.conf")" = vecchio ]
  [ ! -e "$BATS_TEST_TMPDIR/rclone.calls" ]
}

@test "vps-backup connect: copia di sicurezza che fallisce = rifiuto prima di toccare il file attuale" {
  bk_tool_env
  echo vecchio >"$VPS_OPT/secrets/rclone.conf"
  make_stub cp 'exit 1'
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("nulla è cambiato"))' <<<"$output"
  [ "$(cat "$VPS_OPT/secrets/rclone.conf")" = vecchio ]
  [ -z "$(ls -A "$VPS_OPT/secrets" | grep -- '-prev\|-new' || true)" ]
  [ ! -e "$BATS_TEST_TMPDIR/rclone.calls" ]
}

@test "vps-backup connect: copia di sicurezza vuota (cp che non copia) = rifiuto, mai ripristino di un file vuoto" {
  bk_tool_env
  echo vecchio >"$VPS_OPT/secrets/rclone.conf"
  make_stub cp 'exit 0'
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  [ "$(cat "$VPS_OPT/secrets/rclone.conf")" = vecchio ]
}

@test "vps-backup connect: avanzi .rclone-prev/.rclone-new di un giro interrotto vengono tolti" {
  bk_tool_env
  echo a >"$VPS_OPT/secrets/.rclone-prev.AAAAAA"
  echo b >"$VPS_OPT/secrets/.rclone-new.BBBBBB"
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -eq 0 ]
  [ "$(ls -A "$VPS_OPT/secrets" | grep rclone)" = rclone.conf ]
}

@test "vps-backup config: config.json che non si scrive = errore e drop-in com'era" {
  bk_tool_env
  echo x >"$VPS_OPT/secrets/rclone.conf"
  bk_tool config <<<'{"enabled":true,"time":"02:15","folder":"a"}'
  [ "$status" -eq 0 ]
  prima="$(cat "$SYSTEMD_DIR/vps-backup.timer.d/ora.conf")"
  rm "$BK_CONFIG"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\ncase "$1" in "%s"/*) exit 1;; esac\nexec /usr/bin/mktemp "$@"\n' "$BK_DIR" >"$BATS_TEST_TMPDIR/bin/mktemp"
  chmod +x "$BATS_TEST_TMPDIR/bin/mktemp"
  bk_tool config <<<'{"enabled":true,"time":"05:45","folder":"a"}'
  [ "$status" -ne 0 ]
  jq -e '.ok == false' <<<"$output"
  [ "$(cat "$SYSTEMD_DIR/vps-backup.timer.d/ora.conf")" = "$prima" ]
  [ ! -e "$BK_CONFIG" ]
}

@test "vps-backup: sotto sudo l'ambiente di rclone e VPS_NO_CHOWN vengono tolti" {
  grep -q 'unset VPS_NO_CHOWN "${!RCLONE_@}"' "$REPO_ROOT/tools/vps-backup"
}

# ---------------------------------------------------------------------------
# Task 3: il giro (_run, run), conservazione, pannello, avviso
# ---------------------------------------------------------------------------

# bk_run_env — Drive finto in $BATS_TEST_TMPDIR/drive, pannello con il suo .env,
# curl che finge Telegram. rclone.fail = sottocomandi che falliscono (separati da spazio),
# rclone.msg = il loro messaggio, rclone.trunc = il file caricato arriva troncato.
bk_run_env() {
  bk_tool_env
  export MON_CONFIG="$BATS_TEST_TMPDIR/mon.json" BK_NOW=20261001-0400
  DRIVE="$BATS_TEST_TMPDIR/drive"
  mkdir -p "$DRIVE" "$BATS_TEST_TMPDIR/panel/config"
  echo 'DB_NAME=mysql' >"$BATS_TEST_TMPDIR/panel/config/.env"
  jq --arg p "$BATS_TEST_TMPDIR/panel" '.panel.path = $p | .panel.db = "vpspanel"' "$VPS_OPT/manifest.json" >"$VPS_OPT/m.tmp"
  mv "$VPS_OPT/m.tmp" "$VPS_OPT/manifest.json"
  echo x >"$VPS_OPT/secrets/rclone.conf"
  echo '{"enabled":true,"time":"04:00","folder":"F"}' >"$BK_CONFIG"
  # il dump non deve ereditare i lock di vps-backup
  # shellcheck disable=SC2016
  make_stub mariadb-dump 'n=0; for f in /proc/self/fd/*; do case "$(readlink "$f" 2>/dev/null)" in *vps-*.lock) n=$((n+1));; esac; done
echo $n >>"$BATS_TEST_TMPDIR/lockfds"; echo "-- dump $*"; exit "${STUB_RC_mariadb_dump:-0}"'
  # shellcheck disable=SC2016
  make_stub rclone 'T="$BATS_TEST_TMPDIR"; D="$T/drive"
echo "$*" >>"$T/rclone.calls"
jq -c ".job | {step, domain}" "$BK_STATE" >>"$T/steps.log" 2>/dev/null || echo null >>"$T/steps.log"
n=0; for f in /proc/self/fd/*; do case "$(readlink "$f" 2>/dev/null)" in *vps-*.lock) n=$((n+1));; esac; done; echo $n >>"$T/lockfds"
[[ "$1" == --config ]] && shift 2
sub="$1"; shift
if [[ " $(cat "$T/rclone.fail" 2>/dev/null) " == *" $sub "* ]]; then cat "$T/rclone.msg" >&2; exit 1; fi
rem() { echo "$D/${1#gdrive:}"; }
case "$sub" in
  mkdir) mkdir -p "$(rem "$1")" ;;
  copyto)
    if [[ "$1" == gdrive:* ]]; then cp "$(rem "$1")" "$2" || exit 1; exit 0; fi
    mkdir -p "$(dirname "$(rem "$2")")"
    cp "$BK_STATE" "$T/state.during" 2>/dev/null || true
    if [[ -f "$T/rclone.trunc" ]]; then head -c 3 "$1" >"$(rem "$2")"; else cp "$1" "$(rem "$2")"; fi ;;
  lsjson)
    mode="$1"; d="$(rem "$2")"
    [[ -d "$d" ]] || { echo "directory not found" >&2; exit 3; }
    for f in "$d"/*; do
      [[ -e "$f" ]] || continue
      if [[ "$mode" == --dirs-only && -d "$f" ]]; then jq -nc --arg n "$(basename "$f")" "{Name:\$n,IsDir:true}"; fi
      if [[ "$mode" == --files-only && -f "$f" ]]; then jq -nc --arg n "$(basename "$f")" --argjson s "$(stat -c %s "$f")" "{Name:\$n,Size:\$s,IsDir:false}"; fi
    done | jq -s . ;;
  cat) n=999999999; if [[ "$1" == --count ]]; then n="$2"; shift 2; fi; f="$(rem "$1")"; [[ -f "$f" ]] || { echo "object not found" >&2; exit 3; }; head -c "$n" "$f" ;;
  deletefile) rm -f "$(rem "${@: -1}")" ;;
  purge) rm -rf "$(rem "${@: -1}")" ;;
  cleanup) ;;
esac
exit 0'
  # shellcheck disable=SC2016
  make_stub curl 'T="$BATS_TEST_TMPDIR"
n=0; for f in /proc/self/fd/*; do case "$(readlink "$f" 2>/dev/null)" in *vps-*.lock) n=$((n+1));; esac; done; echo $n >>"$T/curl.lockfds"
printf "%s\n" "$@" >>"$T/curl.args"
cat >>"$T/curl.stdin"
printf "%s" "${CURL_REPLY:-{\"ok\":true\}}"'
  jq -n --arg t "123456:ABCdefGHIjklMNOpqrSTUvwxYZ0123456789_-" \
    '{enabled:false,telegram:{bot_token:$t,chat_id:"-100123"},healthchecks_url:"",urls:[],thresholds:{}}' >"$MON_CONFIG"
}

# drive_files DOMINIO — nomi dei file sul Drive finto, uno per riga.
drive_files() { ls "$DRIVE/F/$1" 2>/dev/null || true; }

@test "_run: tre siti = tre caricamenti più il pannello, niente in backups/tmp, stato e permessi" {
  bk_run_env
  mk_site a.it yes
  mk_site b.it no
  mk_site c.it yes
  bk_tool _run
  [ "$status" -eq 0 ]
  [ "$(grep -c ' copyto ' "$BATS_TEST_TMPDIR/rclone.calls")" -eq 4 ]
  for d in a.it b.it c.it; do
    [ "$(drive_files $d)" = "$d-20261001-0400.tar.gz" ]
    run bk_manifest "$DRIVE/F/$d/$d-20261001-0400.tar.gz"
    [ "$(jq -r .domain <<<"$output")" = "$d" ]
  done
  [ "$(drive_files _pannello)" = pannello-20261001-0400.sql.gz ]
  gzip -t "$DRIVE/F/_pannello/pannello-20261001-0400.sql.gz"
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
  [ "$(stat -c %a "$BK_STATE")" = 600 ]
  jq -e '.job == null and .last_run.ok == true and (.last_run.sites | length) == 3
    and (.last_run.sites | all(.ok)) and .last_run.panel.ok == true and .last_run.alert == null' "$BK_STATE"
  [ ! -e "$BATS_TEST_TMPDIR/curl.args" ]
}

@test "_run: durante il giro state.json ha job con unità, inizio, passo e dominio" {
  bk_run_env
  mk_site a.it no
  bk_tool _run
  [ "$status" -eq 0 ]
  jq -e '.job.step == "upload" or .job.step == "panel"' "$BATS_TEST_TMPDIR/state.during"
  # l'ultima fotografia (caricamento del pannello) ha comunque unità e inizio
  jq -e '.job.unit == "vps-backup.service" and (.job.started | length > 0)' "$BATS_TEST_TMPDIR/state.during"
}

@test "_run: alla quarta esecuzione su Drive restano 3 copie per sito e per il pannello" {
  bk_run_env
  mk_site a.it yes
  for n in 1 2 3 4; do
    BK_NOW="2026100${n}-0400" bk_tool _run
    [ "$status" -eq 0 ]
  done
  [ "$(drive_files a.it | wc -l)" -eq 3 ]
  [ "$(drive_files a.it | head -1)" = a.it-20261002-0400.tar.gz ]
  [ "$(drive_files _pannello | wc -l)" -eq 3 ]
  [ "$(drive_files _pannello | tail -1)" = pannello-20261004-0400.sql.gz ]
  # senza cestino e senza cleanup (lo scope drive.file non permette di svuotarlo)
  run ! grep -q ' cleanup' "$BATS_TEST_TMPDIR/rclone.calls"
  grep -q 'deletefile --drive-use-trash=false gdrive:F/a.it/a.it-20261001-0400.tar.gz' "$BATS_TEST_TMPDIR/rclone.calls"
  [ -z "$(grep ' deletefile ' "$BATS_TEST_TMPDIR/rclone.calls" | grep -v -- '--drive-use-trash=false' || true)" ]
  jq -e '.last_run.sites[0].deleted == 1' "$BK_STATE"
}

@test "_run: caricamento che fallisce (token revocato) = nessuna eliminazione, ogni sito ko con motivo, un solo avviso" {
  bk_run_env
  mk_site a.it yes
  mk_site b.it no
  mkdir -p "$DRIVE/F/a.it"
  for n in 1 2 3; do echo vecchia >"$DRIVE/F/a.it/a.it-2026090${n}-0400.tar.gz"; done
  echo copyto >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "Failed to copy: invalid_grant: Token has been expired or revoked." >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_tool _run
  [ "$status" -eq 1 ]
  run ! grep -q ' deletefile \| purge \| cleanup' "$BATS_TEST_TMPDIR/rclone.calls"
  [ "$(drive_files a.it | wc -l)" -eq 3 ]
  jq -e '.last_run.ok == false and (.last_run.sites | all(.ok == false and (.reason | test("revoked"))))
    and .last_run.alert == "sent" and .job == null' "$BK_STATE"
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
  # un solo messaggio, con N, dominio e motivo; il token del bot solo in stdin
  [ "$(grep -c '^text=' "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
  grep -qx "text=💾 $(hostname): Backup: 2 siti non salvati" "$BATS_TEST_TMPDIR/curl.args"
  grep -q '^pannello: ' "$BATS_TEST_TMPDIR/curl.args"
  grep -q '^a.it: caricamento su Drive non riuscito' "$BATS_TEST_TMPDIR/curl.args"
  grep -q '^b.it: caricamento su Drive non riuscito' "$BATS_TEST_TMPDIR/curl.args"
  run ! grep -q '123456:ABC' "$BATS_TEST_TMPDIR/curl.args"
}

@test "_run: Drive che non risponde = ogni sito ko senza costruire archivi, un solo avviso" {
  bk_run_env
  mk_site a.it yes
  echo mkdir >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "couldn't login" >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_tool _run
  [ "$status" -eq 1 ]
  jq -e '.last_run.sites[0].ok == false and (.last_run.sites[0].reason | test("non risponde")) and .last_run.panel.ok == false' "$BK_STATE"
  [ "$(grep -c '^text=' "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
}

@test "_run: dimensione su Drive diversa = sito ko e copia caricata cancellata, vecchie intatte" {
  bk_run_env
  mk_site a.it no
  mkdir -p "$DRIVE/F/a.it"
  for n in 1 2 3; do echo vecchia >"$DRIVE/F/a.it/a.it-2026090${n}-0400.tar.gz"; done
  : >"$BATS_TEST_TMPDIR/rclone.trunc"
  bk_tool _run
  [ "$status" -eq 1 ]
  jq -e '.last_run.sites[0].ok == false and (.last_run.sites[0].reason | test("dimensione diversa"))' "$BK_STATE"
  [ "$(drive_files a.it | wc -l)" -eq 3 ]
  [ ! -e "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz" ]
}

@test "_run: spazio insufficiente per un sito: lui ko, gli altri salvati, tmp vuota" {
  bk_run_env
  mk_site big.it no
  mk_site ok.it no
  # shellcheck disable=SC2016
  make_stub du 'case "$*" in *big.it*) printf "99999999999999\t%s\n" "${@: -1}";; *) exec /usr/bin/du "$@";; esac'
  bk_tool _run
  [ "$status" -eq 1 ]
  jq -e '(.last_run.sites[] | select(.domain == "big.it") | .ok == false and .reason == "spazio insufficiente")
    and (.last_run.sites[] | select(.domain == "ok.it") | .ok == true)' "$BK_STATE"
  [ -z "$(drive_files big.it)" ]
  [ -n "$(drive_files ok.it)" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
  [ "$(grep -c '^text=' "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
}

@test "_run: sito con il lock preso = sito occupato, gli altri vanno avanti" {
  bk_run_env
  mk_site busy.it no
  mk_site free.it no
  exec {lk}>>"$BK_LOCK_DIR/vps-site.$(site_slug busy.it).lock"
  flock -n "$lk"
  bk_tool _run
  exec {lk}>&-
  [ "$status" -eq 1 ]
  jq -e '(.last_run.sites[] | select(.domain == "busy.it") | .reason == "sito occupato")
    and (.last_run.sites[] | select(.domain == "free.it") | .ok == true)' "$BK_STATE"
  [ -z "$(drive_files busy.it)" ]
}

@test "_run: solo i siti active o disabled, un registro rovinato non ferma il giro" {
  bk_run_env
  mk_site a.it no
  mk_site off.it no
  site_reg_update off.it '.state = "disabled"'
  mk_site new.it no
  site_reg_update new.it '.state = "creating"'
  echo '{rotto' >"$SITES_DIR/zz.it.json"
  bk_tool _run
  [ "$status" -eq 0 ]
  [ -n "$(drive_files a.it)" ]
  [ -n "$(drive_files off.it)" ]
  [ -z "$(drive_files new.it)" ]
}

@test "_run: sito eliminato, ultima copia di 31 giorni fa = cartella cancellata; di 29 = resta" {
  bk_run_env
  mk_site a.it no
  mkdir -p "$DRIVE/F/vecchio.it" "$DRIVE/F/recente.it" "$DRIVE/F/_pannello" "$DRIVE/F/senzadata.it"
  echo x >"$DRIVE/F/vecchio.it/vecchio.it-$(date -d '31 days ago' +%Y%m%d)-0400.tar.gz"
  echo x >"$DRIVE/F/vecchio.it/vecchio.it-$(date -d '40 days ago' +%Y%m%d)-0400.tar.gz"
  echo x >"$DRIVE/F/recente.it/recente.it-$(date -d '29 days ago' +%Y%m%d)-0400.tar.gz"
  echo x >"$DRIVE/F/_pannello/pannello-$(date -d '90 days ago' +%Y%m%d)-0400.sql.gz"
  echo x >"$DRIVE/F/senzadata.it/qualcosa.bin"
  echo '{"job":null,"last_run":null,"known":["vecchio.it","recente.it","senzadata.it"]}' >"$BK_STATE"
  bk_tool _run
  [ "$status" -eq 0 ]
  [ ! -e "$DRIVE/F/vecchio.it" ]
  jq -e '.known | index("vecchio.it") == null and index("a.it") != null and index("recente.it") != null' "$BK_STATE"
  [ -d "$DRIVE/F/recente.it" ]
  [ -d "$DRIVE/F/senzadata.it" ]
  [ -d "$DRIVE/F/a.it" ]
  jq -e '.last_run.purged == ["vecchio.it"]' "$BK_STATE"
}

@test "_run: un sito ancora nel registro (anche creating) non viene mai eliminato da Drive" {
  bk_run_env
  mk_site a.it no
  mk_site new.it no
  site_reg_update new.it '.state = "creating"'
  mkdir -p "$DRIVE/F/new.it"
  echo x >"$DRIVE/F/new.it/new.it-20200101-0400.tar.gz"
  bk_tool _run
  [ -d "$DRIVE/F/new.it" ]
}

@test "_run: avviso Telegram con sorveglianza spenta; esito in last_run.alert (sent / failed / not_configured)" {
  bk_run_env
  mk_site a.it no
  echo copyto >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "Drive pieno" >"$BATS_TEST_TMPDIR/rclone.msg"
  jq -e '.enabled == false' "$MON_CONFIG"
  bk_tool _run
  jq -e '.last_run.alert == "sent"' "$BK_STATE"
  export CURL_REPLY='{"ok":false,"description":"chat not found","error_code":400}'
  bk_tool _run
  jq -e '.last_run.alert == "failed: chat not found"' "$BK_STATE"
  rm -f "$MON_CONFIG"
  bk_tool _run
  jq -e '.last_run.alert == "not_configured"' "$BK_STATE"
}

@test "_run: dump del pannello con root dal socket, database dal manifest, non dal .env del pannello" {
  bk_run_env
  mk_site a.it no
  bk_tool _run
  [ "$status" -eq 0 ]
  zcat "$DRIVE/F/_pannello/pannello-20261001-0400.sql.gz" | grep -q -- '--single-transaction --routines --events vpspanel'
}

@test "_run: dump che fallisce = pannello ko, siti salvati, avviso con la riga pannello" {
  bk_run_env
  mk_site a.it no
  # il dump del sito non ha db; quello del pannello fallisce
  STUB_RC_mariadb_dump=1 bk_tool _run
  [ "$status" -eq 1 ]
  jq -e '.last_run.ok == false and .last_run.panel.ok == false and .last_run.sites[0].ok == true' "$BK_STATE"
  [ -z "$(drive_files _pannello)" ]
  jq -e '.last_run.alert == "sent"' "$BK_STATE"
  grep -qx "text=💾 $(hostname): Backup: pannello non salvato" "$BATS_TEST_TMPDIR/curl.args"
  grep -q '^pannello: dump del database del pannello non riuscito' "$BATS_TEST_TMPDIR/curl.args"
}

@test "_run: avanzi bk.* vecchi di oltre un giorno in tmp si tolgono, quelli freschi no" {
  bk_run_env
  mkdir -p "$BK_BACKUPS/tmp/bk.vecchio" "$BK_BACKUPS/tmp/bk.fresco"
  touch -d '2 days ago' "$BK_BACKUPS/tmp/bk.vecchio"
  mk_site a.it no
  bk_tool _run
  [ ! -e "$BK_BACKUPS/tmp/bk.vecchio" ]
  [ -d "$BK_BACKUPS/tmp/bk.fresco" ]
}

@test "_run: senza Drive collegato = errore" {
  bk_run_env
  rm "$VPS_OPT/secrets/rclone.conf"
  bk_tool _run
  [ "$status" -ne 0 ]
  [[ "$output" == *"non collegato"* ]]
}

@test "_run: rifiutato attraverso sudo (resta interno)" {
  bk_run_env
  run env SUDO_USER=panel VPS_OPT="$VPS_OPT" bash "$T_TOOL" _run
  [ "$status" -ne 0 ]
  [[ "$output" == *"comando interno"* ]]
}

@test "lock globale: _run, run, connect, disconnect e config rifiutano mentre un giro lo tiene; status risponde" {
  bk_run_env
  mk_site a.it no
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  bk_tool _run
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup in corso"* ]]
  bk_tool run
  [ "$status" -ne 0 ]
  jq -e '.error == "backup in corso"' <<<"$output"
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  jq -e '.error == "backup in corso, riprova dopo"' <<<"$output"
  bk_tool disconnect
  [ "$status" -ne 0 ]
  jq -e '.error == "backup in corso, riprova dopo"' <<<"$output"
  bk_tool config <<<'{"enabled":true,"time":"05:00"}'
  [ "$status" -ne 0 ]
  jq -e '.error == "backup in corso, riprova dopo"' <<<"$output"
  [ -f "$VPS_OPT/secrets/rclone.conf" ]
  bk_tool status
  [ "$status" -eq 0 ]
  exec {gl}>&-
  bk_tool disconnect
  [ "$status" -eq 0 ]
}

@test "run: parte come unità systemd vps-backup-run e risponde subito" {
  bk_run_env
  bk_tool run
  [ "$status" -eq 0 ]
  jq -e '.ok == true and .started == true' <<<"$output"
  grep -q 'systemd-run --unit vps-backup-run --collect' "$CALLS"
  grep -q 'BK_UNIT=vps-backup-run' "$CALLS"
  grep -q ' _run$' "$CALLS"
}

@test "run: systemd-run che fallisce = errore" {
  bk_run_env
  STUB_RC_systemd_run=1 bk_tool run
  [ "$status" -ne 0 ]
  jq -e '.ok == false' <<<"$output"
}

@test "status: un job rimasto in state.json senza lock tenuto = job null e interrupted" {
  bk_run_env
  echo '{"job":{"unit":"vps-backup.service","started":"2026-10-01T04:00:00+02:00","step":"upload","domain":"a.it"},"last_run":null}' >"$BK_STATE"
  bk_tool status
  jq -e '.job == null and .interrupted == true' <<<"$output"
  # con il lock tenuto il giro è vivo: il job si mostra
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  bk_tool status
  exec {gl}>&-
  jq -e '.job.step == "upload" and .job.domain == "a.it" and .interrupted == false' <<<"$output"
}

@test "connect: se il ripristino del collegamento precedente fallisce, la copia di sicurezza resta e l'errore lo dice" {
  bk_run_env
  echo vecchio >"$VPS_OPT/secrets/rclone.conf"
  echo mkdir >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "Invalid token" >"$BATS_TEST_TMPDIR/rclone.msg"
  # il primo mv (nuovo file al posto del vecchio) funziona, il secondo (ripristino) no
  # shellcheck disable=SC2016
  make_stub mv 'n="$BATS_TEST_TMPDIR/mv.n"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo $c >"$n"
if (( c >= 2 )); then exit 1; fi
exec /usr/bin/mv "$@"'
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  jq -e '.error | test("non è stato ripristinato")' <<<"$output"
  [ "$(cat "$VPS_OPT"/secrets/.rclone-prev.*)" = vecchio ]
}

# ---------------------------------------------------------------------------
# Task 3, fix round 1
# ---------------------------------------------------------------------------

@test "_run: Drive irraggiungibile con zero siti = avviso con la riga pannello" {
  bk_run_env
  echo mkdir >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "couldn't login" >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_tool _run
  [ "$status" -eq 1 ]
  jq -e '.last_run.ok == false and .last_run.alert == "sent" and .job == null' "$BK_STATE"
  grep -qx "text=💾 $(hostname): Backup: pannello non salvato" "$BATS_TEST_TMPDIR/curl.args"
  grep -q '^pannello: Google Drive non risponde' "$BATS_TEST_TMPDIR/curl.args"
}

@test "_run: esce con 1 se un sito è fallito, con stato scritto e avviso inviato; 0 se tutto salvato" {
  bk_run_env
  mk_site a.it no
  bk_tool _run
  [ "$status" -eq 0 ]
  echo copyto >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "Drive pieno" >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_tool _run
  [ "$status" -eq 1 ]
  jq -e '.last_run.alert == "sent" and .job == null' "$BK_STATE"
}

@test "_run: VPS ricostruita (stato vuoto) = cartelle vecchie su Drive mai eliminate" {
  bk_run_env
  mk_site a.it no
  mkdir -p "$DRIVE/F/altro.it"
  echo x >"$DRIVE/F/altro.it/altro.it-$(date -d '60 days ago' +%Y%m%d)-0400.tar.gz"
  bk_tool _run
  [ "$status" -eq 0 ]
  [ -d "$DRIVE/F/altro.it" ]
  run ! grep -q ' purge' "$BATS_TEST_TMPDIR/rclone.calls"
  # il sito salvato entra in known
  jq -e '.known == ["a.it"]' "$BK_STATE"
}

@test "_run: known sopravvive ai giri e un sito eliminato esce da known dopo la pulizia" {
  bk_run_env
  mk_site a.it no
  mk_site b.it no
  bk_tool _run
  jq -e '.known | sort == ["a.it","b.it"]' "$BK_STATE"
  rm "$SITES_DIR/b.it.json"
  bk_tool _run
  jq -e '.known | sort == ["a.it","b.it"]' "$BK_STATE"
  # b.it ha ancora una copia recente: resta
  [ -d "$DRIVE/F/b.it" ]
}

@test "_run: conservazione e pulizia guardano solo i nomi che crea il programma" {
  bk_run_env
  mk_site a.it no
  mkdir -p "$DRIVE/F/a.it" "$DRIVE/F/_pannello" "$DRIVE/F/gone.it"
  for n in 1 2 3; do echo v >"$DRIVE/F/a.it/a.it-2026090${n}-0400.tar.gz"; done
  echo n >"$DRIVE/F/a.it/note-20200101-1200.txt"
  echo f >"$DRIVE/F/a.it/other.it-29990101-0400.tar.gz"
  echo f >"$DRIVE/F/a.it/a.it-29990101-0400.tar.gz.bak"
  echo p >"$DRIVE/F/_pannello/note-20200101-1200.txt"
  echo p >"$DRIVE/F/_pannello/pannello-29990101-0400.sql.gz.old"
  # una cartella eliminata con dentro solo un file estraneo e futuro/vecchio
  echo x >"$DRIVE/F/gone.it/other-20200101-0400.tar.gz"
  echo '{"job":null,"last_run":null,"known":["gone.it"]}' >"$BK_STATE"
  bk_tool _run
  [ "$status" -eq 0 ]
  # le tre copie vecchie: ne restano 2 + la nuova, gli estranei intatti
  [ ! -e "$DRIVE/F/a.it/a.it-20260901-0400.tar.gz" ]
  [ -e "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz" ]
  [ -e "$DRIVE/F/a.it/note-20200101-1200.txt" ]
  [ -e "$DRIVE/F/a.it/other.it-29990101-0400.tar.gz" ]
  [ -e "$DRIVE/F/a.it/a.it-29990101-0400.tar.gz.bak" ]
  [ -e "$DRIVE/F/_pannello/note-20200101-1200.txt" ]
  [ -e "$DRIVE/F/_pannello/pannello-29990101-0400.sql.gz.old" ]
  # nessuna copia riconoscibile del sito: la cartella non si elimina
  [ -d "$DRIVE/F/gone.it" ]
}

@test "_run: purge senza cestino (--drive-use-trash=false)" {
  bk_run_env
  mk_site a.it no
  mkdir -p "$DRIVE/F/vecchio.it"
  echo x >"$DRIVE/F/vecchio.it/vecchio.it-$(date -d '40 days ago' +%Y%m%d)-0400.tar.gz"
  echo '{"job":null,"last_run":null,"known":["vecchio.it"]}' >"$BK_STATE"
  bk_tool _run
  grep -q 'purge --drive-use-trash=false gdrive:F/vecchio.it' "$BATS_TEST_TMPDIR/rclone.calls"
}

@test "_run: i lock non arrivano ai figli (rclone e dump)" {
  bk_run_env
  mk_site a.it yes
  bk_tool _run
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/lockfds" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/lockfds")" = 0 ]
}

@test "_run: cartella bk.run.* di un giro morto si toglie a qualunque età" {
  bk_run_env
  mkdir -p "$BK_BACKUPS/tmp/bk.run.MORTO1" "$BK_BACKUPS/tmp/bk.altro"
  mk_site a.it no
  bk_tool _run
  [ ! -e "$BK_BACKUPS/tmp/bk.run.MORTO1" ]
  [ -d "$BK_BACKUPS/tmp/bk.altro" ]
}

@test "_run: du che fallisce = dimensione del sito non leggibile, non spazio insufficiente" {
  bk_run_env
  mk_site rotto.it no
  mk_site ok.it no
  # shellcheck disable=SC2016
  make_stub du 'case "$*" in *rotto.it*) exit 1;; *) exec /usr/bin/du "$@";; esac'
  bk_tool _run
  [ "$status" -eq 1 ]
  jq -e '(.last_run.sites[] | select(.domain == "rotto.it") | .reason == "dimensione del sito non leggibile")
    and (.last_run.sites[] | select(.domain == "ok.it") | .ok)' "$BK_STATE"
}

@test "_run: la stima del peso conta solo public/ (du -sbP) più wp-config e database" {
  bk_run_env
  mk_site a.it no
  # shellcheck disable=SC2016
  make_stub du 'echo "$*" >>"$BATS_TEST_TMPDIR/du.calls"; exec /usr/bin/du "$@"'
  bk_tool _run
  grep -q -- "-sbP -- $SITES_WWW/a.it/public" "$BATS_TEST_TMPDIR/du.calls"
}

@test "_run: i passi in state.json durante il giro, nell'ordine" {
  bk_run_env
  mk_site a.it no
  mkdir -p "$DRIVE/F/a.it"
  for n in 1 2 3; do echo v >"$DRIVE/F/a.it/a.it-2026090${n}-0400.tar.gz"; done
  bk_tool _run
  [ "$status" -eq 0 ]
  seq="$(jq -r '"\(.step):\(.domain)"' "$BATS_TEST_TMPDIR/steps.log" | uniq | paste -sd' ')"
  [ "$seq" = "start:null upload:a.it retention:a.it panel:null purge:null" ]
}

@test "status: job con unità systemd ancora attiva = job mostrato, non interrotto" {
  bk_run_env
  echo '{"job":{"unit":"vps-backup-run","started":"s","step":"site","domain":"a.it"},"last_run":null}' >"$BK_STATE"
  echo active >"$BATS_TEST_TMPDIR/unit.active"
  bk_tool status
  jq -e '.job.step == "site" and .interrupted == false' <<<"$output"
  rm "$BATS_TEST_TMPDIR/unit.active"
  bk_tool status
  jq -e '.job == null and .interrupted == true' <<<"$output"
  grep -q 'is-active vps-backup-run.service vps-backup.service' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "run: un secondo run con l'unità già partita (lock non ancora preso) = backup in corso" {
  bk_run_env
  echo active >"$BATS_TEST_TMPDIR/unit.active"
  bk_tool run
  [ "$status" -ne 0 ]
  jq -e '.error == "backup in corso"' <<<"$output"
  run ! grep -q 'systemd-run' "$CALLS"
}

@test "config: il lock globale è libero quando partono daemon-reload e enable" {
  bk_run_env
  export LOCKCHECK="$BK_LOCK_DIR/vps-backup.lock"
  # il lock del test stesso non c'è: systemctl prova a prenderlo e riesce solo se _no_se_in_corso l'ha lasciato
  bk_tool config <<<'{"enabled":true,"time":"05:00"}'
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/lock.at.systemctl" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/lock.at.systemctl")" = free ]
}

# ---------------------------------------------------------------------------
# Copie locali, copie su Drive, ripristino (Task 4)
# ---------------------------------------------------------------------------

# rs_env — ambiente dei ripristini: Drive finto (bk_run_env) più un finto server SQL
# che tiene i database in $FAKEDB/<db>/<tabella> e capisce solo le poche istruzioni
# che il codice usa. Chi non è root può lavorare solo sul proprio database
# (e su <slug>__ripristino); la riga BROKEN simula un dump rotto.
rs_env() {
  bk_run_env
  export FAKEDB="$BATS_TEST_TMPDIR/fakedb" BK_CF_PURGE="$BATS_TEST_TMPDIR/bin/vps-cf-purge"
  mkdir -p "$FAKEDB"
  # shellcheck disable=SC2016
  make_stub mariadb 'T="$BATS_TEST_TMPDIR"; F="$T/fakedb"
echo "mariadb $*" >>"$T/mariadb.calls"
allargs=" $* "
cp "$BK_STATE" "$T/state.during.$(date +%s%N)" 2>/dev/null || true
for l in "$BK_LOCK_DIR"/vps-site.*.lock "$BK_LOCK_DIR"/vps-backup.lock; do
  [[ -e "$l" ]] || continue
  if flock -n "$l" true; then echo "libero $(basename "$l")" >>"$T/lock.seen"; else echo "preso $(basename "$l")" >>"$T/lock.seen"; fi
done
user=root; db=""; q=""
while (($#)); do
  case "$1" in
    --defaults-file=*) cnf="${1#*=}"; user="$(sed -n "s/^user=//p" "$cnf")"; cp "$cnf" "$T/cnf.seen"; cat "$cnf" >>"$T/cnf.all" ;;
    -e) q="$2"; shift ;;
    -*) ;;
    *) db="$1" ;;
  esac
  shift
done
if [[ -n "$q" ]]; then in="$q"; else in="$(cat)"; fi
[[ "$user" == root ]] || printf '%s\n' "$in" >>"$T/load.stdin"
ok_db() { [[ "$1" == "$user" || "$1" == "${user}__ripristino" || ( "$user" == *_r && "$1" == "${user%_r}__ripristino" ) ]]; }
if [[ "$user" != root && -n "$db" ]] && ! ok_db "$db"; then echo "ERROR 1044 access denied" >&2; exit 1; fi
sandbox=no; [[ "$allargs" == *" --sandbox "* ]] && sandbox=si
if [[ "$user" != root && -f "$T/fail.load.$db" ]]; then rm -f "$T/fail.load.$db"; echo "ERROR 2013 lost connection" >&2; exit 1; fi
while IFS= read -r line; do
  case "$line" in
    "DROP DATABASE IF EXISTS "*) n="${line#*\`}"; n="${n%%\`*}"; rm -rf "${F:?}/${n:?}"; echo "$user drop $n" >>"$T/sql.log" ;;
    "CREATE DATABASE "*) n="${line#*\`}"; n="${n%%\`*}"; mkdir -p "$F/$n"; echo "$user create $n" >>"$T/sql.log" ;;
    GRANT*|REVOKE*|"CREATE USER"*|"DROP USER"*) echo "$user $line" >>"$T/grants.log" ;;
    "DROP TABLE "*) n="${line#DROP TABLE }"; n="${n%;}"; n="${n//\`/}"; rm -f "$F/$db/$n" ;;
    \\!*|system\ *|tee\ *|source\ *)
      if [[ "$sandbox" == si ]]; then echo "ERROR: command not allowed in sandbox mode" >&2; exit 1; fi
      case "$line" in
        \\!*) eval "${line#* }" ;;
        system\ *) eval "${line#* }" ;;
        tee\ *) : >"${line#* }" ;;
        source\ *) echo "ERROR 1064 (42000): You have an error in your SQL syntax near $(cat "${line#* }")" >&2; exit 1 ;;
      esac ;;
    "CREATE TABLE "*) [[ -d "$F/$db" ]] || { echo "ERROR 1046 no database" >&2; exit 1; }; n="${line#*\`}"; n="${n%%\`*}"; : >"$F/$db/$n" ;;
    "INSERT INTO "*) n="${line#*\`}"; n="${n%%\`*}"; [[ -f "$F/$db/$n" ]] || { echo "ERROR 1146" >&2; exit 1; }; echo "$line" >>"$F/$db/$n" ;;
    BROKEN*) echo "ERROR 1064 (42000): syntax error" >&2; exit 1 ;;
    "USE "*) n="${line#USE }"; n="${n%;}"; if [[ "$user" != root ]] && ! ok_db "$n"; then echo "ERROR 1044 access denied" >&2; exit 1; fi; db="$n" ;;
  esac
done <<<"$in"
exit "${STUB_RC_mariadb:-0}"'
  # il dump di un database finto: le sue tabelle con le righe; DUMP_EXTRA aggiunge una riga in coda
  # shellcheck disable=SC2016
  make_stub mariadb-dump 'T="$BATS_TEST_TMPDIR"; F="$T/fakedb"; db="${@: -1}"
[[ "${STUB_RC_mariadb_dump:-0}" == 0 ]] || exit "$STUB_RC_mariadb_dump"
echo "-- dump $db"
for t in "$F/$db"/*; do
  [[ -f "$t" ]] || continue
  echo "CREATE TABLE \`$(basename "$t")\` (id int);"
  cat "$t"
done
[[ -z "${DUMP_EXTRA:-}" ]] || echo "$DUMP_EXTRA"
exit 0'
  # shellcheck disable=SC2016
  make_stub vps-cf-purge 'n=0; for f in /proc/self/fd/*; do case "$(readlink "$f" 2>/dev/null)" in *vps-*.lock) n=$((n+1));; esac; done; echo $n >>"$BATS_TEST_TMPDIR/cf.lockfds"
echo "vps-cf-purge $*" >>"$BATS_TEST_TMPDIR/cf.purge"; exit "${STUB_RC_cf_purge:-0}"'
  # redis-cli come in sites_helper, ma conta anche i lock ereditati
  # shellcheck disable=SC2016
  make_stub redis-cli 'n=0; for f in /proc/self/fd/*; do case "$(readlink "$f" 2>/dev/null)" in *vps-*.lock) n=$((n+1));; esac; done; echo $n >>"$BATS_TEST_TMPDIR/redis.lockfds"
echo "redis-cli $* auth=${REDISCLI_AUTH:+si}" >>"$CALLS"; exit "${STUB_RC_redis_cli:-0}"'
  # l'utente Redis del sito c'è nel file ACL
  printf 'user default off\nuser site_a_it on #abc ~site_a_it:* +@all\n' >"$REDIS_ACL_FILE"
}

# fdb_set DB TABELLA [RIGA...] — crea la tabella nel finto server.
fdb_set() {
  local db="$1" t="$2"
  shift 2
  mkdir -p "$FAKEDB/$db"
  : >"$FAKEDB/$db/$t"
  local r
  for r in "$@"; do printf 'INSERT INTO `%s` VALUES (%s);\n' "$t" "$r" >>"$FAKEDB/$db/$t"; done
}

# fdb_tables DB — tabelle del finto server, in una riga.
fdb_tables() { ls "$FAKEDB/$1" 2>/dev/null | paste -sd' '; }

# rs_site — sito a.it con database "buono", archiviato in backups/sites; poi
# modificato: un file nuovo, uno tolto, wp-config cambiato, tabelle diverse.
# Lascia il nome dell'archivio in $ARC_NAME (kind/file) e il percorso in $ARC.
rs_site() {
  local d=a.it slug root
  mk_site "$d" yes
  site_reg_update "$d" '.zone = "miosito.it"'
  slug="$(site_reg_get "$d" .slug)"
  root="$SITES_WWW/$d"
  printf 'DB_HOST=localhost\nDB_NAME=%s\nDB_USER=%s\nDB_PASS=Password-di-prova-123\n' "$slug" "$slug" >"$root/db.env"
  fdb_set "$slug" utenti "1,'ana'" "2,'bo'"
  fdb_set "$slug" ordini "10"
  mkdir -p "$BK_BACKUPS/sites"
  ARC_NAME="sites/$d-20261001-0400.tar.gz"
  ARC="$BK_BACKUPS/$ARC_NAME"
  bk_archive "$d" "$ARC"
  # dopo l'archivio il sito cambia
  echo nuovo >"$root/public/nuovo.txt"
  rm -f "$root/public/-x"
  echo '<?php // wp-config cambiato' >"$root/wp-config.php"
  rm -f "${FAKEDB:?}/${slug:?}/ordini"
  fdb_set "$slug" extra "7"
}

# --- list-local, read-local, delete-local ------------------------------------

@test "list-local: panel, sito nuovo, sito vecchio senza manifest, copia di sicurezza; restorable e scadenze" {
  rs_env
  mk_site a.it no
  mkdir -p "$BK_BACKUPS"/{panel,sites,restore}
  bk_archive a.it "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz"
  bk_archive a.it "$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz"
  # formato vecchio: tar di tutta la cartella e dump a parte
  tar -czf "$BK_BACKUPS/sites/b.it-20260901-120000.tar.gz" -C "$SITES_WWW" a.it
  echo x | gzip >"$BK_BACKUPS/sites/b.it-20260901-120000.sql.gz"
  echo y | gzip >"$BK_BACKUPS/panel/v1.6.1-20261003-030000-ab12.sql.gz"
  echo z >"$BK_BACKUPS/sites/estraneo.txt"
  touch -d '2026-10-01 04:00' "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz"
  touch -d '2026-10-02 10:15' "$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz"
  touch -d '2026-09-01 12:00' "$BK_BACKUPS/sites/b.it-20260901-120000".*
  touch -d '2026-10-03 03:00' "$BK_BACKUPS/panel/v1.6.1-20261003-030000-ab12.sql.gz"
  bk_tool list-local
  [ "$status" -eq 0 ]
  jq -e '.ok == true and (.items | length) == 5' <<<"$output"
  jq -e '.items[] | select(.name == "sites/a.it-20261001-0400.tar.gz")
    | .kind == "site" and .domain == "a.it" and .restorable == true and (.size > 0) and (.expires | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) and (.date | test("^2026-10-01T04:00"))' <<<"$output"
  jq -e '.items[] | select(.name == "restore/a.it-20261002-101500.tar.gz") | .kind == "restore" and .restorable == true and .domain == "a.it" and .expires == "2026-10-09"' <<<"$output"
  jq -e '.items[] | select(.name == "sites/b.it-20260901-120000.tar.gz") | .restorable == false and .kind == "site" and .domain == "b.it" and .expires == "2026-10-01"' <<<"$output"
  jq -e '.items[] | select(.name == "sites/b.it-20260901-120000.sql.gz") | .restorable == false' <<<"$output"
  jq -e '.items[] | select(.kind == "panel") | .name == "panel/v1.6.1-20261003-030000-ab12.sql.gz" and .domain == null and .expires == null and .restorable == false' <<<"$output"
  # ordinate dalla più recente
  [ "$(jq -r '.items[0].kind' <<<"$output")" = panel ]
}

@test "list-local: cartelle vuote o mancanti = elenco vuoto" {
  rs_env
  bk_tool list-local
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"ok":true,"items":[]}' ]
}

@test "read-local: la copia esce su stdout byte per byte; nomi non validi rifiutati" {
  rs_env
  mkdir -p "$BK_BACKUPS"/{panel,sites,restore}
  head -c 3000 /dev/urandom >"$BK_BACKUPS/panel/p-20261003-030000-ab12.sql.gz"
  bash "$T_TOOL" read-local panel/p-20261003-030000-ab12.sql.gz >"$BATS_TEST_TMPDIR/out.bin" 2>/dev/null
  cmp "$BATS_TEST_TMPDIR/out.bin" "$BK_BACKUPS/panel/p-20261003-030000-ab12.sql.gz"
  local n
  for n in ../../etc/passwd panel/../../etc/passwd panel/a/b.sql.gz tmp/x.tar.gz sites/..%2f x.sql.gz "panel/a b.sql.gz" panel/ "" sites/a.it-20261001-0400.tar.gz; do
    bk_tool read-local "$n"
    [ "$status" -ne 0 ] || { echo "accettato: $n"; false; }
    jq -e '.ok == false' <<<"$output"
  done
}

@test "delete-local: elimina solo dentro panel, sites e restore; ../../etc/passwd rifiutato" {
  rs_env
  mkdir -p "$BK_BACKUPS"/{panel,sites,restore}
  echo x >"$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz"
  echo x >"$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz"
  echo precious >"$BATS_TEST_TMPDIR/fuori"
  ln -s "$BATS_TEST_TMPDIR/fuori" "$BK_BACKUPS/sites/l.it-20261001-0400.tar.gz"
  local n
  for n in ../../etc/passwd restore/../sites/a.it-20261001-0400.tar.gz restore/a.it-20261002-101500.tar.gz/../x tmp/x ../fuori restore/a.it-20261002-1015.tar.gz.sh; do
    bk_tool delete-local "$n"
    [ "$status" -ne 0 ] || { echo "accettato: $n"; false; }
  done
  # un collegamento simbolico non si segue e non si tocca
  bk_tool delete-local sites/l.it-20261001-0400.tar.gz
  [ "$status" -ne 0 ]
  [ -f "$BATS_TEST_TMPDIR/fuori" ]
  [ -f "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz" ]
  bk_tool delete-local restore/a.it-20261002-101500.tar.gz
  [ "$status" -eq 0 ]
  jq -e '.ok == true' <<<"$output"
  [ ! -e "$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz" ]
  [ -f "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz" ]
  bk_tool delete-local restore/a.it-20261002-101500.tar.gz
  [ "$status" -ne 0 ]
}

@test "delete-local: rifiutato mentre un giro o un ripristino tiene il lock globale" {
  rs_env
  mkdir -p "$BK_BACKUPS/restore"
  echo x >"$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz"
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  bk_tool delete-local restore/a.it-20261002-101500.tar.gz
  exec {gl}>&-
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup in corso"* ]]
  [ -f "$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz" ]
}

# --- list-remote, read-remote -------------------------------------------------

@test "list-remote: siti con copie (più recente prima), present dal registro, pannello" {
  rs_env
  mk_site a.it no
  mkdir -p "$DRIVE/F/a.it" "$DRIVE/F/vecchio.it" "$DRIVE/F/_pannello"
  echo aa >"$DRIVE/F/a.it/a.it-20261001-0400.tar.gz"
  echo aaaa >"$DRIVE/F/a.it/a.it-20261002-0400.tar.gz"
  echo "non mia" >"$DRIVE/F/a.it/appunti.txt"
  echo v >"$DRIVE/F/vecchio.it/vecchio.it-20260901-0400.tar.gz"
  echo pp >"$DRIVE/F/_pannello/pannello-20261002-0400.sql.gz"
  bk_tool list-remote
  [ "$status" -eq 0 ]
  jq -e '.ok == true and (.sites | length) == 2' <<<"$output"
  jq -e '.sites[] | select(.domain == "a.it") | .present == true and (.copies | map(.name)) == ["a.it/a.it-20261002-0400.tar.gz","a.it/a.it-20261001-0400.tar.gz"]
    and .copies[0].size == 5 and (.copies[0].date | test("^2026-10-02T04:00"))' <<<"$output"
  jq -e '.sites[] | select(.domain == "vecchio.it") | .present == false and (.copies | length) == 1' <<<"$output"
  jq -e '.panel == [{"name":"_pannello/pannello-20261002-0400.sql.gz","date":"2026-10-02T04:00:00","size":3}]' <<<"$output"
}

@test "list-remote: cartella ancora inesistente = elenchi vuoti; Drive non collegato = errore" {
  rs_env
  bk_tool list-remote
  [ "$status" -eq 0 ]
  jq -e '.ok == true and .sites == [] and .panel == []' <<<"$output"
  rm "$VPS_OPT/secrets/rclone.conf"
  bk_tool list-remote
  [ "$status" -ne 0 ]
  [[ "$output" == *"non collegato"* ]]
}

@test "list-remote: Drive che non risponde = errore leggibile" {
  rs_env
  mkdir -p "$DRIVE/F"
  echo lsjson >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "token revocato" >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_tool list-remote
  [ "$status" -ne 0 ]
  [[ "$output" == *"token revocato"* ]]
}

@test "read-remote: scarica da Drive e manda su stdout, niente resta in backups/tmp; nomi non validi rifiutati" {
  rs_env
  mkdir -p "$DRIVE/F/a.it" "$DRIVE/F/_pannello"
  head -c 5000 /dev/urandom >"$DRIVE/F/a.it/a.it-20261001-0400.tar.gz"
  head -c 700 /dev/urandom >"$DRIVE/F/_pannello/pannello-20261001-0400.sql.gz"
  bash "$T_TOOL" read-remote a.it/a.it-20261001-0400.tar.gz >"$BATS_TEST_TMPDIR/o1" 2>/dev/null
  cmp "$BATS_TEST_TMPDIR/o1" "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz"
  bash "$T_TOOL" read-remote _pannello/pannello-20261001-0400.sql.gz >"$BATS_TEST_TMPDIR/o2" 2>/dev/null
  cmp "$BATS_TEST_TMPDIR/o2" "$DRIVE/F/_pannello/pannello-20261001-0400.sql.gz"
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
  local n
  for n in ../x a.it/../b.it/b.it-20261001-0400.tar.gz a.it/b.it-20261001-0400.tar.gz a.it/a.it-20261001-0400.tar.gz/x \
    /a.it/a.it-20261001-0400.tar.gz a.it/appunti.txt _pannello/../a.it/x "a.it/a.it-20261001-0400.tar.gz;ls" "" a.it _pannello/a.it-20261001-0400.tar.gz; do
    bk_tool read-remote "$n"
    [ "$status" -ne 0 ] || { echo "accettato: $n"; false; }
    jq -e '.ok == false' <<<"$output"
  done
  bk_tool read-remote a.it/a.it-20261009-0400.tar.gz
  [ "$status" -ne 0 ]
  [[ "$output" == *"non trovata"* ]]
}

# --- restore / restore-local: avvio -------------------------------------------

@test "restore: parte come unità vps-backup-restore-<slug> con _restore remote, risposta started" {
  rs_env
  rs_site
  mkdir -p "$DRIVE/F/a.it"
  cp "$ARC" "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz"
  bk_tool restore a.it a.it/a.it-20261001-0400.tar.gz files
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"ok":true,"started":true}' ]
  grep -q 'systemd-run --unit vps-backup-restore-site_a_it --collect' "$CALLS"
  grep -q 'BK_UNIT=vps-backup-restore-site_a_it' "$CALLS"
  grep -q ' _restore remote a.it a.it/a.it-20261001-0400.tar.gz files$' "$CALLS"
  # il sito non è stato toccato dal solo avvio
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
}

@test "restore-local: parte con _restore local, il dominio viene dal nome del file" {
  rs_env
  rs_site
  bk_tool restore-local "$ARC_NAME" all
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"ok":true,"started":true}' ]
  grep -q " _restore local a.it $ARC_NAME all\$" "$CALLS"
}

@test "restore: argomenti non validi, sito sconosciuto, Drive non collegato = errore e nessuna unità" {
  rs_env
  rs_site
  local a
  for a in "a.it a.it/a.it-20261001-0400.tar.gz tutto" "a.it a.it/a.it-20261001-0400.tar.gz" "a.it b.it/b.it-20261001-0400.tar.gz files" \
    "a.it a.it/../a.it-20261001-0400.tar.gz files" "../a.it a.it/a.it-20261001-0400.tar.gz files" "z.it z.it/z.it-20261001-0400.tar.gz files" \
    "a.it a.it/a.it-20261001-0400.tar.gz;x files"; do
    # shellcheck disable=SC2086
    bk_tool restore $a
    [ "$status" -ne 0 ] || { echo "accettato: $a"; false; }
  done
  for a in "panel/p-20261003-030000-ab12.sql.gz all" "../x all" "sites/a.it-20261001-0400.tar.gz tutto" "sites/a.it-20261001-0400.sql.gz all" "sites/z.it-20261001-0400.tar.gz all"; do
    # shellcheck disable=SC2086
    bk_tool restore-local $a
    [ "$status" -ne 0 ] || { echo "accettato: $a"; false; }
  done
  run ! grep -q 'systemd-run' "$CALLS"
  rm "$VPS_OPT/secrets/rclone.conf"
  bk_tool restore a.it a.it/a.it-20261001-0400.tar.gz files
  [ "$status" -ne 0 ]
  [[ "$output" == *"non collegato"* ]]
}

@test "restore: rifiutato con 'backup in corso' (lock globale) e 'ripristino in corso' (lock del sito)" {
  rs_env
  rs_site
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  bk_tool restore-local "$ARC_NAME" files
  exec {gl}>&-
  [ "$status" -ne 0 ]
  jq -e '.error == "backup in corso"' <<<"$output"
  exec {sl}>>"$BK_LOCK_DIR/vps-site.site_a_it.lock"
  flock -n "$sl"
  bk_tool restore-local "$ARC_NAME" files
  exec {sl}>&-
  [ "$status" -ne 0 ]
  [[ "$output" == *"ripristino in corso"* ]]
  run ! grep -q 'systemd-run' "$CALLS"
}

@test "restore: systemd-run che fallisce = errore" {
  rs_env
  rs_site
  STUB_RC_systemd_run=1 bk_tool restore-local "$ARC_NAME" files
  [ "$status" -ne 0 ]
  jq -e '.ok == false' <<<"$output"
}

@test "_restore: rifiutato attraverso sudo (resta interno)" {
  rs_env
  run env SUDO_USER=panel VPS_OPT="$VPS_OPT" bash "$T_TOOL" _restore local a.it x files
  [ "$status" -ne 0 ]
  [[ "$output" == *"comando interno"* ]]
}

# --- _restore: i passi ----------------------------------------------------------

# rs_run SRC DOM NAME MODE — lancia il ripristino vero e proprio (l'unità di systemd).
rs_run() { bk_tool _restore "$@"; }

@test "_restore db: tabelle del sito sostituite da quelle dell'archivio, file intatti, copia di sicurezza fatta, temporaneo tolto" {
  rs_env
  rs_site
  local slug=site_a_it
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  jq -e '.ok == true and .restore_ok == true' <<<"$output"
  [ "$(fdb_tables $slug)" = "ordini utenti" ]
  grep -q "'ana'" "$FAKEDB/$slug/utenti"
  # il database temporaneo non c'è più e il suo permesso è stato tolto
  [ ! -d "$FAKEDB/${slug}__ripristino" ]
  grep -q "DROP USER IF EXISTS 'site_a_it_r'" "$BATS_TEST_TMPDIR/grants.log"
  # file del sito intatti (anche quelli cambiati dopo l'archivio)
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  grep -q 'wp-config cambiato' "$SITES_WWW/a.it/wp-config.php"
  # copia di sicurezza: solo la parte toccata, nel formato nuovo
  [ "$(ls "$BK_BACKUPS/restore" | wc -l)" -eq 1 ]
  local s="$BK_BACKUPS/restore/$(ls "$BK_BACKUPS/restore")"
  [[ "$s" =~ /a\.it-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]]
  [ "$(stat -c %a "$s")" = 600 ]
  bk_verify "$s"
  tar -xzOf "$s" db.sql.gz | gzip -dc | grep -q 'extra'
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "_restore db: il dump si carica con l'utente del sito (mai root), password solo in un file 600, mai negli argomenti" {
  rs_env
  rs_site
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  grep -q '^user=site_a_it$' "$BATS_TEST_TMPDIR/cnf.seen"
  grep -q '^user=site_a_it_r$' "$BATS_TEST_TMPDIR/cnf.all"
  grep -q 'Password-di-prova-123' "$BATS_TEST_TMPDIR/cnf.seen"
  run ! grep -q 'Password-di-prova-123' "$BATS_TEST_TMPDIR/mariadb.calls"
  run ! grep -q 'Password-di-prova-123' "$VPS_LOG"
  # il permesso sul temporaneo c'è solo per il tempo del caricamento, con il _ protetto
  grep -q 'GRANT ALL PRIVILEGES ON `site\\_a\\_it\\_\\_ripristino`.\* TO .site_a_it_r.' "$BATS_TEST_TMPDIR/grants.log"
}

@test "_restore db: DEFINER tolto dalle definizioni di oggetti (si caricano con l'utente del sito), righe di dati intatte" {
  rs_env
  rs_site
  fdb_set site_a_it note "1,'DEFINER=\`x\`@\`y\`'"
  DUMP_EXTRA='/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER tr BEFORE INSERT ON u FOR EACH ROW SET NEW.a = 1 */' bk_archive a.it "$BK_BACKUPS/$ARC_NAME"
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  grep -q 'TRIGGER tr BEFORE INSERT' "$BATS_TEST_TMPDIR/load.stdin"
  run ! grep -q 'DEFINER=`root`' "$BATS_TEST_TMPDIR/load.stdin"
  grep -q "INSERT INTO \`note\` VALUES (1,'DEFINER=\`x\`@\`y\`')" "$BATS_TEST_TMPDIR/load.stdin"
}

@test "_restore files: public/ come nell'archivio, wp-config.php invariato, utente del sito, niente temporanei" {
  rs_env
  rs_site
  local root="$SITES_WWW/a.it"
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  jq -e '.restore_ok == true' <<<"$output"
  [ -f "$root/public/-x" ]
  [ -f "$root/public/a b.php" ]
  [ ! -e "$root/public/nuovo.txt" ]
  grep -q 'wp-config cambiato' "$root/wp-config.php"
  # il database non si tocca
  [ "$(fdb_tables site_a_it)" = "extra utenti" ]
  # tutto come utente del sito
  grep -q '^runuser -u site_a_it' "$CALLS"
  # nessun avanzo: né area di estrazione né il vecchio contenuto
  [ -z "$(ls -A "$root/tmp" | grep -v '^sess$' || true)" ]
  [ -d "$root/public" ]
}

@test "_restore files: la cartella public/ resta la stessa (permessi e ACL non si perdono), si sostituisce il contenuto" {
  rs_env
  rs_site
  local root="$SITES_WWW/a.it" ino
  ino="$(stat -c %i "$root/public")"
  chmod 2770 "$root/public"
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$root/public")" = "$ino" ]
  [ "$(stat -c %a "$root/public")" = 2770 ]
}

@test "_restore files: l'estrazione avviene come utente del sito, in tmp/.vpsbackup-x.*, con --no-same-owner e --no-same-permissions" {
  rs_env
  rs_site
  # shellcheck disable=SC2016
  make_stub tar 'case " $* " in *" -x"*) echo "tar $* cwd=$PWD" >>"$BATS_TEST_TMPDIR/tar.x";; esac; exec /usr/bin/tar "$@"'
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  grep -q -- '--no-same-owner' "$BATS_TEST_TMPDIR/tar.x"
  grep -q -- '--no-same-permissions' "$BATS_TEST_TMPDIR/tar.x"
  grep -q -- "-C tmp/.vpsbackup-x\." "$BATS_TEST_TMPDIR/tar.x"
  grep -q "cwd=$SITES_WWW/a.it" "$BATS_TEST_TMPDIR/tar.x"
}

@test "_restore all: file e database insieme" {
  rs_env
  rs_site
  rs_run local a.it "$ARC_NAME" all
  [ "$status" -eq 0 ]
  [ "$(fdb_tables site_a_it)" = "ordini utenti" ]
  [ -f "$SITES_WWW/a.it/public/-x" ]
  [ ! -e "$SITES_WWW/a.it/public/nuovo.txt" ]
  grep -q 'wp-config cambiato' "$SITES_WWW/a.it/wp-config.php"
  local s="$BK_BACKUPS/restore/$(ls "$BK_BACKUPS/restore")"
  tar -tzf "$s" | grep -qx db.sql.gz
  tar -xzOf "$s" files.tar.gz | tar -tzf - | grep -q 'public/nuovo.txt'
}

@test "_restore: manifest di un altro dominio = rifiutato prima di toccare nulla, nessuna copia di sicurezza" {
  rs_env
  rs_site
  mk_site b.it yes
  fdb_set site_b_it t "1"
  cp "$ARC" "$BK_BACKUPS/sites/b.it-20261001-0400.tar.gz"
  rs_run local b.it sites/b.it-20261001-0400.tar.gz all
  [ "$status" -ne 0 ]
  [ "$(fdb_tables site_b_it)" = "t" ]
  [ -f "$SITES_WWW/b.it/public/a b.php" ]
  [ -z "$(ls -A "$BK_BACKUPS/restore" 2>/dev/null)" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
  [[ "$(jq -r '.last_restore.error' "$BK_STATE")" == *"a.it"* ]]
}

@test "_restore: archivio con '../x' = rifiutato, sito intatto, niente copia di sicurezza né temporanei" {
  rs_env
  rs_site
  local w="$BATS_TEST_TMPDIR/evil" sha
  mkdir -p "$w/src/public"
  echo e >"$w/src/public/ok"
  tar -cf "$w/files.tar" -C "$w/src" public --transform 's,^public/ok$,public/../../x,'
  gzip -n "$w/files.tar"
  sha="$(sha256sum "$w/files.tar.gz" | cut -d' ' -f1)"
  jq -n --arg s "$sha" '{domain:"a.it", sha256:{files:$s, db:null}}' >"$w/manifest.json"
  tar -czf "$BK_BACKUPS/sites/a.it-20261005-0400.tar.gz" -C "$w" manifest.json files.tar.gz
  rs_run local a.it sites/a.it-20261005-0400.tar.gz files
  [ "$status" -ne 0 ]
  jq -e '.last_restore.ok == false' "$BK_STATE"
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ ! -e "$SITES_WWW/a.it/public/ok" ]
  [ -z "$(ls -A "$BK_BACKUPS/restore" 2>/dev/null)" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
  [ -z "$(ls -A "$SITES_WWW/a.it/tmp" | grep -v '^sess$' || true)" ]
}

@test "_restore: sha256 sbagliato = rifiutato, sito intatto, niente copia di sicurezza" {
  rs_env
  rs_site
  local w="$BATS_TEST_TMPDIR/x"
  mkdir -p "$w"
  tar -xzf "$ARC" -C "$w"
  jq '.sha256.files = ("0" * 64)' "$w/manifest.json" >"$w/m2" && mv "$w/m2" "$w/manifest.json"
  tar -czf "$BK_BACKUPS/sites/a.it-20261005-0400.tar.gz" -C "$w" manifest.json files.tar.gz db.sql.gz
  rs_run local a.it sites/a.it-20261005-0400.tar.gz all
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ "$(fdb_tables site_a_it)" = "extra utenti" ]
  [ -z "$(ls -A "$BK_BACKUPS/restore" 2>/dev/null)" ]
  jq -e '.last_restore.ok == false and (.last_restore.error | test("checksum"))' "$BK_STATE"
}

@test "_restore: archivio nel formato vecchio (senza manifest) = rifiutato" {
  rs_env
  rs_site
  tar -czf "$BK_BACKUPS/sites/a.it-20260901-120000.tar.gz" -C "$SITES_WWW" a.it
  rs_run local a.it sites/a.it-20260901-120000.tar.gz files
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  jq -e '.last_restore.ok == false' "$BK_STATE"
}

@test "_restore db: dump rotto a metà = il sito resta com'era (il caricamento di prova non lo tocca), esito con errore" {
  rs_env
  rs_site
  # un archivio con checksum giusti ma SQL che si rompe dopo le prime tabelle
  DUMP_EXTRA=BROKEN bk_archive a.it "$BK_BACKUPS/$ARC_NAME"
  fdb_set site_a_it prima "5"
  local before
  before="$(fdb_tables site_a_it)"
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -ne 0 ]
  jq -e '.restore_ok == false' <<<"$output"
  [ "$(fdb_tables site_a_it)" = "$before" ]
  [ ! -d "$FAKEDB/site_a_it__ripristino" ]
  jq -e '.last_restore.ok == false and .last_restore.mode == "db" and (.last_restore.error | length > 0)' "$BK_STATE"
  # nessuna copia di sicurezza lasciata per un ripristino mai cominciato
  [ -z "$(ls -A "$BK_BACKUPS/restore" 2>/dev/null)" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "_restore all: dump rotto = anche i file restano com'erano" {
  rs_env
  rs_site
  DUMP_EXTRA=BROKEN bk_archive a.it "$BK_BACKUPS/$ARC_NAME"
  rs_run local a.it "$ARC_NAME" all
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ ! -e "$SITES_WWW/a.it/public/-x" ]
  [ -z "$(ls -A "$SITES_WWW/a.it/tmp" | grep -v '^sess$' || true)" ]
}

@test "_restore db: caricamento vero che fallisce dopo la prova = si ricarica la copia di sicurezza" {
  rs_env
  rs_site
  local before
  before="$(fdb_tables site_a_it)"
  # la prova (su <slug>__ripristino) passa, il caricamento nel database del sito no
  touch "$BATS_TEST_TMPDIR/fail.load.site_a_it"
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -ne 0 ]
  jq -e '.last_restore.ok == false' "$BK_STATE"
  [ "$(fdb_tables site_a_it)" = "$before" ]
  grep -q '7' "$FAKEDB/site_a_it/extra"
}

@test "_restore all: database che fallisce dopo lo scambio dei file = anche i file tornano come prima" {
  rs_env
  rs_site
  touch "$BATS_TEST_TMPDIR/fail.load.site_a_it"
  rs_run local a.it "$ARC_NAME" all
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ ! -e "$SITES_WWW/a.it/public/-x" ]
  [ "$(fdb_tables site_a_it)" = "extra utenti" ]
  [ -z "$(ls -A "$SITES_WWW/a.it/tmp" | grep -v '^sess$' || true)" ]
}

@test "_restore files: scambio che fallisce a metà = il contenuto di prima torna in public/" {
  rs_env
  rs_site
  local root="$SITES_WWW/a.it"
  # lo spostamento del contenuto nuovo dentro public/ fallisce (quello di ritorno no)
  # shellcheck disable=SC2016
  make_stub mv 'if [[ "$*" == *"-t public"* && "$*" == *".vpsbackup-x."* ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -ne 0 ]
  [ -f "$root/public/nuovo.txt" ]
  [ -f "$root/public/a b.php" ]
  jq -e '.last_restore.ok == false' "$BK_STATE"
}

@test "_restore: archivio senza database ma sito con database = 'all' e 'db' rifiutati, 'files' accettato" {
  rs_env
  rs_site
  mk_site c.it no
  bk_archive c.it "$BK_BACKUPS/sites/c.it-20261001-0400.tar.gz"
  site_reg_update c.it '.db = true'
  rs_run local c.it sites/c.it-20261001-0400.tar.gz all
  [ "$status" -ne 0 ]
  rs_run local c.it sites/c.it-20261001-0400.tar.gz db
  [ "$status" -ne 0 ]
  jq -e '.last_restore.error | test("database")' "$BK_STATE"
  rs_run local c.it sites/c.it-20261001-0400.tar.gz files
  [ "$status" -eq 0 ]
}

@test "_restore: sito sconosciuto o non attivo, modo sbagliato, nome non valido = rifiutati" {
  rs_env
  rs_site
  rs_run local z.it sites/z.it-20261001-0400.tar.gz files
  [ "$status" -ne 0 ]
  rs_run local a.it "$ARC_NAME" tutto
  [ "$status" -ne 0 ]
  rs_run local a.it ../../etc/passwd files
  [ "$status" -ne 0 ]
  rs_run local a.it panel/p-20261003-030000-ab12.sql.gz files
  [ "$status" -ne 0 ]
  site_reg_update a.it '.state = "creating"'
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
}

@test "_restore: prende il lock globale e quello del sito per tutta la durata, li libera alla fine" {
  rs_env
  rs_site
  : >"$BK_LOCK_DIR/vps-site.site_a_it.lock"
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  grep -q 'preso vps-backup.lock' "$BATS_TEST_TMPDIR/lock.seen"
  grep -q 'preso vps-site.site_a_it.lock' "$BATS_TEST_TMPDIR/lock.seen"
  run ! grep -q 'libero vps-backup.lock' "$BATS_TEST_TMPDIR/lock.seen"
  # finito: liberi
  run bk_global_busy
  [ "$status" -eq 1 ]
  run bk_site_locked site_a_it
  [ "$status" -eq 1 ]
}

@test "_restore: rifiutato se un giro (lock globale) o un altro processo sul sito è in corso" {
  rs_env
  rs_site
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  rs_run local a.it "$ARC_NAME" files
  exec {gl}>&-
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup in corso"* ]]
  exec {sl}>>"$BK_LOCK_DIR/vps-site.site_a_it.lock"
  flock -n "$sl"
  rs_run local a.it "$ARC_NAME" files
  exec {sl}>&-
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
}

@test "_restore: lo stato in state.json durante il lavoro (op restore, dominio, passo), alla fine job null e last_restore; last_run e known restano" {
  rs_env
  rs_site
  echo '{"job":null,"last_run":{"ok":true,"started":"s"},"known":["a.it"]}' >"$BK_STATE"
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  local during
  during="$(ls "$BATS_TEST_TMPDIR"/state.during.* | head -n1)"
  jq -e '.job.op == "restore" and .job.domain == "a.it" and (.job.step | length > 0) and (.job.unit | length > 0) and (.job.started | length > 0)' "$during"
  jq -e --arg n "$ARC_NAME" '.job == null and .last_run.ok == true and .known == ["a.it"]
    and .last_restore.ok == true and .last_restore.domain == "a.it" and .last_restore.mode == "db"
    and .last_restore.name == $n and .last_restore.error == null and (.last_restore.finished | length > 0)' "$BK_STATE"
  [ "$(stat -c %a "$BK_STATE")" = 600 ]
  # un giro dopo il ripristino non cancella last_restore
  bk_tool _run
  jq -e '.last_restore.ok == true' "$BK_STATE"
  bk_tool status
  jq -e '.last_restore.domain == "a.it"' <<<"$output"
}

@test "_restore: Telegram a ogni esito, con il nome della macchina" {
  rs_env
  rs_site
  # la data è quella della copia (dal manifest), non quella del ripristino
  local exp
  exp="$(date -d "$(bk_manifest "$ARC" | jq -r .date)" '+%d/%m %H:%M')"
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  grep -q "♻️ $(hostname): a.it ripristinato al $exp: database" "$BATS_TEST_TMPDIR/curl.args"
  : >"$BATS_TEST_TMPDIR/curl.args"
  rs_run local a.it "$ARC_NAME" all
  grep -q "ripristinato al $exp: tutto" "$BATS_TEST_TMPDIR/curl.args"
  : >"$BATS_TEST_TMPDIR/curl.args"
  rs_run local a.it "$ARC_NAME" files
  grep -q "ripristinato al $exp: file" "$BATS_TEST_TMPDIR/curl.args"
}

@test "_restore: un fallimento manda il messaggio di errore con il motivo e dice che il sito è com'era" {
  rs_env
  rs_site
  local w="$BATS_TEST_TMPDIR/x"
  mkdir -p "$w"
  tar -xzf "$ARC" -C "$w"
  jq '.sha256.files = ("0" * 64)' "$w/manifest.json" >"$w/m2" && mv "$w/m2" "$w/manifest.json"
  tar -czf "$BK_BACKUPS/sites/a.it-20261005-0400.tar.gz" -C "$w" manifest.json files.tar.gz db.sql.gz
  rs_run local a.it sites/a.it-20261005-0400.tar.gz files
  [ "$status" -ne 0 ]
  grep -q "$(hostname): ripristino di a.it NON riuscito" "$BATS_TEST_TMPDIR/curl.args"
  grep -q 'checksum' "$BATS_TEST_TMPDIR/curl.args"
  jq -e '.last_restore.alert == "sent"' "$BK_STATE"
}

@test "_restore: dopo il successo svuota la cache Redis del sito (EVAL con SCAN, mai KEYS) e Cloudflare; errori solo registrati" {
  rs_env
  rs_site
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  grep -q 'redis-cli --no-auth-warning --user vps-admin EVAL' "$CALLS"
  grep -q 'SCAN' "$CALLS"
  run ! grep -q 'KEYS' "$CALLS"
  grep -q 'site_a_it:\*' "$CALLS"
  grep -qx 'vps-cf-purge miosito.it --all' "$BATS_TEST_TMPDIR/cf.purge"
  # entrambi falliscono: il ripristino riesce lo stesso
  : >"$CALLS"
  STUB_RC_redis_cli=1 STUB_RC_cf_purge=1 rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  jq -e '.last_restore.ok == true' "$BK_STATE"
  grep -q 'cache' "$VPS_LOG"
}

@test "_restore: sito senza utente Redis e senza zona = nessuna chiamata alla cache" {
  rs_env
  rs_site
  printf 'user default off\n' >"$REDIS_ACL_FILE"
  site_reg_update a.it '.zone = null'
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  run ! grep -q 'redis-cli' "$CALLS"
  [ ! -e "$BATS_TEST_TMPDIR/cf.purge" ]
}

@test "_restore remote: scarica da Drive in backups/tmp, verifica, ripristina, niente resta in tmp" {
  rs_env
  rs_site
  mkdir -p "$DRIVE/F/a.it"
  cp "$ARC" "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz"
  rs_run remote a.it a.it/a.it-20261001-0400.tar.gz files
  [ "$status" -eq 0 ]
  grep -q ' copyto gdrive:F/a.it/a.it-20261001-0400.tar.gz ' "$BATS_TEST_TMPDIR/rclone.calls"
  [ -f "$SITES_WWW/a.it/public/-x" ]
  [ ! -e "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
  jq -e '.last_restore.source == "remote"' "$BK_STATE"
}

@test "_restore remote: la copia di un altro sito o un nome strano = rifiutato" {
  rs_env
  rs_site
  mkdir -p "$DRIVE/F/a.it" "$DRIVE/F/b.it"
  cp "$ARC" "$DRIVE/F/b.it/b.it-20261001-0400.tar.gz"
  rs_run remote a.it b.it/b.it-20261001-0400.tar.gz files
  [ "$status" -ne 0 ]
  rs_run remote a.it a.it/../b.it/b.it-20261001-0400.tar.gz files
  [ "$status" -ne 0 ]
  rs_run remote a.it a.it/a.it-20261001-0400.tar.gz files
  [ "$status" -ne 0 ]
  [[ "$(jq -r .last_restore.error "$BK_STATE")" == *"non trovata"* ]]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "_restore remote: archivio manomesso su Drive (sha256) = rifiutato prima di toccare il sito" {
  rs_env
  rs_site
  mkdir -p "$DRIVE/F/a.it"
  local w="$BATS_TEST_TMPDIR/x"
  mkdir -p "$w"
  tar -xzf "$ARC" -C "$w"
  echo "iniettato" >>"$w/files.tar.gz"
  tar -czf "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz" -C "$w" manifest.json files.tar.gz db.sql.gz
  rs_run remote a.it a.it/a.it-20261001-0400.tar.gz all
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ -z "$(ls -A "$BK_BACKUPS/restore" 2>/dev/null)" ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

@test "_restore: una copia di sicurezza (kind restore) si può ripristinare, e riporta il sito a prima del ripristino" {
  rs_env
  rs_site
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  [ ! -e "$SITES_WWW/a.it/public/nuovo.txt" ]
  local s
  s="$(ls "$BK_BACKUPS/restore")"
  rs_run local a.it "restore/$s" files
  [ "$status" -eq 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ ! -e "$SITES_WWW/a.it/public/-x" ]
}

@test "_restore: spazio insufficiente per la copia di sicurezza = rifiutato, sito intatto" {
  rs_env
  rs_site
  # shellcheck disable=SC2016
  make_stub df 'printf "File system 1B-blocks Used Available Use%% Mounted on\n/dev/x 1000 0 1000 0%% /\n"'
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -ne 0 ]
  jq -e '.last_restore.error | test("spazio")' "$BK_STATE"
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
}

# --- la seconda linea di difesa: l'area di estrazione dopo tar -------------------

@test "_restore files: se il controllo dell'area di estrazione trova un collegamento che esce, nulla cambia e l'area sparisce" {
  rs_env
  rs_site
  # un archivio vero con un collegamento relativo innocuo; realpath finto lo fa risolvere fuori
  local w="$BATS_TEST_TMPDIR/ln" sha
  mkdir -p "$w/public"
  echo ok >"$w/public/a"
  ln -s a "$w/public/l"
  tar -czf "$w/files.tar.gz" -C "$w" public
  sha="$(sha256sum "$w/files.tar.gz" | cut -d' ' -f1)"
  jq -n --arg s "$sha" '{domain:"a.it", sha256:{files:$s, db:null}}' >"$w/manifest.json"
  tar -czf "$BK_BACKUPS/sites/a.it-20261005-0400.tar.gz" -C "$w" manifest.json files.tar.gz
  # shellcheck disable=SC2016
  make_stub realpath 'echo /etc/passwd'
  rs_run local a.it sites/a.it-20261005-0400.tar.gz files
  [ "$status" -ne 0 ]
  jq -e '.last_restore.ok == false and (.last_restore.error | test("non sicuro"))' "$BK_STATE"
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ ! -e "$SITES_WWW/a.it/public/l" ]
  [ -z "$(ls -A "$SITES_WWW/a.it/tmp" | grep -v '^sess$' || true)" ]
  [ -z "$(ls -A "$BK_BACKUPS/restore" 2>/dev/null)" ]
}

@test "_restore files: dopo lo scambio i permessi per Nginx (ACL di www-data) si riapplicano a public/, come utente del sito" {
  rs_env
  rs_site
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  grep -q 'setfacl -R -m u:www-data:rX -m d:u:www-data:rX public' "$CALLS"
}

# walk_env — un'area di estrazione finta dentro la radice del sito.
walk_env() {
  rs_env
  mk_site a.it no
  root="$SITES_WWW/a.it"
  S="tmp/.vpsbackup-x.AbCdEf"
  mkdir -p "$root/$S/public/sub"
  echo ok >"$root/$S/public/sub/f"
}

@test "controllo dell'area di estrazione: collegamenti relativi e assoluti dentro il sito, passano" {
  walk_env
  ln -s sub/f "$root/$S/public/ok1"
  ln -s ../public/sub "$root/$S/public/ok2"
  ln -s "$root/public/sub/f" "$root/$S/public/ok3"
  ln -s "$root/wp-config.php" "$root/$S/public/ok4"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -eq 0 ]
}

@test "controllo dell'area di estrazione: collegamento che esce (relativo, assoluto, a catena) = rifiutato" {
  walk_env
  ln -s ../../../../../../etc/shadow "$root/$S/public/sub/fuori"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -ne 0 ]
  rm "$root/$S/public/sub/fuori"
  ln -s /etc/shadow "$root/$S/public/abs"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -ne 0 ]
  rm "$root/$S/public/abs"
  ln -s "$SITES_WWW/altro.it/public/x" "$root/$S/public/altro"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -ne 0 ]
  rm "$root/$S/public/altro"
  # catena: il primo link sta dentro, il secondo porta fuori
  ln -s ../../../../../../etc "$root/$S/x"
  ln -s ../x "$root/$S/public/sub/uno"
  ln -s uno "$root/$S/public/sub/due"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -ne 0 ]
}

@test "controllo dell'area di estrazione: fifo e file speciali = rifiutati" {
  walk_env
  mkfifo "$root/$S/public/sub/pipe"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -ne 0 ]
  [[ "$output" == *"speciale"* ]]
}

@test "controllo dell'area di estrazione: collegamento fisico a un file fuori = rifiutato; fra file dell'area va bene" {
  walk_env
  ln "$root/$S/public/sub/f" "$root/$S/public/sub/gemello"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -eq 0 ]
  echo fuori >"$root/fuori"
  ln "$root/fuori" "$root/$S/public/sub/h"
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -ne 0 ]
  [[ "$output" == *"collegamento fisico"* ]]
}

@test "controllo dell'area di estrazione: gira come utente del sito (runuser)" {
  walk_env
  run _bk_walk_staging site_a_it "$root" "$S"
  [ "$status" -eq 0 ]
  grep -q '^runuser -u site_a_it' "$CALLS"
}

# --- pulizia delle copie di sicurezza -----------------------------------------------

@test "_run: le copie di sicurezza di oltre 7 giorni si tolgono, le più recenti restano" {
  rs_env
  mkdir -p "$BK_BACKUPS/restore"
  echo x >"$BK_BACKUPS/restore/a.it-20260901-101500.tar.gz"
  echo x >"$BK_BACKUPS/restore/a.it-20261001-101500.tar.gz"
  touch -d '8 days ago' "$BK_BACKUPS/restore/a.it-20260901-101500.tar.gz"
  touch -d '6 days ago' "$BK_BACKUPS/restore/a.it-20261001-101500.tar.gz"
  bk_tool _run
  [ ! -e "$BK_BACKUPS/restore/a.it-20260901-101500.tar.gz" ]
  [ -e "$BK_BACKUPS/restore/a.it-20261001-101500.tar.gz" ]
}

@test "vps-site _prune toglie anche le copie di sicurezza di oltre 7 giorni" {
  rs_env
  mkdir -p "$BK_BACKUPS/restore" "$SITES_BACKUPS"
  echo x >"$BK_BACKUPS/restore/a.it-20260901-101500.tar.gz"
  echo x >"$BK_BACKUPS/restore/a.it-20261001-101500.tar.gz"
  touch -d '8 days ago' "$BK_BACKUPS/restore/a.it-20260901-101500.tar.gz"
  touch -d '6 days ago' "$BK_BACKUPS/restore/a.it-20261001-101500.tar.gz"
  run bash "$REPO_ROOT/tools/vps-site" _prune
  [ "$status" -eq 0 ]
  [ ! -e "$BK_BACKUPS/restore/a.it-20260901-101500.tar.gz" ]
  [ -e "$BK_BACKUPS/restore/a.it-20261001-101500.tar.gz" ]
}

@test "vps-backup: l'ambiente del chiamante non entra (BK_CF_PURGE, REDIS_*)" {
  grep -q 'BK_CF_PURGE' "$REPO_ROOT/tools/vps-backup"
  grep -q 'REDIS_ACL_FILE' "$REPO_ROOT/tools/vps-backup"
  grep -q 'REDIS_ADMIN_SECRET' "$REPO_ROOT/tools/vps-backup"
}

# ---------------------------------------------------------------------------
# Fix round 1 (Task 4)
# ---------------------------------------------------------------------------

# Il client SQL non è mai root e non esegue nulla di ciò che sta nel dump.
@test "_restore db: dump con \\!, system, tee, source = rifiutato, nessun file creato, nessun testo segreto, database intatto" {
  rs_env
  rs_site
  printf 'root:SEGRETOSHADOW:\n' >"$BATS_TEST_TMPDIR/shadow"
  local p
  for p in "\\! touch $BATS_TEST_TMPDIR/pwned" "system touch $BATS_TEST_TMPDIR/pwned" "tee $BATS_TEST_TMPDIR/pwned" "source $BATS_TEST_TMPDIR/shadow"; do
    DUMP_EXTRA="$p" bk_archive a.it "$BK_BACKUPS/$ARC_NAME"
    rs_run local a.it "$ARC_NAME" db
    [ "$status" -ne 0 ] || { echo "accettato: $p"; false; }
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ] || { echo "eseguito: $p"; false; }
    run ! grep -r SEGRETOSHADOW "$BK_STATE" "$VPS_LOG"
    [[ "$output" != *SEGRETOSHADOW* ]]
    [ "$(fdb_tables site_a_it)" = "extra utenti" ]
  done
}

@test "_restore db: il client SQL ha --sandbox --binary-mode --local-infile=0 e gira attraverso il runner dell'utente del sito" {
  rs_env
  rs_site
  cat >"$BATS_TEST_TMPDIR/runuser-log" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/runner.log"
shift 3
if [[ "$1" == env ]]; then shift; while [[ "$1" == -i || "$1" == *=* ]]; do shift; done; fi
exec "$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/runuser-log"
  FM_RUNUSER="$BATS_TEST_TMPDIR/runuser-log" rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  grep -q -- '--sandbox --binary-mode --local-infile=0' "$BATS_TEST_TMPDIR/mariadb.calls"
  [ "$(grep -c -- '--defaults-file=' "$BATS_TEST_TMPDIR/mariadb.calls")" -ge 2 ]
  # ogni chiamata col file delle credenziali è passata dal runner (utente del sito)
  [ "$(grep -c 'site_a_it -- .*mariadb --defaults-file=' "$BATS_TEST_TMPDIR/runner.log" || true)" -ge 2 ]
  # le credenziali non restano in tmp/ del sito
  [ -z "$(ls -A "$SITES_WWW/a.it/tmp" | grep -v '^sess$' || true)" ]
}

@test "_restore db: la prova usa un utente usa-e-getta <slug>_r che non può toccare il database del sito" {
  rs_env
  rs_site
  DUMP_EXTRA='USE site_a_it;
DROP TABLE utenti;' bk_archive a.it "$BK_BACKUPS/$ARC_NAME"
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -ne 0 ]
  # il database vero è com'era e la copia di sicurezza non è nemmeno stata fatta
  [ "$(fdb_tables site_a_it)" = "extra utenti" ]
  [ -z "$(ls -A "$BK_BACKUPS/restore" 2>/dev/null)" ]
  # utente creato dopo la pulizia iniziale e tolto alla fine, anche se la prova è fallita
  local first create last
  first="$(grep -n "DROP USER IF EXISTS 'site_a_it_r'" "$BATS_TEST_TMPDIR/grants.log" | head -n1 | cut -d: -f1)"
  create="$(grep -n "CREATE USER 'site_a_it_r'" "$BATS_TEST_TMPDIR/grants.log" | head -n1 | cut -d: -f1)"
  last="$(grep -n "DROP USER IF EXISTS 'site_a_it_r'" "$BATS_TEST_TMPDIR/grants.log" | tail -n1 | cut -d: -f1)"
  [ "$first" -lt "$create" ]
  [ "$create" -lt "$last" ]
  grep -q "GRANT ALL PRIVILEGES ON \`site\\\\_a\\\\_it\\\\_\\\\_ripristino\`.\* TO 'site_a_it_r'" "$BATS_TEST_TMPDIR/grants.log"
  [ ! -d "$FAKEDB/site_a_it__ripristino" ]
  # nessun permesso per l'utente del sito sul temporaneo
  run ! grep -q "TO 'site_a_it'@" "$BATS_TEST_TMPDIR/grants.log"
}

@test "_restore files: se lo spostamento del vecchio contenuto fallisce a metà, niente si cancella e tutto torna in public/" {
  rs_env
  rs_site
  local root="$SITES_WWW/a.it"
  echo extra >"$root/public/zzz"
  # il primo mv verso la cartella del vecchio sposta una sola voce e poi fallisce
  # shellcheck disable=SC2016
  make_stub mv 'if [[ "$*" == *"-t tmp/.vpsbackup-old."* ]]; then
  args=("$@"); i=0; for a in "${args[@]}"; do i=$((i+1)); [[ "$a" == -- ]] && break; done
  /usr/bin/mv -t "${args[1]}" -- "${args[$i]}"
  exit 1
fi
exec /usr/bin/mv "$@"'
  make_stub rm 'echo "rm $*" >>"$BATS_TEST_TMPDIR/rm.calls"; exec /usr/bin/rm "$@"'
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -ne 0 ]
  [ -f "$root/public/nuovo.txt" ]
  [ -f "$root/public/a b.php" ]
  [ -f "$root/public/zzz" ]
  [ ! -e "$root/public/-x" ]
  jq -e '.last_restore.ok == false and (.last_restore.error | test("tornato"))' "$BK_STATE"
  # nessun rm sul contenuto di public/
  run ! grep -E 'rm .* public(/| |$)' "$BATS_TEST_TMPDIR/rm.calls"
}

@test "_restore: il job dice la copia di sicurezza dal passo safety in poi; status la mostra con interrupted" {
  rs_env
  rs_site
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  local last
  last="$(ls "$BATS_TEST_TMPDIR"/state.during.* | sort | tail -n1)"
  jq -e '.job.safety | test("^a\\.it-[0-9]{8}-[0-9]{6}\\.tar\\.gz$")' "$last"
  jq -e '.job.safety' "$last" >/dev/null
  echo '{"job":{"unit":"u","op":"restore","started":"s","step":"files","domain":"a.it","safety":"a.it-20261001-101500.tar.gz"},"last_run":null}' >"$BK_STATE"
  bk_tool status
  jq -e '.job == null and .interrupted == true and .interrupted_job.safety == "a.it-20261001-101500.tar.gz"' <<<"$output"
}

@test "_restore e _run: avanzi di oltre un giorno in tmp/ del sito (.vpsbackup-old/x/c) si tolgono, quelli recenti no" {
  rs_env
  rs_site
  local t="$SITES_WWW/a.it/tmp" d
  for d in .vpsbackup-old.20200101000000 .vpsbackup-x.AbCdEf .vpsbackup-c.XyZ123; do
    mkdir -p "$t/$d/sub"
    touch -d '2 days ago' "$t/$d"
  done
  mkdir -p "$t/.vpsbackup-old.20261022000000"
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  [ ! -e "$t/.vpsbackup-old.20200101000000" ]
  [ ! -e "$t/.vpsbackup-x.AbCdEf" ]
  [ ! -e "$t/.vpsbackup-c.XyZ123" ]
  [ -d "$t/.vpsbackup-old.20261022000000" ]
  mkdir -p "$t/.vpsbackup-old.20200202000000"
  touch -d '3 days ago' "$t/.vpsbackup-old.20200202000000"
  bk_tool _run
  [ ! -e "$t/.vpsbackup-old.20200202000000" ]
  [ -d "$t/.vpsbackup-old.20261022000000" ]
  [ -f "$t/sess" ]
}

@test "_restore files: lo spazio per l'estrazione si calcola sul peso non compresso della copia" {
  rs_env
  mk_site a.it no
  truncate -s 800M "$SITES_WWW/a.it/public/grande.bin"
  bk_archive a.it "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz" 2>/dev/null || { mkdir -p "$BK_BACKUPS/sites"; bk_archive a.it "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz"; }
  # compresso pesa poco, estratto 800 MB: con 1 GB liberi non basta (serve il peso + margine)
  # shellcheck disable=SC2016
  make_stub df 'printf "File system 1B-blocks Used Available Use%% Mounted on\n/dev/x 9999999999 0 1073741824 0%% /\n"'
  rs_run local a.it sites/a.it-20261001-0400.tar.gz files
  [ "$status" -ne 0 ]
  jq -e '.last_restore.error | test("spazio")' "$BK_STATE"
  [ -e "$SITES_WWW/a.it/public/grande.bin" ]
}

@test "restore: mentre una scrittura di vps-files tiene il lock condiviso del sito, ripristino e avvio sono rifiutati" {
  rs_env
  rs_site
  exec {sh}>>"$BK_LOCK_DIR/vps-site.site_a_it.lock"
  flock -s -n "$sh"
  bk_tool restore-local "$ARC_NAME" files
  [ "$status" -ne 0 ]
  rs_run local a.it "$ARC_NAME" files
  exec {sh}>&-
  [ "$status" -ne 0 ]
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
}

@test "_restore: curl (Telegram), redis-cli e vps-cf-purge non ereditano i descrittori dei lock" {
  rs_env
  rs_site
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/curl.lockfds" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/curl.lockfds")" = 0 ]
  [ -s "$BATS_TEST_TMPDIR/redis.lockfds" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/redis.lockfds")" = 0 ]
  # anche la pulizia della cache di Cloudflare (zona nel registro e Cloudflare attivo)
  [ -s "$BATS_TEST_TMPDIR/cf.lockfds" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/cf.lockfds")" = 0 ]
  jq -e '.last_restore.alert == "sent"' "$BK_STATE"
}

# ---------------------------------------------------------------------------
# Task 5: avanzi della prova, messaggi di errore veritieri, manifest da Drive
# ---------------------------------------------------------------------------

@test "_restore files: scambio fallito e ritorno fallito (uscita 4), il messaggio non indica l'area di estrazione già tolta" {
  rs_env
  rs_site
  local root="$SITES_WWW/a.it"
  echo extra >"$root/public/zzz"
  # la fase 1 sposta una voce e fallisce, e anche il ritorno (mv verso public/) fallisce
  # shellcheck disable=SC2016
  make_stub mv 'if [[ "$*" == *"-t public"* ]]; then exit 1; fi
if [[ "$*" == *"-t tmp/.vpsbackup-old."* ]]; then
  args=("$@"); i=0; for a in "${args[@]}"; do i=$((i+1)); [[ "$a" == -- ]] && break; done
  /usr/bin/mv -t "${args[1]}" -- "${args[$i]}"
  exit 1
fi
exec /usr/bin/mv "$@"'
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -ne 0 ]
  jq -e '.last_restore.ok == false' "$BK_STATE"
  local err
  err="$(jq -r '.last_restore.error' "$BK_STATE")"
  [[ "$err" == *"NON è tornato"* ]]
  [[ "$err" == *"tmp/.vpsbackup-old."* ]]
  [[ "$err" == *"public/ può esserci una parte dei file della copia"* ]]
  [[ "$err" == *"copia di sicurezza"* ]]
  # l'area di estrazione è stata tolta: il messaggio non manda a cercarci nulla
  [[ "$err" != *".vpsbackup-x."* ]]
  [ -z "$(ls -A "$root/tmp" | grep 'vpsbackup-x' || true)" ]
  jq -e '.last_restore.alert' "$BK_STATE"
}

@test "_restore all: database fallito e annullamento dei file fallito, il messaggio dice che parte del nuovo può essere ancora in public/" {
  rs_env
  rs_site
  touch "$BATS_TEST_TMPDIR/fail.load.site_a_it"
  # l'annullamento sposta il contenuto nuovo in <vecchio>.new: qui non ci riesce
  # shellcheck disable=SC2016
  make_stub mv 'if [[ "$*" == *".new"* ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
  rs_run local a.it "$ARC_NAME" all
  [ "$status" -ne 0 ]
  local err
  err="$(jq -r '.last_restore.error' "$BK_STATE")"
  [[ "$err" == *"NON sono tornati tutti in public/"* ]]
  [[ "$err" == *"una parte dei file nuovi può essere ancora in public/"* ]]
  [[ "$err" == *"copia di sicurezza"* ]]
}

@test "_restore: l'utente e il database temporanei di una prova uccisa si tolgono all'inizio di ogni ripristino, anche 'files'" {
  rs_env
  rs_site
  mkdir -p "$FAKEDB/site_a_it__ripristino"
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  [ ! -d "$FAKEDB/site_a_it__ripristino" ]
  grep -q "DROP USER IF EXISTS 'site_a_it_r'" "$BATS_TEST_TMPDIR/grants.log"
  # nemmeno un ripristino rifiutato subito dopo (copia di un altro sito) li lascia
  mkdir -p "$FAKEDB/site_a_it__ripristino"
  rs_run local a.it sites/b.it-20261001-0400.tar.gz files
  [ "$status" -ne 0 ]
}

@test "_run: anche il giro notturno toglie utente e database temporanei di una prova uccisa" {
  rs_env
  rs_site
  mkdir -p "$FAKEDB/site_a_it__ripristino"
  : >"$BATS_TEST_TMPDIR/grants.log"
  bk_tool _run
  [ ! -d "$FAKEDB/site_a_it__ripristino" ]
  grep -q "DROP USER IF EXISTS 'site_a_it_r'" "$BATS_TEST_TMPDIR/grants.log"
}

@test "bk_remote_manifest: legge solo l'inizio dell'archivio su Drive e restituisce il manifest; copia senza manifest = errore" {
  rs_env
  rs_site
  mkdir -p "$DRIVE/F/a.it"
  # un archivio grande: il manifest è il primo membro, bastano i primi 256 KiB
  head -c 3000000 /dev/urandom >"$SITES_WWW/a.it/public/grande.bin"
  bk_archive a.it "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz"
  BK_ERR=""
  bk_remote_manifest a.it/a.it-20261001-0400.tar.gz
  [ "$(jq -r '"\(.domain) \(.type) \(.db)"' <<<"$_BK_MANIFEST")" = "a.it php true" ]
  grep -q -- 'cat --count 262144 gdrive:F/a.it/a.it-20261001-0400.tar.gz' "$BATS_TEST_TMPDIR/rclone.calls"
  # un archivio vecchio (senza manifest) e un nome inesistente
  tar -czf "$DRIVE/F/a.it/a.it-20260901-0400.tar.gz" -C "$SITES_WWW" a.it
  run bk_remote_manifest a.it/a.it-20260901-0400.tar.gz
  [ "$status" -eq 1 ]
  bk_remote_manifest a.it/a.it-20260801-0400.tar.gz || true
  [[ "$BK_ERR" == *"object not found"* ]]
  run bk_remote_manifest _pannello/pannello-20261001-0400.sql.gz
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$BK_BACKUPS/tmp")" ]
}

# ---------------------------------------------------------------------------
# Fix round 1 di Task 5: copie parziali, manifest limitato, prefisso, attesa del lock
# ---------------------------------------------------------------------------

@test "_restore: una copia solo-database con modalità files o all è rifiutata prima di toccare il sito, senza copia di sicurezza" {
  rs_env
  rs_site
  mkdir -p "$BK_BACKUPS/restore"
  bk_archive a.it "$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz" db
  local m
  for m in files all; do
    rs_run local a.it restore/a.it-20261002-101500.tar.gz "$m"
    [ "$status" -ne 0 ]
    jq -e '.last_restore.ok == false and (.last_restore.error | test("solo il database")) and .last_restore.safety == null' "$BK_STATE"
  done
  [ -f "$SITES_WWW/a.it/public/nuovo.txt" ]
  [ ! -e "$SITES_WWW/a.it/public/-x" ]
  [ "$(ls "$BK_BACKUPS/restore" | wc -l)" -eq 1 ]
  [ -z "$(ls -A "$SITES_WWW/a.it/tmp" | grep -v '^sess$' || true)" ]
  # la modalità giusta passa
  rs_run local a.it restore/a.it-20261002-101500.tar.gz db
  [ "$status" -eq 0 ]
}

@test "_restore: una copia solo-file con modalità db o all è rifiutata, con files passa" {
  rs_env
  rs_site
  mkdir -p "$BK_BACKUPS/restore"
  bk_archive a.it "$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz" files
  local m
  for m in db all; do
    rs_run local a.it restore/a.it-20261002-101500.tar.gz "$m"
    [ "$status" -ne 0 ]
    jq -e '.last_restore.ok == false and (.last_restore.error | test("solo i file")) and .last_restore.safety == null' "$BK_STATE"
  done
  [ "$(fdb_tables site_a_it)" = "extra utenti" ]
  rs_run local a.it restore/a.it-20261002-101500.tar.gz files
  [ "$status" -eq 0 ]
}

@test "list-local: parts (all, db, files) per le copie nel formato nuovo, null per le altre" {
  rs_env
  mk_site a.it no
  mkdir -p "$BK_BACKUPS"/{panel,sites,restore}
  bk_archive a.it "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz"
  bk_archive a.it "$BK_BACKUPS/restore/a.it-20261002-101500.tar.gz" db
  bk_archive a.it "$BK_BACKUPS/restore/a.it-20261003-101500.tar.gz" files
  tar -czf "$BK_BACKUPS/sites/b.it-20260901-120000.tar.gz" -C "$SITES_WWW" a.it
  echo y | gzip >"$BK_BACKUPS/panel/p-20261003-030000.sql.gz"
  bk_tool list-local
  [ "$status" -eq 0 ]
  jq -e '(.items[] | select(.name == "sites/a.it-20261001-0400.tar.gz") | .parts) == "all"' <<<"$output"
  jq -e '(.items[] | select(.name == "restore/a.it-20261002-101500.tar.gz") | .parts) == "db"' <<<"$output"
  jq -e '(.items[] | select(.name == "restore/a.it-20261003-101500.tar.gz") | .parts) == "files"' <<<"$output"
  jq -e '(.items[] | select(.name == "sites/b.it-20260901-120000.tar.gz") | .parts) == null' <<<"$output"
  jq -e '(.items[] | select(.kind == "panel") | .parts) == null' <<<"$output"
}

@test "bk_archive: table_prefix nel manifest di un WordPress, dal wp-config.php vivo e solo se valido" {
  mk_site wp.it yes
  site_reg_update wp.it '.type = "wordpress"'
  printf "<?php\n\$table_prefix = 'xy7_';\n" >"$SITES_WWW/wp.it/wp-config.php"
  bk_archive wp.it "$BATS_TEST_TMPDIR/o1.tar.gz"
  [ "$(bk_manifest "$BATS_TEST_TMPDIR/o1.tar.gz" | jq -r .table_prefix)" = xy7_ ]
  printf "<?php\n\$table_prefix = 'a;b';\n" >"$SITES_WWW/wp.it/wp-config.php"
  bk_archive wp.it "$BATS_TEST_TMPDIR/o2.tar.gz"
  [ "$(bk_manifest "$BATS_TEST_TMPDIR/o2.tar.gz" | jq -r .table_prefix)" = wp_ ]
  printf "<?php\n\$table_prefix = '%s';\n" "$(printf 'a%.0s' {1..21})" >"$SITES_WWW/wp.it/wp-config.php"
  bk_archive wp.it "$BATS_TEST_TMPDIR/o3.tar.gz"
  [ "$(bk_manifest "$BATS_TEST_TMPDIR/o3.tar.gz" | jq -r .table_prefix)" = wp_ ]
  # un sito non WordPress non ha il campo
  mk_site php.it no
  bk_archive php.it "$BATS_TEST_TMPDIR/o4.tar.gz"
  [ "$(bk_manifest "$BATS_TEST_TMPDIR/o4.tar.gz" | jq -r .table_prefix)" = null ]
}

@test "bk_manifest: un manifest oltre 64 KiB è rifiutato" {
  local w="$BATS_TEST_TMPDIR/big"
  mkdir -p "$w"
  jq -n --arg pad "$(head -c 70000 /dev/zero | tr '\0' x)" '{domain:"x.it", pad:$pad}' >"$w/manifest.json"
  echo f >"$w/files.tar.gz"
  tar -czf "$w/a.tar.gz" -C "$w" manifest.json files.tar.gz
  run bk_manifest "$w/a.tar.gz"
  [ "$status" -ne 0 ]
  jq -n '{domain:"x.it"}' >"$w/manifest.json"
  tar -czf "$w/b.tar.gz" -C "$w" manifest.json files.tar.gz
  run bk_manifest "$w/b.tar.gz"
  [ "$status" -eq 0 ]
}

@test "bk_remote_manifest: manifest.json deve essere il primo membro, e non può superare 64 KiB; timeout breve" {
  rs_env
  mkdir -p "$DRIVE/F/a.it" "$BATS_TEST_TMPDIR/w"
  local w="$BATS_TEST_TMPDIR/w"
  jq -n '{domain:"a.it"}' >"$w/manifest.json"
  echo f >"$w/files.tar.gz"
  # primo membro sbagliato
  tar -czf "$DRIVE/F/a.it/a.it-20261001-0400.tar.gz" -C "$w" files.tar.gz manifest.json
  run bk_remote_manifest a.it/a.it-20261001-0400.tar.gz
  [ "$status" -eq 1 ]
  # manifest enorme
  jq -n --arg pad "$(head -c 70000 /dev/zero | tr '\0' x)" '{domain:"a.it", pad:$pad}' >"$w/manifest.json"
  tar -czf "$DRIVE/F/a.it/a.it-20261002-0400.tar.gz" -C "$w" manifest.json files.tar.gz
  run bk_remote_manifest a.it/a.it-20261002-0400.tar.gz
  [ "$status" -eq 1 ]
  # normale
  jq -n '{domain:"a.it"}' >"$w/manifest.json"
  tar -czf "$DRIVE/F/a.it/a.it-20261003-0400.tar.gz" -C "$w" manifest.json files.tar.gz
  bk_remote_manifest a.it/a.it-20261003-0400.tar.gz
  [ "$(jq -r .domain <<<"$_BK_MANIFEST")" = a.it ]
  grep -q 'timeout 45 ' "$REPO_ROOT/lib/backup.sh"
}

@test "_restore con BK_LOCK_WAIT aspetta un giro che finisce; senza, fallisce subito" {
  rs_env
  rs_site
  flock -x -w 5 "$BK_LOCK_DIR/vps-backup.lock" sleep 3 &
  local bg=$!
  sleep 0.5
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup in corso"* ]]
  BK_LOCK_WAIT=10 rs_run local a.it "$ARC_NAME" files
  wait "$bg"
  [ "$status" -eq 0 ]
  jq -e '.last_restore.ok == true' "$BK_STATE"
}

@test "_restore files su un WordPress senza cron: lo installa; con 'db' no" {
  rs_env
  rs_site
  site_reg_update a.it '.type = "wordpress"'
  [ ! -e "$CRON_D/vps-site-site_a_it" ]
  rs_run local a.it "$ARC_NAME" db
  [ "$status" -eq 0 ]
  [ ! -e "$CRON_D/vps-site-site_a_it" ]
  rs_run local a.it "$ARC_NAME" files
  [ "$status" -eq 0 ]
  [ -f "$CRON_D/vps-site-site_a_it" ]
}

@test "vps-backup: BK_LOCK_WAIT non entra dall'ambiente del chiamante sotto sudo" {
  grep -q 'BK_LOCK_WAIT' "$REPO_ROOT/tools/vps-backup"
  grep -q 'BK_CF_PURGE BK_LOCK_WAIT' "$REPO_ROOT/tools/vps-backup"
}

@test "list-local: manifest illeggibile (oltre 64 KiB) o parts sconosciuto = restorable false, parts null" {
  rs_env
  mk_site a.it no
  mkdir -p "$BK_BACKUPS/sites" "$BATS_TEST_TMPDIR/w"
  local w="$BATS_TEST_TMPDIR/w"
  echo f >"$w/files.tar.gz"
  jq -n --arg pad "$(head -c 70000 /dev/zero | tr '\0' x)" '{domain:"a.it", pad:$pad}' >"$w/manifest.json"
  tar -czf "$BK_BACKUPS/sites/a.it-20261001-0400.tar.gz" -C "$w" manifest.json files.tar.gz
  jq -n '{domain:"a.it", parts:"strano"}' >"$w/manifest.json"
  tar -czf "$BK_BACKUPS/sites/a.it-20261002-0400.tar.gz" -C "$w" manifest.json files.tar.gz
  echo 'non json' >"$w/manifest.json"
  tar -czf "$BK_BACKUPS/sites/a.it-20261003-0400.tar.gz" -C "$w" manifest.json files.tar.gz
  bk_tool list-local
  [ "$status" -eq 0 ]
  jq -e '[.items[] | select(.restorable == false and .parts == null)] | length == 3' <<<"$output"
}

# ---------------------------------------------------------------------------
# vps-backup auth-start | auth-finish | auth-cancel (Task 12)
# ---------------------------------------------------------------------------

AUTH_STATE='Xy_9-abcDEF123456789xyz'
AUTH_CID='202264815644.apps.googleusercontent.com'
AUTH_LOC="https://accounts.google.com/o/oauth2/auth?access_type=offline&client_id=$AUTH_CID&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2F&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file&state=Xy_9-abcDEF123456789xyz"

# fw_live_stubs — iptables e ip6tables finti: `-C` riesce solo per la regola esatta che
# genera bk_firewall_install, salvo i file fw.off / fw6.off (la regola non è in vigore) e
# ip6.nochain (la catena v6 non esiste).
fw_live_stubs() {
  # shellcheck disable=SC2016
  make_stub iptables 'T="$BATS_TEST_TMPDIR"
echo "iptables $*" >>"$T/fw.calls"
[[ ! -f "$T/fw.off" ]] || exit 1
[[ "$*" == "-C ufw-before-output -o lo -p tcp --dport 53682 -m owner ! --uid-owner 0 -j REJECT" ]] && exit 0
exit 1'
  # shellcheck disable=SC2016
  make_stub ip6tables 'T="$BATS_TEST_TMPDIR"
echo "ip6tables $*" >>"$T/fw.calls"
if [[ "$1" == -S ]]; then [[ ! -f "$T/ip6.nochain" ]] && exit 0; exit 1; fi
[[ ! -f "$T/fw6.off" ]] || exit 1
[[ "$*" == "-C ufw6-before-output -o lo -p tcp --dport 53682 -m owner ! --uid-owner 0 -j REJECT" ]] && exit 0
exit 1'
}

# auth_env — ambiente del tool: systemd-run finto che lancia tests/auth_mock.pl (un
# finto `rclone authorize` vero, in ascolto su 127.0.0.1:53682), systemctl, iptables e
# ip6tables finti, `ss` vero con riscritture opzionali (ss.pid, ss.local, ss.extra per
# l'ascolto; ss.est_pid per il socket stabilito) e un curl che non deve mai essere usato.
# Il mock annota le richieste ricevute in mock.log.
auth_env() {
  bk_tool_env
  export BK_PROC_DIR="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$BK_PROC_DIR"
  SS_REAL="$(PATH=/usr/sbin:/usr/bin:/sbin:/bin command -v ss)"
  export SS_REAL
  fw_live_stubs
  # shellcheck disable=SC2016
  make_stub curl 'echo "curl $*" >>"$BATS_TEST_TMPDIR/curl.calls"; exit 1'
  # shellcheck disable=SC2016
  make_stub ss 'T="$BATS_TEST_TMPDIR"
echo "ss $*" >>"$T/ss.calls"
out="$("$SS_REAL" "$@")" || true
if [[ " $* " == *" established "* ]]; then
  if [[ -f "$T/ss.est_pid" ]]; then out="$(sed -E "/^[0-9]+ +[0-9]+ +127\.0\.0\.1:53682 /s/pid=[0-9]+/pid=$(cat "$T/ss.est_pid")/" <<<"$out")"; fi
else
  if [[ -f "$T/ss.pid" ]]; then out="$(sed -E "s/pid=[0-9]+/pid=$(cat "$T/ss.pid")/" <<<"$out")"; fi
  if [[ -f "$T/ss.local" ]]; then out="$(sed -E "s/127\.0\.0\.1:53682/0.0.0.0:53682/" <<<"$out")"; fi
  if [[ -f "$T/ss.extra" ]]; then out="$out"$'"'"'\n'"'"'"$(cat "$T/ss.extra")"; fi
fi
printf "%s\n" "$out"'
  # shellcheck disable=SC2016
  make_stub systemctl 'T="$BATS_TEST_TMPDIR"
echo "$*" >>"$T/systemctl.calls"
if [[ "$1" == is-active ]]; then
  if [[ "$*" == *vps-backup-auth* ]]; then
    if [[ -f "$T/auth.active" ]]; then echo active; exit 0; fi
    echo inactive; exit 3
  fi
  if [[ -f "$T/unit.active" ]]; then echo active; exit 0; fi
  echo inactive; echo inactive; exit 3
fi
if [[ "$1" == stop && "$*" == *vps-backup-auth* ]]; then
  [[ ! -f "$T/mainpid" ]] || kill "$(cat "$T/mainpid")" 2>/dev/null
  rm -f "$T/auth.active"; exit 0
fi
if [[ "$1" == show ]]; then
  if [[ -f "$T/mainpid.force" ]]; then cat "$T/mainpid.force"; else cat "$T/mainpid" 2>/dev/null || echo 4242; fi
  exit 0
fi
if [[ -f "$T/fail.$1" ]]; then exit 1; fi
exit 0'
  # shellcheck disable=SC2016
  make_stub systemd-run 'T="$BATS_TEST_TMPDIR"
echo "systemd-run $*" >>"$T/calls"
ls -l /proc/$$/fd >"$T/sdrun.fds" 2>/dev/null
if [[ -f "$T/fail.systemd-run" ]]; then echo "boom" >&2; exit 1; fi
for a in "$@"; do
  case "$a" in
    StandardError=file:*) err="${a#StandardError=file:}" ;;
    StandardOutput=file:*) out="${a#StandardOutput=file:}" ;;
    EnvironmentFile=*) cp "${a#EnvironmentFile=}" "$T/auth.env.copy" ;;
  esac
done
touch "$T/auth.active"
if [[ -f "$T/auth.err" ]]; then cat "$T/auth.err" >>"$err"; fi
mode=run; [[ ! -f "$T/auth.nostart" ]] || mode=nostart
perl "$REPO_ROOT/tests/auth_mock.pl" "$err" "$out" Xy_9-abcDEF123456789xyz "$T/auth.location" "$T/auth.out" "$T/auth.env.copy" "$T/auth.active" "$mode" "$T/mock.log" "$T/auth.errafter" </dev/null >/dev/null 2>&1 &
pid=$!
echo "$pid" >"$T/mainpid"
mkdir -p "$BK_PROC_DIR/$pid"
exe="$(command -v rclone)"; [[ ! -f "$T/proc.exe" ]] || exe="$(cat "$T/proc.exe")"
ln -sf "$exe" "$BK_PROC_DIR/$pid/exe"
for _ in $(seq 40); do "$SS_REAL" -Hltn "sport = :53682" | grep -q . && break; sleep 0.1; done
disown
exit 0'
}

# hold_port — un altro processo (non l'unità) tiene la porta 53682.
hold_port() {
  perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 53682, Listen => 1, ReuseAddr => 1) or die; sleep 30' </dev/null >/dev/null 2>&1 &
  disown
  local i
  for i in $(seq 30); do "$SS_REAL" -Hltn "sport = :53682" | grep -q . && return 0; sleep 0.1; done
  return 1
}

teardown() {
  # pkill assoluto: setup mette uno stub di pkill nel PATH dei test
  /usr/bin/pkill -f 'tests/auth_mock.pl' 2>/dev/null || true
  /usr/bin/pkill -f 'LocalPort => 53682' 2>/dev/null || true
  # il test dopo deve trovare la porta libera
  local i
  for i in $(seq 50); do
    "${SS_REAL:-/usr/bin/ss}" -Hltn 'sport = :53682' 2>/dev/null | grep -q . || break
    sleep 0.1
  done
}

# bk_auth ARGS... — come bk_tool, con le attese brevi.
bk_auth() {
  run --separate-stderr env VPS_OPT="$VPS_OPT" VPS_LIB="$REPO_ROOT/lib" VPS_LOG="$VPS_LOG" VPS_NO_CHOWN=1 \
    SYSTEMD_DIR="$SYSTEMD_DIR" BK_DIR="$BK_DIR" BK_LOCK_DIR="$BK_LOCK_DIR" PATH="$PATH" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    BK_AUTH_START_WAIT=1 BK_AUTH_FINISH_WAIT=1 \
    bash "$T_TOOL" "$@"
}

auth_out_token() {
  printf 'Paste the following into your remote machine --->\n%s\n<---End paste\n' "$TOKEN_OK" >"$BATS_TEST_TMPDIR/auth.out"
}

AUTH_REDIRECT="http://127.0.0.1:53682/?state=$AUTH_STATE&code=4%2F0AbC_d-e.f~g&scope=https://www.googleapis.com/auth/drive.file"

@test "auth-start: unità temporanea con rclone authorize drive, scope drive.file nell'ambiente, URL di Google e scadenza" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  jq -e --arg u "$AUTH_LOC" '.ok == true and .url == $u and (.expires | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' <<<"$output"
  c="$BATS_TEST_TMPDIR/calls"
  grep -q -- '--unit vps-backup-auth ' "$c"
  grep -q -- '--collect' "$c"
  grep -q -- "-p EnvironmentFile=$BK_DIR/auth/env" "$c"
  grep -q -- "-p StandardOutput=file:$BK_DIR/auth/out" "$c"
  grep -q -- "-p StandardError=file:$BK_DIR/auth/err" "$c"
  grep -q -- ' authorize drive --auth-no-open-browser$' "$c"
  [ "$(cat "$BATS_TEST_TMPDIR/auth.env.copy")" = 'RCLONE_DRIVE_SCOPE=drive.file' ]
  [ "$(stat -c %a "$BK_DIR/auth")" = 700 ]
  [ "$(stat -c %a "$BK_DIR/auth/env")" = 600 ]
  [ "$(stat -c %a "$BK_DIR/auth/out")" = 600 ]
  # lo stato salvato è quello di rclone
  [ "$(jq -r .state "$BK_DIR/auth/meta.json")" = "$AUTH_STATE" ]
  # la richiesta la scrive il builtin di bash sulla connessione verificata: nessun curl
  grep -qF "GET /auth?state=$AUTH_STATE HTTP/1.1" "$BATS_TEST_TMPDIR/mock.log"
  [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
  grep -q -- '-p RuntimeMaxSec=960 ' "$c"
  now="$(date +%s)"
  exp="$(jq -r .expires "$BK_DIR/auth/meta.json")"
  ((exp - now >= 890 && exp - now <= 900))
}

@test "auth-start: client id e secret propri solo nel file d'ambiente, mai negli argomenti, nell'output o nel log" {
  auth_env
  bk_auth auth-start < <(printf 'mio-id.apps.googleusercontent.com\nGOCSPX-abc_DEF-123\n')
  [ "$status" -eq 0 ]
  grep -qxF 'RCLONE_DRIVE_SCOPE=drive.file' "$BATS_TEST_TMPDIR/auth.env.copy"
  grep -qxF 'RCLONE_DRIVE_CLIENT_ID=mio-id.apps.googleusercontent.com' "$BATS_TEST_TMPDIR/auth.env.copy"
  grep -qxF 'RCLONE_DRIVE_CLIENT_SECRET=GOCSPX-abc_DEF-123' "$BATS_TEST_TMPDIR/auth.env.copy"
  [ -e "$BATS_TEST_TMPDIR/calls" ]
  run ! grep -q 'GOCSPX\|mio-id' "$BATS_TEST_TMPDIR/calls"
  run ! grep -q 'GOCSPX' <<<"$output$stderr"
  [ -e "$VPS_LOG" ]
  run ! grep -q 'GOCSPX' "$VPS_LOG"
}

@test "auth-start: client id senza secret o con caratteri strani = rifiutato, niente unità" {
  auth_env
  bk_auth auth-start < <(printf 'solo-id\n')
  [ "$status" -ne 0 ]
  jq -e '.ok == false' <<<"$output"
  bk_auth auth-start < <(printf 'id\nsec ret\n')
  [ "$status" -ne 0 ]
  bk_auth auth-start < <(printf 'id\nsec\nCOSA\n')
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-start: un'autorizzazione precedente viene fermata prima della nuova" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  : >"$BATS_TEST_TMPDIR/systemctl.calls"
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ "$(grep -c 'systemd-run' "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
}

@test "auth-start: rclone che non stampa l'indirizzo entro il limite = errore, unità fermata e file tolti" {
  auth_env
  touch "$BATS_TEST_TMPDIR/auth.nostart"
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("non ha risposto"))' <<<"$output"
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ ! -e "$BK_DIR/auth" ]
  [ ! -e "$BATS_TEST_TMPDIR/mock.log" ]
}

@test "auth-start: rclone che muore subito (porta occupata) = errore con il suo messaggio, niente file" {
  auth_env
  # l'unità risulta già finita: il messaggio di rclone sta nel file degli errori
  printf 'Failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: address already in use\n' >"$BATS_TEST_TMPDIR/auth.err"
  # shellcheck disable=SC2016
  make_stub systemd-run 'T="$BATS_TEST_TMPDIR"
for a in "$@"; do case "$a" in StandardError=file:*) err="${a#StandardError=file:}";; esac; done
cat "$T/auth.err" >>"$err"
exit 0'
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("address already in use"))' <<<"$output"
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-start: systemd-run che fallisce = errore, niente file" {
  auth_env
  touch "$BATS_TEST_TMPDIR/fail.systemd-run"
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e '.ok == false' <<<"$output"
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-start: se il redirect non porta a accounts.google.com = rifiutato e tutto fermato" {
  auth_env
  local loc
  for loc in 'https://evil.example/o/oauth2/auth?x=1' 'http://accounts.google.com/o/oauth2/auth' 'https://accounts.google.com.evil.it/x' 'https://accounts.google.com/x y'; do
    printf '%s' "$loc" >"$BATS_TEST_TMPDIR/auth.location"
    bk_auth auth-start </dev/null
    [ "$status" -ne 0 ]
    jq -e '.ok == false and (has("url") | not)' <<<"$output"
    [ ! -e "$BK_DIR/auth" ]
  done
}

@test "auth-start: rclone non installato = errore leggibile, niente unità" {
  auth_env
  export BK_RCLONE="rclone-che-non-esiste --config /x"
  run --separate-stderr env VPS_OPT="$VPS_OPT" VPS_LIB="$REPO_ROOT/lib" VPS_LOG="$VPS_LOG" VPS_NO_CHOWN=1 SYSTEMD_DIR="$SYSTEMD_DIR" \
    BK_DIR="$BK_DIR" BK_LOCK_DIR="$BK_LOCK_DIR" PATH="$PATH" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" BK_RCLONE="$BK_RCLONE" \
    bash "$T_TOOL" auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("rclone"))' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "auth-start: nessun descrittore dei lock passa a systemd-run; il lock globale è libero dopo" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/sdrun.fds" ]
  run ! grep -q 'vps-backup.*\.lock' "$BATS_TEST_TMPDIR/sdrun.fds"
  run bk_global_busy
  [ "$status" -ne 0 ]
}

@test "auth-finish: caso buono — curl con l'indirizzo ricostruito, rclone.conf scritto, nessun token in output/log/argomenti, tutto pulito" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  auth_out_token
  : >"$BATS_TEST_TMPDIR/mock.log"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -eq 0 ]
  jq -e --arg f "Plancia-$(hostname -s)" '.ok == true and .folder == $f' <<<"$output"
  # l'indirizzo chiamato è ricostruito da state e code (la barra obliqua codificata), senza il resto
  grep -qF "GET /?state=$AUTH_STATE&code=4%2F0AbC_d-e.f~g HTTP/1.1" "$BATS_TEST_TMPDIR/mock.log"
  run ! grep -q 'scope' "$BATS_TEST_TMPDIR/mock.log"
  # nessun curl: state e code non passano da nessun argomento
  [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
  c="$VPS_OPT/secrets/rclone.conf"
  [ "$(stat -c %a "$c")" = 600 ]
  grep -qxF 'scope = drive.file' "$c"
  grep -q '"refresh_token":"1//SEGRETO-RINNOVO"' "$c"
  run ! grep -q 'SEGRETO\|0AbC' <<<"$output$stderr"
  [ -e "$VPS_LOG" ]
  run ! grep -q 'SEGRETO\|0AbC' "$VPS_LOG"
  [ -e "$BATS_TEST_TMPDIR/calls" ]
  [ -e "$BATS_TEST_TMPDIR/rclone.calls" ]
  [ -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
  run ! grep -q 'SEGRETO\|0AbC' "$BATS_TEST_TMPDIR/calls" "$BATS_TEST_TMPDIR/rclone.calls" "$BATS_TEST_TMPDIR/systemctl.calls" "$BATS_TEST_TMPDIR/ss.calls"
  # unità fermata, cartella delle autorizzazioni tolta (con il token dentro)
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ ! -e "$BK_DIR/auth" ]
  [ -e "$BK_DIR" ]
  run ! grep -rl 'SEGRETO' "$BK_DIR"
}

@test "auth-finish: client id e secret dati all'avvio finiscono in rclone.conf" {
  auth_env
  bk_auth auth-start < <(printf 'mio-id.apps.googleusercontent.com\nGOCSPX-abc_DEF-123\n')
  [ "$status" -eq 0 ]
  auth_out_token
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -eq 0 ]
  c="$VPS_OPT/secrets/rclone.conf"
  grep -qxF 'client_id = mio-id.apps.googleusercontent.com' "$c"
  grep -qxF 'client_secret = GOCSPX-abc_DEF-123' "$c"
  run ! grep -q 'GOCSPX' <<<"$output$stderr"
}

@test "auth-finish: forme accettate dell'indirizzo incollato (localhost, code con / grezza, spazi, frammento, ordine diverso)" {
  auth_env
  auth_out_token
  local u
  for u in \
    "http://localhost:53682/?state=$AUTH_STATE&code=4/0AbC_d-e.f~g" \
    "  http://127.0.0.1:53682/?code=4%2f0AbC_d-e.f~g&state=$AUTH_STATE  " \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=4%2F0AbC_d-e.f~g#" \
    "HTTP://LocalHost:53682?state=$AUTH_STATE&code=4%2F0AbC_d-e.f~g&authuser=0&prompt=consent"; do
    bk_auth auth-start </dev/null
    [ "$status" -eq 0 ]
    rm -f "$VPS_OPT/secrets/rclone.conf"
    bk_auth auth-finish <<<"$u"
    [ "$status" -eq 0 ]
    [ "$(tail -n1 "$BATS_TEST_TMPDIR/mock.log" | tr -d '\r')" = "GET /?state=$AUTH_STATE&code=4%2F0AbC_d-e.f~g HTTP/1.1" ]
  done
}

@test "auth-finish: indirizzi non ammessi = rifiutati senza chiamare curl, e l'autorizzazione resta in attesa" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  : >"$BATS_TEST_TMPDIR/mock.log"
  local u
  for u in \
    "http://127.0.0.1:53682/?state=ALTRO&code=abc" \
    "http://127.0.0.1:53682/?code=abc" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE" \
    "http://127.0.0.1:53682/" \
    "http://evil:53682/?state=$AUTH_STATE&code=abc" \
    "http://127.0.0.1.evil.it:53682/?state=$AUTH_STATE&code=abc" \
    "http://user@127.0.0.1:53682/?state=$AUTH_STATE&code=abc" \
    "http://127.0.0.1:53683/?state=$AUTH_STATE&code=abc" \
    "http://127.0.0.1/?state=$AUTH_STATE&code=abc" \
    "https://127.0.0.1:53682/?state=$AUTH_STATE&code=abc" \
    "ftp://127.0.0.1:53682/?state=$AUTH_STATE&code=abc" \
    "http://127.0.0.1:53682/auth?state=$AUTH_STATE&code=abc" \
    "http://127.0.0.1:53682/x/?state=$AUTH_STATE&code=abc" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=ab c" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=ab%20c" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=ab%00c" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=ab%3Bc" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=a\$(touch x)" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=a\"b" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=abc&code=def" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&state=$AUTH_STATE&code=abc" \
    "http://127.0.0.1:53682/?state=$AUTH_STATE&code=$(head -c 1100 /dev/zero | tr '\0' a)" \
    "non è un indirizzo" \
    ""; do
    bk_auth auth-finish <<<"$u"
    [ "$status" -ne 0 ]
    jq -e '.ok == false and (.error | length > 0)' <<<"$output"
  done
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ ! -e "$VPS_OPT/secrets/rclone.conf" ]
  [ ! -e x ]
  # ancora in attesa: l'utente può incollare l'indirizzo giusto
  [ -f "$BK_DIR/auth/meta.json" ]
  bk_auth status
  jq -e '.auth.pending == true' <<<"$output"
}

@test "auth-finish: più di 4 KiB o più righe = rifiutato" {
  auth_env
  bk_auth auth-start </dev/null
  : >"$BATS_TEST_TMPDIR/mock.log"
  bk_auth auth-finish < <(head -c 5000 /dev/zero | tr '\0' a)
  [ "$status" -ne 0 ]
  bk_auth auth-finish < <(printf '%s\n%s\n' "$AUTH_REDIRECT" "$AUTH_REDIRECT")
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
}

@test "auth-finish: error=access_denied = messaggio leggibile, nessuna chiamata a curl, tutto pulito" {
  auth_env
  bk_auth auth-start </dev/null
  : >"$BATS_TEST_TMPDIR/mock.log"
  bk_auth auth-finish <<<"http://127.0.0.1:53682/?error=access_denied&state=$AUTH_STATE"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("negato"))' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ ! -e "$BK_DIR/auth" ]
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "auth-finish: error=access_denied con state sbagliato non annulla nulla" {
  auth_env
  bk_auth auth-start </dev/null
  bk_auth auth-finish <<<"http://127.0.0.1:53682/?error=access_denied&state=ALTRO"
  [ "$status" -ne 0 ]
  [ -f "$BK_DIR/auth/meta.json" ]
}

@test "auth-finish: nessuna autorizzazione aperta = errore" {
  auth_env
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("Collega Google Drive"))' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/mock.log" ]
}

@test "auth-finish: autorizzazione scaduta = 'ricomincia', unità e file tolti, nessuna chiamata" {
  auth_env
  bk_auth auth-start </dev/null
  jq -c '.expires = 1000' "$BK_DIR/auth/meta.json" >"$BK_DIR/auth/m" && mv "$BK_DIR/auth/m" "$BK_DIR/auth/meta.json"
  : >"$BATS_TEST_TMPDIR/mock.log"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("scadut")) and (.error | test("ricomincia"))' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-finish: unità non più attiva (rclone ucciso) = 'ricomincia', nessuna chiamata" {
  auth_env
  bk_auth auth-start </dev/null
  rm -f "$BATS_TEST_TMPDIR/auth.active"
  : >"$BATS_TEST_TMPDIR/mock.log"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("ricomincia"))' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-finish: lock globale occupato = rifiutato prima di usare il code, l'autorizzazione resta" {
  auth_env
  bk_auth auth-start </dev/null
  : >"$BATS_TEST_TMPDIR/mock.log"
  exec {gl}>>"$BK_LOCK_DIR/vps-backup.lock"
  flock -n "$gl"
  auth_out_token
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.error == "backup in corso, riprova dopo"' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ -f "$BK_DIR/auth/meta.json" ]
  exec {gl}>&-
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -eq 0 ]
}

@test "auth-finish: niente curl: la richiesta è scritta dal builtin di bash; il lock globale è libero dopo" {
  auth_env
  bk_auth auth-start </dev/null
  auth_out_token
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
  run bk_global_busy
  [ "$status" -ne 0 ]
}

@test "auth-finish: il token non arriva entro il limite = errore, tutto pulito" {
  auth_env
  bk_auth auth-start </dev/null
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("token"))' <<<"$output"
  [ ! -e "$BK_DIR/auth" ]
  [ ! -e "$VPS_OPT/secrets/rclone.conf" ]
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "auth-finish: rclone fallisce (code non valido) = il suo messaggio, senza code né token" {
  auth_env
  bk_auth auth-start </dev/null
  # rclone muore dopo aver ricevuto il code: errore nel file degli errori
  printf 'Failed to configure token: oauth2: cannot fetch token: 400 Bad Request invalid_grant 4/0AbC_d-e.f~g\n' >"$BATS_TEST_TMPDIR/auth.errafter"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("invalid_grant"))' <<<"$output"
  run ! grep -q '0AbC' <<<"$output$stderr"
  [ -e "$VPS_LOG" ]
  run ! grep -q '0AbC' "$VPS_LOG"
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-finish: rclone che chiude la connessione senza rispondere = errore, tutto pulito" {
  auth_env
  bk_auth auth-start </dev/null
  touch "$BATS_TEST_TMPDIR/mock.log.drop"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false' <<<"$output"
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-finish: token illeggibile o senza refresh_token = errore di connect, nessun rclone.conf, tutto pulito" {
  auth_env
  bk_auth auth-start </dev/null
  printf 'Paste the following into your remote machine --->\n{"access_token":"ya29.SEGRETO-ACCESSO"}\n<---End paste\n' >"$BATS_TEST_TMPDIR/auth.out"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("token non valido"))' <<<"$output"
  run ! grep -q 'SEGRETO' <<<"$output$stderr"
  [ ! -e "$VPS_OPT/secrets/rclone.conf" ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-finish: Drive rifiuta il collegamento = rclone.conf di prima, errore senza token, tutto pulito" {
  auth_env
  echo vecchio >"$VPS_OPT/secrets/rclone.conf"
  chmod 600 "$VPS_OPT/secrets/rclone.conf"
  echo mkdir >"$BATS_TEST_TMPDIR/rclone.fail"
  echo "ERROR : Invalid token ya29.SEGRETO-ACCESSO" >"$BATS_TEST_TMPDIR/rclone.msg"
  bk_auth auth-start </dev/null
  auth_out_token
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("Invalid token"))' <<<"$output"
  run ! grep -q 'SEGRETO' <<<"$output$stderr"
  [ "$(cat "$VPS_OPT/secrets/rclone.conf")" = vecchio ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-cancel: ferma l'unità, toglie la cartella, risponde ok; senza autorizzazione risponde ok lo stesso" {
  auth_env
  bk_auth auth-start </dev/null
  [ -d "$BK_DIR/auth" ]
  bk_auth auth-cancel
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ ! -e "$BK_DIR/auth" ]
  bk_auth auth-cancel
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
}

@test "status: auth pending con scadenza durante l'attesa, non più dopo scadenza, unità morta o annullo" {
  auth_env
  bk_auth status
  jq -e '.auth == {pending:false, expires:null}' <<<"$output"
  bk_auth auth-start </dev/null
  exp="$(jq -r .expires <<<"$output")"
  bk_auth status
  jq -e --arg e "$exp" '.auth.pending == true and .auth.expires == $e' <<<"$output"
  rm -f "$BATS_TEST_TMPDIR/auth.active"
  bk_auth status
  jq -e '.auth == {pending:false, expires:null}' <<<"$output"
  touch "$BATS_TEST_TMPDIR/auth.active"
  jq -c '.expires = 1000' "$BK_DIR/auth/meta.json" >"$BK_DIR/auth/m" && mv "$BK_DIR/auth/m" "$BK_DIR/auth/meta.json"
  bk_auth status
  jq -e '.auth.pending == false' <<<"$output"
  bk_auth auth-cancel
  bk_auth status
  jq -e '.auth.pending == false' <<<"$output"
}

@test "vps-backup: le variabili di auth non entrano dall'ambiente del chiamante sotto sudo" {
  local v
  for v in BK_AUTH_DIR BK_AUTH_EXTRA BK_AUTH_START_WAIT BK_AUTH_FINISH_WAIT BK_AUTH_FD; do
    grep -q "$v" "$REPO_ROOT/tools/vps-backup"
  done
}

@test "auth-start: BK_AUTH_EXTRA aggiunge righe all'ambiente dell'unità (solo per i collaudi)" {
  auth_env
  printf 'RCLONE_DRIVE_TOKEN_URL=http://127.0.0.1:1/token\n' >"$BATS_TEST_TMPDIR/extra.env"
  run --separate-stderr env VPS_OPT="$VPS_OPT" VPS_LIB="$REPO_ROOT/lib" VPS_LOG="$VPS_LOG" VPS_NO_CHOWN=1 SYSTEMD_DIR="$SYSTEMD_DIR" \
    BK_DIR="$BK_DIR" BK_LOCK_DIR="$BK_LOCK_DIR" PATH="$PATH" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" BK_AUTH_EXTRA="$BATS_TEST_TMPDIR/extra.env" BK_AUTH_START_WAIT=1 \
    bash "$T_TOOL" auth-start </dev/null
  [ "$status" -eq 0 ]
  grep -qxF 'RCLONE_DRIVE_TOKEN_URL=http://127.0.0.1:1/token' "$BATS_TEST_TMPDIR/auth.env.copy"
}

# --- tetti di tempo delle chiamate a Drive (il pannello aspetta ~125 s) ---------

@test "connect: rclone che si pianta = errore 'tempo scaduto' entro il tetto, rclone.conf di prima intatto" {
  bk_tool_env
  export BK_CONNECT_TIMEOUT=1
  echo vecchio >"$VPS_OPT/secrets/rclone.conf"
  chmod 600 "$VPS_OPT/secrets/rclone.conf"
  for sub in mkdir rcat deletefile; do
    # shellcheck disable=SC2016
    make_stub rclone 'for a in "$@"; do if [[ "$a" == '"$sub"' ]]; then exec sleep 20; fi; done; cat >/dev/null 2>&1 </dev/null; exit 0'
    SECONDS=0
    bk_tool connect <<<"$TOKEN_OK"
    [ "$status" -ne 0 ]
    ((SECONDS < 10))
    jq -e '.ok == false and (.error | test("tempo scaduto"))' <<<"$output"
    [ "$(cat "$VPS_OPT/secrets/rclone.conf")" = vecchio ]
  done
}

@test "auth-finish: rclone che si pianta nelle prove su Drive = stesso tetto, tutto pulito" {
  auth_env
  export BK_CONNECT_TIMEOUT=1
  # shellcheck disable=SC2016
  make_stub rclone 'for a in "$@"; do if [[ "$a" == mkdir ]]; then exec sleep 20; fi; done; exit 0'
  bk_auth auth-start </dev/null
  auth_out_token
  SECONDS=0
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  ((SECONDS < 10))
  jq -e '.ok == false and (.error | test("tempo scaduto"))' <<<"$output"
  [ ! -e "$VPS_OPT/secrets/rclone.conf" ]
  [ ! -e "$BK_DIR/auth" ]
}

# list_remote_stub — rclone finto: a.it risponde, b.it si pianta, l'elenco delle cartelle può piantarsi.
list_remote_stub() {
  # shellcheck disable=SC2016
  make_stub rclone 'case "$*" in
  *--dirs-only*) if [[ -f "$BATS_TEST_TMPDIR/hang.top" ]]; then exec sleep 20; fi; echo "[{\"Name\":\"a.it\"},{\"Name\":\"b.it\"}]" ;;
  *"gdrive:F/a.it") echo "[{\"Name\":\"a.it-20261001-0400.tar.gz\",\"Size\":5}]" ;;
  *"gdrive:F/b.it") exec sleep 20 ;;
esac
exit 0'
}

@test "list-remote: una cartella che non risponde = elenco parziale con partial:true, il resto c'è" {
  bk_run_env
  export BK_RC_TIMEOUT=1
  list_remote_stub
  SECONDS=0
  bk_tool list-remote
  [ "$status" -eq 0 ]
  ((SECONDS < 10))
  jq -e '.ok == true and .partial == true and (.sites | map(.domain)) == ["a.it"]' <<<"$output"
}

@test "list-remote: finito il budget si restituisce quanto raccolto con partial:true" {
  bk_run_env
  export BK_LIST_BUDGET=2
  list_remote_stub
  bk_tool list-remote
  [ "$status" -eq 0 ]
  jq -e '.ok == true and .partial == true and .sites == []' <<<"$output"
}

@test "list-remote: elenco delle cartelle che si pianta = errore, senza partial" {
  bk_run_env
  export BK_RC_TIMEOUT=1
  touch "$BATS_TEST_TMPDIR/hang.top"
  list_remote_stub
  bk_tool list-remote
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | test("tempo scaduto"))' <<<"$output"
}

@test "list-remote: tutto risponde = nessun campo partial" {
  bk_run_env
  mkdir -p "$BATS_TEST_TMPDIR/drive"
  list_remote_stub
  # niente b.it: solo a.it
  # shellcheck disable=SC2016
  make_stub rclone 'case "$*" in
  *--dirs-only*) echo "[{\"Name\":\"a.it\"}]" ;;
  *"gdrive:F/a.it") echo "[{\"Name\":\"a.it-20261001-0400.tar.gz\",\"Size\":5}]" ;;
esac
exit 0'
  bk_tool list-remote
  [ "$status" -eq 0 ]
  jq -e '.ok == true and (has("partial") | not) and (.sites | length) == 1' <<<"$output"
}

@test "vps-backup: i tetti di tempo non entrano dall'ambiente del chiamante sotto sudo" {
  local v
  for v in BK_CONNECT_TIMEOUT BK_RC_TIMEOUT BK_LIST_BUDGET _BK_RCQ_TO; do
    grep -q "$v" "$REPO_ROOT/tools/vps-backup"
  done
}

# --- fix round 1: porta riservata a root, ascolto verificato, indirizzo di Google controllato ---

PORT_MSG='la porta 53682 è occupata da un altro processo: collegamento annullato'

@test "auth-start: l'unità è indurita (DynamicUser, nessun privilegio, filesystem in sola lettura, solo rete)" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  c="$BATS_TEST_TMPDIR/calls"
  local p
  for p in DynamicUser=yes NoNewPrivileges=yes ProtectSystem=strict ProtectHome=yes PrivateTmp=yes 'CapabilityBoundingSet=' TimeoutStopSec=5; do
    grep -q -- "-p $p " "$c"
  done
  grep -q -- '-p RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX ' "$c"
}

@test "auth-start: porta già occupata prima dell'avvio = rifiutato senza avviare rclone" {
  auth_env
  hold_port
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e --arg m "$PORT_MSG" '.ok == false and .error == $m' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-start: il listener non è il processo dell'unità (altro pid, due listener, 0.0.0.0, MainPID diverso, eseguibile diverso) = rifiutato, niente richiesta, tutto pulito" {
  auth_env
  local k
  for k in pid local extra mainpid.force proc.exe; do
    rm -f "$BATS_TEST_TMPDIR"/{ss.pid,ss.local,ss.extra,mainpid.force,proc.exe,mock.log}
    case "$k" in
      pid) echo 999 >"$BATS_TEST_TMPDIR/ss.pid" ;;
      local) touch "$BATS_TEST_TMPDIR/ss.local" ;;
      extra) echo 'LISTEN 0 4096 [::1]:53682 [::]:* users:(("x",pid=999,fd=7))' >"$BATS_TEST_TMPDIR/ss.extra" ;;
      mainpid.force) echo 31337 >"$BATS_TEST_TMPDIR/mainpid.force" ;;
      proc.exe) echo /bin/sleep >"$BATS_TEST_TMPDIR/proc.exe" ;;
    esac
    bk_auth auth-start </dev/null
    [ "$status" -ne 0 ] || { echo "accettato: $k"; false; }
    jq -e --arg m "$PORT_MSG" '.ok == false and .error == $m' <<<"$output"
    [ ! -e "$BATS_TEST_TMPDIR/mock.log" ]
    [ ! -e "$BK_DIR/auth" ]
  done
  # il registro dice chi occupava la porta, non lo state
  grep -q 'porta 53682' "$VPS_LOG"
  run ! grep -q "$AUTH_STATE" "$VPS_LOG"
}

@test "auth-start: il socket stabilito è di un altro processo = niente scritto sulla connessione, rifiutato" {
  auth_env
  echo 999 >"$BATS_TEST_TMPDIR/ss.est_pid"
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e --arg m "$PORT_MSG" '.ok == false and .error == $m' <<<"$output"
  # la connessione è stata aperta ma il mock non ha ricevuto nessuna richiesta
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "auth-finish: socket stabilito di un altro processo, o listener cambiato = il code non viene scritto, tutto pulito" {
  auth_env
  local k
  for k in ss.est_pid ss.pid; do
    rm -f "$BATS_TEST_TMPDIR"/{ss.est_pid,ss.pid}
    bk_auth auth-start </dev/null
    [ "$status" -eq 0 ]
    auth_out_token
    : >"$BATS_TEST_TMPDIR/mock.log"
    echo 999 >"$BATS_TEST_TMPDIR/$k"
    bk_auth auth-finish <<<"$AUTH_REDIRECT"
    [ "$status" -ne 0 ]
    jq -e --arg m "$PORT_MSG" '.ok == false and .error == $m' <<<"$output"
    [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
    [ ! -e "$VPS_OPT/secrets/rclone.conf" ]
    [ ! -e "$BK_DIR/auth" ]
  done
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "auth-start: l'indirizzo di Google viene controllato parametro per parametro" {
  auth_env
  local base="https://accounts.google.com/o/oauth2/auth?access_type=offline&client_id=$AUTH_CID&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2F&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file&state=$AUTH_STATE"
  local bad
  for bad in \
    "${base/$AUTH_CID/evil.apps.googleusercontent.com}" \
    "${base/127.0.0.1%3A53682/evil.it%3A53682}" \
    "${base/53682%2F&response_type/53683%2F&response_type}" \
    "${base/drive.file/drive}" \
    "${base/auth%2Fdrive.file/auth%2Fdrive.file%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive}" \
    "${base/state=$AUTH_STATE/state=ALTRO}" \
    "${base/response_type=code/response_type=token}" \
    "${base/https:\/\/accounts.google.com/https://accounts.google.com.evil.it}" \
    "${base/o\/oauth2\/auth/o\/oauth2\/v2\/auth}" \
    "${base/https:/http:}" \
    "$base&login_hint=x" \
    "$base&state=$AUTH_STATE" \
    "${base/access_type=offline&/}" ; do
    printf '%s' "$bad" >"$BATS_TEST_TMPDIR/auth.location"
    bk_auth auth-start </dev/null
    [ "$status" -ne 0 ] || { echo "accettato: $bad"; false; }
    jq -e '.ok == false and (has("url") | not)' <<<"$output"
    [ ! -e "$BK_DIR/auth" ]
  done
}

@test "auth-start: con client id proprio l'indirizzo di Google deve usare quello" {
  auth_env
  bk_auth auth-start < <(printf 'mio-id.apps.googleusercontent.com\nGOCSPX-abc_DEF-123\n')
  [ "$status" -eq 0 ]
  jq -e '.url | contains("client_id=mio-id.apps.googleusercontent.com")' <<<"$output"
  # un indirizzo con il client di default invece non va bene
  printf '%s' "$AUTH_LOC" >"$BATS_TEST_TMPDIR/auth.location"
  bk_auth auth-start < <(printf 'mio-id.apps.googleusercontent.com\nGOCSPX-abc_DEF-123\n')
  [ "$status" -ne 0 ]
}

# --- firewall ---

fw_files() {
  export BK_UFW_DIR="$BATS_TEST_TMPDIR/ufw"
  mkdir -p "$BK_UFW_DIR"
  printf '*filter\n:ufw-before-output - [0:0]\n-A ufw-before-output -o lo -j ACCEPT\nCOMMIT\n' >"$BK_UFW_DIR/before.rules"
  printf '*filter\n:ufw6-before-output - [0:0]\n-A ufw6-before-output -o lo -j ACCEPT\nCOMMIT\n' >"$BK_UFW_DIR/before6.rules"
  chmod 640 "$BK_UFW_DIR/before.rules" "$BK_UFW_DIR/before6.rules"
}

@test "bk_firewall_install: solo uid 0 può connettersi alla porta 53682 di loopback, v4 e v6, prima dell'ACCEPT" {
  fw_files
  bk_firewall_install
  grep -qxF -- '-I ufw-before-output 1 -o lo -p tcp --dport 53682 -m owner ! --uid-owner 0 -j REJECT' "$BK_UFW_DIR/before.rules"
  grep -qxF -- '-I ufw6-before-output 1 -o lo -p tcp --dport 53682 -m owner ! --uid-owner 0 -j REJECT' "$BK_UFW_DIR/before6.rules"
  # la regola sta prima di COMMIT e il file ha ancora tutto il resto
  [ "$(tail -n1 "$BK_UFW_DIR/before.rules")" = COMMIT ]
  grep -qxF -- '-A ufw-before-output -o lo -j ACCEPT' "$BK_UFW_DIR/before.rules"
  [ "$(stat -c %a "$BK_UFW_DIR/before.rules")" = 640 ]
}

@test "bk_firewall_install: idempotente, ufw ricaricato solo la prima volta e solo se attivo" {
  fw_files
  fw_live_stubs
  # shellcheck disable=SC2016
  make_stub ufw 'echo "ufw $*" >>"$BATS_TEST_TMPDIR/ufw.log"; if [[ "$1" == status ]]; then echo "Status: active"; fi'
  bk_firewall_install
  cp "$BK_UFW_DIR/before.rules" "$BATS_TEST_TMPDIR/b1"
  bk_firewall_install
  cmp "$BK_UFW_DIR/before.rules" "$BATS_TEST_TMPDIR/b1"
  [ "$(grep -c -- '--dport 53682' "$BK_UFW_DIR/before.rules")" -eq 1 ]
  [ "$(grep -c -- '--dport 53682' "$BK_UFW_DIR/before6.rules")" -eq 1 ]
  [ "$(grep -c 'ufw reload' "$BATS_TEST_TMPDIR/ufw.log")" -eq 1 ]
}

@test "bk_firewall_install: blocco già nel file ma regola non in vigore = reload; in vigore = niente reload" {
  fw_files
  fw_live_stubs
  # shellcheck disable=SC2016
  make_stub ufw 'echo "ufw $*" >>"$BATS_TEST_TMPDIR/ufw.log"; if [[ "$1" == status ]]; then echo "Status: active"; fi'
  bk_firewall_install
  : >"$BATS_TEST_TMPDIR/ufw.log"
  # regola in vigore: niente reload
  bk_firewall_install
  run ! grep -q 'ufw reload' "$BATS_TEST_TMPDIR/ufw.log"
  # il blocco c'è ma la regola non è viva (ufw ricaricato a mano, regola persa): reload
  touch "$BATS_TEST_TMPDIR/fw.off"
  bk_firewall_install
  grep -q 'ufw reload' "$BATS_TEST_TMPDIR/ufw.log"
}

@test "bk_firewall_install: ufw spento = lo dice nel registro, non fallisce (il collegamento resta rifiutato)" {
  fw_files
  fw_live_stubs
  touch "$BATS_TEST_TMPDIR/fw.off"
  # shellcheck disable=SC2016
  make_stub ufw 'if [[ "$1" == status ]]; then echo "Status: inactive"; fi'
  bk_firewall_install
  grep -qi 'ufw non attivo' "$VPS_LOG"
}

@test "bk_firewall_install: ufw spento = nessun reload; file assenti = niente da fare; file senza COMMIT = errore e file intatto" {
  fw_files
  # shellcheck disable=SC2016
  make_stub ufw 'echo "ufw $*" >>"$BATS_TEST_TMPDIR/ufw.log"; if [[ "$1" == status ]]; then echo "Status: inactive"; fi'
  fw_live_stubs
  bk_firewall_install
  [ -e "$BATS_TEST_TMPDIR/ufw.log" ]
  run ! grep -q 'ufw reload' "$BATS_TEST_TMPDIR/ufw.log"
  export BK_UFW_DIR="$BATS_TEST_TMPDIR/nessuno"
  bk_firewall_install
  fw_files
  echo 'senza commit' >"$BK_UFW_DIR/before.rules"
  run bk_firewall_install
  [ "$status" -ne 0 ]
  [ "$(cat "$BK_UFW_DIR/before.rules")" = 'senza commit' ]
}

@test "opt_backup_files installa la regola del firewall (anche con --tools-only)" {
  grep -q 'bk_firewall_install' "$REPO_ROOT/lib/opt.sh"
  # --tools-only passa da opt_system_files, che chiama opt_backup_files
  grep -q 'opt_backup_files' "$REPO_ROOT/lib/opt.sh"
}

@test "vps-backup: le variabili del firewall e dei processi non entrano dall'ambiente del chiamante sotto sudo" {
  local v
  for v in BK_AUTH_RCLONE BK_PROC_DIR BK_UFW_DIR; do
    grep -q "$v" "$REPO_ROOT/tools/vps-backup"
  done
}

# --- avanzi di auth/ ---

@test "status e _run tolgono gli avanzi di un'autorizzazione vecchia; una recente o valida resta" {
  auth_env
  bk_auth auth-start </dev/null
  # recente: resta anche se scaduta nel meta
  jq -c '.expires = 1000' "$BK_DIR/auth/meta.json" >"$BK_DIR/auth/m" && mv "$BK_DIR/auth/m" "$BK_DIR/auth/meta.json"
  bk_auth status
  [ -d "$BK_DIR/auth" ]
  # vecchia e scaduta: via
  touch -d '2 hours ago' "$BK_DIR/auth"
  bk_auth status
  [ ! -e "$BK_DIR/auth" ]
  grep -q 'stop vps-backup-auth' "$BATS_TEST_TMPDIR/systemctl.calls"
  # vecchia ma ancora valida: resta
  bk_auth auth-start </dev/null
  touch -d '2 hours ago' "$BK_DIR/auth"
  bk_auth status
  [ -d "$BK_DIR/auth" ]
  # _run: stessa pulizia
  grep -q 'bk_auth_prune' <(sed -n '/^bk_run_all()/,/^}/p' "$REPO_ROOT/lib/backup.sh")
}

# --- connect: nessun lock ereditato da rclone, SIGKILL di scorta ---

@test "connect: rclone non eredita i lock e, se ignora SIGTERM, viene ucciso dopo il tetto" {
  bk_tool_env
  export BK_CONNECT_TIMEOUT=1
  # shellcheck disable=SC2016
  make_stub rclone 'T="$BATS_TEST_TMPDIR"
ls -l /proc/$$/fd >>"$T/rclone.fds" 2>/dev/null
for a in "$@"; do
  if [[ "$a" == mkdir ]]; then
    trap "" TERM
    # un figlio che non muore con SIGTERM: solo SIGKILL al gruppo lo ferma
    while :; do sleep 1; done
  fi
done
exit 0'
  SECONDS=0
  bk_tool connect <<<"$TOKEN_OK"
  [ "$status" -ne 0 ]
  ((SECONDS < 15))
  jq -e '.ok == false and (.error | test("tempo scaduto"))' <<<"$output"
  [ -f "$BATS_TEST_TMPDIR/rclone.fds" ]
  run ! grep -q 'vps-backup.*\.lock' "$BATS_TEST_TMPDIR/rclone.fds"
}

# --- fix round 2: regola verificata viva, connessione fissata ---

FW_MSG='regola del firewall per la porta 53682 non attiva: esegui install.sh --tools-only'

@test "auth-start: senza la regola del firewall viva (v4, o v6 se la catena esiste) = rifiutato, niente unità" {
  auth_env
  touch "$BATS_TEST_TMPDIR/fw.off"
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e --arg m "$FW_MSG" '.ok == false and .error == $m' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
  [ ! -e "$BK_DIR/auth" ]
  rm -f "$BATS_TEST_TMPDIR/fw.off"
  touch "$BATS_TEST_TMPDIR/fw6.off"
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e --arg m "$FW_MSG" '.error == $m' <<<"$output"
  # senza catena v6 (IPv6 spento in ufw) basta la v4
  touch "$BATS_TEST_TMPDIR/ip6.nochain"
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  # il comando controllato è esattamente la regola generata dall'installer
  grep -qxF 'iptables -C ufw-before-output -o lo -p tcp --dport 53682 -m owner ! --uid-owner 0 -j REJECT' "$BATS_TEST_TMPDIR/fw.calls"
}

@test "auth-finish: regola del firewall non più viva = rifiutato, il code non viene scritto e l'autorizzazione resta" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  auth_out_token
  : >"$BATS_TEST_TMPDIR/mock.log"
  touch "$BATS_TEST_TMPDIR/fw.off"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e --arg m "$FW_MSG" '.error == $m' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ -f "$BK_DIR/auth/meta.json" ]
  rm -f "$BATS_TEST_TMPDIR/fw.off"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -eq 0 ]
}

@test "auth-finish: a meno di 30 secondi dalla scadenza = 'ricomincia', il code non viene scritto" {
  auth_env
  bk_auth auth-start </dev/null
  [ "$status" -eq 0 ]
  jq -c --argjson e "$(($(date +%s) + 10))" '.expires = $e' "$BK_DIR/auth/meta.json" >"$BK_DIR/auth/m" && mv "$BK_DIR/auth/m" "$BK_DIR/auth/meta.json"
  : >"$BATS_TEST_TMPDIR/mock.log"
  bk_auth auth-finish <<<"$AUTH_REDIRECT"
  [ "$status" -ne 0 ]
  jq -e '.error | test("ricomincia")' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/mock.log" ]
  [ ! -e "$BK_DIR/auth" ]
}

@test "lib: niente 'set -- \$out' senza virgolette, niente curl nelle chiamate locali di auth" {
  run ! grep -n 'set -- \$out' "$REPO_ROOT/lib/backup.sh"
  run ! grep -n 'curl' <(sed -n '/^# --- collegamento a Drive senza rclone/,$p' "$REPO_ROOT/lib/backup.sh" | grep -v '^ *#')
}

@test "auth-start: l'indirizzo di Google inatteso dice che una versione di rclone diversa può esserne la causa" {
  auth_env
  printf '%s' "https://evil.example/x" >"$BATS_TEST_TMPDIR/auth.location"
  bk_auth auth-start </dev/null
  [ "$status" -ne 0 ]
  jq -e '.error | test("versione di rclone diversa")' <<<"$output"
}
