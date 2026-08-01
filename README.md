# osTicket Docker Compose stack

Self-hosted [osTicket](https://osticket.com) helpdesk: a custom PHP 8.3 Apache image + MariaDB 11.4, orchestrated with docker-compose.

## Quick start

1. Configure secrets:

   ```sh
   cp .env.example .env
   # edit .env and set MARIADB_ROOT_PASSWORD and MARIADB_PASSWORD
   ```

2. Build and start:

   ```sh
   docker compose up -d --build
   ```

3. Run the web installer at <http://localhost:8080/setup/> (port from `OSTICKET_HTTP_PORT` in `.env`). Enter:

   | Field             | Value                        |
   |-------------------|------------------------------|
   | MySQL Hostname    | `db`                         |
   | MySQL Database    | `osticket`                   |
   | MySQL Username    | `osticket`                   |
   | MySQL Password    | the `MARIADB_PASSWORD` from `.env` |

4. On the final wizard step, osTicket prompts you to delete the `setup/` folder. This image does it for you automatically on the next container start (once `include/ost-config.php` exists), so just restart:

   ```sh
   docker compose restart osticket
   ```

   Then log in at <http://localhost:8080/scp/> (the admin account you created in the wizard).

## Useful commands

- Validate compose: `docker compose config`
- Check required PHP extensions: `docker compose exec osticket php -m`
- Follow logs: `docker compose logs -f`
- Rebuild after Dockerfile changes: `docker compose up -d --build`

## Gotchas

- Do **not** use the official `osticket/osticket` hub image; it is stale (PHP 7 era) and osTicket v1.18.4 requires PHP 8.2–8.4. Use the repo `Dockerfile`.
- The image is pinned to `php:8.3-apache-bookworm`: the un-pinned `php:8.3-apache` tag now tracks Debian trixie, where `libc-client-dev` (needed to compile PHP's `imap` extension) no longer exists.
- DB must be MariaDB, not MySQL 8 — MySQL 8's `caching_sha2_password` auth breaks osTicket's installer.
- `include/` is a named volume (`osticket_data`), so `ost-config.php`, plugins, and language packs persist. The volume shadows the image's `include/`: rebuilding the image does **not** update files already in the volume.
- osTicket and PHP versions are controlled by `OSTICKET_VERSION` in `.env` and the `php:` base image tag in `Dockerfile` respectively.
- Secrets live in `.env` (gitignored); never commit it. Changes to `.env` require `docker compose up -d` to re-apply.

## Layout

- `Dockerfile` — PHP 8.3 Apache + osTicket extensions (gd, gettext, imap, intl, mysqli, pdo_mysql, zip, apcu); app source downloaded from the GitHub release zip (`upload/` → `/var/www/html`)
- `docker/entrypoint.sh` — auto-removes `/var/www/html/setup` once installation is complete
- `docker-compose.yml` — `db` (mariadb:11.4, utf8mb4) + `osticket` (build: .), healthchecks + `depends_on`
- `.env.example` — config template
