#!/bin/bash
set -eux

FREEPBX_VERSION="${1:-17}"

# Install MariaDB server temporarily for the build
apt-get update
apt-get install -y --no-install-recommends mariadb-server
rm -rf /var/lib/apt/lists/*

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
fwconsole reload || true
fwconsole chown || true

echo ">>> FreePBX install phase complete"

# --- From here on, don't let errors stop the build ---
set +e

# Dump schemas for runtime import
echo ">>> Dumping database schemas..."
mariadb-dump asterisk > /usr/local/src/asterisk.sql
mariadb-dump asteriskcdrdb > /usr/local/src/asteriskcdrdb.sql
echo ">>> Schema dump complete"

# Stop Asterisk and MariaDB
echo ">>> Stopping services..."
/usr/sbin/asterisk -rx "core stop now" 2>/dev/null
sleep 2
kill "$MYSQL_PID" 2>/dev/null
wait "$MYSQL_PID" 2>/dev/null

# Remove MariaDB server
echo ">>> Removing MariaDB server..."
dpkg --purge --force-remove-reinstreq --force-depends \
  mariadb-server mariadb-server-10.11 mariadb-server-core-10.11 2>/dev/null
rm -rf /var/lib/mysql /var/run/mysqld /etc/mysql
apt-get autoremove -y 2>/dev/null
apt-get clean
rm -rf /var/lib/apt/lists/*

# Remove build script and FreePBX source
rm -f /usr/local/src/build-freepbx.sh
rm -rf /usr/local/src/freepbx

echo "=== FreePBX build-time install complete ==="
