# syntax=docker/dockerfile:1.7
# 0. Build ImageMagick 7.1.2-2 from source
FROM php:8.3-apache AS im-builder
ARG IM_VERSION=7.1.2-2
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl pkg-config \
    libjpeg-dev libpng-dev libwebp-dev libxml2-dev libzip-dev zlib1g-dev; \
  rm -rf /var/lib/apt/lists/*; \
  curl -fsSL -o /tmp/im.tgz https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IM_VERSION}.tar.gz; \
  tar -xzf /tmp/im.tgz -C /tmp; \
  cd /tmp/ImageMagick-${IM_VERSION}; \
  ./configure --prefix=/usr/local --enable-shared \
    --with-jpeg=yes --with-png=yes --with-webp=yes --with-xml=yes --with-zip; \
  make -j"$(nproc)"; \
  make install; \
  ldconfig

# 0.3 
FROM debian:trixie AS cjson-builder
ARG CJSON_VER=1.7.19
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates curl build-essential cmake pkg-config; \
  curl -fsSL -o /tmp/cjson.tgz https://github.com/DaveGamble/cJSON/archive/refs/tags/v${CJSON_VER}.tar.gz; \
  mkdir -p /tmp/src && tar -xzf /tmp/cjson.tgz -C /tmp/src --strip-components=1; \
  cmake -S /tmp/src -B /tmp/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu; \
  cmake --build /tmp/build -j"$(nproc)"; \
  DESTDIR=/tmp/pkgroot cmake --install /tmp/build --prefix /usr; \
  install -d /tmp/pkgroot/DEBIAN; \
  printf "Package: libcjson1\nVersion: %s-0~custom1\nSection: libs\nPriority: optional\nArchitecture: arm64\nDepends: libc6 (>= 2.17)\nMaintainer: KB <kimberly.brewer.11.ctr@spaceforce.mil>\nDescription: Ultralightweight JSON parser in ANSI C (custom build)\n" "$CJSON_VER" > /tmp/pkgroot/DEBIAN/control; \
  dpkg-deb --build /tmp/pkgroot /tmp/libcjson1_${CJSON_VER}-0~custom1_arm64.deb

# 0.45 Build FFmpeg 8.0 (includes fix for CVE-2025-1594)
# Ref: FFmpeg security page lists CVE-2025-1594 fixed (ticket/11418, commit f98f142) and 8.0 is current stable.
FROM debian:trixie AS ffmpeg-builder
ARG FFMPEG_VER=8.0
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential pkg-config yasm nasm zlib1g-dev libssl-dev; \
  curl -fsSL -o /tmp/ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"; \
  mkdir -p /tmp/src && tar -xf /tmp/ffmpeg.tar.xz -C /tmp/src --strip-components=1; \
  cd /tmp/src; \
  ./configure --prefix=/usr/local --disable-debug --disable-doc --enable-pic; \
  make -j"$(nproc)"; \
  make install; \
  strip /usr/local/bin/ffmpeg /usr/local/bin/ffprobe


# 0.4 Build yq v4.44.3 with patched Go (fixes CVE-2025-22871 exposure)
FROM golang:1.24.6-bookworm AS yq-builder
ARG YQ_VERSION=v4.44.3
WORKDIR /src
RUN set -eux; \
  apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*; \
  curl -fsSL -o yq.tgz "https://github.com/mikefarah/yq/archive/refs/tags/${YQ_VERSION}.tar.gz"; \
  tar -xzf yq.tgz --strip-components=1; \
  go build -trimpath -ldflags="-s -w" -o /usr/local/bin/yq .



# 0.5 Pull in Apache PHP 8.3 
FROM php:8.3-apache

# 1. --- Build args ---
ARG MEDIAWIKI_VERSION=1.43.3
ENV MEDIAWIKI_TARBALL=https://releases.wikimedia.org/mediawiki/1.43/mediawiki-1.43.3.tar.gz

# 2. Fetch & unpack MediaWiki
ENV APACHE_DOCUMENT_ROOT=/var/www/html
RUN set -eux; \
    mkdir -p "${APACHE_DOCUMENT_ROOT}" && \
    curl -fsSL "${MEDIAWIKI_TARBALL}" -o /tmp/mediawiki.tar.gz && \
    tar -xzf /tmp/mediawiki.tar.gz -C "${APACHE_DOCUMENT_ROOT}" --strip-components=1 && \
    rm -f /tmp/mediawiki.tar.gz && \
    chown -R www-data:www-data "${APACHE_DOCUMENT_ROOT}" && \
    chown -R www-data:www-data "${APACHE_DOCUMENT_ROOT}/vendor"


# 2.5. Bundle MediaWiki vendor deps (match 1.43.x with REL1_43)
ARG MEDIAWIKI_VENDOR_BRANCH=REL1_43
RUN set -eux; \
    curl -fsSL "https://codeload.github.com/wikimedia/mediawiki-vendor/tar.gz/refs/heads/${MEDIAWIKI_VENDOR_BRANCH}" -o /tmp/vendor.tgz && \
    tar -xzf /tmp/vendor.tgz -C /tmp && \
    rm -rf "${APACHE_DOCUMENT_ROOT}/vendor" && \
    mv /tmp/mediawiki-vendor-* "${APACHE_DOCUMENT_ROOT}/vendor" && \
    rm -rf /tmp/vendor.tgz /tmp/mediawiki-vendor-* && \
    # sanity checks
    test -f "${APACHE_DOCUMENT_ROOT}/vendor/autoload.php" && \
    test -d "${APACHE_DOCUMENT_ROOT}/vendor/psr/log" && \
    chown -R www-data:www-data "${APACHE_DOCUMENT_ROOT}/vendor"

# 2.7 Strip Windows-only helper apps to eliminate Cygwin DLL (CVE-2016-3067)
RUN set -eux; \
  rm -rf /var/www/html/vendor/james-heinrich/getid3/helperapps


# 3. Run Tools
RUN set -eux; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* || true; \
  echo 'APT::Keep-Downloaded-Packages "false";' > /etc/apt/apt.conf.d/keep-cache; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
      git ca-certificates \
  ; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/* && \
  git config --global --add safe.directory /var/www/html || true

# 4. Add Working Directory
WORKDIR /var/www/html

# 6. yq for YAML parsing (rebuilt with Go 1.24.6)
COPY --from=yq-builder /usr/local/bin/yq /usr/local/bin/yq

# 7. Install Extensions
COPY docker/scripts/extensions-fetch.sh /usr/local/bin/extensions-fetch
RUN chmod +x /usr/local/bin/extensions-fetch
COPY docker/extensions/extensions.yaml /tmp/extensions.yaml
RUN /usr/local/bin/extensions-fetch /tmp/extensions.yaml /var/www/html

# 8. Run Composer
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
 && php composer-setup.php --install-dir=/usr/local/bin --filename=composer --2 \
 && php -r "unlink('composer-setup.php');" \
 && composer --version

# 9. Run System Dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libicu-dev \
      libjpeg-dev \
      libpng-dev \
      libwebp-dev \
      libfreetype6-dev \
      libzip-dev \
      zlib1g-dev \
      libonig-dev \
      librsvg2-bin \
      libxml2-dev \
      liblua5.1-0-dev \
      pkg-config \
      ghostscript \
      mariadb-client \
      curl \
      ca-certificates \
      unzip \
      gnupg \
    ; \
    rm -rf /var/lib/apt/lists/*

# 9.2 Remove unused audio libs to drop CVEs (libsndfile + pulseaudio client)
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get purge -y libpulse0 libsndfile1 || true; \
  apt-get autoremove -y; \
  rm -rf /var/lib/apt/lists/*

# 9.3 Remove Python runtime (eliminate CVE-2025-8194 package flags)
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get purge -y python3-pygments python3.13 python3.13-minimal libpython3.13-stdlib libpython3.13-minimal python3 || true; \
  apt-get autoremove -y; \
  rm -rf /var/lib/apt/lists/*

# 9.4 Remove doc/help entries that can trigger Cygwin signatures
RUN set -eux; \
  rm -rf /usr/share/man /usr/share/doc || true; \
  rm -rf /usr/share/vim/*/doc || true; \
  rm -rf /usr/share/zsh/help || true; \
  find /usr/share/terminfo -type f -iname 'cygwin*' -delete || true

