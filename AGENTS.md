# osTicket docker image and compose project

Self-hosted osTicket helpdesk stack: a custom PHP 8.3 Apache image + MariaDB, orchestrated with docker-compose.

## Commands
- First run: `cp .env.example .env`, set the DB passwords, then `docker compose up -d --build`
- Validate compose: `docker compose config`
- Install is a manual web wizard: browse to `http://localhost:8080/setup/` (DB host `db`, creds from `.env`); there is no auto-install entrypoint
- After the wizard writes `include/ost-config.php`, `docker/entrypoint.sh` auto-deletes `/var/www/html/setup` on next container start — no manual hardening step
- Check required PHP extensions: `docker compose exec osticket php -m`
- Rebuild after Dockerfile changes: `docker compose up -d --build`

## Gotchas
- Do NOT use the official `osticket/osticket` hub image; it is stale (PHP 7 era) and osTicket v1.18.4 requires PHP 8.2–8.4. Use the repo `Dockerfile`.
- Image is pinned to `php:8.3-apache-bookworm`. Do NOT unpin: default `php:8.3-apache` tracks Debian trixie, where `libc-client-dev` (needed to build the `imap` extension) no longer exists. `imap` is bundled in PHP 8.3 but moved to PECL in 8.4.
- DB must be MariaDB, not MySQL 8 — MySQL 8's `caching_sha2_password` auth breaks osTicket's installer.
- `include/` is a named volume (`osticket_data`), so `ost-config.php`, plugins, and language packs persist, but the volume shadows the image's `include/`: rebuilding the image does NOT update files already in the volume.
- osTicket version is `OSTICKET_VERSION` in `.env` (default `1.18.4`), passed as a build arg; PHP version is the base image tag in `Dockerfile`.
- Secrets live in `.env` (gitignored); never commit it. Changes to `.env` require `docker compose up -d` to re-apply.

## Layout
- `Dockerfile` — PHP 8.3 Apache (bookworm) + osTicket extensions (gd, gettext, imap, intl, mysqli, pdo_mysql, zip, apcu); app source downloaded from the GitHub release zip (`upload/` → `/var/www/html`)
- `docker/entrypoint.sh` — auto-removes `/var/www/html/setup` once installation is complete; execs `apache2-foreground`
- `docker-compose.yml` — `db` (mariadb:11.4, utf8mb4) + `osticket` (build: .), healthchecks + `depends_on`
- `.env.example` — config template
