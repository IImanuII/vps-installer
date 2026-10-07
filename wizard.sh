#!/usr/bin/env bash
# Procedura guidata: tutte le domande all'inizio, risposte in answers.env.

if [[ -z "${VPS_ROOT:-}" ]]; then
  VPS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
export VPS_ROOT
for _lib in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"/lib/*.sh; do
  source "$_lib"
done

W_TITLE="VPS Installer $VPS_INSTALLER_VERSION"

wt() {
  whiptail --title "$W_TITLE" "$@" 3>&1 1>&2 2>&3
}

confirm_quit() {
  if wt --yesno "Vuoi annullare l'installazione?" 8 60; then
    exit 1
  fi
}

# ask_input VAR TESTO DEFAULT VALIDATORE MESSAGGIO_ERRORE
ask_input() {
  local var="$1" text="$2" def="$3" validator="$4" err="$5" val
  while true; do
    if ! val="$(wt --inputbox "$text" 14 78 "$def")"; then
      confirm_quit
      continue
    fi
    val="$(trim "$val")"
    if "$validator" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    wt --msgbox "$err" 12 78 || true
    if [[ "$var" != ADMIN_PUBKEY ]]; then
      def="$val"
    fi
  done
}

# ask_secret VAR TESTO VALIDATORE MESSAGGIO_ERRORE
ask_secret() {
  local var="$1" text="$2" validator="$3" err="$4" val
  while true; do
    if ! val="$(wt --passwordbox "$text" 12 78)"; then
      confirm_quit
      continue
    fi
    if "$validator" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    wt --msgbox "$err" 10 78 || true
  done
}

ask_new_password() {
  local var="$1" text="$2" p1 p2
  while true; do
    ask_secret p1 "$text" valid_password "La password deve avere almeno 12 caratteri e stare su una riga."
    ask_secret p2 "Ripeti la password:" valid_password "La password deve avere almeno 12 caratteri."
    if [[ "$p1" == "$p2" ]]; then
      printf -v "$var" '%s' "$p1"
      return 0
    fi
    wt --msgbox "Le password non coincidono, riprova." 8 60 || true
  done
}

# ask_yesno VAR TESTO [DEFAULT=yes]
ask_yesno() {
  local var="$1" text="$2" def="${3:-yes}" opts=()
  if [[ "$def" == no ]]; then
    opts+=(--defaultno)
  fi
  if wt "${opts[@]}" --yesno "$text" 12 78; then
    printf -v "$var" yes
  else
    printf -v "$var" no
  fi
}

# ask_menu VAR TESTO DEFAULT TAG DESCRIZIONE [TAG DESCRIZIONE...]
ask_menu() {
  local var="$1" text="$2" def="$3" val
  shift 3
  while ! val="$(wt --default-item "$def" --menu "$text" 16 78 6 "$@")"; do
    confirm_quit
  done
  printf -v "$var" '%s' "$val"
}

wizard_defaults() {
  local v
  for v in "${ANSWER_VARS[@]}"; do
    printf -v "$v" '%s' ""
  done
  # shellcheck disable=SC2034
  WANT_NGINX=no WANT_PHP=no WANT_MARIADB=no WANT_REDIS=no WANT_CERTBOT=no WANT_PMA=no
  PANEL_ENABLED=no CF_ENABLED=no CF_LOCK_ORIGIN=no MAIL_ENABLED=no ROOT_LOGIN=no
}

wizard_preflight() {
  local errs
  errs="$(preflight_errors)"
  if [[ -n "$errs" ]]; then
    wt --msgbox "Impossibile continuare:\n\n$errs" 16 78 || true
    exit 1
  fi
  wt --msgbox "Benvenuto.\n\nTi farò alcune domande, poi l'installazione procederà da sola.\nAlla fine ti chiederò di verificare l'accesso SSH da una seconda finestra.\n\nTieni pronta la tua chiave SSH PUBBLICA (es. il contenuto di ~/.ssh/id_ed25519.pub)." 16 78 || true
}

wizard_system() {
  ask_input HOSTNAME_NEW "Nome host della VPS (minuscole, cifre, trattini):" \
    "$(hostname -s | tr '[:upper:]' '[:lower:]')" valid_hostname "Nome host non valido."
  ask_input TIMEZONE "Fuso orario:" "Europe/Rome" valid_timezone "Fuso orario non valido (es. Europe/Rome)."
  ask_input LOCALE "Lingua di sistema (locale):" "it_IT.UTF-8" valid_locale "Locale non valido (es. it_IT.UTF-8)."
}

