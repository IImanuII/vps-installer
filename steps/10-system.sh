# shellcheck shell=bash
# Sistema: aggiornamenti, hostname, fuso orario, locale, NTP, aggiornamenti automatici.

step_main() {
  log "Sistema: aggiornamento dei pacchetti (può richiedere qualche minuto)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q -o DPkg::Lock::Timeout=300 >>"$VPS_LOG" 2>&1
  apt-get full-upgrade -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold >>"$VPS_LOG" 2>&1
  apt_install sudo htop git curl unzip 7zip ca-certificates gnupg whiptail jq gettext-base \
    locales chrony unattended-upgrades apt-listchanges tmux openssl cron xz-utils

  install -d -m 755 "$VPS_OPT"
  install -d -m 700 "$VPS_OPT/secrets"

  log "Sistema: hostname $HOSTNAME_NEW"
  hostnamectl set-hostname "$HOSTNAME_NEW"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $HOSTNAME_NEW/" /etc/hosts
  else
    echo "127.0.1.1 $HOSTNAME_NEW" >>/etc/hosts
  fi

  log "Sistema: fuso orario $TIMEZONE, locale $LOCALE"
  timedatectl set-timezone "$TIMEZONE"
  if ! grep -q "^${LOCALE} UTF-8" /etc/locale.gen; then
    echo "$LOCALE UTF-8" >>/etc/locale.gen
  fi
  locale-gen >>"$VPS_LOG" 2>&1
  update-locale LANG="$LOCALE"

  log "Sistema: NTP (chrony)"
  install -D -m 644 "$VPS_TEMPLATES/chrony-vps.sources" /etc/chrony/sources.d/vps.sources
  systemctl restart chrony

  log "Sistema: aggiornamenti di sicurezza automatici"
  install -m 644 "$VPS_TEMPLATES/apt-52vps-unattended" /etc/apt/apt.conf.d/52vps-unattended
  install -m 644 "$VPS_TEMPLATES/apt-20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
  systemctl enable --now unattended-upgrades >>"$VPS_LOG" 2>&1
}