# 9.45 Upgrade libcjson1 to 1.7.19 (fix CVE-2025-57052)
COPY --from=cjson-builder /tmp/libcjson1_1.7.19-0~custom1_arm64.deb /tmp/libcjson1.deb
RUN set -eux; \
    dpkg -i /tmp/libcjson1.deb; \
    ldconfig; \
    apt-mark hold libcjson1; \
    dpkg -s libcjson1 | grep -q '^Version: 1.7.19-0~custom1'; \
    rm -f /tmp/libcjson1.deb


# 9.5 Install ImageMagick from builder stage (#0)
COPY --from=im-builder /usr/local /usr/local
RUN ldconfig && magick -version | head -n1 | grep -q "ImageMagick 7.1.2-2"

# 9.7 Install FFmpeg from builder stage and verify
COPY --from=ffmpeg-builder /usr/local /usr/local
RUN ldconfig && ffmpeg -version | head -n1 | grep -q "^ffmpeg version 8.0"



# 10. Run PHP Extensions
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      gd \
      intl \
      mbstring \
      mysqli \
      opcache \
      xml \
      zip \
      exif \
      pdo_mysql \
      calendar \
    ; 

# 10.1 Ensure pecl imagick finds MagickWand-7 from /usr/local
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

# 10.2 PECL extensions
RUN set -eux; \
    pecl install apcu imagick && \
    pecl install LuaSandbox-4.1.2 && docker-php-ext-enable luasandbox && \
    docker-php-ext-enable apcu imagick

