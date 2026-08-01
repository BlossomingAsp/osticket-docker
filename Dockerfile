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

COPY docker/entrypoint.sh /usr/local/bin/osticket-entrypoint
RUN chmod +x /usr/local/bin/osticket-entrypoint

WORKDIR /var/www/html

EXPOSE 80

ENTRYPOINT ["osticket-entrypoint"]
CMD ["apache2-foreground"]
