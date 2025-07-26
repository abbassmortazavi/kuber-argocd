#syntax=docker/dockerfile:1.15.0

# Versions
FROM dunglas/frankenphp:1.5-php8.4-alpine AS upstream

# The different stages of this Dockerfile are meant to be built into separate images
# https://docs.docker.com/develop/develop-images/multistage-build/#stop-at-a-specific-build-stage
# https://docs.docker.com/compose/compose-file/#target

# ---------------------------------------------------------------------
# Base stage
# ---------------------------------------------------------------------
FROM upstream AS base

# Set work directory and environment
WORKDIR /app
ENV APP_ENV=production

# Install dependencies in a single layer
RUN apk --no-cache add \
        openssh-client \
        acl \
        file \
        gettext \
        git \
        curl \
        gmp-dev \
        graphviz \
        ca-certificates \
    && update-ca-certificates

# Install PHP extensions in a single layer
# https://github.com/mlocati/docker-php-extension-installer
# https://github.com/docker-library/docs/tree/0fbef0e8b8c403f581b794030f9180a68935af9d/php#how-to-install-more-php-extensions
RUN --mount=type=bind,from=mlocati/php-extension-installer:2,source=/usr/bin/install-php-extensions,target=/usr/local/bin/install-php-extensions \
    install-php-extensions \
        @composer-2 \
        apcu \
        intl \
        opcache \
        zip \
        rdkafka \
        pcntl \
        memcached \
        gmp \
        bcmath \
        pdo_mysql \
        pdo_pgsql \
        redis \
        sockets \
        gettext \
        gd \
    && docker-php-source delete \
    && apk del --no-cache ${PHPIZE_DEPS} ${BUILD_DEPENDS}

# https://getcomposer.org/doc/03-cli.md#composer-allow-superuser
ENV COMPOSER_ALLOW_SUPERUSER=1

COPY --link .docker/php/conf.d/app.ini $PHP_INI_DIR/conf.d/
COPY --link --chmod=+x .docker/php/docker-php-entrypoint /usr/local/bin/docker-php-entrypoint

ENTRYPOINT ["docker-php-entrypoint"]

CMD ["php", "artisan", "octane:start"]

# ---------------------------------------------------------------------
# Development stage
# ---------------------------------------------------------------------
FROM base AS development

ENV APP_ENV=local XDEBUG_MODE=off

RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

ENV APP_ENV=local XDEBUG_MODE=off

# https://github.com/mlocati/docker-php-extension-installer
# https://github.com/docker-library/docs/tree/0fbef0e8b8c403f581b794030f9180a68935af9d/php#how-to-install-more-php-extensions
RUN --mount=type=bind,from=mlocati/php-extension-installer:2,source=/usr/bin/install-php-extensions,target=/usr/local/bin/install-php-extensions \
        install-php-extensions \
            xdebug

COPY --link .docker/php/conf.d/app.dev.ini $PHP_INI_DIR/conf.d/

COPY --link composer.* ./

# Install PHP dependencies
RUN --mount=type=secret,id=composer_auth,dst=/app/auth.json \
    composer install --prefer-dist --no-progress --no-interaction --no-scripts

# ---------------------------------------------------------------------
# Composer stage
# ---------------------------------------------------------------------
FROM composer:2 AS composer

WORKDIR /app

ENV COMPOSER_ALLOW_SUPERUSER=1
ENV COMPOSER_MEMORY_LIMIT=-1

RUN mkdir -m 0600 ~/.ssh && \
    ssh-keyscan github.com >> ~/.ssh/known_hosts

COPY composer.json composer.lock ./

RUN --mount=type=secret,id=composer_auth,dst=/app/auth.json \
    composer install --prefer-dist --no-dev --no-autoloader --no-scripts --no-progress --ignore-platform-reqs

# ---------------------------------------------------------------------
# Production stage
# ---------------------------------------------------------------------
FROM base AS production

ENV APP_ENV=production

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY --link .docker/php/conf.d/app.prod.ini $PHP_INI_DIR/conf.d/

COPY --link composer.* ./

COPY --from=composer /app/vendor ./vendor/
RUN --mount=type=secret,id=composer_auth,dst=/app/auth.json \
    composer install --prefer-dist --no-dev --no-autoloader --no-scripts --no-progress

# Copy application sources
COPY --link . ./

RUN rm -Rf .docker/

