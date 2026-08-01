#!/bin/sh
set -e

CONFIG=/var/www/html/include/ost-config.php

# osTicket hardens itself by requiring the setup/ directory to be removed
# once installation is complete. Doing it here (rather than documenting a
# manual `rm`) makes the image safe on every container start: once
# include/ost-config.php exists the installer is no longer reachable,
# even after a container recreate.
if [ -f "$CONFIG" ] && [ -d /var/www/html/setup ]; then
    rm -rf /var/www/html/setup
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

exec "$@"
