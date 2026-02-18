#!/usr/bin/env bash
set -e

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-freepbx}"
DB_PASS="${DB_PASS:-freepbx}"
DB_NAME="${DB_NAME:-asterisk}"
DB_CDR_NAME="${DB_CDR_NAME:-asteriskcdrdb}"

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
# First-run: import pre-built schema and update DB connection
# ---------------------------------------------------------------
init_db() {
  echo "=== First-run: importing FreePBX database schema ==="

  # Import the pre-built SQL dumps
  mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < /usr/local/src/asterisk.sql
  mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_CDR_NAME" < /usr/local/src/asteriskcdrdb.sql

  # Update FreePBX config to point to the external DB
  if [ -f /etc/freepbx.conf ]; then
    sed -i "s/\$amp_conf\['AMPDBHOST'\] = .*/\$amp_conf['AMPDBHOST'] = '${DB_HOST}';/" /etc/freepbx.conf
    sed -i "s/\$amp_conf\['AMPDBUSER'\] = .*/\$amp_conf['AMPDBUSER'] = '${DB_USER}';/" /etc/freepbx.conf
    sed -i "s/\$amp_conf\['AMPDBPASS'\] = .*/\$amp_conf['AMPDBPASS'] = '${DB_PASS}';/" /etc/freepbx.conf
  fi

  touch "$INSTALLED_MARKER"
  echo "=== Database import complete ==="
}

# ---------------------------------------------------------------
# Start services
# ---------------------------------------------------------------
start_services() {
  # Ensure run directory exists
  mkdir -p /var/run/asterisk
  chown asterisk:asterisk /var/run/asterisk

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
  init_db
fi

# Ensure ownership is correct on mounted volumes
chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk 2>/dev/null || true

start_services
