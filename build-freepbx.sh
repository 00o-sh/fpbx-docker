#!/bin/bash
set -eux

FREEPBX_VERSION="${1:-17}"

# Install MariaDB server temporarily for the FreePBX package postinst
apt-get update
apt-get install -y --no-install-recommends mariadb-server
rm -rf /var/lib/apt/lists/*

# --- Start temporary MariaDB ---
mkdir -p /var/run/mysqld
chown mysql:mysql /var/run/mysqld
mysqld --user=mysql --datadir=/var/lib/mysql &
MYSQL_PID=$!

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

# --- Provide a minimal Asterisk config so it can start ---
mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk \
  /var/spool/asterisk /etc/asterisk

# Determine modules directory
AST_MOD_DIR=$(find /usr/lib -type d -name modules -path '*/asterisk/*' 2>/dev/null | head -1)
AST_MOD_DIR="${AST_MOD_DIR:-/usr/lib/x86_64-linux-gnu/asterisk/modules}"

cat > /etc/asterisk/asterisk.conf <<ASTEOF
[directories]
astetcdir => /etc/asterisk
astmoddir => ${AST_MOD_DIR}
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
astsbindir => /usr/sbin

[options]
runuser = asterisk
rungroup = asterisk
ASTEOF

cat > /etc/asterisk/modules.conf <<'MODEOF'
[modules]
autoload = yes
MODEOF

cat > /etc/asterisk/logger.conf <<'LOGEOF'
[general]

[logfiles]
console => notice,warning,error
LOGEOF

chown asterisk:asterisk /etc/asterisk/asterisk.conf /etc/asterisk/modules.conf /etc/asterisk/logger.conf

# --- Start Asterisk temporarily ---
/usr/sbin/asterisk -U asterisk -G asterisk -C /etc/asterisk/asterisk.conf

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

# --- Install FreePBX from Sangoma repo ---
echo ">>> Installing FreePBX ${FREEPBX_VERSION} from Sangoma repo..."
apt-get update
apt-get install -y --no-install-recommends \
  -o Dpkg::Options::="--force-confnew" \
  freepbx${FREEPBX_VERSION}
rm -rf /var/lib/apt/lists/*

# The freepbx17 postinst shuts down MariaDB and then tries
# "systemctl restart mariadb" which doesn't exist in Docker.
# Restart it manually so fwconsole and mariadb-dump work.
if ! mariadb -e "SELECT 1" &>/dev/null; then
  echo ">>> MariaDB died during package install — restarting..."
  mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld
  mysqld --user=mysql --datadir=/var/lib/mysql &
  MYSQL_PID=$!
  retries=30
  until mariadb -e "SELECT 1" &>/dev/null; do
    retries=$((retries - 1))
    if [ "$retries" -le 0 ]; then
      echo "ERROR: MariaDB failed to restart after package install" >&2
      exit 1
    fi
    sleep 2
  done
  echo ">>> MariaDB restarted (PID $MYSQL_PID)."
fi

# Restart Asterisk if the package install killed it
if ! /usr/sbin/asterisk -rx "core show version" &>/dev/null; then
  echo ">>> Asterisk died during package install — restarting..."
  /usr/sbin/asterisk -U asterisk -G asterisk -C /etc/asterisk/asterisk.conf
  retries=30
  until /usr/sbin/asterisk -rx "core show version" &>/dev/null; do
    retries=$((retries - 1))
    if [ "$retries" -le 0 ]; then
      echo "ERROR: Asterisk failed to restart after package install" >&2
      exit 1
    fi
    sleep 2
  done
  echo ">>> Asterisk restarted."
fi

# Post-install module setup (matches official sng_freepbx_debian_install.sh)
echo ">>> Running fwconsole post-install..."

# Remove commercial modules that cannot work without a license,
# but keep sysadmin + firewall so the FreePBX firewall UI stays available.
echo ">>> Removing unlicensed commercial modules (keeping sysadmin/firewall)..."
fwconsole ma list 2>/dev/null | awk '/Commercial/ {print $2}' | while read -r mod; do
  case "$mod" in
    sysadmin|firewall) echo "  keeping: $mod" ;;
    *) echo "  removing commercial module: $mod"
       fwconsole ma -f remove "$mod" 2>/dev/null || true ;;
  esac
done

# Install and enable open-source modules that were flagged as missing
fwconsole ma install recordings || true
fwconsole ma enable recordings || true
fwconsole ma installlocal || true
fwconsole ma upgradeall || true
fwconsole reload || true
fwconsole restart || true
fwconsole ma refreshsignatures || true

echo ">>> FreePBX install phase complete"

# Dump schemas for runtime import to external DB (still under set -e).
# After dumping, strip DEFINER clauses from triggers/views/routines so
# the runtime user can import without SUPER privilege.
echo ">>> Dumping database schemas..."
mariadb-dump asterisk > /usr/local/src/asterisk.sql
mariadb-dump asteriskcdrdb > /usr/local/src/asteriskcdrdb.sql
sed -i 's/\sDEFINER=[^ ]*//' /usr/local/src/asterisk.sql /usr/local/src/asteriskcdrdb.sql

# Validate the dumps contain the critical table
if ! grep -q 'freepbx_settings' /usr/local/src/asterisk.sql; then
  echo "ERROR: asterisk.sql dump is missing freepbx_settings table — FreePBX install likely failed" >&2
  exit 1
fi
echo ">>> Schema dump complete (validated)"

# --- From here on, don't let errors stop the build ---
set +e

# Stop Asterisk and MariaDB
echo ">>> Stopping services..."
/usr/sbin/asterisk -rx "core stop now" 2>/dev/null
sleep 2
kill "$MYSQL_PID" 2>/dev/null
wait "$MYSQL_PID" 2>/dev/null

# Remove MariaDB server (bypass maintainer scripts)
echo ">>> Removing MariaDB server..."
dpkg --purge --force-remove-reinstreq --force-depends \
  mariadb-server mariadb-server-10.11 mariadb-server-core-10.11 2>/dev/null
rm -rf /var/lib/mysql /var/run/mysqld /etc/mysql
apt-get autoremove -y 2>/dev/null
apt-get clean
rm -rf /var/lib/apt/lists/*

# Cleanup
rm -f /usr/local/src/build-freepbx.sh

echo "=== FreePBX build-time install complete ==="