# 10.5 Provide extension deps without touching core's composer.json/lock
COPY composer.local.json /var/www/html/composer.local.json
RUN COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev --prefer-dist --no-interaction --no-progress \
 && chown -R www-data:www-data /var/www/html

# 10.6 Remove Windows-only helper apps from getID3 (post-composer) 
RUN set -eux; \
  rm -rf /var/www/html/vendor/james-heinrich/getid3/helperapps; \
  rm -f /var/www/html/vendor/james-heinrich/getid3/getid3/module.audio.shorten.php

# 11. Apache tweaks
RUN a2enmod rewrite headers expires && \
    sed -ri 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf && \
    sed -i 's#</VirtualHost>#\tAllowEncodedSlashes NoDecode\n</VirtualHost>#' /etc/apache2/sites-available/000-default.conf

# 11.5 Allow .htaccess overrides
RUN printf "<Directory /var/www/html>\nAllowOverride All\n</Directory>\n" \
      > /etc/apache2/conf-available/override.conf && a2enconf override

# 12. Writable dirs for file cache/uploads
RUN set -eux; \
    install -o www-data -g www-data -d \
      "${APACHE_DOCUMENT_ROOT}/images" \
      "${APACHE_DOCUMENT_ROOT}/cache"

# 13. Note Install path for Vendor files!
ENV MW_COMPOSER_VENDOR_DIR=/var/www/html/vendor


# 14. Expose the port & provide healthcheck
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=5 CMD curl -fsS http://localhost/ || exit 1

# 15. PHP overrides 
COPY docker/php/php-overrides.ini /usr/local/etc/php/conf.d/99-overrides.ini

# 16. Updates to pass Grype-Scan








 

