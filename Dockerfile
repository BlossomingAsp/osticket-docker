# Stage: bundle osTicket community plugins (hydrated with their composer
# deps) so the runtime image can provision them into the include/ volume.
FROM php:8.3-cli-bookworm AS plugin-builder

# Pinned commit on the osTicket-plugins 1.17.x branch (targets the 1.18 API).
ARG PLUGINS_COMMIT=adfef052c2aeab4d67e4892c30d2ede27e6ea627

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends unzip curl; \
    rm -rf /var/lib/apt/lists/*

# make.php hydrate resolves the plugins' composer deps (league/oauth2-client,
# sonata/google-authenticator, ...) into each plugin folder's lib/.
RUN set -eux; \
    curl -fsSL -o /tmp/plugs.zip \
        "https://codeload.github.com/osTicket/osTicket-plugins/zip/${PLUGINS_COMMIT}"; \
    unzip -q /tmp/plugs.zip -d /tmp; \
    cd "/tmp/osTicket-plugins-${PLUGINS_COMMIT}"; \
    php make.php hydrate; \
    mkdir -p /opt/osticket-plugins; \
    cp -r auth-oauth2 auth-2fa /opt/osticket-plugins/; \
    rm -rf /tmp/plugs.zip "/tmp/osTicket-plugins-${PLUGINS_COMMIT}"

FROM php:8.3-apache-bookworm

ARG OSTICKET_VERSION=1.18.4

ENV APACHE_DOCUMENT_ROOT=/var/www/html \
    DEBIAN_FRONTEND=noninteractive

# System build deps for PHP extensions osTicket needs
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libc-client2007e-dev \
        libcurl4-openssl-dev \
        libfreetype6-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libkrb5-dev \
        libonig-dev \
        libpng-dev \
        libssl-dev \
        libxml2-dev \
        libzip-dev \
        zlib1g-dev \
        gettext \
        unzip \
        curl \
    ; \
    rm -rf /var/lib/apt/lists/*

# Configure + install osTicket's required/recommended PHP extensions
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-configure imap --with-kerberos --with-imap-ssl; \
    docker-php-ext-install -j"$(nproc)" \
        gd \
        gettext \
        imap \
        intl \
        mysqli \
        pdo_mysql \
        zip \
    ; \
    pecl install apcu; \
    docker-php-ext-enable apcu; \
    rm -rf /tmp/pear

# Apache: enable the modules osTicket's .htaccess relies on
RUN set -eux; \
    a2enmod rewrite headers; \
    echo "ServerName localhost" >> /etc/apache2/apache2.conf

# osTicket source: GitHub release zip, web root is the upload/ dir
RUN set -eux; \
    curl -fsSL -o /tmp/osticket.zip \
        "https://github.com/osTicket/osTicket/releases/download/v${OSTICKET_VERSION}/osTicket-v${OSTICKET_VERSION}.zip"; \
    unzip -q /tmp/osticket.zip -d /tmp/osticket; \
    cp -r /tmp/osticket/upload/. /var/www/html/; \
    rm -rf /tmp/osticket /tmp/osticket.zip; \
    chown -R www-data:www-data /var/www/html

# Language pack: bundle the OSTICKET_LANG pack (from downloads.osticket.com)
# so a fresh install can register it and persist system_language. Only en_US
# ships as a directory in the source; other languages ship as .phar files
# named after the short language code on S3 (e.g. hu.phar). We save it under
# the full code (hu_HU.phar) because Internationalization::availableLanguages()
# derives the language code from the phar basename. A copy is staged under
# /opt/osticket-i18n so the entrypoint can re-sync it into the include/
# volume on every start (the volume shadows the image's include/).
ARG OSTICKET_LANG=en_US
RUN set -eux; \
    if [ "$OSTICKET_LANG" != "en_US" ]; then \
        lang_short="${OSTICKET_LANG%%_*}"; \
        lang_minor="${OSTICKET_VERSION%.*}.x"; \
        mkdir -p /opt/osticket-i18n /var/www/html/include/i18n; \
        curl -fsSL -o "/opt/osticket-i18n/${OSTICKET_LANG}.phar" \
            "https://s3.amazonaws.com/downloads.osticket.com/lang/${lang_minor}/${lang_short}.phar"; \
        cp "/opt/osticket-i18n/${OSTICKET_LANG}.phar" "/var/www/html/include/i18n/${OSTICKET_LANG}.phar"; \
        chown www-data:www-data "/var/www/html/include/i18n/${OSTICKET_LANG}.phar"; \
    fi

# Community plugins, hydrated at build time. The entrypoint copies the
# requested ones into the include/ volume (see docker/entrypoint.sh).
COPY --from=plugin-builder /opt/osticket-plugins /opt/osticket-plugins

# Post-install provisioning script (entrypoint invokes it via `php`).
COPY docker/provision.php /opt/osticket-provision.php

COPY docker/entrypoint.sh /usr/local/bin/osticket-entrypoint
RUN chmod +x /usr/local/bin/osticket-entrypoint

WORKDIR /var/www/html

EXPOSE 80

ENTRYPOINT ["osticket-entrypoint"]
CMD ["apache2-foreground"]
