# shellcheck shell=bash
# Redis solo su localhost.

step_enabled() {
  is_yes "$WANT_REDIS"
}

step_main() {
  log "Redis: installazione"
  apt_install redis-server
  local conf=/etc/redis/redis.conf
  sed -i -E 's/^#? *bind .*/bind 127.0.0.1 -::1/' "$conf"
  sed -i -E 's/^#? *protected-mode .*/protected-mode yes/' "$conf"
  systemctl enable redis-server >>"$VPS_LOG" 2>&1
  systemctl restart redis-server
}
