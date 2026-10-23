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
  jq -e --arg f "Plancia-$(hostname -s)" '. == {ok:true,connected:false,folder:$f,enabled:false,time:"04:00",job:null,interrupted:false,last_run:null,drive:null}' <<<"$output"
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
  echo 'DB_NAME=vpspanel' >"$BATS_TEST_TMPDIR/panel/config/.env"
  jq --arg p "$BATS_TEST_TMPDIR/panel" '.panel.path = $p' "$VPS_OPT/manifest.json" >"$VPS_OPT/m.tmp"
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
  deletefile) rm -f "$(rem "${@: -1}")" ;;
  purge) rm -rf "$(rem "${@: -1}")" ;;
  cleanup) ;;
esac
exit 0'
  # shellcheck disable=SC2016
  make_stub curl 'T="$BATS_TEST_TMPDIR"
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

@test "_run: dump del pannello con root dal socket, database dal .env del pannello" {
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
