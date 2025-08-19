# syntax=docker/dockerfile:1.7
FROM php:8.3-apache

# --- Build args (tune these per environment) ---
ARG MEDIAWIKI_VERSION=1.43.1
ARG MEDIAWIKI_TARBALL=https://releases.wikimedia.org/mediawiki/${MEDIAWIKI_VERSION%.*}/mediawiki-${MEDIAWIKI_VERSION}.tar.gz

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

# Document root will be the MediaWiki directory
ENV APACHE_DOCUMENT_ROOT=/var/www/html

WORKDIR /var/www

# --- Fetch & unpack MediaWiki tarball ---
RUN set -eux; \
    curl -fsSL "${MEDIAWIKI_TARBALL}" -o /tmp/mediawiki.tar.gz; \
    tar -xzf /tmp/mediawiki.tar.gz -C /var/www; \
    rm /tmp/mediawiki.tar.gz; \
    mv /var/www/mediawiki-${MEDIAWIKI_VERSION}/* "${APACHE_DOCUMENT_ROOT}/"; \
    rm -rf /var/www/mediawiki-${MEDIAWIKI_VERSION} \
    chown -R www-data:www-data "${APACHE_DOCUMENT_ROOT}"

# --- Create writable dirs commonly used by MW (if you plan to use file cache/uploads) ---
RUN set -eux; \
    install -o www-data -g www-data -d \
      "${APACHE_DOCUMENT_ROOT}/images" \
      "${APACHE_DOCUMENT_ROOT}/cache"

# You will mount LocalSettings.php at runtime, e.g.:
# -v $(pwd)/LocalSettings.php:/var/www/html/LocalSettings.php:ro

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=5 CMD curl -fsS http://localhost/ || exit 1
