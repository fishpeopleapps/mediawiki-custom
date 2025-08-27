# syntax=docker/dockerfile:1.7
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
    test -d "${APACHE_DOCUMENT_ROOT}/vendor/psr/log"


# 3. Run Tools
RUN set -eux; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* || true; \
  echo 'APT::Keep-Downloaded-Packages "false";' > /etc/apt/apt.conf.d/keep-cache; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates \
  ; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/* && \
  git config --global --add safe.directory /var/www/html || true

# 4. Add Working Directory
WORKDIR /var/www/html

# 6. yq for YAML parsing
RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \
     -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# 7. Install Extensions
COPY docker/scripts/extensions-fetch.sh /usr/local/bin/extensions-fetch
RUN chmod +x /usr/local/bin/extensions-fetch
COPY docker/extensions/extensions.yaml /tmp/extensions.yaml
RUN GIT_TRACE=1 GIT_CURL_VERBOSE=1 /usr/local/bin/extensions-fetch /tmp/extensions.yaml /var/www/html

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
      libfreetype6-dev \
      libzip-dev \
      zlib1g-dev \
      libonig-dev \
      libxml2-dev \
      imagemagick \
      ghostscript \
      ffmpeg \
      mariadb-client \
      curl \
      ca-certificates \
      unzip \
      gnupg \
    ; \
    rm -rf /var/lib/apt/lists/*

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

# 10.5 Provide extension deps without touching core's composer.json/lock
COPY composer.local.json /var/www/html/composer.local.json
RUN COMPOSER_ALLOW_SUPERUSER=1 composer update \
    --no-dev --prefer-dist --no-interaction --no-progress

# 11. Apache tweaks
RUN a2enmod rewrite headers expires && \
    sed -ri 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

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
