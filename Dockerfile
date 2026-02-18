FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

ARG ASTERISK_VERSION=21
ARG FREEPBX_VERSION=17

WORKDIR /usr/src

# Install base dependencies and PHP 8.2
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build tools
    build-essential pkg-config automake autoconf libtool libtool-bin \
    bison flex \
    # General utilities
    curl wget git subversion ca-certificates gnupg lsb-release cron \
    sox lame ffmpeg mpg123 sqlite3 uuid expect unixodbc \
    # Libraries for Asterisk
    libssl-dev libncurses5-dev libnewt-dev libsqlite3-dev \
    libjansson-dev libxml2-dev libxslt1-dev uuid-dev \
    default-libmysqlclient-dev libasound2-dev libogg-dev \
    libvorbis-dev libicu-dev libcurl4-openssl-dev libical-dev \
    libneon27-dev libsrtp2-dev libspandsp-dev \
    unixodbc-dev odbc-mariadb \
    # Apache & PHP 8.2
    apache2 \
    php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-gd \
    php8.2-mbstring php8.2-mysql php8.2-xml php8.2-intl \
    php8.2-soap php8.2-sqlite3 php8.2-bcmath php8.2-zip \
    php-pear \
    # MariaDB client
    mariadb-client \
    # Node.js & npm
    nodejs npm \
    # Security
    ipset iptables fail2ban \
    # Mail
    postfix libsasl2-modules mailutils \
    # Misc
    logrotate certbot python3-certbot-apache \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Download and build Asterisk
RUN set -eux \
  && cd /usr/src \
  && curl -fsSL "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}-current.tar.gz" -o asterisk.tar.gz \
  && tar -xzf asterisk.tar.gz \
  && rm asterisk.tar.gz \
  && cd asterisk-${ASTERISK_VERSION}.*/ \
  && contrib/scripts/get_mp3_source.sh \
  && ./configure --libdir=/usr/lib64 --with-pjproject-bundled --with-jansson-bundled \
  && make menuselect.makeopts \
  && menuselect/menuselect \
       --disable BUILD_NATIVE \
       --enable format_mp3 \
       menuselect.makeopts \
  && make -j"$(nproc)" \
  && make install \
  && make samples \
  && ldconfig

# Create asterisk user and set permissions
RUN groupadd -r asterisk \
  && useradd -r -d /var/lib/asterisk -g asterisk asterisk \
  && usermod -aG audio,dialout asterisk \
  && chown -R asterisk:asterisk /etc/asterisk \
  && chown -R asterisk:asterisk /var/lib/asterisk \
  && chown -R asterisk:asterisk /var/log/asterisk \
  && chown -R asterisk:asterisk /var/spool/asterisk \
  && chown -R asterisk:asterisk /usr/lib64/asterisk \
  && echo "/usr/lib64" >> /etc/ld.so.conf.d/x86_64-linux-gnu.conf \
  && ldconfig

# Configure Asterisk to run as asterisk user
RUN sed -i 's|;runuser|runuser|' /etc/asterisk/asterisk.conf \
  && sed -i 's|;rungroup|rungroup|' /etc/asterisk/asterisk.conf

# Configure Apache for FreePBX
RUN sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf \
  && sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf \
  && echo "ServerName localhost" >> /etc/apache2/apache2.conf \
  && a2enmod rewrite \
  && rm -f /var/www/html/index.html

# Configure PHP for FreePBX
RUN sed -i 's/\(^upload_max_filesize = \).*/\120M/' /etc/php/8.2/apache2/php.ini \
  && sed -i 's/\(^memory_limit = \).*/\1256M/' /etc/php/8.2/apache2/php.ini \
  && (grep -q '^max_input_vars' /etc/php/8.2/apache2/php.ini \
      && sed -i 's/\(^max_input_vars = \).*/\110000/' /etc/php/8.2/apache2/php.ini \
      || sed -i 's/;.*max_input_vars.*/max_input_vars = 10000/' /etc/php/8.2/apache2/php.ini)

# Download FreePBX
RUN set -eux \
  && cd /usr/local/src \
  && curl -fsSL "https://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}.0-latest.tgz" -o freepbx.tgz \
  && tar -xzf freepbx.tgz \
  && rm freepbx.tgz

# Clean up build artifacts
RUN rm -rf /usr/src/asterisk-${ASTERISK_VERSION}.*/ \
  && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /usr/local/src

# Copy configuration files
COPY config/odbc/odbcinst.ini /etc/odbcinst.ini
COPY config/odbc/odbc.ini /etc/odbc.ini
COPY config/fail2ban/jail.local /etc/fail2ban/jail.local
COPY config/fail2ban/asterisk.conf /etc/fail2ban/filter.d/asterisk.conf
COPY config/logrotate/asterisk /etc/logrotate.d/asterisk
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
  && mkdir -p /var/log/asterisk \
  && touch /var/log/asterisk/full \
  && chown -R asterisk:asterisk /var/log/asterisk

# SIP/PJSIP signaling
EXPOSE 5060/udp 5060/tcp 5061/tcp
# HTTP/HTTPS for web UI
EXPOSE 80 443
# RTP media (configurable range)
EXPOSE 10000-20000/udp
# UCP WebSocket
EXPOSE 8001 8003

VOLUME ["/etc/asterisk", "/var/lib/asterisk", "/var/spool/asterisk", "/var/log/asterisk"]

CMD ["/entrypoint.sh"]
