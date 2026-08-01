#!/bin/sh
set -e

DOCROOT=/var/www/html
CONFIG="$DOCROOT/include/ost-config.php"

# Ensure a config file exists so the installer can run. The installer (or
# the auto-installer below) rewrites this file in place once done; on an
# empty include/ volume this removes the manual "copy ost-sampleconfig.php"
# step for wizard-based installs too.
if [ ! -f "$CONFIG" ]; then
    cp "$DOCROOT/setup/inc/ost-sampleconfig.php" "$CONFIG"
    echo "Created $CONFIG from the osTicket sample config"
fi
# The wizard (Apache/php as www-data) rewrites this file in place, so it
# must be writable by the web server user, not just root.
chown www-data:www-data "$CONFIG" 2>/dev/null || true

INSTALLED=0
if grep -q "define('OSTINSTALLED',TRUE)" "$CONFIG" 2>/dev/null; then
    INSTALLED=1
fi

# --- Optional auto-install via the official web wizard --------------------
# Only runs when OSTICKET_AUTOINSTALL=1 and the config is still the fresh
# template. We briefly run Apache in the background to POST the wizard
# steps (prereq -> config -> install), then stop it so the CMD below can
# start Apache normally.
if [ "$INSTALLED" = 0 ] && [ "${OSTICKET_AUTOINSTALL:-0}" = "1" ]; then
    echo "Auto-installing osTicket via the setup wizard..."
    : "${OSTICKET_HELPDESK_NAME:?OSTICKET_HELPDESK_NAME required for auto-install}"
    : "${OSTICKET_DEFAULT_EMAIL:?OSTICKET_DEFAULT_EMAIL required for auto-install}"
    : "${OSTICKET_ADMIN_EMAIL:?OSTICKET_ADMIN_EMAIL required for auto-install}"
    : "${OSTICKET_ADMIN_USERNAME:?OSTICKET_ADMIN_USERNAME required for auto-install}"
    : "${OSTICKET_ADMIN_PASSWORD:?OSTICKET_ADMIN_PASSWORD required for auto-install}"
    : "${MARIADB_DATABASE:?MARIADB_DATABASE required for auto-install}"
    : "${MARIADB_USER:?MARIADB_USER required for auto-install}"
    : "${MARIADB_PASSWORD:?MARIADB_PASSWORD required for auto-install}"

    apache2-foreground >/dev/null 2>&1 &
    APACHE_PID=$!
    trap 'kill "$APACHE_PID" 2>/dev/null || true' EXIT

    i=0
    until curl -fsS -o /dev/null "http://localhost/"; do
        i=$((i + 1))
        if [ "$i" -gt 60 ]; then
            echo "auto-install: Apache did not become ready in time" >&2
            exit 1
        fi
        sleep 1
    done

    BASE="http://localhost/setup/install.php"
    JAR=/tmp/ost-install-cookies.txt

    # Curl config file: carries the cookie jar and the optional header args.
    # Headers use the config-file form ("Name: value" quoted) so they survive
    # shell quoting/word-splitting untouched. The Host header makes the
    # wizard record the real helpdesk URL; X-Forwarded-Proto makes osTicket
    # see HTTPS.
    CONF=/tmp/ost-install-curl.conf
    printf 'cookie = %s\ncookie-jar = %s\n' "$JAR" "$JAR" > "$CONF"
    if [ -n "${OSTICKET_HELPDESK_URL:-}" ]; then
        host="${OSTICKET_HELPDESK_URL#*://}"
        host="${host%%/*}"
        printf 'header = "Host: %s"\n' "$host" >> "$CONF"
        case "$OSTICKET_HELPDESK_URL" in
            https://*) printf 'header = "X-Forwarded-Proto: https"\n' >> "$CONF" ;;
        esac
    fi

    curl -fsS -K "$CONF" -d "s=prereq" "$BASE"
    curl -fsS -K "$CONF" -d "s=config" "$BASE"
    curl -fsS -K "$CONF" \
        --data-urlencode "s=install" \
        --data-urlencode "name=${OSTICKET_HELPDESK_NAME}" \
        --data-urlencode "email=${OSTICKET_DEFAULT_EMAIL}" \
        --data-urlencode "lang_id=${OSTICKET_LANG:-en_US}" \
        --data-urlencode "timezone=${OSTICKET_TIMEZONE:-UTC}" \
        --data-urlencode "fname=${OSTICKET_ADMIN_FNAME:-Admin}" \
        --data-urlencode "lname=${OSTICKET_ADMIN_LNAME:-User}" \
        --data-urlencode "admin_email=${OSTICKET_ADMIN_EMAIL}" \
        --data-urlencode "username=${OSTICKET_ADMIN_USERNAME}" \
        --data-urlencode "passwd=${OSTICKET_ADMIN_PASSWORD}" \
        --data-urlencode "passwd2=${OSTICKET_ADMIN_PASSWORD}" \
        --data-urlencode "prefix=ost_" \
        --data-urlencode "dbhost=db" \
        --data-urlencode "dbname=${MARIADB_DATABASE}" \
        --data-urlencode "dbuser=${MARIADB_USER}" \
        --data-urlencode "dbpass=${MARIADB_PASSWORD}" \
        "$BASE"

    kill "$APACHE_PID" 2>/dev/null || true
    wait "$APACHE_PID" 2>/dev/null || true
    trap - EXIT

    if grep -q "define('OSTINSTALLED',TRUE)" "$CONFIG"; then
        echo "osTicket installed successfully"
        INSTALLED=1
    else
        echo "auto-install: the installer reported an error; see the wizard output" >&2
        exit 1
    fi
