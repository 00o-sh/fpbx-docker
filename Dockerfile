FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ARG ASTERISK_VERSION=22
ARG FREEPBX_VERSION=17
ARG PHPVERSION="8.2"

# Add Sangoma/FreePBX repository
RUN apt-get update \
  && apt-get install -y --no-install-recommends wget gnupg ca-certificates \
  && wget -qO - http://deb.freepbx.org/gpg/aptly-pubkey.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/freepbx.gpg \
  && echo "deb [arch=amd64] http://deb.freepbx.org/freepbx${FREEPBX_VERSION}-prod bookworm main" \
       > /etc/apt/sources.list.d/freepbx.list \
  && printf 'Package: *\nPin: origin deb.freepbx.org\nPin-Priority: 600\n' \
       > /etc/apt/preferences.d/freepbx \
  && rm -rf /var/lib/apt/lists/*

# Install all runtime dependencies + Asterisk + FreePBX deps
RUN apt-get update \
  && echo "postfix postfix/mailname string freepbx.localdomain" | debconf-set-selections \
  && echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections \
  && apt-get install -y \
    curl ca-certificates gnupg sudo \
    # Asterisk from Sangoma repo
    asterisk${ASTERISK_VERSION} \
    asterisk${ASTERISK_VERSION}-core \
    asterisk${ASTERISK_VERSION}-curl \
    asterisk${ASTERISK_VERSION}-odbc \
    asterisk${ASTERISK_VERSION}-ogg \
    asterisk${ASTERISK_VERSION}-flite \
    asterisk${ASTERISK_VERSION}-resample \
    asterisk${ASTERISK_VERSION}-snmp \
    asterisk${ASTERISK_VERSION}-speex \
    asterisk${ASTERISK_VERSION}-sqlite3 \
    asterisk${ASTERISK_VERSION}-voicemail \
    asterisk${ASTERISK_VERSION}-addons \
    asterisk${ASTERISK_VERSION}-addons-core \
    asterisk${ASTERISK_VERSION}-addons-mysql \
    asterisk${ASTERISK_VERSION}-addons-bluetooth \
    asterisk${ASTERISK_VERSION}-addons-ooh323 \
    asterisk${ASTERISK_VERSION}-doc \
    asterisk${ASTERISK_VERSION}-g729 \
    asterisk${ASTERISK_VERSION}-res-digium-phone \
    asterisk-version-switch \
    asterisk-sounds-core-en-ulaw \
    # Utilities
    sox lame ffmpeg mpg123 sqlite3 uuid expect \
    net-tools sngrep flite at cron \
    # Apache & PHP 8.2
    apache2 \
    php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-gd \
    php8.2-mbstring php8.2-mysql php8.2-xml php8.2-intl \
    php8.2-soap php8.2-sqlite3 php8.2-bcmath php8.2-zip \
    php8.2-bz2 php8.2-ldap php8.2-ssh2 php8.2-redis \
    php-pear \
    # IonCube (required by FreePBX)
    ioncube-loader-82 \
    # MariaDB client
    mariadb-client \
    # ODBC + runtime libs not pulled as deps
    unixodbc odbc-mariadb liburiparser1 \
    # Node.js & npm
    nodejs npm \
    # Redis
    redis-server \
    # Security
    ipset iptables fail2ban \
    # Mail
    postfix libsasl2-modules mailutils \
    # Misc
    logrotate incron \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Configure asterisk user, Apache, PHP
RUN set -eux \
  # Asterisk user (may already exist from package)
  && (getent group asterisk || groupadd -r asterisk) \
  && (id asterisk 2>/dev/null || useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk) \
  && usermod -aG audio,dialout asterisk \
  # Directories
  && mkdir -p /var/run/asterisk /var/lib/asterisk/moh /var/lib/asterisk/sounds \
             /var/log/asterisk /var/spool/asterisk /etc/asterisk /tftpboot \
             /var/lib/php/session \
  && touch /etc/asterisk/extconfig_custom.conf \
          /etc/asterisk/extensions_override_freepbx.conf \
          /etc/asterisk/extensions_additional.conf \
          /etc/asterisk/extensions_custom.conf \
  && chown -R asterisk:asterisk /var/run/asterisk /var/lib/asterisk \
       /var/log/asterisk /var/spool/asterisk /etc/asterisk /tftpboot \
       /var/www/html /var/lib/php/session \
  # Apache config (matches official sng_freepbx_debian_install.sh)
  && a2enmod ssl rewrite expires \
  && sed -i 's/\(APACHE_RUN_USER=\)\(.*\)/\1asterisk/' /etc/apache2/envvars \
  && sed -i 's/\(APACHE_RUN_GROUP=\)\(.*\)/\1asterisk/' /etc/apache2/envvars \
  && sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf \
  && echo "ServerName localhost" >> /etc/apache2/apache2.conf \
  && sed -i 's/\(^ServerTokens \).*/\1Prod/' /etc/apache2/conf-available/security.conf \
  && sed -i 's/\(^ServerSignature \).*/\1Off/' /etc/apache2/conf-available/security.conf \
  && rm -f /var/www/html/index.html \
  # PHP config
  && sed -i 's/\(^upload_max_filesize = \).*/\120M/' /etc/php/8.2/apache2/php.ini \
  && sed -i 's/\(^memory_limit = \).*/\1256M/' /etc/php/8.2/apache2/php.ini \
  && sed -i 's/\(^expose_php = \).*/\1Off/' /etc/php/8.2/apache2/php.ini \
  && sed -i 's/;max_input_vars = 1000/max_input_vars = 2000/' /etc/php/8.2/apache2/php.ini \
  && sed -i 's/;pcre.jit=1/pcre.jit=0/' /etc/php/8.2/apache2/php.ini \
  # IPv4 precedence (matches official script)
  && sed -i 's/^#\s*precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf \
  # OpenSSL compat
  && sed -i 's/^openssl_conf = openssl_init$/openssl_conf = default_conf/' /etc/ssl/openssl.cnf \
  && printf '\n[ default_conf ]\nssl_conf = ssl_sect\n[ssl_sect]\nsystem_default = system_default_sect\n[system_default_sect]\nMinProtocol = TLSv1.2\nCipherString = DEFAULT:@SECLEVEL=1\n' \
       >> /etc/ssl/openssl.cnf

