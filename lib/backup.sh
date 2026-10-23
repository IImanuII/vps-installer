# shellcheck shell=bash
# Libreria di vps-backup: archivio di un sito, verifica, conservazione, lock per sito.
# Richiede lib/common.sh, lib/sites.sh e lib/files.sh (fm_as_site, fm_site_check).
#
# Formato dell'archivio di un sito (un solo file .tar.gz):
#   manifest.json   dominio, tipo, www, db, slug, login_path, data, versione, sha256
#   files.tar.gz    public/... (letto come utente del sito) + wp-config.php (letto da root)
#   db.sql.gz       solo se il sito ha un database

: "${BK_DIR:=$VPS_OPT/backup}"
: "${BK_BACKUPS:=$VPS_OPT/backups}"
: "${BK_LOCK_DIR:=/run}"

# Messaggio dell'ultimo errore di bk_archive / bk_verify (leggibile dal chiamante).
export BK_ERR=""
# Risultati di bk_connect (cartella) e bk_config_apply (configurazione da scrivere).
export BK_FOLDER="" BK_CONFIG_NEW=""
# Descrittore del lock di sito tenuto da questo processo (vuoto se nessuno).
export BK_SITE_LOCK_FD=""

# --- lock per sito ---------------------------------------------------------

# bk_lock_file SLUG — percorso del lock del sito.
bk_lock_file() {
  printf '%s/vps-site.%s.lock' "$BK_LOCK_DIR" "$1"
}

# Lo slug finisce in un nome di file: solo la forma che vps-site genera.
_bk_slug_ok() {
  [[ "${1-}" =~ ^site_[a-z0-9_]{1,27}$ ]]
}

# bk_site_lock SLUG — prende il lock del sito senza attendere e lo tiene su un
# descrittore allocato da bash (BK_SITE_LOCK_FD): i numeri fissi 6-9 sono già usati
# da redis_acl.sh, sites.sh, vps-site e vps-monitor. 1 se occupato o non apribile.
# Il nuovo lock si prova prima di lasciare il vecchio: un tentativo fallito non fa
# perdere quello già tenuto, e due lock sullo stesso sito nello stesso processo si
# vedono tra loro.
bk_site_lock() {
  local f old fd
  _bk_slug_ok "${1-}" || return 2
  f="$(bk_lock_file "$1")"
  old="$(umask)"
  umask 077
  # shellcheck disable=SC2261
  { exec {fd}>>"$f"; } 2>/dev/null || {
    umask "$old"
    return 1
  }
  umask "$old"
  chmod 600 "$f" 2>/dev/null || true
  if ! flock -n "$fd"; then
    exec {fd}>&-
    return 1
  fi
  if [[ -n "$BK_SITE_LOCK_FD" ]]; then
    exec {BK_SITE_LOCK_FD}>&-
  fi
  BK_SITE_LOCK_FD="$fd"
}

# bk_site_lock_shared SLUG — lock condiviso del sito, per chi scrive nel sito mentre
# non c'è un ripristino (vps-files, vps-site): più scrittori insieme vanno bene, ma il
# ripristino (lock esclusivo, flock -n) non parte finché ce n'è uno, e viceversa. Si tiene
# fino alla fine del processo; fm_as_site lo chiude per i figli. 0 preso; 1 occupato
# (ripristino o giro in corso); 2 slug non valido.
bk_site_lock_shared() {
  local f fd old
  _bk_slug_ok "${1-}" || return 2
  f="$(bk_lock_file "$1")"
  old="$(umask)"
  umask 077
  # shellcheck disable=SC2261
  { exec {fd}>>"$f"; } 2>/dev/null || {
    umask "$old"
    return 1
  }
  umask "$old"
  chmod 600 "$f" 2>/dev/null || true
  if ! flock -s -n "$fd"; then
    exec {fd}>&-
    return 1
  fi
  if [[ -n "$BK_SITE_LOCK_FD" ]]; then
    exec {BK_SITE_LOCK_FD}>&-
  fi
  BK_SITE_LOCK_FD="$fd"
}

# _bk_nolock COMANDO... — esegue un programma esterno senza i descrittori dei lock
# (globale e del sito): un figlio vivo non deve tenerli dopo la morte del giro.
_bk_nolock() {
  (
    if [[ -n "${BK_GLOBAL_FD:-}" ]]; then exec {BK_GLOBAL_FD}>&-; fi
    if [[ -n "${BK_SITE_LOCK_FD:-}" ]]; then exec {BK_SITE_LOCK_FD}>&-; fi
    exec "$@"
  )
}

# bk_site_unlock — rilascia il lock tenuto da questo processo.
bk_site_unlock() {
  if [[ -n "$BK_SITE_LOCK_FD" ]]; then
    exec {BK_SITE_LOCK_FD}>&-
    BK_SITE_LOCK_FD=""
  fi
}

# bk_site_locked SLUG — 0 se un altro processo tiene il lock del sito, 1 se è libero
# (o il file non esiste: non lo crea), 2 se lo slug non è valido. Un file che c'è ma
# non si riesce ad aprire conta come occupato: nel dubbio non si tocca il sito.
bk_site_locked() {
  local f fd rc=1
  _bk_slug_ok "${1-}" || return 2
  f="$(bk_lock_file "$1")"
  [[ -e "$f" || -L "$f" ]] || return 1
  # shellcheck disable=SC2261
  { exec {fd}<"$f"; } 2>/dev/null || return 0
  flock -n "$fd" || rc=0
  exec {fd}>&-
  return "$rc"
}

# --- spazio e conservazione ------------------------------------------------

