# syntax=docker/dockerfile:1.7
# 0.0 Build ImageMagick 7.1.2-2 from source
FROM --platform=linux/amd64 php:8.3-apache AS im-builder
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

# 0.45 Build FFmpeg 8.0 
FROM --platform=linux/amd64 debian:trixie AS ffmpeg-builder
ARG FFMPEG_VER=8.0

# Purge Debian's vulnerable ffmpeg and libav libraries
RUN set -eux; \
  apt-get purge -y 'ffmpeg' 'libav*' 'libsw*' 'libpostproc*' || true; \
  apt-get autoremove -y || true; \
  apt-get autoclean -y || true

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential pkg-config yasm nasm zlib1g-dev libssl-dev; \
  apt-get install -y \
    libx264-dev \
    libx265-dev \
    libvpx-dev \
    libmp3lame-dev \
    libopus-dev; \
  rm -rf /var/lib/apt/lists/*; \
  curl -fsSL -o /tmp/ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"; \
  mkdir -p /tmp/src && tar -xf /tmp/ffmpeg.tar.xz -C /tmp/src --strip-components=1; \
  cd /tmp/src; \
  ./configure \
    --prefix=/usr/local \
    --disable-debug \
    --disable-doc \
    --enable-pic \
    --enable-gpl \
    --enable-nonfree \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libvpx \
    --enable-libmp3lame \
    --enable-libopus; \
  make -j"$(nproc)"; \
  make install; \
  strip /usr/local/bin/ffmpeg /usr/local/bin/ffprobe

# 0.6 Build yq v4.44.3 with patched Go (CVE-2025-22871)
FROM --platform=linux/amd64 golang:1.24.6-bookworm AS yq-builder
ARG YQ_VERSION=v4.44.3
WORKDIR /src
RUN set -eux; \
  apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*; \
  curl -fsSL -o yq.tgz "https://codeload.github.com/mikefarah/yq/tar.gz/refs/tags/${YQ_VERSION}" && \
  tar -xzf yq.tgz --strip-components=1; \
  go build -trimpath -ldflags="-s -w" -o /usr/local/bin/yq .

# 0.8 Pull in Apache PHP 8.3 
FROM --platform=linux/amd64 php:8.3-apache-trixie
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

# 2.5. Bundle MediaWiki vendor deps
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

# 3. Run Tools
RUN set -eux; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* || true; \
  echo 'APT::Keep-Downloaded-Packages "false";' > /etc/apt/apt.conf.d/keep-cache; \
  apt-get update; \
  apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/* && \
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

# 7.1 remove yq for CVEs: 57187 / 58188 
RUN rm -f /usr/local/bin/yq

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
      poppler-utils \
      mariadb-client \
      curl \
      ca-certificates \
      unzip \
      gnupg \
    ; \
    apt-mark manual ghostscript poppler-utils; \
    rm -rf /var/lib/apt/lists/*


# 9.1 Ensure apache2 present and protected from autoremove 
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apache2-bin && rm -rf /var/lib/apt/lists/*; \
  apt-mark manual apache2-bin; \
  ln -sf /usr/sbin/apache2 /usr/local/bin/apache2

# 9.15 Pin base Apache packages so autoremove won't delete them 
RUN set -eux; apt-mark manual apache2 apache2-bin apache2-data apache2-utils

# 9.2 Remove unused audio libs to drop CVEs (libsndfile + pulseaudio client)
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get purge -y libpulse0 libsndfile1 || true; \
  rm -rf /var/lib/apt/lists/*

# 9.5 Install ImageMagick from builder stage (#0)
COPY --from=im-builder /usr/local /usr/local
RUN ldconfig && magick -version | head -n1 | grep -q "ImageMagick 7.1.2-2"

# 9.7 Install FFmpeg from builder stage and verify
COPY --from=ffmpeg-builder /usr/local /usr/local
COPY --from=ffmpeg-builder /usr/lib/x86_64-linux-gnu/libx264.so.* /usr/lib/x86_64-linux-gnu/
COPY --from=ffmpeg-builder /usr/lib/x86_64-linux-gnu/libx265.so.* /usr/lib/x86_64-linux-gnu/
COPY --from=ffmpeg-builder /usr/lib/x86_64-linux-gnu/libvpx.so.*  /usr/lib/x86_64-linux-gnu/
COPY --from=ffmpeg-builder /usr/lib/x86_64-linux-gnu/libmp3lame.so.* /usr/lib/x86_64-linux-gnu/
COPY --from=ffmpeg-builder /usr/lib/x86_64-linux-gnu/libopus.so.* /usr/lib/x86_64-linux-gnu/
RUN apt-get update && apt-get install -y libnuma1 && rm -rf /var/lib/apt/lists/*
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
    apt-get update; \
    apt-get install -y --no-install-recommends wget; \
    rm -rf /var/lib/apt/lists/*; \
    pecl install apcu imagick && \
    pecl install LuaSandbox-4.1.2 && docker-php-ext-enable luasandbox && \
    docker-php-ext-enable apcu imagick

# 10.5 Provide extension deps without touching core's composer.json/lock
COPY composer.local.json /var/www/html/composer.local.json
RUN COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev --prefer-dist --no-interaction --no-progress \
 && chown -R www-data:www-data /var/www/html

# 11. Apache tweaks
RUN a2enmod rewrite headers expires && \
    sed -ri 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf && \
    sed -i 's#</VirtualHost>#\tAllowEncodedSlashes NoDecode\n</VirtualHost>#' /etc/apache2/sites-available/000-default.conf

# 11.5 Allow .htaccess overrides <- Not sure this is working
RUN printf "<Directory /var/www/html>\nAllowOverride All\n</Directory>\n" \
      > /etc/apache2/conf-available/override.conf && a2enconf override

# 12. Writable dirs for file cache/uploads
RUN set -eux; \
    install -o www-data -g www-data -d \
      "${APACHE_DOCUMENT_ROOT}/images" \
      "${APACHE_DOCUMENT_ROOT}/cache"

# 13. Note Install path for Vendor files! < - feels like this should be with the vendor block above?
ENV MW_COMPOSER_VENDOR_DIR=/var/www/html/vendor

# 14. Expose the port & provide healthcheck <- purpose of the health check? 
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=5 CMD curl -fsS http://localhost/ || exit 1

# 15. PHP overrides <- not using this yet
COPY docker/php/php-overrides.ini /usr/local/etc/php/conf.d/99-overrides.ini

# 16 Ensure apache2 is on PATH for apache2-foreground to prevent cycling cont
RUN set -eux; \
  if ! command -v apache2 >/dev/null 2>&1; then \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apache2-bin && rm -rf /var/lib/apt/lists/*; \
  fi; \
  ln -sf /usr/sbin/apache2 /usr/local/bin/apache2; \
  command -v apache2

# 17. Pin Apache so cleanup won't remove it again (only if installed) (fix CVE-2025-9086)
RUN set -eux; \
  for p in apache2 apache2-bin apache2-data apache2-utils; do \
    if dpkg -s "$p" >/dev/null 2>&1; then apt-mark manual "$p"; fi; \
  done

# 18. Install ConvertPDF2Wiki runtime dependencies (pandoc + pdf2docx)
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        pandoc; \
    pip3 install --no-cache-dir --break-system-packages pdf2docx; \
    rm -rf /var/lib/apt/lists/*

# 18.5 Remove Python runtime (eliminate CVE-2025-8194 package flags)
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get purge -y python3-pygments python3.13 python3.13-minimal libpython3.13-stdlib libpython3.13-minimal python3 || true; \
  rm -rf /var/lib/apt/lists/*

# 19 remove vulnerable ffmpeg libraries introduced from pip (ConvertPDF2Wiki)
RUN set -eux; \
  find /usr/local/lib -type f \( \
    -name 'libav*' -o \
    -name 'libsw*' -o \
    -name 'libpostproc*' \
  \) -delete || true; \
  find /usr/local/lib -type d -name 'opencv_python_headless.libs' -exec rm -rf {} + || true;

# 20 Remove Cygwin References (CVE-2016-3067) 
RUN set -eux; \
  rm -rf /var/www/html/vendor/james-heinrich/getid3/helperapps || true; \
  rm -f /var/www/html/vendor/james-heinrich/getid3/getid3/module.audio.shorten.php || true; \
  rm -rf /usr/share/man /usr/share/doc || true; \
  rm -rf /usr/share/vim/*/doc || true; \
  rm -rf /usr/share/zsh/help || true; \
  find /usr/share/terminfo -type f -iname 'cygwin*' -delete || true
