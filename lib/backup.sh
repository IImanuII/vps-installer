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

# --- lock per sito ---------------------------------------------------------

# bk_lock_file SLUG — percorso del lock del sito.
bk_lock_file() {
  printf '%s/vps-site.%s.lock' "$BK_LOCK_DIR" "$1"
}

# bk_site_lock SLUG — prende il lock del sito senza attendere e lo tiene sul
# descrittore 6 finché il chiamante (o bk_site_unlock) non lo chiude. 1 se occupato.
# Si apre prima sul 7: così un tentativo fallito non fa perdere un lock già tenuto
# sul 6, e due chiamate sullo stesso sito nello stesso processo si vedono tra loro.
bk_site_lock() {
  local f old
  f="$(bk_lock_file "${1-}")"
  old="$(umask)"
  umask 077
  # shellcheck disable=SC2261
  { exec 7>>"$f"; } 2>/dev/null || {
    umask "$old"
    return 1
  }
  umask "$old"
  chmod 600 "$f" 2>/dev/null || true
  if ! flock -n 7; then
    exec 7>&-
    return 1
  fi
  exec 6>&7 7>&-
}

# bk_site_unlock — rilascia il lock tenuto sul descrittore 6.
bk_site_unlock() {
  exec 6>&-
}

# bk_site_locked SLUG — 0 se un altro processo tiene il lock del sito. Lo prova su
# un descrittore a parte e lo rilascia subito; non crea il file.
bk_site_locked() {
  local f
  f="$(bk_lock_file "${1-}")"
  [[ -e "$f" ]] || return 1
  (
    # shellcheck disable=SC2261
    { exec 8<"$f"; } 2>/dev/null || exit 1
    if flock -n 8; then exit 1; fi
    exit 0
  )
}

# --- spazio e conservazione ------------------------------------------------

# bk_space_ok DIR BYTES — 0 se lo spazio libero su DIR supera BYTES*2 + 512 MB
# (archivio finale + temporanei, più un margine per il resto del disco).
bk_space_ok() {
  local dir="${1-}" bytes="${2-}" free
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  free="$(df -PB1 "$dir" 2>/dev/null | awk 'NR == 2 {print $4}')"
  [[ "$free" =~ ^[0-9]+$ ]] || return 1
  ((free > bytes * 2 + 536870912))
}