# bk_space_ok DIR BYTES — 0 se lo spazio libero su DIR supera BYTES*2 + 512 MB
# (archivio finale + temporanei, più un margine per il resto del disco). BYTES
# oltre 2^50 (un petabyte) è un errore, non un calcolo che trabocca.
bk_space_ok() {
  local dir="${1-}" bytes="${2-}" free
  [[ "$bytes" =~ ^[0-9]{1,16}$ ]] || return 1
  bytes=$((10#$bytes))
  ((bytes <= 1125899906842624)) || return 1
  free="$(df -PB1 "$dir" 2>/dev/null | awk 'NR == 2 {print $4}')"
  [[ "$free" =~ ^[0-9]{1,18}$ ]] || return 1
  ((10#$free > bytes * 2 + 536870912))
}

# bk_keep_plan NOMI... — nomi del tipo qualcosa-AAAAMMGG-HHMM.ext: stampa quelli da
# eliminare, cioè tutti tranne gli ultimi 3 per data (la data è l'ultima occorrenza
# nel nome). Un nome senza data non si tocca mai (non si cancella ciò che non si
# riconosce).
bk_keep_plan() {
  local n key
  local -a rows=()
  for n in "$@"; do
    if [[ "$n" =~ ^.*-([0-9]{8}-[0-9]{4}([0-9]{2})?)\.[^/]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      rows+=("$key $n")
    fi
  done
  ((${#rows[@]} > 3)) || return 0
  printf '%s\n' "${rows[@]}" | LC_ALL=C sort | head -n "$((${#rows[@]} - 3))" | cut -d' ' -f2-
}

# --- archivio ---------------------------------------------------------------

# bk_manifest ARCHIVIO — stampa manifest.json dell'archivio.
# Il manifest non è autenticato: si legge al massimo 64 KiB (oltre, è un errore).
bk_manifest() {
  local m
  m="$(tar -xzOf "${1-}" manifest.json 2>/dev/null | head -c 65537)" || true
  ((${#m} > 0 && ${#m} <= 65536)) || return 1
  printf '%s\n' "$m"
}

# bk_tmp_dir — cartella di lavoro dentro BK_BACKUPS/tmp (root 700; non /tmp, che
# può stare in RAM). Stampa il percorso.
bk_tmp_dir() {
  install -d -m 700 "$BK_BACKUPS" "$BK_BACKUPS/tmp" || return 1
  mktemp -d "$BK_BACKUPS/tmp/bk.XXXXXX"
}

# _bk_log_file FILE ETICHETTA — mette nel registro il contenuto di FILE (testo di un
# comando che gira con dati del sito) su una riga sola, senza caratteri di controllo:
# un sito non deve poter scrivere righe finte nel registro.
_bk_log_file() {
  [[ -s "$1" ]] || return 0
  printf '[%s] bk_archive: %s: %s\n' "$(date '+%F %T')" "$2" \
    "$(head -c 500 "$1" | LC_ALL=C tr -c '[:print:]' '?')" >>"$VPS_LOG" 2>/dev/null || true
}

# bk_archive DOMINIO OUT [PARTI] — scrive l'archivio del sito in OUT. Tutto si costruisce in
# una cartella temporanea e si sposta in OUT solo a lavoro finito: se qualcosa
# fallisce non resta nulla di ciò che questa chiamata ha creato (un OUT già esistente
# non si tocca) e BK_ERR dice perché. Uscita 0/1.
# PARTI (all|files|db, predefinito all) serve alla copia di sicurezza di un ripristino,
# che salva solo ciò che si sta per sovrascrivere: la parte non salvata resta un
# files.tar.gz vuoto (o senza db.sql.gz), che un ripristino di quella parte rifiuta.
bk_archive() {
  local d="${1-}" out="${2-}" parts="${3:-all}" w rc=0 existed=0
  if [[ "$parts" != all && "$parts" != files && "$parts" != db ]]; then
    BK_ERR="parti da salvare non valide"
    return 1
  fi
  BK_ERR=""
  if [[ -z "$out" ]]; then
    BK_ERR="percorso di destinazione mancante"
    return 1
  fi
  [[ -e "$out" || -L "$out" ]] && existed=1
  w="$(bk_tmp_dir)" || {
    BK_ERR="cartella temporanea non disponibile"
    return 1
  }
  (umask 077 && _bk_archive_in "$d" "$out" "$w" "$parts") || rc=$?
  if ((rc)) && [[ -s "$w/err" ]]; then
    BK_ERR="$(head -n1 "$w/err")"
  fi
  rm -rf "$w"
  if ((rc)); then
    rm -f "$out.part"
    ((existed)) || rm -f "$out"
    return 1
  fi
}

# _bk_archive_in DOMINIO OUT LAVORO — corpo di bk_archive (in una subshell: BK_ERR non
# risale, quindi passa dal file LAVORO/err).
_bk_archive_in() {
  local d="$1" out="$2" w="$3" parts="${4:-all}" info slug root rc=0 type login hasdb www first
  info="$(fm_site_check "$d" "deleting creating" 2>&1)" || {
    printf '%s\n' "$info" >"$w/err"
    return 1
  }
  slug="${info%% *}"
  root="${info#* }"
  type="$(site_reg_get "$d" .type)"
  www="$(site_reg_get "$d" .www)"
  hasdb="$(site_reg_get "$d" .db)"
  login="$(site_reg_get "$d" '.wordpress.login_path // ""')"

  # public/ come utente del sito: root non segue mai link piazzati dal sito. Il tar
  # va su stdout rediretto a un file (niente pipe: alcune build le rifiutano). I link
  # restano link. Uscita 1 di tar = un file è cambiato mentre lo leggeva: va bene.
  if [[ "$parts" != db && -d "$root/public" ]]; then
    fm_as_site "$slug" "$root" env LC_ALL=C.UTF-8 tar --warning=no-file-changed -cf - public \
      >"$w/files.tar" 2>"$w/tar.err" || rc=$?
    _bk_log_file "$w/tar.err" "tar di $d"
    if ((rc > 1)); then
      echo "lettura dei file del sito non riuscita (tar $rc)" >"$w/err"
      return 1
    fi
    # Un cambio di utente fallito (runuser, cd) esce con 1 come "file cambiato" ma non
    # lascia nulla: senza questo controllo l'archivio avrebbe solo wp-config.php.
    tar -tf "$w/files.tar" >"$w/first.lst" 2>/dev/null || true
    first="$(head -n1 "$w/first.lst")"
    if [[ ! -s "$w/files.tar" || ( "$first" != public && "$first" != public/ ) ]]; then
      echo "lettura di public/ come utente del sito non riuscita (archivio vuoto)" >"$w/err"
      return 1
    fi
  else
    # tar vuoto valido: la fine-archivio sono blocchi da 512 byte di zeri
    head -c 10240 /dev/zero >"$w/files.tar"
  fi

  # wp-config.php è di root (640) fuori da public/: lo legge root direttamente, ma
  # mai se è un link (lo mette root, ma non si segue nulla per principio).
  if [[ "$parts" != db && -L "$root/wp-config.php" ]]; then
    echo "wp-config.php è un collegamento: sito non archiviato" >"$w/err"
    return 1
  fi
  if [[ "$parts" != db && -f "$root/wp-config.php" ]]; then
    LC_ALL=C.UTF-8 _bk_nolock tar --append --file="$w/files.tar" -C "$root" wp-config.php 2>"$w/tar2.err" || {
      _bk_log_file "$w/tar2.err" "wp-config.php di $d"
      echo "wp-config.php non aggiunto all'archivio" >"$w/err"
      return 1
    }
  fi
  gzip -n "$w/files.tar" || {
    echo "compressione dei file non riuscita" >"$w/err"
    return 1
  }

  # Prefisso delle tabelle di un WordPress: dal wp-config.php vivo (di root, il sito non lo
  # riscrive), mai da quello dell'archivio né dai nomi delle tabelle del dump.
  local prefix=""
  if [[ "$type" == wordpress && -f "$root/wp-config.php" && ! -L "$root/wp-config.php" ]]; then
    prefix="$(sed -n "s/^\$table_prefix *= *'\([A-Za-z0-9_]*\)' *;.*/\1/p" "$root/wp-config.php" | head -n1)"
  fi
  [[ "$prefix" =~ ^[A-Za-z0-9_]{1,20}$ ]] || prefix=""
  [[ "$type" != wordpress || -n "$prefix" ]] || prefix=wp_

  local dbsha=""
  if [[ "$hasdb" == true && "$parts" != files ]]; then
    # dump su file, poi gzip: se il dump fallisce lo si sa dal suo codice di uscita
    _bk_nolock mariadb-dump --single-transaction --routines --events "$slug" >"$w/db.sql" 2>"$w/dump.err" || {
      _bk_log_file "$w/dump.err" "dump di $d"
      echo "dump del database non riuscito" >"$w/err"
      return 1
    }
    gzip -n "$w/db.sql" || {
      echo "compressione del database non riuscita" >"$w/err"
      return 1
    }
    dbsha="$(sha256sum "$w/db.sql.gz" | cut -d' ' -f1)"
  fi

  jq -n --arg d "$d" --arg t "$type" --arg slug "$slug" --arg login "$login" \
    --arg www "$www" --arg db "$hasdb" --arg at "$(date -Iseconds)" \
    --arg v "$VPS_INSTALLER_VERSION" --arg parts "$parts" --arg prefix "$prefix" \
    --arg fsha "$(sha256sum "$w/files.tar.gz" | cut -d' ' -f1)" --arg dsha "$dbsha" '
    {domain: $d, type: $t, www: ($www == "true"), db: ($db == "true"), slug: $slug,
     login_path: (if $login == "" then null else $login end), date: $at,
     installer_version: $v, parts: $parts, table_prefix: (if $prefix == "" then null else $prefix end),
     sha256: {files: $fsha, db: (if $dsha == "" then null else $dsha end)}}' >"$w/manifest.json" || {
    echo "manifest non scritto" >"$w/err"
    return 1
  }

  local -a members=(manifest.json files.tar.gz)
  [[ -f "$w/db.sql.gz" ]] && members+=(db.sql.gz)
  tar -czf "$w/out.tar.gz" -C "$w" "${members[@]}" 2>>"$VPS_LOG" || {
    echo "archivio finale non scritto" >"$w/err"
    return 1
  }
  # prima accanto a OUT, poi rename: OUT non è mai a metà, nemmeno su un altro disco
  { mv -f "$w/out.tar.gz" "$out.part" && mv -f "$out.part" "$out"; } || {
    echo "archivio non spostato in $out" >"$w/err"
    return 1
  }
}

# --- verifica ---------------------------------------------------------------

# bk_verify_names LISTA RADICE — LISTA è l'output di
#   tar -P --numeric-owner --quoting-style=c -tvzf files.tar.gz
# (-P: senza, tar toglie la "/" iniziale e il nome assoluto non si vede). Con lo stile
# "c" nome e destinazione di un link sono ciascuno tra virgolette e con gli escape: non
# si divide mai il testo a occhio, quindi un " -> " dentro un nome o uno spazio
# nel nome non spostano nulla. Ogni riga deve avere esattamente la forma
#   TIPO+PERMESSI PROPRIETARIO PESO AAAA-MM-GG HH:MM "nome" [-> "dest" | link to "dest"]
# altrimenti si rifiuta tutto (fail closed). Tipi ammessi: - d l h.
# RADICE è la cartella del sito (es. /var/www/dominio): un link assoluto è ammesso solo
# se punta lì dentro. Stampa il primo problema e restituisce 1.
bk_verify_names() {
  LC_ALL=C awk -v root="$2" '
    function unq(s, start,   i, c, o, v, k, ch) {
      # s[start] è la prima lettera dopo la virgoletta; legge fino alla chiusura
      o = ""; i = start; QEND = 0
      while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "\"") { QEND = i; return o }
        if (c == "\\") {
          i++; c = substr(s, i, 1)
          if (c == "\\" || c == "\"") o = o c
          else if (c ~ /[0-7]/) {
            v = 0; k = 0
            while (k < 3 && substr(s, i, 1) ~ /[0-7]/) { v = v * 8 + substr(s, i, 1); i++; k++ }
            i--
            o = o (v == 0 ? "?" : sprintf("%c", v))
          } else o = o "?"
        } else o = o c
        i++
      }
      return o
    }
    function norm(n,   a, c, i, r) {
      c = split(n, a, "/"); r = ""
      for (i = 1; i <= c; i++) { if (a[i] == "" || a[i] == ".") continue; r = (r == "" ? a[i] : r "/" a[i]) }
      return r
    }
    # percorso T partendo dalla cartella START (già normalizzata); "" se resta dentro
    function walk(start, t,   a, c, i, d, st, j, cur) {
      d = 0
      if (start != "") d = split(start, st, "/")
      c = split(t, a, "/")
      for (i = 1; i <= c; i++) {
        if (a[i] == "" || a[i] == ".") continue
        if (d > 0) {
          cur = st[1]; for (j = 2; j <= d; j++) cur = cur "/" st[j]
          if (cur in sym) return "attraversa un altro collegamento"
        }
        if (a[i] == "..") { if (d == 0) return "esce dalla cartella del sito"; d-- }
        else { d++; st[d] = a[i] }
      }
      return ""
    }
    function fail(m) { print m; bad = 1; exit 1 }
    BEGIN {
      perm = ""; for (i = 0; i < 9; i++) perm = perm "[rwxsStT-]"
      re = "^.(" perm ") [0-9]+/[0-9]+ +[0-9]+ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] \""
      n = 0
    }
    {
      line = $0
      if (!match(line, re)) fail("riga non riconosciuta: " line)
      t = substr(line, 1, 1)
      if (t != "-" && t != "d" && t != "l" && t != "h") fail("tipo di voce non ammesso: " line)
      nm = unq(line, RLENGTH + 1)
      if (!QEND) fail("riga non chiusa: " line)
      rest = substr(line, QEND + 1)
      tg = ""
      if (t == "l" || t == "h") {
        pre = (t == "l") ? " -> \"" : " link to \""
        if (substr(rest, 1, length(pre)) != pre) fail("destinazione mancante: " line)
        tg = unq(rest, length(pre) + 1)
        if (!QEND || QEND != length(rest)) fail("destinazione non valida: " line)
      } else if (rest != "") fail("riga con testo in più: " line)
      n++; ty[n] = t; na[n] = nm; ta[n] = tg
      if (t == "l") sym[norm(nm)] = 1
    }
    END {
      if (bad) exit 1
      for (k = 1; k <= n; k++) {
        nm = na[k]; t = ty[k]; tg = ta[k]
        if (nm ~ /^\//) fail("nome assoluto: " nm)
        c = split(nm, a, "/")
        for (i = 1; i <= c; i++) if (a[i] == "..") fail("nome con \"..\": " nm)
        nn = norm(nm); pre = ""; c = split(nn, a, "/")
        for (i = 1; i < c; i++) {
          pre = (pre == "" ? a[i] : pre "/" a[i])
          if (pre in sym) fail("voce sotto un collegamento: " nm)
        }
        if (t == "l" || t == "h") {
          if (tg == "") fail("destinazione vuota: " nm)
          if (tg ~ /^\//) {
            if (t == "h" || root == "") fail("destinazione assoluta: " nm " -> " tg)
            if (tg == root) rel = ""
            else if (index(tg, root "/") == 1) rel = substr(tg, length(root) + 2)
            else fail("collegamento fuori dal sito: " nm " -> " tg)
            m = walk("", rel)
          } else if (t == "h") m = walk("", tg)
          else {
            dir = nn; if (dir ~ /\//) sub(/\/[^\/]*$/, "", dir); else dir = ""
            m = walk(dir, tg)
          }
          if (m != "") fail("collegamento " m ": " nm " -> " tg)
        }
      }
    }' "$1"
}

# bk_verify ARCHIVIO — 0 se l'archivio è integro e sicuro da estrarre: contiene solo
# manifest.json, files.tar.gz e (opzionale) db.sql.gz come file regolari senza doppioni,
# i sha256 del manifest tornano, e files.tar.gz non ha nomi assoluti, "..", né link che
# escono dalla cartella del sito (vedi bk_verify_names). Non estrae nulla nel sito.
# 1 con BK_ERR altrimenti.
bk_verify() {
  local a="${1-}" w rc=0
  BK_ERR=""
  if [[ ! -f "$a" ]]; then
    BK_ERR="archivio non trovato"
    return 1
  fi
  w="$(bk_tmp_dir)" || {
    BK_ERR="cartella temporanea non disponibile"
    return 1
  }
  _bk_verify_in "$a" "$w" || rc=$?
  if ((rc)) && [[ -s "$w/err" ]]; then
    BK_ERR="$(head -n1 "$w/err")"
  fi
  rm -rf "$w"
  return "$rc"
}

_bk_verify_in() {
  local a="$1" w="$2" line t name have_db=0 want got dom
  local -A seen=()
  local re='^(.)[rwxsStT-]{9} [0-9]+/[0-9]+ +[0-9]+ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} "([^"\\]*)"$'
  # 1. l'archivio esterno ha solo le tre voci previste, una volta, file regolari
  LC_ALL=C.UTF-8 tar -P --numeric-owner --quoting-style=c -tvzf "$a" >"$w/outer.lst" 2>/dev/null || {
    echo "archivio illeggibile" >"$w/err"
    return 1
  }
  while IFS= read -r line; do
    if [[ ! "$line" =~ $re ]]; then
      echo "voce non riconosciuta nell'archivio" >"$w/err"
      return 1
    fi
    t="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    if [[ "$t" != - ]]; then
      echo "voce non ammessa nell'archivio: $name" >"$w/err"
      return 1
    fi
    case "$name" in
      manifest.json | files.tar.gz | db.sql.gz) ;;
      *)
        echo "voce non ammessa nell'archivio: $name" >"$w/err"
        return 1
        ;;
    esac
    if [[ -n "${seen[$name]-}" ]]; then
      echo "voce duplicata nell'archivio: $name" >"$w/err"
      return 1
    fi
    seen[$name]=1
    [[ "$name" == db.sql.gz ]] && have_db=1
  done <"$w/outer.lst"
  tar -xzf "$a" -C "$w" --no-same-owner --no-same-permissions manifest.json files.tar.gz 2>/dev/null || {
    echo "archivio incompleto: mancano manifest.json o files.tar.gz" >"$w/err"
    return 1
  }
  if ((have_db)); then
    tar -xzf "$a" -C "$w" --no-same-owner --no-same-permissions db.sql.gz 2>/dev/null || {
      echo "db.sql.gz illeggibile" >"$w/err"
      return 1
    }
  fi
  # 2. manifest e checksum
  jq -e . "$w/manifest.json" >/dev/null 2>&1 || {
    echo "manifest non valido" >"$w/err"
    return 1
  }
  dom="$(jq -r '.domain // ""' "$w/manifest.json")"
  if ! valid_domain "$dom"; then
    echo "dominio del manifest non valido" >"$w/err"
    return 1
  fi
  want="$(jq -r '.sha256.files // ""' "$w/manifest.json")"
  got="$(sha256sum "$w/files.tar.gz" | cut -d' ' -f1)"
  if [[ ! "$want" =~ ^[0-9a-f]{64}$ || "$want" != "$got" ]]; then
    echo "checksum di files.tar.gz non corrisponde" >"$w/err"
    return 1
  fi
  want="$(jq -r '.sha256.db // ""' "$w/manifest.json")"
  if ((have_db)); then
    got="$(sha256sum "$w/db.sql.gz" | cut -d' ' -f1)"
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ || "$want" != "$got" ]]; then
      echo "checksum di db.sql.gz non corrisponde" >"$w/err"
      return 1
    fi
  elif [[ -n "$want" ]]; then
    echo "db.sql.gz dichiarato nel manifest ma assente" >"$w/err"
    return 1
  fi
  # 3. nomi e link di files.tar.gz
  LC_ALL=C.UTF-8 tar -P --numeric-owner --quoting-style=c -tvzf "$w/files.tar.gz" >"$w/files.lst" 2>/dev/null || {
    echo "files.tar.gz illeggibile" >"$w/err"
    return 1
  }
  bk_verify_names "$w/files.lst" "$(site_root "$dom")" >"$w/err" || return 1
  rm -f "$w/err"
}

# --- configurazione, collegamento a Google Drive, stato (tools/vps-backup) -----

: "${BK_CONFIG:=$BK_DIR/config.json}"
: "${BK_STATE:=$BK_DIR/state.json}"
: "${BK_RCLONE_CONF:=$VPS_OPT/secrets/rclone.conf}"
# Comando rclone (sostituibile nei test). Il file di configurazione è sempre esplicito.
: "${BK_RCLONE:=rclone --config $BK_RCLONE_CONF}"
: "${BK_TIME_DEFAULT:=04:00}"

# bk_valid_time HH:MM — 00:00-23:59.
bk_valid_time() {
  [[ "${1-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# bk_valid_folder NOME — un solo nome di cartella, mai un percorso.
bk_valid_folder() {
  [[ "${1-}" =~ ^[A-Za-z0-9._-]{1,64}$ && "${1-}" != . && "${1-}" != .. ]]
}

# bk_default_folder — Plancia-<nome macchina>, ripulito dai caratteri non ammessi.
bk_default_folder() {
  local h
  h="$(hostname -s 2>/dev/null || true)"
  h="$(printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '-' | head -c 50)"
  [[ -n "$h" ]] || h=vps
  printf 'Plancia-%s' "$h"
}

# bk_config_json — configurazione valida: ogni campo mancante o sbagliato torna
# al predefinito (un config.json rovinato a mano non deve bloccare lo stato).
bk_config_json() {
  local raw='{}' df
  df="$(bk_default_folder)"
  if [[ -f "$BK_CONFIG" ]]; then raw="$(jq -c 'if type == "object" then . else {} end' "$BK_CONFIG" 2>/dev/null)" || raw='{}'; fi
  [[ -n "$raw" ]] || raw='{}'
  jq -c --arg t "$BK_TIME_DEFAULT" --arg f "$df" '{
    enabled: (if .enabled == true then true else false end),
    time: (if (.time | type) == "string" and (.time | test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) then .time else $t end),
    folder: (if (.folder | type) == "string" and (.folder | test("^[A-Za-z0-9._-]{1,64}$")) and .folder != "." and .folder != ".." then .folder else $f end)
  }' <<<"$raw"
}

# bk_clean_msg TESTO [SEGRETO...] — una riga leggibile da un messaggio di rclone:
# ultima riga non vuota, segreti noti e token in forma riconoscibile tolti,
# caratteri non stampabili sostituiti, al massimo 200 caratteri.
bk_clean_msg() {
  local m s
  m="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n1 || true)"
  shift
  for s in "$@"; do
    if [[ -n "$s" ]]; then m="${m//"$s"/***}"; fi
  done
  m="$(printf '%s' "$m" | sed -E 's/ya29\.[A-Za-z0-9._-]+/***/g; s#1//[A-Za-z0-9._-]+#***#g; s/("?(access_token|refresh_token|client_secret)"?[ =:]+)"?[^" ,}]+/\1***/g' | tr -c '[:print:]' '?' | head -c 200)"
  [[ -n "$m" ]] || m="errore sconosciuto"
  printf '%s' "$m"
}

# bk_drive_json — {used,total} da `rclone about`, "null" se Drive non risponde.
# total 0 = spazio illimitato (rclone non lo riporta).
bk_drive_json() {
  local out
  local -a cmd
  read -ra cmd <<<"$BK_RCLONE"
  if ! out="$(timeout 20 "${cmd[@]}" about gdrive: --json 2>/dev/null </dev/null)"; then
    printf 'null'
    return 0
  fi
  out="$(jq -c 'if type == "object" and (.used | type) == "number" then {used: (.used | floor), total: ((.total // 0) | floor)} else null end' <<<"$out" 2>/dev/null)" || out=""
  printf '%s' "${out:-null}"
}

# bk_status_json — risposta di `vps-backup status`.
bk_status_json() {
  local cfg state='{}' drive=null conn=false interrupted running=0 ijob
  # Prima si guarda se un giro è vivo (lock o unità systemd), poi si legge lo stato:
  # un giro che parte o finisce nel frattempo non può essere dichiarato interrotto.
  if bk_global_busy || bk_unit_alive; then running=1; fi
  cfg="$(bk_config_json)"
  if [[ -f "$BK_STATE" ]]; then state="$(jq -c 'if type == "object" then . else {} end' "$BK_STATE" 2>/dev/null)" || state='{}'; fi
  [[ -n "$state" ]] || state='{}'
  if [[ -f "$BK_RCLONE_CONF" ]]; then
    conn=true
    drive="$(bk_drive_json)"
  fi
  # Un giro morto (kill, riavvio) lascia `job` in state.json: se il lock globale è
  # libero e nessuna unità gira, nessuno sta più lavorando: niente job e
  # `interrupted` a true.
  interrupted=false
  ijob=null
  if [[ "$(jq -c '.job // null' <<<"$state")" != null ]] && ((!running)); then
    interrupted=true
    ijob="$(jq -c '.job' <<<"$state")"
    state="$(jq -c '.job = null' <<<"$state")"
  fi
  jq -nc --argjson c "$cfg" --argjson s "$state" --argjson d "$drive" --argjson conn "$conn" --argjson i "$interrupted" --argjson ij "$ijob" \
    '{ok: true, connected: $conn, folder: $c.folder, enabled: $c.enabled, time: $c.time,
      job: ($s.job // null), interrupted: $i, interrupted_job: $ij, last_run: ($s.last_run // null),
      last_restore: ($s.last_restore // null), drive: $d}'
}

# bk_connect DATI_STDIN — riga 1: token JSON di `rclone authorize`; righe 2-3
# (facoltative, insieme): client id e secret propri. Il token arriva solo da stdin
# e finisce solo in rclone.conf (600, scritto qui, mai passato come argomento).
# Imposta BK_FOLDER (nome della cartella); in caso di errore BK_ERR e 1, senza file
# lasciati. Va chiamata senza $(...): le variabili andrebbero perse nella subshell.
bk_connect() {
  local -a righe cmd
  local tok id sec folder tmp prev="" out rc=0 conf dir at rt
  mapfile -t righe < <(printf '%s' "$1")
  tok="${righe[0]:-}"
  id="${righe[1]:-}"
  sec="${righe[2]:-}"
  tok="${tok%$'\r'}" id="${id%$'\r'}" sec="${sec%$'\r'}"
  if [[ -z "$tok" ]]; then
    BK_ERR="token mancante"
    return 1
  fi
  if ! jq -e -s 'length == 1 and (.[0] | type == "object"
      and (.access_token | type == "string" and length > 0)
      and (.refresh_token | type == "string" and length > 0))' <<<"$tok" >/dev/null 2>&1; then
    BK_ERR="token non valido: serve il testo stampato da \"rclone authorize\" (access_token e refresh_token)"
    return 1
  fi
  if [[ -n "$id$sec" ]]; then
    if [[ ! "$id" =~ ^[A-Za-z0-9._~-]{1,256}$ || ! "$sec" =~ ^[A-Za-z0-9._~-]{1,256}$ ]]; then
      BK_ERR="client id e secret vanno indicati insieme e con caratteri validi"
      return 1
    fi
  fi
  at="$(jq -r '.access_token' <<<"$tok")"
  rt="$(jq -r '.refresh_token' <<<"$tok")"
  tok="$(jq -c '{access_token, token_type: (.token_type // "Bearer"), refresh_token, expiry}
    | with_entries(select(.value != null))' <<<"$tok")"
  folder="$(jq -r .folder <<<"$(bk_config_json)")"

  conf="$BK_RCLONE_CONF"
  dir="$(dirname "$conf")"
  # Questa funzione gira sotto `|| json_err`: errexit e trap ERR sono spenti, quindi
  # ogni operazione sui file è controllata a mano e il file attuale non si tocca
  # finché la copia di sicurezza e il nuovo file non sono pronti.
  install -d -m 700 "$dir" || { BK_ERR="cartella dei segreti non disponibile"; return 1; }
  # Avanzi di un collegamento interrotto (processo ucciso a metà).
  rm -f "$dir"/.rclone-prev.* "$dir"/.rclone-new.*
  if [[ -f "$conf" ]]; then
    prev="$(umask 077; mktemp "$dir/.rclone-prev.XXXXXX")" || prev=""
    if [[ -z "$prev" ]] || ! cp -p "$conf" "$prev" || ! cmp -s "$conf" "$prev"; then
      [[ -z "$prev" ]] || rm -f "$prev"
      BK_ERR="copia di sicurezza del collegamento attuale non riuscita: nulla è cambiato"
      return 1
    fi
  fi
  tmp="$(umask 077; mktemp "$dir/.rclone-new.XXXXXX")" || tmp=""
  if [[ -z "$tmp" ]]; then
    [[ -z "$prev" ]] || rm -f "$prev"
    BK_ERR="file del collegamento non creato: nulla è cambiato"
    return 1
  fi
  if ! {
    printf '[gdrive]\ntype = drive\nscope = drive.file\n'
    if [[ -n "$id" ]]; then printf 'client_id = %s\nclient_secret = %s\n' "$id" "$sec"; fi
    printf 'token = %s\n' "$tok"
  } >"$tmp" || ! chmod 600 "$tmp" || ! own root:root "$tmp" || ! mv -f "$tmp" "$conf"; then
    rm -f "$tmp"
    [[ -z "$prev" ]] || rm -f "$prev"
    BK_ERR="file del collegamento non scritto: nulla è cambiato"
    return 1
  fi

  read -ra cmd <<<"$BK_RCLONE"
  out="$("${cmd[@]}" mkdir "gdrive:$folder" 2>&1 </dev/null)" || rc=$?
  if ((rc == 0)); then
    out="$(printf 'plancia' | "${cmd[@]}" rcat "gdrive:$folder/.plancia-test" 2>&1)" || rc=$?
  fi
  if ((rc == 0)); then
    out="$("${cmd[@]}" deletefile "gdrive:$folder/.plancia-test" 2>&1 </dev/null)" || rc=$?
  fi
  if ((rc != 0)); then
    # Il collegamento non è valido: torna il file di prima, o nessun file.
    BK_ERR="Google Drive non ha accettato il collegamento: $(bk_clean_msg "$out" "$tok" "$at" "$rt" "$sec")"
    if [[ -n "$prev" ]]; then
      # Se il ripristino fallisce la copia di sicurezza resta dov'è (non si cancella:
      # sarebbe l'unico esemplare del collegamento che funzionava) e lo si dice.
      if ! mv -f "$prev" "$conf"; then
        BK_ERR="$BK_ERR; il collegamento precedente non è stato ripristinato, la copia è in $prev"
      fi
    else
      rm -f "$conf"
    fi
    log "vps-backup: collegamento non riuscito ($BK_ERR)"
    return 1
  fi
  [[ -z "$prev" ]] || rm -f "$prev"
  BK_FOLDER="$folder"
}

# bk_config_apply DATI_JSON — valida {enabled,time,folder} e imposta la configurazione
# da scrivere in BK_CONFIG_NEW; BK_ERR e 1 se non valida (anche questa senza $(...)).
# folder omesso = quello attuale.
bk_config_apply() {
  local d="$1" en t f
  if ! jq -e 'type == "object"' <<<"$d" >/dev/null 2>&1; then
    BK_ERR="configurazione non valida"
    return 1
  fi
  en="$(jq -r '.enabled | if type == "boolean" then tostring else "x" end' <<<"$d")"
  if [[ "$en" != true && "$en" != false ]]; then
    BK_ERR="enabled deve essere true o false"
    return 1
  fi
  t="$(jq -r '.time | if type == "string" then . else "" end' <<<"$d")"
  if ! bk_valid_time "$t"; then
    BK_ERR="orario non valido (HH:MM, da 00:00 a 23:59)"
    return 1
  fi
  if [[ "$(jq 'has("folder")' <<<"$d")" == true ]]; then
    f="$(jq -r '.folder | if type == "string" then . else "" end' <<<"$d")"
  else
    f="$(jq -r .folder <<<"$(bk_config_json)")"
  fi
  if ! bk_valid_folder "$f"; then
    BK_ERR="nome cartella non valido (lettere, numeri, punto, trattino, al massimo 64 caratteri)"
    return 1
  fi
  BK_CONFIG_NEW="$(jq -nc --argjson e "$en" --arg t "$t" --arg f "$f" '{enabled: $e, time: $t, folder: $f}')"
}

# --- il giro (vps-backup _run) ---------------------------------------------------

# Lock globale: lo tiene _run per tutto il giro (e in futuro il ripristino);
# connect/disconnect/config lo chiedono senza aspettare. Descrittore allocato da
# bash: nessun numero fisso, che qui sono già presi (reg_lock usa il 7 e il 9).
BK_GLOBAL_FD=""

bk_global_lock_file() {
  printf '%s/vps-backup.lock' "$BK_LOCK_DIR"
}

# bk_lock_global [SECONDI] — 0 lock preso (resta tenuto fino a bk_unlock_global o alla fine
# del processo); 1 occupato o non apribile.
bk_lock_global() {
  local f fd wait="${1:-0}"
  [[ "$wait" =~ ^[0-9]{1,4}$ ]] || wait=0
  f="$(bk_global_lock_file)"
  # shellcheck disable=SC2261
  { exec {fd}>>"$f"; } 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null || true
  if ((wait > 0)); then
    flock -w "$wait" "$fd" || {
      exec {fd}>&-
      return 1
    }
  elif ! flock -n "$fd"; then
    exec {fd}>&-
    return 1
  fi
  BK_GLOBAL_FD="$fd"
}

bk_unlock_global() {
  if [[ -n "$BK_GLOBAL_FD" ]]; then
    exec {BK_GLOBAL_FD}>&-
    BK_GLOBAL_FD=""
  fi
}

# bk_unit_alive — 0 se l'unità di un giro (a mano o del timer) o di un ripristino
# sta girando o partendo.
bk_unit_alive() {
  local out
  out="$(systemctl is-active vps-backup-run.service vps-backup.service 'vps-backup-restore-*.service' 2>/dev/null || true)"
  grep -qE '^(active|activating|reloading|deactivating)$' <<<"$out"
}

# bk_global_busy — 0 se un altro processo tiene il lock globale. Se il file non si
# apre, nessuno può tenerlo: libero.
bk_global_busy() {
  local f fd rc=1
  f="$(bk_global_lock_file)"
  [[ -e "$f" ]] || return 1
  # shellcheck disable=SC2261
  { exec {fd}<"$f"; } 2>/dev/null || return 1
  flock -n "$fd" || rc=0
  exec {fd}>&-
  return "$rc"
}

: "${BK_PURGE_DAYS:=30}"
: "${BK_RUN_DIR:=}"
_BK_RC=()
_BK_OUT=""
_BK_LST=""
_BK_DELETED=0
_BK_ERRMSG=""
_BK_SITES='[]'
_BK_PANEL='null'
_BK_PURGED='[]'
_BK_STARTED=""
_BK_PREV_LAST='null'
_BK_KNOWN='[]'
_BK_RCRC=0
_BK_LAST_RESTORE='null'

# _bk_rcq ARGOMENTI... — rclone con stdout in _BK_OUT e messaggio d'errore ripulito
# (una riga, senza token) in _BK_ERRMSG. Mai stdin dal terminale.
_bk_rcq() {
  local rc=0 ef own=0
  # Fuori da un giro (list-remote, read-remote) non c'è una cartella di lavoro: il
  # file degli errori è un temporaneo che si toglie subito.
  if [[ -n "$BK_RUN_DIR" ]]; then
    ef="$BK_RUN_DIR/rc.err"
  else
    ef="$(mktemp)" || return 1
    own=1
  fi
  _BK_OUT="$(_bk_nolock "${_BK_RC[@]}" "$@" 2>"$ef" </dev/null)" || rc=$?
  _BK_ERRMSG=""
  _BK_RCRC="$rc"
  if ((rc != 0)); then _BK_ERRMSG="$(bk_clean_msg "$(cat "$ef" 2>/dev/null || true)")"; fi
  if ((own)); then rm -f -- "$ef"; fi
  return "$rc"
}

# _bk_state_write JOB LAST — state.json (600) con sostituzione atomica. L'esito
# dell'ultimo ripristino (last_restore) sta nello stesso file: un giro non lo cancella.
# `known` sono
# i domini che questa installazione ha già salvato almeno una volta: solo quelli si
# potranno eliminare da Drive (una VPS ricostruita non cancella le copie di altri).
_bk_state_write() {
  install -d -m 700 "$BK_DIR" || return 1
  jq -nc --argjson j "$1" --argjson l "$2" --argjson k "$_BK_KNOWN" --argjson r "$_BK_LAST_RESTORE" \
    '{job: $j, last_run: $l, known: $k, last_restore: $r}' | write_file "$BK_STATE" 600 root:root
}

# _bk_progress PASSO [DOMINIO] — il pannello legge job.step e job.domain.
_bk_progress() {
  local job
  job="$(jq -nc --arg u "${BK_UNIT:-vps-backup.service}" --arg s "$_BK_STARTED" --arg st "$1" --arg d "${2-}" \
    '{unit: $u, op: "run", started: $s, step: $st, domain: (if $d == "" then null else $d end)}')"
  _bk_state_write "$job" "$_BK_PREV_LAST" || log "vps-backup: state.json non scritto"
}

# _bk_add_site DOMINIO OK(true|false) MOTIVO FILE DIMENSIONE ELIMINATE
_bk_add_site() {
  _BK_SITES="$(jq -c --arg d "$1" --argjson ok "$2" --arg r "$3" --arg f "${4:-}" --arg s "${5:-0}" --arg n "${6:-0}" \
    '. + [{domain: $d, ok: $ok, reason: (if $r == "" then null else $r end),
           file: (if $f == "" then null else $f end), size: ($s | tonumber), deleted: ($n | tonumber)}]' <<<"$_BK_SITES")"
}

# _bk_stamp — AAAAMMGG-HHMM del momento (BK_NOW solo nei test).
_bk_stamp() {
  printf '%s' "${BK_NOW:-$(date +%Y%m%d-%H%M)}"
}

# _bk_ls_files CARTELLA_SU_DRIVE — imposta _BK_LST con righe "dimensione|nome" dei
# soli file con nome ordinario (quelli creati qui); 1 se Drive non risponde.
# Niente $(...): _BK_ERRMSG andrebbe perso.
_bk_ls_files() {
  _BK_LST=""
  _bk_rcq lsjson --files-only "gdrive:$1" || return 1
  _BK_LST="$(jq -r '.[] | select(.Name | test("^[A-Za-z0-9._-]+$")) | "\(.Size)|\(.Name)"' <<<"$_BK_OUT")" || {
    _BK_ERRMSG="risposta di Drive non leggibile"
    return 1
  }
}

# _bk_upload LOCALE CARTELLA NOME — copyto e confronto della dimensione con quella di
# Drive; la copia caricata ma diversa si cancella. Se riesce, _BK_LST è l'elenco dei
# file della cartella (per la conservazione); se no, _BK_ERRMSG dice perché.
_bk_upload() {
  local local_f="$1" dir="$2" name="$3" want got msg
  want="$(stat -c %s "$local_f")"
  if ! _bk_rcq copyto "$local_f" "gdrive:$dir/$name"; then
    _BK_ERRMSG="caricamento su Drive non riuscito: $_BK_ERRMSG"
    return 1
  fi
  if ! _bk_ls_files "$dir"; then
    msg="controllo della copia su Drive non riuscito: $_BK_ERRMSG"
    _bk_rcq deletefile --drive-use-trash=false "gdrive:$dir/$name" || true
    _BK_ERRMSG="$msg"
    return 1
  fi
  got="$(awk -F'|' -v n="$name" '$2 == n {print $1; exit}' <<<"$_BK_LST")"
  if [[ "$got" != "$want" ]]; then
    msg="la copia su Drive ha dimensione diversa (attesa $want, trovata ${got:-nessuna})"
    _bk_rcq deletefile --drive-use-trash=false "gdrive:$dir/$name" || true
    _BK_ERRMSG="$msg"
    return 1
  fi
}

# _bk_retain CARTELLA NOME_APPENA_CARICATO ELENCO REGEX — tiene le ultime 3 copie fra i
# soli nomi che corrispondono a REGEX (quelli che crea questo programma: altri file
# nella cartella non si contano né si toccano mai); la copia appena caricata e
# controllata non si cancella, qualunque sia la sua data.
# Imposta _BK_DELETED (quante ne ha eliminate).
_bk_retain() {
  local dir="$1" keep="$2" lst="$3" re="$4" n deleted=0
  local -a names=()
  while IFS= read -r n; do
    if [[ -n "$n" && "$n" =~ $re ]]; then names+=("$n"); fi
  done < <(cut -d'|' -f2 <<<"$lst")
  while IFS= read -r n; do
    [[ -n "$n" && "$n" != "$keep" ]] || continue
    # --drive-use-trash=false: con lo scope drive.file il cestino non si può svuotare,
    # quindi la copia si elimina davvero (senza cestino e senza `cleanup`).
    if _bk_rcq deletefile --drive-use-trash=false "gdrive:$dir/$n"; then
      deleted=$((deleted + 1))
    else
      log "vps-backup: eliminazione di $dir/$n non riuscita ($_BK_ERRMSG)"
    fi
  done < <(bk_keep_plan "${names[@]}")
  _BK_DELETED="$deleted"
}

# _bk_site_re DOMINIO — espressione dei nomi delle copie di un sito.
_bk_site_re() {
  printf '^%s-[0-9]{8}-[0-9]{4}\\.tar\\.gz$' "${1//./\\.}"
}

_BK_PANEL_RE='^pannello-[0-9]{8}-[0-9]{4}\.sql\.gz$'

# _bk_known_add DOMINIO / _bk_known_del DOMINIO
_bk_known_add() {
  _BK_KNOWN="$(jq -c --arg d "$1" 'if index($d) then . else . + [$d] end' <<<"$_BK_KNOWN")"
}
_bk_known_del() {
  _BK_KNOWN="$(jq -c --arg d "$1" 'map(select(. != $d))' <<<"$_BK_KNOWN")"
}

# _bk_site_size DOMINIO [PARTI] — stima in byte di quanto pesa l'archivio: public/ (du -P non
# segue i link), wp-config.php e, se c'è, il database. Stampa il numero; 1 se
# public/ non si legge.
_bk_site_size() {
  local d="$1" parts="${2:-all}" root pub=0 wp=0 db=0 slug v
  root="$(site_root "$d")"
  if [[ "$parts" != db && -d "$root/public" ]]; then
    pub="$(du -sbP -- "$root/public" 2>/dev/null | cut -f1 || true)"
    [[ "$pub" =~ ^[0-9]{1,16}$ ]] || return 1
  fi
  if [[ "$parts" != db && -f "$root/wp-config.php" && ! -L "$root/wp-config.php" ]]; then
    wp="$(stat -c %s "$root/wp-config.php" 2>/dev/null || echo 0)"
  fi
  if [[ "$parts" != files && "$(site_reg_get "$d" .db 2>/dev/null || true)" == true ]]; then
    slug="$(site_reg_get "$d" .slug 2>/dev/null || true)"
    if [[ "$slug" =~ ^site_[a-z0-9_]{1,27}$ ]]; then
      v="$(_bk_nolock mariadb -N -B -e "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = '$slug'" 2>/dev/null </dev/null | head -n1 || true)"
      [[ "$v" =~ ^[0-9]{1,16}$ ]] && db="$v"
    fi
  fi
  printf '%s' "$((10#$pub + 10#$wp + 10#$db))"
}

# _bk_one_site DOMINIO CARTELLA — salva un sito; aggiunge l'esito a _BK_SITES.
# Restituisce 0 se salvato, 1 altrimenti (il giro prosegue).
_bk_one_site() {
  local d="$1" folder="$2" slug lrc=0 size name arc ok_size
  _bk_progress site "$d"
  slug="$(site_reg_get "$d" .slug 2>/dev/null || true)"
  bk_site_lock "$slug" || lrc=$?
  if ((lrc == 1)); then
    _bk_add_site "$d" false "sito occupato"
    return 1
  elif ((lrc != 0)); then
    _bk_add_site "$d" false "registro del sito non valido"
    return 1
  fi
  bk_prune_site_tmp "$slug" "$(site_root "$d")"
  if [[ "$(site_reg_get "$d" .db 2>/dev/null || true)" == true ]]; then _bk_db_tmp_clean "$slug"; fi
  if ! size="$(_bk_site_size "$d")"; then
    bk_site_unlock
    _bk_add_site "$d" false "dimensione del sito non leggibile"
    return 1
  fi
  if ! bk_space_ok "$BK_BACKUPS/tmp" "$size"; then
    bk_site_unlock
    _bk_add_site "$d" false "spazio insufficiente"
    return 1
  fi
  name="$d-$(_bk_stamp).tar.gz"
  arc="$BK_RUN_DIR/$name"
  if ! bk_archive "$d" "$arc"; then
    bk_site_unlock
    rm -f -- "$arc"
    _bk_add_site "$d" false "archivio non riuscito: ${BK_ERR:-errore}"
    return 1
  fi
  bk_site_unlock
  _bk_progress upload "$d"
  ok_size="$(stat -c %s "$arc")"
  if ! _bk_upload "$arc" "$folder/$d" "$name"; then
    rm -f -- "$arc"
    _bk_add_site "$d" false "$_BK_ERRMSG"
    return 1
  fi
  rm -f -- "$arc"
  _bk_known_add "$d"
  _bk_progress retention "$d"
  _bk_retain "$folder/$d" "$name" "$_BK_LST" "$(_bk_site_re "$d")"
  _bk_add_site "$d" true "" "$name" "$ok_size" "$_BK_DELETED"
}

# _bk_panel FOLDER — dump del database del pannello (stesso database e stesso modo di
# pd_dump: root dal socket, senza password) in _pannello/, ultimi 3 su Drive.
# Imposta _BK_PANEL.
_bk_panel() {
  local folder="$1" db name f size penv
  _bk_progress panel
  # Come pd_db_name, ma senza pd_load (che termina il processo se il manifest manca).
  penv="$(jq -r '.panel.path // empty' "$(manifest_path)" 2>/dev/null || true)"
  db=""
  if [[ -n "$penv" ]]; then db="$(env_get "$penv/config/.env" DB_NAME 2>/dev/null || true)"; fi
  if ! sql_ident_ok "$db"; then
    _BK_PANEL="$(jq -nc '{ok: false, error: "database del pannello non trovato", file: null}')"
    return 1
  fi
  name="pannello-$(_bk_stamp).sql.gz"
  f="$BK_RUN_DIR/$name"
  if ! (
    set -o pipefail
    umask 077
    _bk_nolock mariadb-dump --single-transaction --routines --events "$db" | _bk_nolock gzip >"$f"
  ) 2>/dev/null; then
    rm -f -- "$f"
    _BK_PANEL="$(jq -nc '{ok: false, error: "dump del database del pannello non riuscito", file: null}')"
    return 1
  fi
  size="$(stat -c %s "$f")"
  if ! _bk_upload "$f" "$folder/_pannello" "$name"; then
    rm -f -- "$f"
    _BK_PANEL="$(jq -nc --arg e "$_BK_ERRMSG" '{ok: false, error: $e, file: null}')"
    return 1
  fi
  rm -f -- "$f"
  _bk_retain "$folder/_pannello" "$name" "$_BK_LST" "$_BK_PANEL_RE"
  _BK_PANEL="$(jq -nc --arg f "$name" --arg s "$size" --arg n "$_BK_DELETED" \
    '{ok: true, error: null, file: $f, size: ($s | tonumber), deleted: ($n | tonumber)}')"
}

# _bk_purge_gone FOLDER — elimina da Drive la cartella di un sito solo se: questa
# installazione l'ha salvato in passato (known), non è più nel registro e la sua
# copia più recente ha più di BK_PURGE_DAYS giorni. Una VPS appena ricostruita (stato
# vuoto) non elimina quindi mai niente; un sito senza copie riconoscibili non si tocca.
_bk_purge_gone() {
  local folder="$1" dirs d newest cutoff n re
  local -a names=()
  [[ -d "$SITES_DIR" ]] || return 0
  _bk_rcq lsjson --dirs-only "gdrive:$folder" || return 0
  dirs="$(jq -r '.[] | select(.Name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) | .Name' <<<"$_BK_OUT" 2>/dev/null)" || return 0
  cutoff="$(date -d "$BK_PURGE_DAYS days ago" +%Y%m%d)"
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != _pannello ]] || continue
    valid_domain "$d" || continue
    if [[ "$(jq --arg d "$d" 'index($d) != null' <<<"$_BK_KNOWN")" != true ]]; then continue; fi
    if site_reg_exists "$d"; then continue; fi
    _bk_ls_files "$folder/$d" || continue
    re="$(_bk_site_re "$d")"
    newest=""
    mapfile -t names < <(cut -d'|' -f2 <<<"$_BK_LST")
    for n in "${names[@]}"; do
      if [[ "$n" =~ $re ]]; then
        [[ "$n" =~ -([0-9]{8})-[0-9]{4}\.tar\.gz$ ]] || continue
        if [[ -z "$newest" || "${BASH_REMATCH[1]}" > "$newest" ]]; then newest="${BASH_REMATCH[1]}"; fi
      fi
    done
    [[ -n "$newest" ]] || continue
    if [[ "$newest" < "$cutoff" ]]; then
      if _bk_rcq purge --drive-use-trash=false "gdrive:$folder/$d"; then
        _BK_PURGED="$(jq -c --arg d "$d" '. + [$d]' <<<"$_BK_PURGED")"
        _bk_known_del "$d"
      else
        log "vps-backup: eliminazione della cartella $d su Drive non riuscita ($_BK_ERRMSG)"
      fi
    fi
  done <<<"$dirs"
}

# _bk_alert — un solo messaggio per giro, se un sito o il pannello sono falliti.
# mon_send funziona anche a sorveglianza spenta; niente coda. Stampa l'esito per
# last_run.alert.
_bk_alert() {
  local text rc=0
  text="$(jq -r --arg h "$(hostname)" --argjson p "$_BK_PANEL" '
    [.[] | select(.ok | not)] as $f
    | if ($f | length) == 0 and ($p.ok // false) then ""
      else
        (if ($f | length) > 0 then "💾 \($h): Backup: \($f | length) siti non salvati"
         else "💾 \($h): Backup: pannello non salvato" end)
        + ([$f[] | "\n\(.domain): \(.reason)"] | join(""))
        + (if ($p.ok // false) then "" else "\npannello: \($p.error // "dump non riuscito")" end)
      end' <<<"$_BK_SITES")"
  if [[ -z "$text" ]]; then
    printf 'null'
    return 0
  fi
  _bk_mon_send "$text" || rc=$?
  if ((rc == 0)); then
    printf '"sent"'
  elif [[ "${MON_SEND_ERR:-}" == "Telegram non configurato" ]]; then
    printf '"not_configured"'
  else
    jq -nc --arg e "${MON_SEND_ERR:-errore sconosciuto}" '"failed: " + $e'
  fi
}

# _bk_last_json ALERT — l'oggetto last_run.
_bk_last_json() {
  local ok
  ok="$(jq -n --argjson s "$_BK_SITES" --argjson p "$_BK_PANEL" '(([$s[] | select(.ok | not)] | length) == 0) and ($p.ok // false)')"
  jq -nc --arg st "$_BK_STARTED" --arg fin "$(date -Iseconds)" --argjson ok "$ok" --argjson s "$_BK_SITES" \
    --argjson p "$_BK_PANEL" --argjson pu "$_BK_PURGED" --argjson al "$1" \
    '{started: $st, finished: $fin, ok: $ok, sites: $s, panel: $p, purged: $pu, alert: $al}'
}

# bk_run_all — il giro. Stampa il riepilogo JSON; 0 se tutto è stato salvato, 1 se un
# sito o il pannello sono falliti (stato scritto e avviso inviato comunque) o se il
# giro non è potuto partire.
bk_run_all() {
  local folder d f alert last st rc=0 drive_ok=0
  local -a doms=()
  if ! bk_lock_global; then
    printf '{"ok":false,"error":"backup in corso"}\n'
    return 1
  fi
  if [[ ! -f "$BK_RCLONE_CONF" ]]; then
    printf '{"ok":false,"error":"Google Drive non collegato"}\n'
    return 1
  fi
  read -ra _BK_RC <<<"$BK_RCLONE"
  folder="$(jq -r .folder <<<"$(bk_config_json)")"
  install -d -m 700 "$BK_BACKUPS" "$BK_BACKUPS/tmp"
  # Col lock globale in mano nessun altro lavora: le cartelle di un giro morto
  # (bk.run.*) si tolgono a qualunque età; gli altri avanzi bk.* dopo un giorno.
  find "$BK_BACKUPS/tmp" -mindepth 1 -maxdepth 1 -name 'bk.run.*' -exec rm -rf -- {} + 2>/dev/null || true
  find "$BK_BACKUPS/tmp" -mindepth 1 -maxdepth 1 -name 'bk.*' -mmin +1440 -exec rm -rf -- {} + 2>/dev/null || true
  bk_prune_restore
  BK_RUN_DIR="$(mktemp -d "$BK_BACKUPS/tmp/bk.run.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$BK_RUN_DIR'" EXIT
  _BK_STARTED="$(date -Iseconds)"
  _BK_SITES='[]' _BK_PANEL='null' _BK_PURGED='[]' _BK_PREV_LAST='null' _BK_KNOWN='[]' _BK_LAST_RESTORE='null'
  if [[ -f "$BK_STATE" ]]; then
    _BK_LAST_RESTORE="$(jq -c '.last_restore // null' "$BK_STATE" 2>/dev/null)" || _BK_LAST_RESTORE='null'
    [[ -n "$_BK_LAST_RESTORE" ]] || _BK_LAST_RESTORE='null'
    _BK_PREV_LAST="$(jq -c '.last_run // null' "$BK_STATE" 2>/dev/null)" || _BK_PREV_LAST='null'
    _BK_KNOWN="$(jq -c '(.known // []) | if type == "array" then map(select(type == "string")) else [] end' "$BK_STATE" 2>/dev/null)" || _BK_KNOWN='[]'
  fi
  [[ -n "$_BK_PREV_LAST" ]] || _BK_PREV_LAST='null'
  [[ -n "$_BK_KNOWN" ]] || _BK_KNOWN='[]'
  _bk_progress start

  # Registro: i siti attivi o disattivati, in ordine.
  if [[ -d "$SITES_DIR" ]]; then
    for f in "$SITES_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      d="$(jq -r 'select(.state == "active" or .state == "disabled") | .domain // empty' "$f" 2>/dev/null)" || continue
      if [[ -n "$d" ]] && valid_domain "$d" && [[ "$f" == "$(site_reg_path "$d")" ]]; then doms+=("$d"); fi
    done
  fi

  # Drive raggiungibile? Se no, ogni sito fallisce subito con lo stesso motivo,
  # senza costruire archivi che non si potrebbero caricare.
  if ! _bk_rcq mkdir "gdrive:$folder"; then
    for d in "${doms[@]}"; do
      _bk_add_site "$d" false "Google Drive non risponde: $_BK_ERRMSG"
    done
    _BK_PANEL="$(jq -nc --arg e "Google Drive non risponde: $_BK_ERRMSG" '{ok: false, error: $e, file: null}')"
  else
    drive_ok=1
    for d in "${doms[@]}"; do
      _bk_one_site "$d" "$folder" || true
    done
    _bk_panel "$folder" || true
  fi

  # Esito e avviso prima della pulizia: un guasto lì non deve toglierli.
  alert="$(_bk_alert)"
  last="$(_bk_last_json "$alert")"
  if ((drive_ok)); then
    _bk_state_write "$(jq -nc --arg u "${BK_UNIT:-vps-backup.service}" --arg s "$_BK_STARTED" \
      '{unit: $u, started: $s, step: "purge", domain: null}')" "$last" || log "vps-backup: state.json non scritto"
    _bk_purge_gone "$folder" || log "vps-backup: pulizia delle cartelle di Drive non riuscita"
    last="$(_bk_last_json "$alert")"
  fi
  _bk_state_write null "$last" || { log "vps-backup: state.json non scritto"; rc=1; }
  st="$(jq -c '{ok: true, finished: true, all_ok: .ok}' <<<"$last")"
  log "vps-backup: giro finito ($st)"
  printf '%s\n' "$st"
  if [[ "$(jq -r .ok <<<"$last")" != true ]]; then rc=1; fi
  return "$rc"
}

# --- copie locali, copie su Drive, ripristino (Task 4) ---------------------------

: "${BK_CF_PURGE:=$VPS_OPT/bin/vps-cf-purge}"

# bk_prune_restore — le copie di sicurezza dei ripristini restano 7 giorni.
bk_prune_restore() {
  [[ -d "$BK_BACKUPS/restore" ]] || return 0
  find "$BK_BACKUPS/restore" -maxdepth 1 -type f -name '*.tar.gz' -mmin +10080 -delete 2>/dev/null || true
}

# bk_local_parse NOME — NOME è "cartella/file" dentro backups/{panel,sites,restore}: la
# forma dei nomi è fissa, niente "/" oltre al primo, niente "..". Imposta _BK_LK
# (cartella), _BK_LF (file), _BK_LD (dominio, vuoto per il pannello). 1 se non valido.
_BK_LK="" _BK_LF="" _BK_LD=""
bk_local_parse() {
  local n="${1-}" k f d
  _BK_LK="" _BK_LF="" _BK_LD=""
  [[ "$n" =~ ^(panel|sites|restore)/([A-Za-z0-9][A-Za-z0-9._-]{0,200})$ ]] || return 1
  k="${BASH_REMATCH[1]}"
  f="${BASH_REMATCH[2]}"
  [[ "$f" != *..* ]] || return 1
  # BASH_REMATCH va copiato subito: valid_domain usa a sua volta un'espressione regolare
  case "$k" in
    panel)
      [[ "$f" =~ \.sql\.gz$ ]] || return 1
      ;;
    sites)
      [[ "$f" =~ ^(.+)-[0-9]{8}-[0-9]{4}([0-9]{2})?\.(tar|sql)\.gz$ ]] || return 1
      d="${BASH_REMATCH[1]}"
      valid_domain "$d" || return 1
      _BK_LD="$d"
      ;;
    restore)
      [[ "$f" =~ ^(.+)-[0-9]{8}-[0-9]{4}([0-9]{2})?\.tar\.gz$ ]] || return 1
      d="${BASH_REMATCH[1]}"
      valid_domain "$d" || return 1
      _BK_LD="$d"
      ;;
  esac
  _BK_LK="$k"
  _BK_LF="$f"
}

# bk_local_path NOME — percorso del file locale, solo se è un file regolare e non un
# collegamento (anche la cartella non deve esserlo). Stampa il percorso.
bk_local_path() {
  bk_local_parse "${1-}" || return 1
  local d="$BK_BACKUPS/$_BK_LK" p="$BK_BACKUPS/$_BK_LK/$_BK_LF"
  [[ -d "$d" && ! -L "$d" && -f "$p" && ! -L "$p" ]] || return 1
  printf '%s' "$p"
}

# bk_list_local_json — {ok, items[]} con le copie di backups/{panel,sites,restore}.
# `restorable`: archivio nel formato nuovo (primo membro manifest.json); gli archivi
# vecchi (tar di tutta la cartella + dump a parte) si possono solo scaricare.
# `expires`: data di scadenza (modifica + 30 giorni per sites, + 7 per restore, null
# per il pannello, di cui restano gli ultimi 5).
bk_list_local_json() {
  local k dir p f mt days exp restorable first kind dom sz parts TAB=$'\t' tbl=""
  for k in panel sites restore; do
    dir="$BK_BACKUPS/$k"
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    for p in "$dir"/*; do
      [[ -f "$p" && ! -L "$p" ]] || continue
      f="${p##*/}"
      bk_local_parse "$k/$f" || continue
      mt="$(stat -c %Y "$p")" || continue
      sz="$(stat -c %s "$p")" || continue
      restorable=false
      parts=""
      exp=""
      dom="$_BK_LD"
      case "$k" in
        panel) kind=panel ;;
        sites)
          kind=site
          days=30
          ;;
        restore)
          kind=restore
          days=7
          ;;
      esac
      if [[ "$k" != panel ]]; then
        exp="$(date -d "@$((mt + days * 86400))" +%F)" || exp=""
        if [[ "$f" == *.tar.gz ]]; then
          first="$(tar -tzf "$p" 2>/dev/null | head -n1 || true)"
          if [[ "$first" == manifest.json ]]; then
            restorable=true
            parts="$(bk_manifest "$p" | jq -r '.parts // "all"' 2>/dev/null || true)"
            [[ "$parts" =~ ^(all|db|files)$ ]] || parts=all
          fi
        fi
      fi
      tbl+="$kind$TAB$k/$f$TAB$dom$TAB$mt$TAB$sz$TAB$exp$TAB$restorable$TAB$parts"$'\n'
    done
  done
  printf '%s' "$tbl" | jq -Rnc '
    [inputs | split("\t") | {kind: .[0], name: .[1], domain: (if .[2] == "" then null else .[2] end),
       t: (.[3] | tonumber), size: (.[4] | tonumber),
       expires: (if .[5] == "" then null else .[5] end), restorable: (.[6] == "true"),
       parts: (if (.[7] // "") == "" then null else .[7] end)}]
    | sort_by(-.t, .name)
    | map({kind, name, domain, date: (.t | strflocaltime("%Y-%m-%dT%H:%M:%S")), size, expires, restorable, parts})
    | {ok: true, items: .}'
}

# bk_remote_parse NOME — "dominio/file" o "_pannello/file" con i nomi che crea il giro.
# Imposta _BK_RD (cartella su Drive) e _BK_RF (file). 1 se non valido.
_BK_RD="" _BK_RF=""
bk_remote_parse() {
  local n="${1-}" d f
  _BK_RD="" _BK_RF=""
  [[ "$n" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9._-]+)$ ]] || return 1
  d="${BASH_REMATCH[1]}"
  f="${BASH_REMATCH[2]}"
  if [[ "$d" == _pannello ]]; then
    [[ "$f" =~ $_BK_PANEL_RE ]] || return 1
  else
    valid_domain "$d" || return 1
    [[ "$f" =~ $(_bk_site_re "$d") ]] || return 1
  fi
  _BK_RD="$d"
  _BK_RF="$f"
}

# _bk_remote_init — Drive collegato e comando rclone pronto. Imposta BK_ERR e 1 se no.
_bk_remote_init() {
  if [[ ! -f "$BK_RCLONE_CONF" ]]; then
    BK_ERR="Google Drive non collegato: collegalo dalla pagina Backup"
    return 1
  fi
  read -ra _BK_RC <<<"$BK_RCLONE"
}

# bk_list_remote_json — {ok, sites[{domain, present, copies[{name,date,size}]}], panel[]}
# con i soli file dai nomi che crea il giro (gli altri sono di altri e non si mostrano).
# Una cartella di backup ancora inesistente dà elenchi vuoti.
bk_list_remote_json() {
  local folder dirs d tag present re size name TAB=$'\t' tbl="" line
  _bk_remote_init || return 1
  folder="$(jq -r .folder <<<"$(bk_config_json)")"
  if ! _bk_rcq lsjson --dirs-only "gdrive:$folder"; then
    if ((_BK_RCRC == 3)); then
      printf '{"ok":true,"sites":[],"panel":[]}\n'
      return 0
    fi
    BK_ERR="Google Drive non risponde: $_BK_ERRMSG"
    return 1
  fi
  dirs="$(jq -r '.[] | select(.Name | test("^[A-Za-z0-9_][A-Za-z0-9._-]*$")) | .Name' <<<"$_BK_OUT" 2>/dev/null)" || {
    BK_ERR="risposta di Drive non leggibile"
    return 1
  }
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ "$d" == _pannello ]]; then
      tag=P
      present=false
      re="$_BK_PANEL_RE"
    elif valid_domain "$d"; then
      tag=S
      present=false
      if site_reg_exists "$d"; then present=true; fi
      re="$(_bk_site_re "$d")"
    else
      continue
    fi
    if ! _bk_ls_files "$folder/$d"; then
      BK_ERR="Google Drive non risponde: $_BK_ERRMSG"
      return 1
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      size="${line%%|*}"
      name="${line#*|}"
      [[ "$size" =~ ^[0-9]{1,18}$ && "$name" =~ $re ]] || continue
      tbl+="$tag$TAB$d$TAB$present$TAB$d/$name$TAB$size"$'\n'
    done <<<"$_BK_LST"
  done <<<"$dirs"
  printf '%s' "$tbl" | jq -Rnc '
    def mk: {name: .[3], date: (.[3] | capture("-(?<y>[0-9]{4})(?<m>[0-9]{2})(?<d>[0-9]{2})-(?<h>[0-9]{2})(?<i>[0-9]{2})\\.")
                               | "\(.y)-\(.m)-\(.d)T\(.h):\(.i):00"), size: (.[4] | tonumber)};
    [inputs | split("\t")] as $r
    | {ok: true,
       sites: ([$r[] | select(.[0] == "S")] | group_by(.[1])
               | map({domain: .[0][1], present: (.[0][2] == "true"), copies: (sort_by(.[3]) | reverse | map(mk))})),
       panel: ([$r[] | select(.[0] == "P")] | sort_by(.[3]) | reverse | map(mk))}'
}

# bk_remote_fetch NOME DEST — scarica la copia da Drive in DEST (file nuovo). Prima si
# guarda che esista con la dimensione attesa e che ci sia spazio; dopo, che la
# dimensione torni. BK_ERR dice perché se fallisce.
bk_remote_fetch() {
  local name="${1-}" dest="${2-}" folder size got
  bk_remote_parse "$name" || {
    BK_ERR="nome della copia non valido"
    return 1
  }
  _bk_remote_init || return 1
  folder="$(jq -r .folder <<<"$(bk_config_json)")"
  if ! _bk_ls_files "$folder/$_BK_RD"; then
    if ((_BK_RCRC == 3)); then
      BK_ERR="copia non trovata su Drive: $name"
    else
      BK_ERR="Google Drive non risponde: $_BK_ERRMSG"
    fi
    return 1
  fi
  size="$(awk -F'|' -v n="$_BK_RF" '$2 == n {print $1; exit}' <<<"$_BK_LST")"
  if [[ ! "$size" =~ ^[0-9]{1,18}$ ]]; then
    BK_ERR="copia non trovata su Drive: $name"
    return 1
  fi
  if ! bk_space_ok "$(dirname -- "$dest")" "$size"; then
    BK_ERR="spazio insufficiente per scaricare la copia"
    return 1
  fi
  if ! _bk_rcq copyto "gdrive:$folder/$_BK_RD/$_BK_RF" "$dest"; then
    rm -f -- "$dest"
    BK_ERR="scaricamento da Drive non riuscito: $_BK_ERRMSG"
    return 1
  fi
  got="$(stat -c %s "$dest" 2>/dev/null || echo -1)"
  if [[ "$got" != "$size" ]]; then
    rm -f -- "$dest"
    BK_ERR="la copia scaricata ha dimensione diversa (attesa $size, trovata $got)"
    return 1
  fi
}

# bk_remote_manifest NOME — manifest.json di una copia su Drive (NOME = dominio/file) in
# _BK_MANIFEST, senza scaricarla tutta: il manifest è il primo membro dell'archivio, quindi
# bastano i primi 256 KiB (tar estrae il primo membro anche da un gzip troncato). Serve
# a `vps-site create --from-backup` per configurare il sito prima del lavoro lungo.
# BK_ERR e 1 se non si riesce. Non si fida del contenuto: chi chiama lo controlla.
_BK_MANIFEST=""
bk_remote_manifest() {
  local name="${1-}" folder w
  _BK_MANIFEST=""
  bk_remote_parse "$name" || {
    BK_ERR="nome della copia non valido"
    return 1
  }
  _bk_remote_init || return 1
  folder="$(jq -r .folder <<<"$(bk_config_json)")"
  w="$(bk_tmp_dir)" || {
    BK_ERR="cartella temporanea non disponibile"
    return 1
  }
  if ! _bk_nolock timeout 45 "${_BK_RC[@]}" cat --count 262144 "gdrive:$folder/$_BK_RD/$_BK_RF" >"$w/head" 2>"$w/err" </dev/null; then
    BK_ERR="Google Drive non risponde: $(bk_clean_msg "$(cat "$w/err" 2>/dev/null || true)")"
    rm -rf -- "$w"
    return 1
  fi
  # come per una copia locale: manifest.json deve essere il PRIMO membro, e il manifest
  # (non autenticato) non può superare 64 KiB
  tar -tzf "$w/head" 2>/dev/null | head -n1 >"$w/first" || true
  if [[ "$(cat "$w/first")" == manifest.json ]]; then
    tar -xzOf "$w/head" manifest.json 2>/dev/null | head -c 65537 >"$w/m.json" || true
  fi
  if [[ ! -s "$w/m.json" ]] || (($(stat -c %s "$w/m.json") > 65536)) || ! jq -e 'type == "object"' "$w/m.json" >/dev/null 2>&1; then
    BK_ERR="manifest della copia non leggibile (non è una copia nel formato nuovo?)"
    rm -rf -- "$w"
    return 1
  fi
  _BK_MANIFEST="$(cat "$w/m.json")"
  rm -rf -- "$w"
}

# --- ripristino --------------------------------------------------------------------

# Script eseguiti come utente del sito (sh di Debian, niente bash). L'area di
# estrazione sta in tmp/ del sito, che è del sito: nessun percorso passa da root.

# Controllo dell'area di estrazione dopo tar (seconda linea di difesa, dopo bk_verify):
# argomenti AREA RADICE. Rifiuta file speciali, collegamenti simbolici che (risolti
# con realpath -m dentro l'area) escono dall'area, e file con più collegamenti fisici
# di quelli presenti nell'area (cioè un legame con qualcosa di fuori). Un collegamento
# assoluto vale solo se punta dentro RADICE, e lo si guarda come se la radice fosse
# l'area. Stampa il primo problema, esce con 1.
read -r -d '' BK_SH_WALK <<'EOS' || true
s="$1"; r="$2"
cd "$s" || exit 2
S="$(pwd -P)"
bad="$(find -P . -mindepth 1 ! -type f ! -type d ! -type l -print -quit)"
if [ -n "$bad" ]; then
  printf 'file speciale (dispositivo, fifo o socket): %s\n' "$bad"
  exit 1
fi
find -P . -type l -exec sh -c '
S="$1"; R="$2"; shift 2
for l; do
  t="$(readlink -- "$l")" || exit 1
  case "$t" in
    "$R" | "$R"/*) t="$S${t#"$R"}" ;;
    /*) printf "collegamento assoluto fuori dal sito: %s\n" "$l"; exit 1 ;;
    *) t="$(dirname -- "$l")/$t" ;;
  esac
  x="$(realpath -m -- "$t")" || exit 1
  case "$x" in
    "$S" | "$S"/*) ;;
    *) printf "collegamento che esce dal sito: %s\n" "$l"; exit 1 ;;
  esac
done' sh "$S" "$r" {} + || exit 1
find -P . -type f -links +1 -printf '%i %n\n' | awk '{ c[$1]++; n[$1] = $2 } END { for (i in c) if (c[i] != n[i]) { print "collegamento fisico verso un file fuori dall area di estrazione"; exit 1 } }' || exit 1
exit 0
EOS

# Scambio del contenuto di public/: il vecchio va in una cartella di tmp/ (stesso
# filesystem, quindi solo rinomine), il nuovo ci entra dall'area di estrazione. La
# cartella public/ non si sostituisce: è di root nella radice (che il sito non può
# modificare) e porta permessi e ACL che servono a Nginx. Mai un rm su public/: se un
# passo fallisce le voci si rimettono dove stavano. Dopo la fase 1 public/ è vuota, quindi
# se la fase 2 fallisce tutto ciò che c'è in public/ viene dall'area e ci torna.
# Uscite: 0 fatto; 3 non riuscito ma il vecchio contenuto è tornato; 4 non riuscito e
# qualcosa non è tornato (il vecchio resta nella cartella old, il nuovo nell'area);
# 65/66/1 niente è stato spostato.
read -r -d '' BK_SH_SWAP <<'EOS' || true
s="$1"; old="$2"
{ [ -d "$s/public" ] && [ ! -L "$s/public" ]; } || exit 65
{ [ -d public ] && [ ! -L public ]; } || exit 66
mkdir "$old" || exit 1
back_old() { find "$old" -mindepth 1 -maxdepth 1 -exec mv -t public -- {} + && rmdir "$old"; }
if ! find public -mindepth 1 -maxdepth 1 -exec mv -t "$old" -- {} +; then
  if back_old; then rm -rf -- "$s"; exit 3; fi
  exit 4
fi
if find "$s/public" -mindepth 1 -maxdepth 1 -exec mv -t public -- {} +; then
  rm -rf -- "$s"
  # Nginx (www-data) legge public/ grazie alle ACL: i file arrivati dall'archivio non
  # le hanno, e uno a 640 o 600 darebbe 403. Come per i file creati dal sito.
  setfacl -R -m u:www-data:rX -m d:u:www-data:rX public >/dev/null 2>&1 || true
  exit 0
fi
if find public -mindepth 1 -maxdepth 1 -exec mv -t "$s/public" -- {} + && back_old; then
  rm -rf -- "$s"
  exit 3
fi
exit 4
EOS

# Rimette il contenuto di prima (dopo uno scambio riuscito ma un passo successivo fallito).
# Il contenuto nuovo non si cancella finché il vecchio non è tornato.
read -r -d '' BK_SH_UNDO <<'EOS' || true
old="$1"; nuovo="$old.new"
mkdir "$nuovo" || exit 1
find public -mindepth 1 -maxdepth 1 -exec mv -t "$nuovo" -- {} + || exit 1
find "$old" -mindepth 1 -maxdepth 1 -exec mv -t public -- {} + || exit 1
rmdir "$old" || exit 1
rm -rf -- "$nuovo"
EOS

# _bk_walk_staging SLUG RADICE AREA — esegue BK_SH_WALK come utente del sito. 0 se
# l'area è pulita; altrimenti stampa il motivo, lo mette in BK_ERR e restituisce 1.
_bk_walk_staging() {
  local slug="$1" root="$2" stage="$3" out rc=0
  out="$(fm_as_site "$slug" "$root" timeout 900 sh -c "$BK_SH_WALK" sh "$stage" "$root" 2>/dev/null)" || rc=$?
  if ((rc != 0)); then
    out="$(printf '%s' "$out" | head -n1 | LC_ALL=C tr -c '[:print:]' '?' | head -c 300)"
    [[ -n "$out" ]] || out="controllo dei file estratti non riuscito (codice $rc)"
    BK_ERR="contenuto della copia non sicuro: $out"
    printf '%s\n' "$out"
    return 1
  fi
}

_BK_STAGE="" _BK_OLD="" _BK_SAFETY="" _BK_R_DOM="" _BK_R_NOTE="" _BK_R_BDATE=""

# bk_space_free_ok DIR BYTES — 0 se su DIR restano più di BYTES + 256 MB.
bk_space_free_ok() {
  local free
  [[ "${2-}" =~ ^[0-9]{1,16}$ ]] || return 1
  free="$(df -PB1 "${1-}" 2>/dev/null | awk 'NR == 2 {print $4}')"
  [[ "$free" =~ ^[0-9]{1,18}$ ]] || return 1
  ((10#$free > 10#$2 + 268435456))
}

# bk_prune_site_tmp SLUG RADICE — avanzi di ripristini interrotti (kill, riavvio) in tmp/
# del sito, oltre un giorno: contenuto di prima, aree di estrazione, file delle credenziali.
# Come utente del sito, mai da root.
bk_prune_site_tmp() {
  [[ -d "$2/tmp" ]] || return 0
  fm_as_site "$1" "$2" sh -c 'find tmp -maxdepth 1 \( -name ".vpsbackup-old.*" -o -name ".vpsbackup-x.*" -o -name ".vpsbackup-c.*" \) -mmin +1440 -exec rm -rf -- {} + 2>/dev/null; exit 0' sh >/dev/null 2>&1 || true
}

# _bk_nolock_fn FUNZIONE ARG... — come _bk_nolock, ma per una funzione di shell.
_bk_nolock_fn() {
  (
    if [[ -n "${BK_GLOBAL_FD:-}" ]]; then exec {BK_GLOBAL_FD}>&-; fi
    if [[ -n "${BK_SITE_LOCK_FD:-}" ]]; then exec {BK_SITE_LOCK_FD}>&-; fi
    "$@"
  )
}

# _bk_mon_send TESTO — mon_send senza i lock nei figli (curl). MON_SEND_ERR torna al
# chiamante attraverso un file, perché la funzione gira in una subshell.
_bk_mon_send_inner() {
  local rc=0
  mon_send "$1" && rc=0 || rc=$?
  printf '%s' "${MON_SEND_ERR:-}" >"$BK_RUN_DIR/send.err"
  return "$rc"
}
_bk_mon_send() {
  local rc=0
  : >"$BK_RUN_DIR/send.err"
  _bk_nolock_fn _bk_mon_send_inner "$1" || rc=$?
  MON_SEND_ERR="$(cat "$BK_RUN_DIR/send.err" 2>/dev/null || true)"
  return "$rc"
}

# _bk_stage_files SLUG RADICE FILES.TAR.GZ — estrae public/ come utente del sito in una
# cartella vuota nuova di tmp/ (mai in public/) e la controlla. Imposta _BK_STAGE
# (percorso relativo alla radice). BK_ERR se fallisce; l'area, se creata, resta
# in _BK_STAGE e la toglie chi chiama.
_bk_stage_files() {
  local slug="$1" root="$2" files="$3" first s total
  _BK_STAGE=""
  first="$(tar -tzf "$files" 2>/dev/null | head -n1 || true)"
  if [[ "$first" != public && "$first" != public/ ]]; then
    BK_ERR="la copia non contiene public/ (non è una copia dei file)"
    return 1
  fi
  # peso non compresso dall'elenco di tar (lo stesso che legge bk_verify), più un margine
  total="$(LC_ALL=C.UTF-8 tar -P --numeric-owner --quoting-style=c -tvzf "$files" 2>/dev/null | awk '{ s += $3 } END { print s + 0 }')"
  if ! bk_space_free_ok "$root/tmp" "$total"; then
    BK_ERR="spazio insufficiente per estrarre la copia"
    return 1
  fi
  s="$(fm_as_site "$slug" "$root" mktemp -d tmp/.vpsbackup-x.XXXXXX 2>/dev/null)" || s=""
  if [[ ! "$s" =~ ^tmp/\.vpsbackup-x\.[A-Za-z0-9]{6}$ ]]; then
    BK_ERR="area di estrazione non creata (tmp/ del sito non scrivibile)"
    return 1
  fi
  _BK_STAGE="$s"
  # umask del sito (fm_as_site), proprietario l'utente del sito, permessi dell'archivio
  # limitati dalla umask (niente setuid): nessuna fiducia nell'archivio.
  if ! fm_as_site "$slug" "$root" env LC_ALL=C.UTF-8 timeout 7200 tar -xzf - -C "$s" --no-same-owner --no-same-permissions -- public \
    <"$files" 2>"$BK_RUN_DIR/untar.err"; then
    _bk_log_file "$BK_RUN_DIR/untar.err" "estrazione per $slug"
    BK_ERR="estrazione dei file non riuscita"
    return 1
  fi
  _bk_walk_staging "$slug" "$root" "$s" >/dev/null || return 1
}

# _bk_stage_clean SLUG RADICE — toglie l'area di estrazione, se c'è.
_bk_stage_clean() {
  [[ "$_BK_STAGE" =~ ^tmp/\.vpsbackup-x\.[A-Za-z0-9]{6}$ ]] || return 0
  fm_as_site "$1" "$2" rm -rf -- "$_BK_STAGE" >/dev/null 2>&1 || log "ATTENZIONE: area di estrazione $2/$_BK_STAGE non rimossa"
  _BK_STAGE=""
}

# _bk_swap_files SLUG RADICE — scambia il contenuto di public/ con quello dell'area.
# Imposta _BK_OLD (dove sta il contenuto di prima) se riesce.
_bk_swap_files() {
  local slug="$1" root="$2" old rc=0
  old="tmp/.vpsbackup-old.$(date +%Y%m%d%H%M%S)"
  fm_as_site "$slug" "$root" timeout 3600 sh -c "$BK_SH_SWAP" sh "$_BK_STAGE" "$old" >"$BK_RUN_DIR/swap.out" 2>&1 || rc=$?
  case "$rc" in
    0)
      _BK_OLD="$old"
      _BK_STAGE=""
      ;;
    3)
      _BK_STAGE=""
      BK_ERR="scambio dei file non riuscito: il contenuto di prima è tornato al suo posto"
      return 1
      ;;
    4)
      # l'area di estrazione viene tolta subito dopo: non si indica come luogo dei file
      BK_ERR="scambio dei file non riuscito e qualcosa NON è tornato al suo posto: il contenuto di prima è in $root/$old e in public/ può esserci una parte dei file della copia; usa la copia di sicurezza ${_BK_SAFETY##*/}"
      _BK_R_NOTE=hard
      return 1
      ;;
    *)
      BK_ERR="scambio dei file non riuscito (codice $rc), public/ non è stata toccata"
      return 1
      ;;
  esac
}

