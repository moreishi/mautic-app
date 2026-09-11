# syntax=docker/dockerfile:1
# Mautic 7.2 production image for Coolify
# Build from repo root: docker build -t mautic-app .
# Base matches official mautic/mautic:7.2-apache (PHP 8.3) and composer platform php 8.2+
ARG PHP_TAG=8.3-apache-bookworm
FROM php:${PHP_TAG}

LABEL org.opencontainers.image.title="loucent-mautic" \
      org.opencontainers.image.description="Mautic 7.2 marketing automation for Coolify" \
      org.opencontainers.image.vendor="Loucent"

ENV APACHE_DOCUMENT_ROOT=/var/www/html \
    COMPOSER_ALLOW_SUPERUSER=1 \
    APP_ENV=prod \
    APP_DEBUG=0

# --- System deps + PHP extensions (Mautic requires imap, gd, intl, pdo_mysql, zip, opcache, ...) ---
# Use mlocati installer (same as official docker-mautic) for reliable builds
ARG IPE_VERSION=2.9.28
ARG IPE_SHA256=2f5970453effac47cfcceafd6103948d78b566c2fb922a8ff639fe249db74aa7
RUN apt-get update && apt-get upgrade -y \
    && apt-get install --no-install-recommends -y \
        cron \
        git \
        unzip \
        zip \
        curl \
        mariadb-client \
        supervisor \
        libavif15 \
        libfreetype6 \
        libjpeg62-turbo \
        libpng16-16 \
        libwebp7 \
        libc-client2007e \
        libxpm4 \
        libzip4 \
    && curl -fsSL https://github.com/mlocati/docker-php-extension-installer/releases/download/${IPE_VERSION}/install-php-extensions \
        -o /usr/local/bin/install-php-extensions \
    && echo "${IPE_SHA256}  /usr/local/bin/install-php-extensions" | sha256sum -c - \
    && chmod +x /usr/local/bin/install-php-extensions \
    && install-php-extensions \
        bcmath \
        curl \
        exif \
        gd \
        imap \
        intl \
        mbstring \
        mysqli \
        opcache \
        pdo_mysql \
        sockets \
        zip \
    && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /etc/cron.daily/*

# Apache: rewrite for Mautic pretty URLs. Docroot is repo root (index.php in /var/www/html).
RUN a2enmod rewrite headers expires \
    && sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
    && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Node 24 for asset builds (matches .ddev nodejs_version 24)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g npm@latest \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html

# Install PHP deps first (better layer caching). Path repo ./app provides mautic/core-lib.
# --no-scripts: composer scripts need the full source + node, they run explicitly below.
COPY composer.json composer.lock ./
COPY app/composer.json ./app/composer.json
COPY patches ./patches
RUN composer install --no-dev --prefer-dist --no-progress --no-interaction --optimize-autoloader --no-scripts

# Copy application source
COPY . .

# Production PHP tweaks
COPY docker/php-coolify.ini /usr/local/etc/php/conf.d/zz-coolify.ini

# Build frontend assets + Mautic assets. Prod zip has no build/gjs_build.php, so skip that script.
# npx patch-package replaces the composer post-install script of the same name
# (applies patches/at.js + patches/chosen-js to node_modules).
RUN npm ci --prefer-offline --no-audit \
    && npx patch-package \
    && npm run build \
    && php bin/console mautic:assets:generate --env=prod --no-interaction \
    && php bin/console cache:warmup --env=prod --no-interaction \
    && chown -R www-data:www-data /var/www/html/var /var/www/html/media/files /var/www/html/media/images \
    && chmod -R ug+rw /var/www/html/var \
    && rm -rf /root/.npm /root/.cache /tmp/*

# Cron + supervisor (cron/worker roles reuse same image with different CMD)
COPY docker/mautic.crontab /etc/cron.d/mautic
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN chmod 644 /etc/cron.d/mautic

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost/s/login -o /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
