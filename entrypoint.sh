#!/usr/bin/env bash
set -e

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-freepbx}"
DB_PASS="${DB_PASS:-freepbx}"
DB_NAME="${DB_NAME:-asterisk}"
DB_CDR_NAME="${DB_CDR_NAME:-asteriskcdrdb}"

FREEPBX_DIR="/usr/local/src/freepbx"
INSTALLED_MARKER="/var/lib/asterisk/.fpbx_installed"

# ---------------------------------------------------------------
# Wait for MariaDB to become available
# ---------------------------------------------------------------
wait_for_db() {
  echo "Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
  local retries=60
  while ! mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1" &>/dev/null; do
    retries=$((retries - 1))
    if [ "$retries" -le 0 ]; then
      echo "ERROR: MariaDB did not become ready in time." >&2
      exit 1
    fi
    sleep 2
  done
  echo "MariaDB is ready."
}

# ---------------------------------------------------------------
# First-run FreePBX installation
# ---------------------------------------------------------------
install_freepbx() {
  echo "=== First-run FreePBX installation ==="

  # Ensure run directory exists for Asterisk socket/PID
  mkdir -p /var/run/asterisk
  chown asterisk:asterisk /var/run/asterisk

  # Start Asterisk temporarily for the installer
  /usr/sbin/asterisk -U asterisk -G asterisk -f &
  local ast_pid=$!

  # Wait for Asterisk to be fully booted
  echo "Waiting for Asterisk to start..."
  local retries=30
  while ! /usr/sbin/asterisk -rx "core show version" &>/dev/null; do
    retries=$((retries - 1))
    if [ "$retries" -le 0 ]; then
      echo "ERROR: Asterisk did not start in time." >&2
      exit 1
    fi
    sleep 2
  done
  echo "Asterisk is running."

  cd "$FREEPBX_DIR"
  ./install -n \
    --dbhost "$DB_HOST" \
    --dbuser "$DB_USER" \
    --dbpass "$DB_PASS" \
    --dbname "$DB_NAME" \
    --cdrdbname "$DB_CDR_NAME" \
    --webroot /var/www/html

  # Install base modules
  fwconsole ma installall
  fwconsole reload
  fwconsole chown

  # Stop the temporary Asterisk - entrypoint will start it properly via fwconsole
  /usr/sbin/asterisk -rx "core stop now" 2>/dev/null || true
  wait "$ast_pid" 2>/dev/null || true
  sleep 2

  touch "$INSTALLED_MARKER"
  echo "=== FreePBX installation complete ==="
}

# ---------------------------------------------------------------
# Start services
# ---------------------------------------------------------------
start_services() {
  # Start cron (for scheduled tasks & logrotate)
  /usr/sbin/cron &

  # Start Redis (used by FreePBX for sessions/cache)
  redis-server --daemonize yes

  # Start postfix (mail)
  service postfix start 2>/dev/null || true

  # Start Fail2ban
  rm -f /var/run/fail2ban/fail2ban.pid /var/run/fail2ban/fail2ban.sock
  fail2ban-client start &

  # Start Asterisk via FreePBX
  fwconsole start

  # Start Apache in foreground (keeps container running)
  exec apache2ctl -D FOREGROUND
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
wait_for_db

if [ ! -f "$INSTALLED_MARKER" ]; then
  install_freepbx
fi

# Ensure ownership is correct on mounted volumes
chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk 2>/dev/null || true

start_services
