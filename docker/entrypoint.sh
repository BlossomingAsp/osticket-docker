#!/bin/sh
set -e

# osTicket hardens itself by requiring the setup/ directory to be removed
# once installation is complete. Doing it here (rather than documenting a
# manual `rm`) makes the image safe on every container start: once
# include/ost-config.php exists the installer is no longer reachable,
# even after a container recreate.
if [ -f /var/www/html/include/ost-config.php ] && [ -d /var/www/html/setup ]; then
    rm -rf /var/www/html/setup
    echo "osTicket install detected; removed /var/www/html/setup"
fi

exec "$@"