# _bk_files_commit SLUG RADICE — ripristino riuscito: il contenuto di prima si toglie.
_bk_files_commit() {
  [[ "$_BK_OLD" =~ ^tmp/\.vpsbackup-old\.[0-9]{14}$ ]] || return 0
  fm_as_site "$1" "$2" rm -rf -- "$_BK_OLD" >/dev/null 2>&1 || log "ATTENZIONE: contenuto di prima $2/$_BK_OLD non rimosso"
  _BK_OLD=""
}

# _bk_files_undo SLUG RADICE — un passo dopo lo scambio è fallito: public/ torna com'era.
_bk_files_undo() {
  [[ "$_BK_OLD" =~ ^tmp/\.vpsbackup-old\.[0-9]{14}$ ]] || return 0
  if fm_as_site "$1" "$2" timeout 3600 sh -c "$BK_SH_UNDO" sh "$_BK_OLD" >/dev/null 2>&1; then
    _BK_OLD=""
    return 0
  fi
  BK_ERR="$BK_ERR; i file di prima NON sono tornati tutti in public/: sono in $2/$_BK_OLD (una parte dei file nuovi può essere ancora in public/, il resto in $2/$_BK_OLD.new); usa la copia di sicurezza ${_BK_SAFETY##*/}"
  _BK_R_NOTE=hard
  return 1
}