# bk_keep_plan NOMI... — nomi del tipo qualcosa-AAAAMMGG-HHMM.ext: stampa quelli da
# eliminare, cioè tutti tranne gli ultimi 3 per data. Un nome senza data non si
# tocca mai (non si cancella ciò che non si riconosce).
bk_keep_plan() {
  local n key
  local -a rows=()
  for n in "$@"; do
    if [[ "$n" =~ -([0-9]{8}-[0-9]{4})\.[^/]*$ ]]; then
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

# bk_archive DOMINIO OUT — scrive l'archivio del sito in OUT. Tutto si costruisce in
# una cartella temporanea e si sposta in OUT solo a lavoro finito: se qualcosa
# fallisce non resta nulla (né temporaneo né OUT) e BK_ERR dice perché. Uscita 0/1.
bk_archive() {
  local d="${1-}" out="${2-}" w rc=0
  BK_ERR=""
  if [[ -z "$out" ]]; then
    BK_ERR="percorso di destinazione mancante"
    return 1
  fi
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
    rm -f "$out"
    return 1
  fi
}

# _bk_archive_in DOMINIO OUT LAVORO — corpo di bk_archive (in una subshell: BK_ERR
# non risale, quindi lo passa dal file LAVORO/err).
_bk_archive_in() {
  local d="$1" out="$2" w="$3" info slug root rc=0 type login hasdb www
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
      >"$w/files.tar" 2>>"$VPS_LOG" || rc=$?
    if ((rc > 1)); then
      echo "lettura dei file del sito non riuscita (tar $rc)" >"$w/err"
      return 1
    fi
  else
    # tar vuoto valido: la fine-archivio sono due blocchi da 512 byte di zeri
    head -c 10240 /dev/zero >"$w/files.tar"
  fi

  # wp-config.php è di root (640) fuori da public/: lo legge root direttamente, ma
  # mai se è un link (lo mette root, ma non si segue nulla per principio).
  if [[ -L "$root/wp-config.php" ]]; then
    echo "wp-config.php è un collegamento: sito non archiviato" >"$w/err"
    return 1
  fi
  if [[ -f "$root/wp-config.php" ]]; then
    LC_ALL=C.UTF-8 tar --append --file="$w/files.tar" -C "$root" wp-config.php 2>>"$VPS_LOG" || {
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
    mariadb-dump --single-transaction "$slug" >"$w/db.sql" 2>>"$VPS_LOG" || {
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
  mv -f "$w/out.tar.gz" "$out" || {
    echo "archivio non spostato in $out" >"$w/err"
    return 1
  }
}

# --- verifica ---------------------------------------------------------------

# bk_verify_names LISTA — LISTA è l'output di `tar -P --numeric-owner -tvzf` (-P: senza, tar toglie la "/" iniziale e il nome assoluto non si vede) di
# files.tar.gz. Stampa il primo problema trovato (e restituisce 1): nome assoluto,
# segmento "..", dispositivi, link assoluto o che esce dalla cartella del sito
# (normalizzato a partire dalla cartella del link), hardlink fuori dall'archivio.
# Il nome di un link e la sua destinazione sono separati da " -> ": se un nome ne
# contiene uno la divisione è ambigua, quindi si provano entrambe le divisioni.
bk_verify_names() {
  LC_ALL=C awk '
    function bad_name(n,   a, i, c) {
      if (n ~ /^\//) return 1
      c = split(n, a, "/")
      for (i = 1; i <= c; i++) if (a[i] == "..") return 1
      return 0
    }
    # profondità della cartella che contiene il nome
    function depth_of(n,   a, i, c, dpt) {
      c = split(n, a, "/"); dpt = 0
      for (i = 1; i < c; i++) if (a[i] != "" && a[i] != ".") dpt++
      return dpt
    }
    # 1 se il percorso relativo T, partendo da profondità DPT, esce dalla radice
    function escapes(t, dpt,   a, i, c) {
      if (t ~ /^\//) return 1
      c = split(t, a, "/")
      for (i = 1; i <= c; i++) {
        if (a[i] == "" || a[i] == ".") continue
        if (a[i] == "..") { dpt--; if (dpt < 0) return 1 }
        else dpt++
      }
      return 0
    }
    {
      line = $0
      t = substr(line, 1, 1)
      if (!match(line, /^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ /)) { print "voce non leggibile: " line; exit 1 }
      rest = substr(line, RLENGTH + 1)
      if (t == "c" || t == "b" || t == "p") { print "voce speciale: " rest; exit 1 }
      if (t == "l") {
        sep = " -> "
        first = index(rest, sep)
        if (first == 0) { print "collegamento senza destinazione: " rest; exit 1 }
        # ultima occorrenza
        last = 0; s = rest
        while ((p = index(s, sep)) > 0) { last += p + length(sep) - 1; s = substr(rest, last + 1) }
        last = last - length(sep) + 1
        n1 = substr(rest, 1, first - 1); t1 = substr(rest, first + length(sep))
        n2 = substr(rest, 1, last - 1);  t2 = substr(rest, last + length(sep))
        if (bad_name(n1) || bad_name(n2)) { print "nome non valido: " rest; exit 1 }
        if (escapes(t1, depth_of(n1)) || escapes(t2, depth_of(n2))) { print "collegamento fuori dal sito: " rest; exit 1 }
      } else if (t == "h") {
        sep = " link to "
        first = index(rest, sep)
        if (first == 0) { print "hardlink senza destinazione: " rest; exit 1 }
        last = 0; s = rest
        while ((p = index(s, sep)) > 0) { last += p + length(sep) - 1; s = substr(rest, last + 1) }
        last = last - length(sep) + 1
        n1 = substr(rest, 1, first - 1); t1 = substr(rest, first + length(sep))
        n2 = substr(rest, 1, last - 1);  t2 = substr(rest, last + length(sep))
        if (bad_name(n1) || bad_name(n2) || escapes(t1, 0) || escapes(t2, 0)) { print "hardlink non valido: " rest; exit 1 }
      } else {
        if (bad_name(rest)) { print "nome non valido: " rest; exit 1 }
      }
    }' "$1"
}

# bk_verify ARCHIVIO — 0 se l'archivio è integro e sicuro da estrarre: contiene solo
# manifest.json, files.tar.gz e (opzionale) db.sql.gz come file regolari, i sha256 del
# manifest tornano, e files.tar.gz non ha nomi assoluti, "..", né link che escono
# dalla cartella del sito. Non estrae nulla nel sito. 1 con BK_ERR altrimenti.
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
  local a="$1" w="$2" line t name have_db=0 want got
  # 1. l'archivio esterno ha solo le tre voci previste, tutte file regolari
  LC_ALL=C.UTF-8 tar -P --numeric-owner -tvzf "$a" >"$w/outer.lst" 2>/dev/null || {
    echo "archivio illeggibile" >"$w/err"
    return 1
  }
  while IFS= read -r line; do
    t="${line:0:1}"
    # nome dopo i cinque campi (permessi, proprietario, peso, data, ora)
    name="$(printf '%s' "$line" | LC_ALL=C sed -E 's/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ //')"
    if [[ "$t" != - ]]; then
      echo "voce non ammessa nell'archivio: $name" >"$w/err"
      return 1
    fi
    case "$name" in
      manifest.json | files.tar.gz) ;;
      db.sql.gz) have_db=1 ;;
      *)
        echo "voce non ammessa nell'archivio: $name" >"$w/err"
        return 1
        ;;
    esac
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
  # 2. checksum
  jq -e . "$w/manifest.json" >/dev/null 2>&1 || {
    echo "manifest non valido" >"$w/err"
    return 1
  }
  want="$(jq -r '.sha256.files // ""' "$w/manifest.json")"
  got="$(sha256sum "$w/files.tar.gz" | cut -d' ' -f1)"
  if [[ -z "$want" || "$want" != "$got" ]]; then
    echo "checksum di files.tar.gz non corrisponde" >"$w/err"
    return 1
  fi
  want="$(jq -r '.sha256.db // ""' "$w/manifest.json")"
  if ((have_db)); then
    got="$(sha256sum "$w/db.sql.gz" | cut -d' ' -f1)"
    if [[ -z "$want" || "$want" != "$got" ]]; then
      echo "checksum di db.sql.gz non corrisponde" >"$w/err"
      return 1
    fi
  elif [[ -n "$want" ]]; then
    echo "db.sql.gz dichiarato nel manifest ma assente" >"$w/err"
    return 1
  fi
  # 3. nomi e link di files.tar.gz
  LC_ALL=C.UTF-8 tar -P --numeric-owner -tvzf "$w/files.tar.gz" >"$w/files.lst" 2>/dev/null || {
    echo "files.tar.gz illeggibile" >"$w/err"
    return 1
  }
  bk_verify_names "$w/files.lst" >"$w/err" || return 1
  rm -f "$w/err"
}