wizard_user() {
  ask_input ADMIN_USER "Nome del tuo utente amministratore (per SSH e sudo):" "" valid_username \
    "Nome utente non valido o riservato.\nUsa minuscole, cifre, _ o -, iniziando con una lettera.\nNon usare root, debian, panel o nomi che iniziano con site_."
  ask_new_password ADMIN_PASS "Password per $ADMIN_USER (serve per sudo, minimo 12 caratteri):"
  ask_input ADMIN_PUBKEY "Incolla la tua chiave SSH PUBBLICA (una riga, es. ssh-ed25519 AAAA... nome):" "" valid_ssh_pubkey \
    "Chiave non valida.\nIncolla il contenuto del file .pub (una sola riga).\nNON incollare la chiave privata.\nSono accettate ed25519, ecdsa e rsa da almeno 2048 bit."
}

wizard_ssh() {
  ask_input SSH_PORT "Porta SSH (consigliata una porta alta casuale):" "$(shuf -i 20000-60000 -n 1)" valid_port \
    "Porta non valida: usa 22 oppure 1024-65535 (escluse 3306, 6379, 8080)."
  ask_menu ROOT_LOGIN "Accesso SSH come root:" no \
    no "Bloccato (consigliato)" \
    prohibit-password "Consentito solo con chiave SSH"
}

wizard_stack() {
  local sel
  while ! sel="$(wt --separate-output --checklist "Componenti da installare (spazio per selezionare, Invio per confermare):" 18 78 6 \
    nginx "Nginx (web server)" ON \
    php "PHP $PHP_VERSION" ON \
    mariadb "MariaDB (database)" ON \
    redis "Redis (cache)" ON \
    certbot "Certbot (certificati SSL)" ON \
    pma "phpMyAdmin (sul dominio del pannello)" ON)"; do
    confirm_quit
  done
  components_from_selection "$sel"
}

wizard_panel() {
  if ! components_allow_panel; then
    PANEL_ENABLED=no
    return 0
  fi
  ask_yesno PANEL_ENABLED "Preparare ora il dominio del pannello di gestione?\n\n(vhost, SSL, database, utente dedicato: il codice del pannello si installa dopo)" yes
  if is_yes "$PANEL_ENABLED"; then
    ask_input PANEL_DOMAIN "Dominio del pannello (es. panel.miosito.it):" "" valid_domain \
      "Dominio non valido (solo minuscole, es. panel.miosito.it)."
  fi
}

wizard_dns_warning() {
  local ip
  ip="$(server_ipv4)" || ip=""
  if [[ -n "$ip" ]] && is_yes "$PANEL_ENABLED" && ! dns_points_here "$PANEL_DOMAIN" "$ip"; then
    wt --msgbox "Attenzione: $PANEL_DOMAIN non punta ancora a $ip.\n\nCrea il record DNS A prima che inizi lo step SSL, altrimenti l'installazione si fermerà lì (potrai riprenderla)." 14 78 || true
  fi
}

wizard_cloudflare() {
  local zone_domain="${PANEL_DOMAIN:-}" found choice
  ask_yesno CF_ENABLED "Usi Cloudflare per i domini di questa VPS?" yes
  if ! is_yes "$CF_ENABLED"; then
    wizard_dns_warning
    return 0
  fi
  if [[ -z "$zone_domain" ]]; then
    ask_input zone_domain "Dominio principale gestito su Cloudflare (es. miosito.it):" "" valid_domain "Dominio non valido."
  fi
  while true; do
    ask_secret CF_API_TOKEN "API token Cloudflare\n(permesso Zone > DNS > Edit sulla zona di $zone_domain):" valid_cf_token \
      "Formato del token non valido."
    if found="$(CF_API_TOKEN="$CF_API_TOKEN" cf_find_zone "$zone_domain" 2>/dev/null)"; then
      # shellcheck disable=SC2034
      CF_ZONE_ID="${found%% *}"
      CF_ZONE="${found#* }"
      break
    fi
    ask_menu choice "Il token non è valido oppure non ha accesso alla zona di $zone_domain." retry \
      retry "Riprova con un altro token" \
      domain "Cambia dominio della zona" \
      skip "Continua senza Cloudflare"
    case "$choice" in
      domain)
        ask_input zone_domain "Dominio principale gestito su Cloudflare (es. miosito.it):" "$zone_domain" valid_domain "Dominio non valido."
        ;;
      skip)
        # shellcheck disable=SC2034
        CF_ENABLED=no CF_API_TOKEN="" CF_ZONE="" CF_ZONE_ID=""
        wizard_dns_warning
        return 0
        ;;
    esac
  done
  ask_yesno CF_LOCK_ORIGIN "Accettare traffico web (80/443) SOLO dagli IP di Cloudflare?\n\n(consigliato: nasconde la VPS a chi la cerca direttamente)" yes
}