fi

# osTicket hardens itself by requiring the setup/ directory to be removed
# once installation is complete. Doing it here (rather than documenting a
# manual `rm`) makes the image safe on every container start.
if [ "$INSTALLED" = 1 ] && [ -d "$DOCROOT/setup" ]; then
    rm -rf "$DOCROOT/setup"
    echo "osTicket install detected; removed /var/www/html/setup"
fi

# For reverse-proxy/HTTPS deployments osTicket only trusts X-Forwarded-*
# headers from proxies listed in TRUSTED_PROXIES (ost-config.php). Inject
# the value from OSTICKET_TRUSTED_PROXIES when set; the line the installer
# writes is define('TRUSTED_PROXIES', '');. Idempotent: a value already
# present is rewritten in place, and an empty env leaves the file alone.
if [ -f "$CONFIG" ] && [ -n "$OSTICKET_TRUSTED_PROXIES" ]; then
    if grep -q "^define('TRUSTED_PROXIES', " "$CONFIG"; then
        sed -i "s|^define('TRUSTED_PROXIES', '[^']*');|define('TRUSTED_PROXIES', '${OSTICKET_TRUSTED_PROXIES}');|" "$CONFIG"
    else
        # No TRUSTED_PROXIES define present - append before the closing tag.
        sed -i "s|^?>|define('TRUSTED_PROXIES', '${OSTICKET_TRUSTED_PROXIES}');\n?>|" "$CONFIG"
    fi
    echo "osTicket install detected; set TRUSTED_PROXIES to ${OSTICKET_TRUSTED_PROXIES}"
fi

# Provision the requested community plugins into the include/ volume. The
# image ships hydrated copies under /opt/osticket-plugins (see Dockerfile).
if [ -n "${OSTICKET_PLUGINS:-}" ]; then
    IFS=','
    for p in $OSTICKET_PLUGINS; do
        p="$(printf '%s' "$p" | tr -d ' ')"
        [ -n "$p" ] || continue
        if [ -d "/opt/osticket-plugins/$p" ]; then
            mkdir -p "$DOCROOT/include/plugins"
            cp -r "/opt/osticket-plugins/$p" "$DOCROOT/include/plugins/"
            echo "Provisioned plugin files: $p"
        else
            echo "Warning: unknown plugin '$p' (not bundled in /opt/osticket-plugins)" >&2
        fi
    done
    unset IFS
fi

# Post-install provisioning: register/enable plugins and configure the
# OAuth2 instances from OSTICKET_* env vars. Requires an installed system.
if [ "$INSTALLED" = 1 ]; then
    php /opt/osticket-provision.php
fi

exec "$@"