# --- database ---------------------------------------------------------------------
#
# Scelta: il dump non si carica con root. L'archivio può venire da Drive e il suo
# SQL non è autenticato (il checksum sta nello stesso archivio): come root potrebbe
# creare utenti o toccare altri database. Si carica con l'utente del sito, che può
# lavorare solo sul proprio database (e, per il tempo della prova, su
# <slug>__ripristino, di cui riceve un permesso che poi si toglie).
# Prima una prova in <slug>__ripristino, senza toccare il sito: un dump rotto o troncato
# si scopre lì. Poi il database del sito si elimina e si ricrea e vi si carica il dump
# (invece di RENAME TABLE dal temporaneo: così viste, routine, eventi e trigger,
# che RENAME TABLE non sposta tra database, restano). Se il caricamento vero fallisce
# si ricarica la copia di sicurezza. I permessi dell'utente non cambiano.

# _bk_sql SQL — istruzioni come root (socket) da stdin; l'errore, ripulito, in _BK_SQLERR.
_bk_sql() {
  local rc=0
  _bk_nolock mariadb <<<"$1" >>"$VPS_LOG" 2>"$BK_RUN_DIR/sql.err" || rc=$?
  _BK_SQLERR=""
  if ((rc != 0)); then _BK_SQLERR="$(bk_clean_msg "$(cat "$BK_RUN_DIR/sql.err" 2>/dev/null || true)")"; fi
  return "$rc"
}