wizard_mail() {
  local choice
  ask_menu choice "Email per gli avvisi (fail2ban, aggiornamenti, certificati):" later \
    later "Configura dopo dal pannello (consigliato)" \
    now "Configura ora (SMTP)"
  if [[ "$choice" == later ]]; then
    MAIL_ENABLED=no
    return 0
  fi
  MAIL_ENABLED=yes
  ask_input SMTP_HOST "Server SMTP (es. smtp.gmail.com, smtp-relay.brevo.com):" "smtp.gmail.com" valid_domain "Host non valido."
  ask_input SMTP_PORT "Porta SMTP (587 STARTTLS, 465 TLS):" "587" valid_smtp_port "Porta non valida (25, 465, 587, 2525)."
  ask_input SMTP_USER "Utente SMTP:" "" valid_line "Utente non valido."
  ask_secret SMTP_PASS "Password SMTP (per Gmail: una app password):" valid_line "Password non valida."
  ask_input SMTP_FROM "Indirizzo mittente:" "$SMTP_USER" valid_email "Email non valida."
  ask_input ALERT_EMAIL "Email che riceve gli avvisi:" "$SMTP_FROM" valid_email "Email non valida."
}

wizard_summary() {
  local s panel cf mail
  panel="no"
  if is_yes "$PANEL_ENABLED"; then panel="$PANEL_DOMAIN"; fi
  cf="no"
  if is_yes "$CF_ENABLED"; then
    cf="sì, zona $CF_ZONE"
    if is_yes "$CF_LOCK_ORIGIN"; then cf+=", 80/443 solo da Cloudflare"; fi
  fi
  mail="da configurare dal pannello"
  if is_yes "$MAIL_ENABLED"; then mail="$SMTP_USER via $SMTP_HOST:$SMTP_PORT, avvisi a $ALERT_EMAIL"; fi
  s="Host:        $HOSTNAME_NEW ($TIMEZONE, $LOCALE)\n"
  s+="Utente:      $ADMIN_USER (password ****, chiave ${ADMIN_PUBKEY%% *})\n"
  s+="SSH:         porta $SSH_PORT, root: $ROOT_LOGIN, password disattivate\n"
  s+="Componenti:  $(components_summary)\n"
  s+="Pannello:    $panel\n"
  s+="Cloudflare:  $cf\n"
  s+="Email:       $mail\n"
  if [[ -n "${COMPONENT_NOTES:-}" ]]; then
    s+="\nCorrezioni automatiche:\n$COMPONENT_NOTES\n"
  fi
  wt --scrolltext --msgbox "Riepilogo delle scelte:\n\n$s" 22 78 || true
  ask_menu WIZARD_CHOICE "Come vuoi procedere?" install \
    install "Installa" \
    restart "Ricomincia le domande" \
    quit "Annulla"
}

main() {
  enable_error_trap
  ((EUID == 0)) || die "Esegui come root"
  [[ -t 0 ]] || die "La procedura guidata richiede un terminale interattivo."
  command -v whiptail >/dev/null 2>&1 || die "whiptail non è installato (apt install whiptail)."
  wizard_preflight
  while true; do
    wizard_defaults
    wizard_system
    wizard_user
    wizard_ssh
    wizard_stack
    wizard_panel
    wizard_cloudflare
    wizard_mail
    resolve_components
    wizard_summary
    case "$WIZARD_CHOICE" in
      install) break ;;
      restart) continue ;;
      *) exit 1 ;;
    esac
  done
  answers_save
  log "Procedura guidata completata, risposte salvate."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
