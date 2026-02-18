#!/bin/bash
set -eux

FREEPBX_VERSION="${1:-17}"

# --- Start temporary MariaDB ---
mkdir -p /var/run/mysqld
chown mysql:mysql /var/run/mysqld
mysqld --user=mysql --datadir=/var/lib/mysql &
MYSQL_PID=$!

# Wait for MariaDB to be ready
echo "Waiting for temporary MariaDB..."
retries=30
until mariadb -e "SELECT 1" &>/dev/null; do
  retries=$((retries - 1))
  if [ "$retries" -le 0 ]; then
    echo "ERROR: MariaDB did not start" >&2
    exit 1
  fi
  sleep 2
done
echo "Temporary MariaDB is ready."

# Create databases and user
mariadb -e "CREATE DATABASE asterisk;"
mariadb -e "CREATE DATABASE asteriskcdrdb;"
mariadb -e "CREATE USER 'freepbx'@'localhost' IDENTIFIED BY 'freepbx';"
mariadb -e "GRANT ALL ON asterisk.* TO 'freepbx'@'localhost';"
mariadb -e "GRANT ALL ON asteriskcdrdb.* TO 'freepbx'@'localhost';"
mariadb -e "FLUSH PRIVILEGES;"

# --- Start Asterisk temporarily ---
mkdir -p /var/run/asterisk
chown asterisk:asterisk /var/run/asterisk
/usr/sbin/asterisk -U asterisk -G asterisk

echo "Waiting for Asterisk..."
retries=30
until /usr/sbin/asterisk -rx "core show version" &>/dev/null; do
  retries=$((retries - 1))
  if [ "$retries" -le 0 ]; then
    echo "ERROR: Asterisk did not start" >&2
    exit 1
  fi
  sleep 2
done
echo "Asterisk is running."

# --- Download and install FreePBX ---
curl -fsSL "https://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}.0-latest.tgz" \
  -o /usr/local/src/freepbx.tgz
tar -xzf /usr/local/src/freepbx.tgz -C /usr/local/src
rm /usr/local/src/freepbx.tgz

cd /usr/local/src/freepbx
./install -n \
  --dbhost localhost \
  --dbuser freepbx \
  --dbpass freepbx \
  --dbname asterisk \
  --cdrdbname asteriskcdrdb \
  --webroot /var/www/html

fwconsole ma installall
fwconsole reload
fwconsole chown

# --- Dump schemas for runtime import ---
mariadb-dump asterisk > /usr/local/src/asterisk.sql
mariadb-dump asteriskcdrdb > /usr/local/src/asteriskcdrdb.sql

# --- Cleanup ---
/usr/sbin/asterisk -rx "core stop now" 2>/dev/null || true
sleep 2
mysqladmin shutdown 2>/dev/null || true
wait "$MYSQL_PID" 2>/dev/null || true

# Remove MariaDB server (not needed at runtime)
apt-get purge -y mariadb-server
apt-get autoremove -y
rm -rf /var/lib/mysql /var/run/mysqld
apt-get clean
rm -rf /var/lib/apt/lists/*

# Remove build script
rm -f /usr/local/src/build-freepbx.sh

echo "=== FreePBX build-time install complete ==="
