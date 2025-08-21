# syntax=docker/dockerfile:1.7
FROM php:8.3-apache

# --- Build args ---
ARG MEDIAWIKI_VERSION=1.43.3
ENV MEDIAWIKI_TARBALL=https://releases.wikimedia.org/mediawiki/1.43/mediawiki-1.43.3.tar.gz

# --- Fetch & unpack MediaWiki tarball ---
ENV APACHE_DOCUMENT_ROOT=/var/www/html
RUN set -eux; \
    mkdir -p "${APACHE_DOCUMENT_ROOT}" && \
    curl -fsSL "${MEDIAWIKI_TARBALL}" -o /tmp/mediawiki.tar.gz && \
    tar -xzf /tmp/mediawiki.tar.gz -C "${APACHE_DOCUMENT_ROOT}" --strip-components=1 && \
    rm -f /tmp/mediawiki.tar.gz && \
    chown -R www-data:www-data "${APACHE_DOCUMENT_ROOT}"

# --- Tools & Composer first  ---
RUN set -eux; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* || true; \
  echo 'APT::Keep-Downloaded-Packages "false";' > /etc/apt/apt.conf.d/keep-cache; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates \
  ; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/*


# Install Composer and verify
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
 && php composer-setup.php --install-dir=/usr/local/bin --filename=composer --2 \
 && php -r "unlink('composer-setup.php');" \
 && composer --version

# --- App context ---
WORKDIR /var/www/html



# --- Composer  ---
COPY composer.json composer.lock* /var/www/html/
RUN COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev --prefer-dist --no-interaction --no-progress

# yq for YAML parsing (and git/curl already installed earlier in your Dockerfile)
RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \
     -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

     # ---  credentials for private repos during build ---
ARG GIT_TOKEN
ENV GIT_ASKPASS=/usr/local/bin/git-askpass.sh
RUN printf '#!/bin/sh\nexec echo \"$GIT_TOKEN\"\n' > /usr/local/bin/git-askpass.sh && chmod +x /usr/local/bin/git-askpass.sh


# Copy fetcher + YAML into the image
COPY docker/scripts/extensions-fetch.sh /usr/local/bin/extensions-fetch
RUN chmod +x /usr/local/bin/extensions-fetch
COPY docker/extensions/extensions.yaml /tmp/extensions.yaml

# Fetch extensions/skins during build
# RUN /usr/local/bin/extensions-fetch /tmp/extensions.yaml /var/www/html
RUN GIT_TRACE=1 GIT_CURL_VERBOSE=1 /usr/local/bin/extensions-fetch /tmp/extensions.yaml /var/www/html


# --- System deps for PHP extensions used by MediaWiki ---
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

# --- PHP extensions  ---
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
    ; \
    { \
      echo 'opcache.enable=1'; \
      echo 'opcache.enable_cli=0'; \
      echo 'opcache.jit_buffer_size=0'; \
      echo 'opcache.max_accelerated_files=10000'; \
      echo 'opcache.memory_consumption=192'; \
      echo 'opcache.interned_strings_buffer=16'; \
      echo 'opcache.validate_timestamps=1'; \
      echo 'opcache.revalidate_freq=2'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# --- Apache tweaks ---
RUN a2enmod rewrite headers expires && \
    sed -ri 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf


# --- Create writable dirs commonly used by MW (if you plan to use file cache/uploads) ---
RUN set -eux; \
    install -o www-data -g www-data -d \
      "${APACHE_DOCUMENT_ROOT}/images" \
      "${APACHE_DOCUMENT_ROOT}/cache"

# You will mount LocalSettings.php at runtime, e.g.:
# -v $(pwd)/LocalSettings.php:/var/www/html/LocalSettings.php:ro

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=5 CMD curl -fsS http://localhost/ || exit 1
