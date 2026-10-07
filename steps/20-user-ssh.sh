# shellcheck shell=bash
# Utente amministratore e configurazione SSH (preparata qui, attivata nello step 99).

step_main() {
  local home keys
  log "Utente: $ADMIN_USER"
  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$ADMIN_USER"
  fi
  usermod -aG sudo "$ADMIN_USER"
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd

  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  keys="$home/.ssh/authorized_keys"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  touch "$keys"
  if ! grep -qxF -- "$ADMIN_PUBKEY" "$keys"; then
    if [[ -s "$keys" && -n "$(tail -c1 "$keys")" ]]; then
      printf '\n' >>"$keys"
    fi
    printf '%s\n' "$ADMIN_PUBKEY" >>"$keys"
  fi
  chown "$ADMIN_USER:$ADMIN_USER" "$keys"
  chmod 600 "$keys"
  if [[ -f "$home/.bashrc" ]]; then
    sed -i 's/^#\?force_color_prompt=.*/force_color_prompt=yes/' "$home/.bashrc"
  fi

  log "SSH: preparo la configurazione (verrà attivata e verificata alla fine)"
  render_template "$VPS_TEMPLATES/sshd-10-vps.conf.tmpl" "$VPS_ROOT/sshd-10-vps.conf" 644 root:root \
    SSH_PORT ROOT_LOGIN SSH_ALLOW_USERS
}
