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
bk_manifest() {
  tar -xzOf "${1-}" manifest.json 2>/dev/null
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

# bk_archive DOMINIO OUT — scrive l'archivio del sito in OUT. Tutto si costruisce in
# una cartella temporanea e si sposta in OUT solo a lavoro finito: se qualcosa
# fallisce non resta nulla di ciò che questa chiamata ha creato (un OUT già esistente
# non si tocca) e BK_ERR dice perché. Uscita 0/1.
bk_archive() {
  local d="${1-}" out="${2-}" w rc=0 existed=0
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
  (umask 077 && _bk_archive_in "$d" "$out" "$w") || rc=$?
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
  local d="$1" out="$2" w="$3" info slug root rc=0 type login hasdb www first
  info="$(fm_site_check "$d" 2>&1)" || {
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
  if [[ -d "$root/public" ]]; then
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
  if [[ -L "$root/wp-config.php" ]]; then
    echo "wp-config.php è un collegamento: sito non archiviato" >"$w/err"
    return 1
  fi
  if [[ -f "$root/wp-config.php" ]]; then
    LC_ALL=C.UTF-8 tar --append --file="$w/files.tar" -C "$root" wp-config.php 2>"$w/tar2.err" || {
      _bk_log_file "$w/tar2.err" "wp-config.php di $d"
      echo "wp-config.php non aggiunto all'archivio" >"$w/err"
      return 1
    }
  fi
  gzip -n "$w/files.tar" || {
    echo "compressione dei file non riuscita" >"$w/err"
    return 1
  }

  local dbsha=""
  if [[ "$hasdb" == true ]]; then
    # dump su file, poi gzip: se il dump fallisce lo si sa dal suo codice di uscita
    mariadb-dump --single-transaction --routines --events "$slug" >"$w/db.sql" 2>"$w/dump.err" || {
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
    --arg v "$VPS_INSTALLER_VERSION" \
    --arg fsha "$(sha256sum "$w/files.tar.gz" | cut -d' ' -f1)" --arg dsha "$dbsha" '
    {domain: $d, type: $t, www: ($www == "true"), db: ($db == "true"), slug: $slug,
     login_path: (if $login == "" then null else $login end), date: $at,
     installer_version: $v,
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
  jq -c 'if type == "object" and (.used | type) == "number" then {used: (.used | floor), total: ((.total // 0) | floor)} else null end' <<<"$out" 2>/dev/null || printf 'null'
}

# bk_status_json — risposta di `vps-backup status`.
bk_status_json() {
  local cfg state='{}' drive=null conn=false
  cfg="$(bk_config_json)"
  if [[ -f "$BK_STATE" ]]; then state="$(jq -c 'if type == "object" then . else {} end' "$BK_STATE" 2>/dev/null)" || state='{}'; fi
  [[ -n "$state" ]] || state='{}'
  if [[ -f "$BK_RCLONE_CONF" ]]; then
    conn=true
    drive="$(bk_drive_json)"
  fi
  jq -nc --argjson c "$cfg" --argjson s "$state" --argjson d "$drive" --argjson conn "$conn" \
    '{ok: true, connected: $conn, folder: $c.folder, enabled: $c.enabled, time: $c.time,
      job: ($s.job // null), last_run: ($s.last_run // null), drive: $d}'
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
    if [[ -n "$prev" ]]; then
      mv -f "$prev" "$conf" || rm -f "$prev"
    else
      rm -f "$conf"
    fi
    BK_ERR="Google Drive non ha accettato il collegamento: $(bk_clean_msg "$out" "$tok" "$at" "$rt" "$sec")"
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