# Install FreePBX at build time using a temp MariaDB
COPY build-freepbx.sh /usr/local/src/build-freepbx.sh
RUN chmod +x /usr/local/src/build-freepbx.sh \
  && /usr/local/src/build-freepbx.sh "${FREEPBX_VERSION}"

# Enable FreePBX Apache/PHP config (matches official sng_freepbx_debian_install.sh)
RUN a2dissite 000-default 2>/dev/null || true \
  && if [ -f /etc/apache2/sites-available/freepbx.conf ]; then \
       a2ensite freepbx; \
     else \
       printf '<VirtualHost *:80>\n  DocumentRoot /var/www/html\n  <Directory /var/www/html>\n    AllowOverride All\n    Require all granted\n  </Directory>\n</VirtualHost>\n' \
         > /etc/apache2/sites-available/freepbx.conf \
       && a2ensite freepbx; \
     fi \
  && a2ensite default-ssl 2>/dev/null || true \
  && phpenmod freepbx 2>/dev/null || true \
  # Redirect / → /admin/ (must be AFTER freepbx package install which overwrites webroot)
  && rm -f /var/www/html/index.html \
  && printf '<?php header("Location: /admin/"); exit; ?>\n' > /var/www/html/index.php \
  && chown asterisk:asterisk /var/www/html/index.php

# Save build-time defaults so the entrypoint can seed empty PVC mounts.
# In k8s, PVCs shadow the image contents — without this, fwconsole and
# all FreePBX module files disappear on first run.
RUN cp -a /etc/asterisk /etc/asterisk-defaults \
  && cp -a /var/lib/asterisk /var/lib/asterisk-defaults

# Copy configs and entrypoint
# Note: odbc.ini is generated at runtime by entrypoint.sh from env vars
COPY config/odbc/odbcinst.ini /etc/odbcinst.ini
COPY config/fail2ban/jail.local /etc/fail2ban/jail.local
COPY config/fail2ban/asterisk.conf /etc/fail2ban/filter.d/asterisk.conf
COPY config/logrotate/asterisk /etc/logrotate.d/asterisk
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 5061/tcp 80 443 10000-20000/udp 8001 8003

# No VOLUME directive — persistence is managed by PVCs in k8s
# and explicit volume mounts in docker-compose.

CMD ["/entrypoint.sh"]
