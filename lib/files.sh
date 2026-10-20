# shellcheck shell=bash
# Libreria di vps-files: validazione dei percorsi, ricerca del sito, esecuzione
# dei comandi come utente del sito. vps-files gira da root su richiesta del
# pannello (chiamante non fidato): root non deve mai aprire file del sito, perché
# un sito compromesso può piazzarci collegamenti simbolici (scalata di privilegi).

: "${FM_RUNUSER:=runuser}"
# Umask dei file creati: 002, come in sites_wp.sh (file 664, cartelle 775): restano
# modificabili dall'admin del gruppo e dal sito, come via SFTP.

# fm_site_check DOMINIO — stampa "slug radice"; 1 con messaggio se il sito non
# esiste nel registro di vps-site o non è in stato active|disabled.
fm_site_check() {
  local d="${1-}" state slug
  if ! valid_domain "$d"; then
    echo "dominio non valido" >&2
    return 1
  fi
  if ! site_reg_exists "$d"; then
    echo "sito $d non trovato" >&2
    return 1
  fi
  state="$(site_reg_get "$d" .state)" || return 1
  if [[ "$state" != active && "$state" != disabled ]]; then
    echo "il sito $d è in stato $state: riprova più tardi" >&2
    return 1
  fi
  slug="$(site_reg_get "$d" .slug)" || return 1
  if [[ ! "$slug" =~ ^site_[a-z0-9_]{1,27}$ ]]; then
    echo "registro del sito $d non valido" >&2
    return 1
  fi
  printf '%s %s\n' "$slug" "$(site_root "$d")"
}

# fm_path_check PERCORSO — percorso relativo alla radice del sito. Stampa l'area
# (public, logs, logsphp, wpconfig, root) e restituisce 0; altrimenti 1.
# Esamina i segmenti uno per uno; non risolve mai nulla sul disco (niente realpath).
fm_path_check() {
  local LC_ALL=C p="${1-}" seg area
  local -a segs
  ((${#p} <= 4096)) || return 1 # byte, per LC_ALL=C
  if [[ -z "$p" ]]; then
    echo root
    return 0
  fi
  [[ "$p" != /* && "$p" != */ ]] || return 1
  [[ "$p" != *[[:cntrl:]]* ]] || return 1
  IFS=/ read -r -a segs <<<"$p"
  for seg in "${segs[@]}"; do
    [[ -n "$seg" && "$seg" != . && "$seg" != .. ]] || return 1
    ((${#seg} <= 255)) || return 1
  done
  case "${segs[0]}" in
    public) area=public ;;
    logs)
      area=logs
      if ((${#segs[@]} > 1)) && [[ "${segs[1]}" == php ]]; then
        area=logsphp
      else
        # in logs/ solo voci dirette: sotto logs/<x>/ (x diverso da php) root non scende
        ((${#segs[@]} <= 2)) || return 1
      fi
      ;;
    wp-config.php)
      ((${#segs[@]} == 1)) || return 1
      area=wpconfig
      ;;
    *) return 1 ;;
  esac
  echo "$area"
}

# fm_writable PERCORSO — 0 solo se l'area è public e il percorso non è public stesso.
fm_writable() {
  local area
  area="$(fm_path_check "${1-}")" || return 1
  [[ "$area" == public && "$1" != public ]]
}

# fm_as_site SLUG RADICE CMD... — esegue CMD come utente del sito, con ambiente
# pulito, dentro la radice, con la umask dei file del sito. stdin/stdout passano.
# Tutto ciò che tocca public/ o logs/php/ passa da qui, mai da root.
fm_as_site() {
  local slug="${1-}" root="${2-}"
  if [[ ! "$slug" =~ ^site_[a-z0-9_]{1,27}$ || -z "$root" || ! -d "$root" ]]; then
    echo "fm_as_site: sito o radice non validi" >&2
    return 2
  fi
  shift 2
  (($#)) || return 2
  (
    cd "$root" || exit 1
    exec "$FM_RUNUSER" -u "$slug" -- env -i PATH=/usr/bin:/bin "HOME=$root/tmp" LC_ALL=C \
      sh -c 'umask 002 && exec "$@"' sh "$@"
  )
}
