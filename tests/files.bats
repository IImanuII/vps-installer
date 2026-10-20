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
    config.php wp-config.php/x logsx logs/../public wp-config.phpx PUBLIC/x $'public/a\nb' $'public/a\tb' $'public/a\x7fb' $'public/a\rb'; do
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
