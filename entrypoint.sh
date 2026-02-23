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
# Seed empty PVC mounts with build-time defaults
# (k8s PVCs shadow the image layers — fresh mounts are empty)
# ---------------------------------------------------------------
init_volumes() {
  if [ -d /var/lib/asterisk-defaults ] && [ ! -f /var/lib/asterisk/bin/fwconsole ]; then
    echo "Seeding /var/lib/asterisk from image defaults..."
    cp -a /var/lib/asterisk-defaults/. /var/lib/asterisk/
  fi
  if [ -d /etc/asterisk-defaults ] && [ ! -f /etc/asterisk/asterisk.conf ]; then
    echo "Seeding /etc/asterisk from image defaults..."
    cp -a /etc/asterisk-defaults/. /etc/asterisk/
  fi
}

# ---------------------------------------------------------------
# Graceful shutdown (k8s sends SIGTERM to PID 1)
# ---------------------------------------------------------------
cleanup() {
  echo "Caught signal — shutting down gracefully..."
  fail2ban-client stop 2>/dev/null || true
  fwconsole stop 2>/dev/null || true
  redis-cli shutdown 2>/dev/null || true
  service postfix stop 2>/dev/null || true
  apache2ctl stop 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# ---------------------------------------------------------------
# Rewrite FreePBX & ODBC configs to point at the external DB
# (runs every start so a container recreate never stales)
# ---------------------------------------------------------------
configure_db() {
  # /etc/freepbx.conf – authoritative DB connection for FreePBX
  cat > /etc/freepbx.conf <<FPBXEOF
<?php
\$amp_conf['AMPDBUSER'] = '${DB_USER}';
\$amp_conf['AMPDBPASS'] = '${DB_PASS}';
\$amp_conf['AMPDBHOST'] = '${DB_HOST}';
\$amp_conf['AMPDBPORT'] = '${DB_PORT}';
\$amp_conf['AMPDBNAME'] = '${DB_NAME}';
\$amp_conf['AMPDBENGINE'] = 'mysql';
\$amp_conf['datasource'] = '';
\$amp_conf['CDRDBNAME'] = '${DB_CDR_NAME}';
\$amp_conf['CDRDBHOST'] = '${DB_HOST}';
\$amp_conf['CDRDBPORT'] = '${DB_PORT}';
\$amp_conf['CDRDBUSER'] = '${DB_USER}';
\$amp_conf['CDRDBPASS'] = '${DB_PASS}';
\$amp_conf['CDRDBTYPE'] = 'mysql';
require_once('/var/www/html/admin/bootstrap.php');
FPBXEOF

  # /etc/odbc.ini – used by Asterisk's ODBC CDR/CEL
  cat > /etc/odbc.ini <<ODBCEOF
[MySQL-asteriskcdrdb]
Description = MySQL connection to '${DB_CDR_NAME}' database
Driver      = MySQL
Server      = ${DB_HOST}
Database    = ${DB_CDR_NAME}
Port        = ${DB_PORT}
Option      = 3
ODBCEOF

  echo "DB configs written (host=${DB_HOST}, port=${DB_PORT})."
}

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
# Sync database-stored FreePBX settings with env vars
# FreePBX loads settings from freepbx_settings which OVERRIDE
# values in /etc/freepbx.conf, so the DB must match the env.
# ---------------------------------------------------------------
sync_db_settings() {
  echo "Syncing FreePBX CDR database settings with environment..."

  # SQL-escape single quotes in values
  local q_cdr="${DB_CDR_NAME//\'/\'\'}"
  local q_host="${DB_HOST//\'/\'\'}"
  local q_port="${DB_PORT//\'/\'\'}"
  local q_user="${DB_USER//\'/\'\'}"
  local q_pass="${DB_PASS//\'/\'\'}"

  mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "
      UPDATE freepbx_settings SET value='${q_cdr}'  WHERE keyword='CDRDBNAME';
      UPDATE freepbx_settings SET value='${q_host}' WHERE keyword='CDRDBHOST';
      UPDATE freepbx_settings SET value='${q_port}' WHERE keyword='CDRDBPORT';
      UPDATE freepbx_settings SET value='${q_user}' WHERE keyword='CDRDBUSER';
      UPDATE freepbx_settings SET value='${q_pass}' WHERE keyword='CDRDBPASS';
      UPDATE freepbx_settings SET value='mysql'     WHERE keyword='CDRDBTYPE';
    " 2>/dev/null || true

  echo "FreePBX CDR settings synced (CDRDBNAME=${DB_CDR_NAME})."
}

# ---------------------------------------------------------------
# Ensure required FreePBX modules are installed and enabled.
# After a fresh PVC seed or schema reimport the DB may lack
# module registrations even though the files exist on disk.
# ---------------------------------------------------------------
ensure_modules() {
  local mods="recordings"
  for mod in $mods; do
    if ! fwconsole ma list 2>/dev/null | grep -qw "$mod"; then
      echo "Installing missing module: $mod"
      fwconsole ma install "$mod" 2>/dev/null || true
    fi
    fwconsole ma enable "$mod" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------
# First-run: import pre-built schema and update DB connection
# ---------------------------------------------------------------
init_db() {
  echo "=== First-run: importing FreePBX database schema ==="

  # Import the pre-built SQL dumps
  mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < /usr/local/src/asterisk.sql
  mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_CDR_NAME" < /usr/local/src/asteriskcdrdb.sql

  # Verify the import created the critical table before marking as installed
  if ! mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
       -e "SELECT 1 FROM freepbx_settings LIMIT 1" &>/dev/null; then
    echo "ERROR: freepbx_settings table missing after import — SQL dumps may be incomplete" >&2
    exit 1
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

  # Start Asterisk via FreePBX
  fwconsole start

  # Start Fail2ban (after Asterisk so log files exist)
  mkdir -p /var/log/asterisk
  touch /var/log/asterisk/full
  rm -f /var/run/fail2ban/fail2ban.pid /var/run/fail2ban/fail2ban.sock
  fail2ban-client start &

  # Start Apache in background; shell stays PID 1 to handle SIGTERM
  echo "FreePBX ready — starting Apache"
  apache2ctl -D FOREGROUND &
  APACHE_PID=$!
  wait $APACHE_PID
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
init_volumes
wait_for_db
configure_db

if [ ! -f "$INSTALLED_MARKER" ]; then
  init_db
fi

# Ensure freepbx_settings rows match env vars (CDR DB name, host, etc.)
sync_db_settings

# Ensure ownership is correct on mounted volumes
chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk 2>/dev/null || true

# Ensure required modules are present and enabled
ensure_modules

start_services