# _bk_db_pw RADICE — la password del sito da db.env (di root nella radice); stampa e
# restituisce 0 solo se si può scrivere tra virgolette in un file di opzioni.
_bk_db_pw() {
  local pw
  pw="$(env_get "$1/db.env" DB_PASS)"
  [[ -n "$pw" && "$pw" != *\"* && "$pw" != *\\* && "$pw" != *$'\n'* ]] || return 1
  printf '%s' "$pw"
}

# Il client SQL che legge il dump non è mai root: un dump può contenere comandi del
# client (\! comando, system, tee, source, LOAD DATA LOCAL INFILE) e chi scrive su
# Drive potrebbe farli eseguire. Gira come utente del sito (fm_as_site, env -i), con
# --sandbox --binary-mode --local-infile=0, e il file delle credenziali lo crea lo
# stesso utente del sito in tmp/ (la password arriva da stdin, mai dagli argomenti) e
# lo toglie alla fine: root non scrive mai in cartelle del sito.

_BK_CNF=""
# _bk_cnf_make SLUG RADICE UTENTE PASSWORD — imposta _BK_CNF (percorso relativo alla radice).
_bk_cnf_make() {
  local f
  _BK_CNF=""
  f="$(printf '[client]\nuser=%s\npassword="%s"\n' "$3" "$4" \
    | fm_as_site "$1" "$2" sh -c 'f="$(mktemp tmp/.vpsbackup-c.XXXXXX)" || exit 1; cat >"$f" || exit 1; printf "%s" "$f"' sh 2>/dev/null)" || return 1
  [[ "$f" =~ ^tmp/\.vpsbackup-c\.[A-Za-z0-9]{6}$ ]] || return 1
  _BK_CNF="$f"
}

_bk_cnf_rm() {
  [[ "$_BK_CNF" =~ ^tmp/\.vpsbackup-c\.[A-Za-z0-9]{6}$ ]] || return 0
  fm_as_site "$1" "$2" rm -f -- "$_BK_CNF" >/dev/null 2>&1 || log "ATTENZIONE: file delle credenziali $2/$_BK_CNF non rimosso"
  _BK_CNF=""
}

_BK_LOADERR=""
# _bk_db_load DATABASE DUMP.GZ SLUG RADICE CNF — carica il dump con il client SQL
# sandbox, come utente del sito. gzip, sed e client in una pipeline con pipefail: un .gz
# troncato è un errore anche se SQL già eseguito. sed toglie DEFINER=`utente`@`host`
# dalle sole righe di definizione di oggetti (iniziano con /*!NNNNN o CREATE/ALTER; le
# righe INSERT non si toccano): un trigger o una vista creati un tempo da root non si
# caricherebbero con l'utente del sito (serve il privilegio SET USER), e così diventano suoi.
_bk_db_load() {
  local rc=0
  (
    set -o pipefail
    _bk_nolock gzip -dc "$2" \
      | _bk_nolock sed -E '/^(\/\*![0-9]+ |CREATE |ALTER )/ s/DEFINER=`[^`]*`@`[^`]*`//g' \
      | fm_as_site "$3" "$4" timeout 7200 mariadb --defaults-file="$5" --sandbox --binary-mode --local-infile=0 "$1"
  ) >/dev/null 2>"$BK_RUN_DIR/load.err" || rc=$?
  _BK_LOADERR=""
  if ((rc != 0)); then _BK_LOADERR="$(bk_clean_msg "$(cat "$BK_RUN_DIR/load.err" 2>/dev/null || true)")"; fi
  return "$rc"
}

# _bk_db_recreate SLUG — database del sito vuoto (i permessi non si toccano).
_bk_db_recreate() {
  _bk_sql "DROP DATABASE IF EXISTS \`$1\`;
CREATE DATABASE \`$1\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

# _bk_db_tmp_clean SLUG — toglie utente e database della prova; si può ripetere (anche
# all'inizio, per gli avanzi di una prova uccisa).
_bk_db_tmp_clean() {
  _bk_sql "DROP USER IF EXISTS '${1}_r'@'localhost';
DROP DATABASE IF EXISTS \`${1}__ripristino\`;" || log "ATTENZIONE: utente o database temporaneo della prova di $1 non rimossi ($_BK_SQLERR)"
}

# _bk_db_dryrun SLUG RADICE DUMP.GZ — prova di caricamento senza toccare il sito: in
# <slug>__ripristino con un utente usa-e-getta <slug>_r (password casuale) che ha
# permessi solo su quel database. Un dump che nomina il database del sito (USE ...) o
# prova altro non ottiene nulla e la prova fallisce.
_bk_db_dryrun() {
  local slug="$1" root="$2" dump="$3" u="${1}_r" t="${1}__ripristino" esc pw rc=0
  if ! sql_ident_ok "$t" || ! sql_ident_ok "$u" || ! _bk_db_pw "$root" >/dev/null; then
    BK_ERR="password del database non leggibile (db.env)"
    return 1
  fi
  esc="${t//_/\\_}"
  _bk_db_tmp_clean "$slug"
  pw="$(rand_secret 32)"
  if ! _bk_sql "CREATE DATABASE \`$t\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$u'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON \`$esc\`.* TO '$u'@'localhost';"; then
    BK_ERR="database temporaneo non creato: $_BK_SQLERR"
    _bk_db_tmp_clean "$slug"
    return 1
  fi
  if ! _bk_cnf_make "$slug" "$root" "$u" "$pw"; then
    BK_ERR="file delle credenziali della prova non creato (tmp/ del sito non scrivibile)"
    _bk_db_tmp_clean "$slug"
    return 1
  fi
  _bk_db_load "$t" "$dump" "$slug" "$root" "$_BK_CNF" || rc=$?
  _bk_cnf_rm "$slug" "$root"
  _bk_db_tmp_clean "$slug"
  if ((rc != 0)); then
    BK_ERR="il dump del database non si carica: $_BK_LOADERR"
    return 1
  fi
}

# _bk_db_swap SLUG RADICE DUMP.GZ SICUREZZA — il database del sito diventa il dump. Se
# fallisce si ricarica il dump della copia di sicurezza SICUREZZA (archivio).
_bk_db_swap() {
  local slug="$1" root="$2" dump="$3" safety="$4" msg pw ok=0
  pw="$(_bk_db_pw "$root")" || {
    BK_ERR="password del database non leggibile (db.env)"
    return 1
  }
  if ! _bk_cnf_make "$slug" "$root" "$slug" "$pw"; then
    BK_ERR="file delle credenziali non creato (tmp/ del sito non scrivibile)"
    return 1
  fi
  if _bk_db_recreate "$slug" && _bk_db_load "$slug" "$dump" "$slug" "$root" "$_BK_CNF"; then
    _bk_cnf_rm "$slug" "$root"
    return 0
  fi
  msg="${_BK_LOADERR:-$_BK_SQLERR}"
  mkdir -p "$BK_RUN_DIR/s"
  if tar -xzf "$safety" -C "$BK_RUN_DIR/s" --no-same-owner --no-same-permissions db.sql.gz 2>/dev/null \
    && _bk_db_recreate "$slug" && _bk_db_load "$slug" "$BK_RUN_DIR/s/db.sql.gz" "$slug" "$root" "$_BK_CNF"; then
    ok=1
  fi
  _bk_cnf_rm "$slug" "$root"
  if ((ok)); then
    BK_ERR="caricamento del database non riuscito ($msg): il database è tornato com'era"
    return 1
  fi
  BK_ERR="caricamento del database non riuscito ($msg) e la copia di sicurezza non si è ricaricata: il database potrebbe essere incompleto, la copia è ${safety##*/}"
  _BK_R_NOTE=hard
  return 1
}

# --- cache e avviso -----------------------------------------------------------------

# _bk_flush_cache DOMINIO SLUG — chiavi Redis del sito (se ha l'utente ACL) e zona
# Cloudflare (se attivo). Un errore si registra e basta: il ripristino è fatto.
_bk_flush_cache() {
  local d="$1" slug="$2" zone
  if grep -q "^user $slug " "$REDIS_ACL_FILE" 2>/dev/null; then
    _bk_nolock_fn site_redis_purge "$d" >/dev/null 2>&1 || log "ATTENZIONE: cache Redis di $d non svuotata"
  fi
  zone="$(site_reg_get "$d" '.zone // ""' 2>/dev/null || true)"
  if [[ -n "$zone" && "$(jq -r '.cloudflare.enabled // false' "$(manifest_path)" 2>/dev/null || true)" == true && -x "$BK_CF_PURGE" ]]; then
    _bk_nolock "$BK_CF_PURGE" "$zone" --all >>"$VPS_LOG" 2>&1 || log "ATTENZIONE: cache Cloudflare di $zone non svuotata"
  fi
}

# _bk_send TESTO — manda il messaggio e stampa l'esito per last_restore.alert.
_bk_send() {
  local rc=0
  _bk_mon_send "$1" || rc=$?
  if ((rc == 0)); then
    printf '"sent"'
  elif [[ "${MON_SEND_ERR:-}" == "Telegram non configurato" ]]; then
    printf '"not_configured"'
  else
    jq -nc --arg e "${MON_SEND_ERR:-errore sconosciuto}" '"failed: " + $e'
  fi
}

# _bk_rprogress PASSO — il pannello legge job.op, job.step e job.domain.
_bk_rprogress() {
  local job
  job="$(jq -nc --arg u "${BK_UNIT:-vps-backup-restore}" --arg s "$_BK_STARTED" --arg st "$1" --arg d "$_BK_R_DOM" \
    --arg sf "${_BK_SAFETY##*/}" \
    '{unit: $u, op: "restore", started: $s, step: $st, domain: $d, safety: (if $sf == "" then null else $sf end)}')"
  _bk_state_write "$job" "$_BK_PREV_LAST" || log "vps-backup: state.json non scritto"
}

# _bk_restore_do SRC DOMINIO NOME MODO SLUG RADICE — i passi. Prima tutto ciò che non
# tocca il sito (scarico, controlli, estrazione nell'area, prova del dump), poi la
# copia di sicurezza, poi gli scambi. Un archivio rifiutato prima non lascia quindi
# nessuna copia di sicurezza. Imposta BK_ERR; 0 se riuscito.
_bk_restore_do() {
  local src="$1" d="$2" name="$3" mode="$4" slug="$5" root="$6"
  local w="$BK_RUN_DIR" arc mdom sitedb hasdb parts sz files_done=0 mparts
  BK_ERR=""
  _BK_R_NOTE=""
  _BK_SAFETY=""
  _BK_STAGE=""
  _BK_OLD=""
  _BK_R_BDATE=""

  # 1. la copia
  if [[ "$src" == local ]]; then
    if ! bk_local_parse "$name" || [[ "$_BK_LK" == panel || "$_BK_LF" != *.tar.gz ]]; then
      BK_ERR="nome della copia non valido"
      return 1
    fi
    [[ "$_BK_LD" == "$d" ]] || {
      BK_ERR="la copia è di $_BK_LD, non di $d"
      return 1
    }
    arc="$(bk_local_path "$name")" || {
      BK_ERR="copia non trovata"
      return 1
    }
  else
    _bk_rprogress download
    if ! bk_remote_parse "$name" || [[ "$_BK_RD" != "$d" ]]; then
      BK_ERR="nome della copia non valido per $d"
      return 1
    fi
    arc="$w/dl.tar.gz"
    bk_remote_fetch "$name" "$arc" || return 1
  fi

  # 2. controllo dell'archivio (checksum, nomi, collegamenti) e del dominio
  _bk_rprogress verify
  bk_verify "$arc" || return 1
  mkdir -p "$w/x"
  tar -xzf "$arc" -C "$w/x" --no-same-owner --no-same-permissions manifest.json files.tar.gz 2>/dev/null || {
    BK_ERR="archivio non leggibile"
    return 1
  }
  mdom="$(jq -r '.domain // ""' "$w/x/manifest.json")"
  if [[ "$mdom" != "$d" ]]; then
    BK_ERR="la copia è del sito ${mdom:-sconosciuto}, non di $d"
    return 1
  fi
  _BK_R_BDATE="$(jq -r '.date // ""' "$w/x/manifest.json")"
  hasdb=false
  if [[ -n "$(jq -r '.sha256.db // ""' "$w/x/manifest.json")" ]]; then
    hasdb=true
    tar -xzf "$arc" -C "$w/x" --no-same-owner --no-same-permissions db.sql.gz 2>/dev/null || {
      BK_ERR="database della copia non leggibile"
      return 1
    }
  fi
  # Una copia parziale (la copia di sicurezza di un ripristino 'db' o 'files') contiene
  # solo una parte: le altre modalità si rifiutano prima di toccare qualsiasi cosa.
  mparts="$(jq -r '.parts // "all"' "$w/x/manifest.json")"
  case "$mparts" in
    all) ;;
    db)
      if [[ "$mode" != db ]]; then
        BK_ERR="la copia contiene solo il database (copia parziale): si può ripristinare solo il database"
        return 1
      fi
      ;;
    files)
      if [[ "$mode" != files ]]; then
        BK_ERR="la copia contiene solo i file (copia parziale): si possono ripristinare solo i file"
        return 1
      fi
      ;;
    *)
      BK_ERR="copia con contenuto non riconosciuto nel manifest"
      return 1
      ;;
  esac

  sitedb="$(site_reg_get "$d" .db)"
  case "$mode" in
    db)
      if [[ "$hasdb" != true ]]; then
        BK_ERR="la copia non contiene il database"
        return 1
      fi
      if [[ "$sitedb" != true ]]; then
        BK_ERR="il sito non ha un database"
        return 1
      fi
      parts=db
      ;;
    files) parts=files ;;
    all)
      if [[ "$hasdb" != "$([[ "$sitedb" == true ]] && echo true || echo false)" ]]; then
        BK_ERR="la copia e il sito non coincidono sul database: ripristina solo i file"
        return 1
      fi
      parts=all
      ;;
  esac

  # 3. prove senza toccare il sito: file nell'area di estrazione, dump nel temporaneo
  if [[ "$mode" != db ]]; then
    _bk_rprogress extract
    if ! _bk_stage_files "$slug" "$root" "$w/x/files.tar.gz"; then
      _bk_stage_clean "$slug" "$root"
      return 1
    fi
  fi
  if [[ "$mode" != files ]]; then
    _bk_rprogress dryrun
    if ! _bk_db_dryrun "$slug" "$root" "$w/x/db.sql.gz"; then
      _bk_stage_clean "$slug" "$root"
      return 1
    fi
  fi

  # 4. copia di sicurezza di ciò che si sta per sovrascrivere. Il nome va nel job prima
  # di cominciare: se il processo muore, il pannello può dire dov'è.
  _BK_SAFETY="$BK_BACKUPS/restore/$d-$(date +%Y%m%d-%H%M%S).tar.gz"
  _bk_rprogress safety
  if ! sz="$(_bk_site_size "$d" "$parts")"; then
    _bk_stage_clean "$slug" "$root"
    BK_ERR="dimensione del sito non leggibile"
    return 1
  fi
  if ! bk_space_ok "$BK_BACKUPS/tmp" "$sz"; then
    _bk_stage_clean "$slug" "$root"
    BK_ERR="spazio insufficiente per la copia di sicurezza"
    return 1
  fi
  install -d -m 700 "$BK_BACKUPS/restore" || {
    _bk_stage_clean "$slug" "$root"
    BK_ERR="cartella delle copie di sicurezza non disponibile"
    return 1
  }
  if ! bk_archive "$d" "$_BK_SAFETY" "$parts"; then
    BK_ERR="copia di sicurezza non riuscita: ${BK_ERR:-errore}"
    _BK_SAFETY=""
    _bk_stage_clean "$slug" "$root"
    return 1
  fi

  # 5. gli scambi
  if [[ "$mode" != db ]]; then
    _bk_rprogress files
    if ! _bk_swap_files "$slug" "$root"; then
      _bk_stage_clean "$slug" "$root"
      return 1
    fi
    files_done=1
  fi
  if [[ "$mode" != files ]]; then
    _bk_rprogress database
    if ! _bk_db_swap "$slug" "$root" "$w/x/db.sql.gz" "$_BK_SAFETY"; then
      # tutto o niente: anche i file tornano come prima
      if ((files_done)); then _bk_files_undo "$slug" "$root" || true; fi
      return 1
    fi
  fi
  _bk_files_commit "$slug" "$root"
  # Un WordPress ricreato da una copia il cui ripristino era fallito non ha il suo cron:
  # un ripristino riuscito di file lo mette.
  if [[ "$mode" != db && "$(site_reg_get "$d" .type)" == wordpress && ! -e "$(site_wp_cron_file "$d")" ]]; then
    (site_wp_cron_add "$d") || log "ATTENZIONE: cron di WordPress di $d non installato"
  fi

  # 6. cache (solo registro in caso d'errore)
  _bk_rprogress cache
  _bk_flush_cache "$d" "$slug"
}

# bk_restore_run SRC DOMINIO NOME MODO — il ripristino (comando interno _restore, in
# un'unità systemd). SRC è local (NOME = cartella/file) o remote (NOME = dominio/file).
# Prende il lock globale e quello del sito per tutto il tempo, scrive il lavoro in
# state.json, manda sempre un messaggio Telegram. Stampa il riepilogo JSON; 0 se
# riuscito, 1 altrimenti (anche se non è potuto partire).
bk_restore_run() {
  local src="${1-}" d="${2-}" name="${3-}" mode="${4-}" info slug root lrc=0 ok=true label text alert fin bdate extra
  _BK_R_DOM="$d"
  if [[ "$src" != local && "$src" != remote ]] || [[ ! "$mode" =~ ^(all|db|files)$ ]]; then
    printf '{"ok":false,"error":"argomenti non validi"}\n'
    return 1
  fi
  # Un sito ricreato da una copia (vps-site create --from-backup) è ancora "creating"
  # quando parte il ripristino, che è l'ultimo passo della sua creazione.
  extra=""
  if [[ "$(site_reg_get "$d" '.from_backup != null' 2>/dev/null || true)" == true ]]; then extra=creating; fi
  info="$(fm_site_check "$d" "$extra" 2>&1)" || {
    jq -nc --arg e "$info" '{ok: false, error: $e}'
    return 1
  }
  slug="${info%% *}"
  root="${info#* }"
  # Dentro la creazione di un sito da copia (vps-site) si aspetta che un giro finisca,
  # invece di far fallire il ripristino subito (BK_LOCK_WAIT: secondi, solo da lì).
  if ! bk_lock_global "${BK_LOCK_WAIT:-0}"; then
    printf '{"ok":false,"error":"backup in corso"}\n'
    return 1
  fi
  bk_site_lock "$slug" || lrc=$?
  if ((lrc == 1)); then
    printf '{"ok":false,"error":"ripristino in corso su questo sito"}\n'
    return 1
  elif ((lrc != 0)); then
    printf '{"ok":false,"error":"registro del sito non valido"}\n'
    return 1
  fi
  install -d -m 700 "$BK_BACKUPS" "$BK_BACKUPS/tmp"
  BK_RUN_DIR="$(mktemp -d "$BK_BACKUPS/tmp/bk.restore.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$BK_RUN_DIR'" EXIT
  _BK_STARTED="$(date -Iseconds)"
  _BK_PREV_LAST='null' _BK_KNOWN='[]' _BK_LAST_RESTORE='null'
  if [[ -f "$BK_STATE" ]]; then
    _BK_PREV_LAST="$(jq -c '.last_run // null' "$BK_STATE" 2>/dev/null)" || _BK_PREV_LAST='null'
    _BK_KNOWN="$(jq -c '(.known // []) | if type == "array" then map(select(type == "string")) else [] end' "$BK_STATE" 2>/dev/null)" || _BK_KNOWN='[]'
    _BK_LAST_RESTORE="$(jq -c '.last_restore // null' "$BK_STATE" 2>/dev/null)" || _BK_LAST_RESTORE='null'
  fi
  [[ -n "$_BK_PREV_LAST" ]] || _BK_PREV_LAST='null'
  [[ -n "$_BK_KNOWN" ]] || _BK_KNOWN='[]'
  [[ -n "$_BK_LAST_RESTORE" ]] || _BK_LAST_RESTORE='null'
  _bk_rprogress start
  bk_prune_site_tmp "$slug" "$root"
  # avanzi di una prova uccisa a metà (utente e database temporanei): via anche se
  # questo ripristino non toccherà il database
  if [[ "$(site_reg_get "$d" .db 2>/dev/null || true)" == true ]]; then _bk_db_tmp_clean "$slug"; fi
  log "vps-backup: ripristino di $d ($mode) da $src ${name//[^[:print:]]/?}"

  _bk_restore_do "$src" "$d" "$name" "$mode" "$slug" "$root" || ok=false
  # area di estrazione o contenuto di prima rimasti: se il ripristino è fallito non
  # deve restare nulla di ciò che questo processo ha creato (tranne, se serve, il
  # contenuto di prima che non è tornato: lo dice BK_ERR).
  if [[ "$ok" == false ]]; then _bk_stage_clean "$slug" "$root"; fi

  case "$mode" in
    all) label="tutto" ;;
    db) label="database" ;;
    *) label="file" ;;
  esac
  bdate=""
  if [[ -n "$_BK_R_BDATE" ]]; then bdate="$(date -d "$_BK_R_BDATE" '+%d/%m %H:%M' 2>/dev/null || true)"; fi
  if [[ "$ok" == true ]]; then
    text="♻️ $(hostname): $d ripristinato al ${bdate:-data sconosciuta}: $label"
  else
    text="♻️ $(hostname): ripristino di $d NON riuscito ($label): ${BK_ERR:-errore}"
    if [[ "$_BK_R_NOTE" == hard ]]; then
      text+=$'\n'"ATTENZIONE: il sito non è tornato del tutto com'era, servono mani: vedi il messaggio sopra."
    else
      text+=$'\n'"Il sito è com'era prima."
    fi
  fi
  alert="$(_bk_send "$text")"
  fin="$(date -Iseconds)"
  _BK_LAST_RESTORE="$(jq -nc --arg d "$d" --arg m "$mode" --arg s "$src" --arg n "$name" --arg st "$_BK_STARTED" --arg f "$fin" \
    --argjson ok "$ok" --arg e "$([[ "$ok" == true ]] && echo "" || echo "${BK_ERR:-errore}")" \
    --arg sf "$([[ -n "$_BK_SAFETY" && -f "$_BK_SAFETY" ]] && basename -- "$_BK_SAFETY" || echo "")" \
    --arg bd "$_BK_R_BDATE" --argjson al "$alert" \
    '{domain: $d, mode: $m, source: $s, name: $n, started: $st, finished: $f, ok: $ok,
      error: (if $e == "" then null else $e end), safety: (if $sf == "" then null else $sf end),
      backup_date: (if $bd == "" then null else $bd end), alert: $al}')"
  _bk_state_write null "$_BK_PREV_LAST" || log "vps-backup: state.json non scritto"
  log "vps-backup: ripristino di $d finito (ok=$ok)"
  jq -nc --argjson ok "$ok" '{ok: true, finished: true, restore_ok: $ok}'
  [[ "$ok" == true ]]
}
