################################################################################
# Stage 1: Build Asterisk from source
################################################################################
FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
ARG ASTERISK_VERSION=21

WORKDIR /usr/src

# Install build-only dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config automake autoconf autoconf-archive \
    libtool libtool-bin bison flex patch bzip2 xmlstarlet \
    python-dev-is-python3 curl wget git subversion ca-certificates \
    libssl-dev libncurses5-dev libnewt-dev libsqlite3-dev \
    libjansson-dev libxml2-dev libxslt1-dev uuid-dev zlib1g-dev \
    default-libmysqlclient-dev libasound2-dev libogg-dev \
    libvorbis-dev libicu-dev libcurl4-openssl-dev libical-dev \
    libneon27-dev libsrtp2-dev libspandsp-dev libedit-dev \
    libspeex-dev libspeexdsp-dev liburiparser-dev libcap-dev \
    libsnmp-dev libldap2-dev libfftw3-dev libsndfile1-dev \
    libcodec2-dev libunbound-dev libgsm1-dev libpopt-dev \
    libresample1-dev libc-client2007e-dev libgmime-3.0-dev \
    liblua5.2-dev libbluetooth-dev libradcli-dev libiksemel-dev \
    libpq-dev freetds-dev binutils-dev unixodbc-dev \
  && rm -rf /var/lib/apt/lists/*

# Download, build, and install Asterisk
RUN set -eux \
  && curl -fsSL "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}-current.tar.gz" -o asterisk.tar.gz \
  && tar -xzf asterisk.tar.gz && rm asterisk.tar.gz \
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

################################################################################
# Stage 2: Runtime image
################################################################################
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ARG FREEPBX_VERSION=17

# Install runtime dependencies only (no -dev packages, no build tools)
RUN apt-get update \
  && echo "postfix postfix/mailname string freepbx.localdomain" | debconf-set-selections \
  && echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections \
  && apt-get install -y --no-install-recommends \
    # Runtime libraries needed by Asterisk
    curl ca-certificates gnupg \
    libssl3 libncurses6 libnewt0.52 libsqlite3-0 \
    libjansson4 libxml2 libxslt1.1 libuuid1 zlib1g \
    default-mysql-client-core libasound2 libogg0 \
    libvorbis0a libvorbisenc2 libicu72 libcurl4 libical3 \
    libneon27-gnutls libsrtp2-1 libspandsp2 libedit2 \
    libspeex1 libspeexdsp1 liburiparser1 libcap2 \
    libsnmp40 libldap-2.5-0 libfftw3-single3 libsndfile1 \
    libcodec2-1.0 libunbound8 libgsm1 libpopt0 \
    libresample1 libc-client2007e libgmime-3.0-0 \
    liblua5.2-0 libbluetooth3 libradcli4 libiksemel3 \
    libpq5 libct4 \
    unixodbc odbc-mariadb \
    # Utilities
    sox lame ffmpeg mpg123 sqlite3 uuid expect sudo \
    net-tools sngrep flite at cron \
    # Apache & PHP 8.2
    apache2 \
    php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-gd \
    php8.2-mbstring php8.2-mysql php8.2-xml php8.2-intl \
    php8.2-soap php8.2-sqlite3 php8.2-bcmath php8.2-zip \
    php8.2-bz2 php8.2-ldap php8.2-ssh2 php8.2-redis \
    php-pear \
    # MariaDB client
    mariadb-client \
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

# Copy Asterisk from builder
COPY --from=builder /usr/sbin/asterisk /usr/sbin/
COPY --from=builder /usr/lib64/asterisk/ /usr/lib64/asterisk/
COPY --from=builder /var/lib/asterisk/ /var/lib/asterisk/
COPY --from=builder /var/spool/asterisk/ /var/spool/asterisk/
COPY --from=builder /var/log/asterisk/ /var/log/asterisk/
COPY --from=builder /etc/asterisk/ /etc/asterisk/
COPY --from=builder /usr/sbin/rasterisk /usr/sbin/
COPY --from=builder /usr/sbin/astcanary /usr/sbin/
COPY --from=builder /usr/sbin/astdb2sqlite3 /usr/sbin/
COPY --from=builder /usr/sbin/astdb2bdb /usr/sbin/

# Create asterisk user, configure services, download FreePBX — single layer
RUN set -eux \
  # Asterisk user
  && groupadd -r asterisk \
  && useradd -r -d /var/lib/asterisk -g asterisk asterisk \
  && usermod -aG audio,dialout asterisk \
  && chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk \
       /var/log/asterisk /var/spool/asterisk /usr/lib64/asterisk \
  && echo "/usr/lib64" >> /etc/ld.so.conf.d/x86_64-linux-gnu.conf \
  && ldconfig \
  # Asterisk config
  && sed -i 's|;runuser|runuser|' /etc/asterisk/asterisk.conf \
  && sed -i 's|;rungroup|rungroup|' /etc/asterisk/asterisk.conf \
  # Apache config
  && sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf \
  && sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf \
  && echo "ServerName localhost" >> /etc/apache2/apache2.conf \
  && a2enmod rewrite \
  && rm -f /var/www/html/index.html \
  # PHP config
  && sed -i 's/\(^upload_max_filesize = \).*/\120M/' /etc/php/8.2/apache2/php.ini \
  && sed -i 's/\(^memory_limit = \).*/\1256M/' /etc/php/8.2/apache2/php.ini \
  && (grep -q '^max_input_vars' /etc/php/8.2/apache2/php.ini \
      && sed -i 's/\(^max_input_vars = \).*/\110000/' /etc/php/8.2/apache2/php.ini \
      || sed -i 's/;.*max_input_vars.*/max_input_vars = 10000/' /etc/php/8.2/apache2/php.ini) \
  # Download FreePBX
  && curl -fsSL "https://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}.0-latest.tgz" \
       -o /usr/local/src/freepbx.tgz \
  && tar -xzf /usr/local/src/freepbx.tgz -C /usr/local/src \
  && rm /usr/local/src/freepbx.tgz \
  # Log directory
  && mkdir -p /var/log/asterisk \
  && touch /var/log/asterisk/full \
  && chown -R asterisk:asterisk /var/log/asterisk

# Copy configs and entrypoint — single layer
COPY config/odbc/odbcinst.ini /etc/odbcinst.ini
COPY config/odbc/odbc.ini /etc/odbc.ini
COPY config/fail2ban/jail.local /etc/fail2ban/jail.local
COPY config/fail2ban/asterisk.conf /etc/fail2ban/filter.d/asterisk.conf
COPY config/logrotate/asterisk /etc/logrotate.d/asterisk
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 5061/tcp 80 443 10000-20000/udp 8001 8003

VOLUME ["/etc/asterisk", "/var/lib/asterisk", "/var/spool/asterisk", "/var/log/asterisk"]

CMD ["/entrypoint.sh"]
