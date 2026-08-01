# osTicket docker image and compose project

Self-hosted osTicket helpdesk stack: a custom PHP 8.3 Apache image + MariaDB, orchestrated with docker-compose.

## Commands
- First run: `cp .env.example .env`, set the DB passwords, then `docker compose up -d --build`
- Validate compose: `docker compose config`
- Install is a manual web wizard: browse to `http://localhost:8080/setup/` (DB host `db`, creds from `.env`); there is no auto-install entrypoint
- After the wizard completes, harden: `docker compose exec osticket sh -c 'rm -rf /var/www/html/setup'`
- Check required PHP extensions: `docker compose exec osticket php -m`
- Rebuild after Dockerfile changes: `docker compose up -d --build`

## Gotchas
- Do NOT use the official `osticket/osticket` hub image; it is stale (PHP 7 era) and osTicket v1.18.4 requires PHP 8.2–8.4. Use the repo `Dockerfile`.
- DB must be MariaDB, not MySQL 8 — MySQL 8's `caching_sha2_password` auth breaks osTicket's installer.
- `include/` is a named volume (`osticket_data`), so `ost-config.php` and language packs persist, but the volume shadows the image's `include/`: rebuilding the image does NOT update files already in the volume.
- osTicket and PHP versions are `ARG`s in `Dockerfile` (defaults `1.18.4` / `8.3`).
- Secrets live in `.env` (gitignored); never commit it. Changes to `.env` require `docker compose up -d` to re-apply.

## Layout
- `Dockerfile` — PHP 8.3 Apache + osTicket extensions (gd, imap, intl, mbstring, mysqli, zip, ...); app source downloaded from the GitHub release zip (`upload/` → `/var/www/html`)
- `apache/osticket.conf` — vhost with `AllowOverride All`, directory indexes off, HTTP access to `include/` denied
- `docker-compose.yml` — `db` (mariadb:11.4, utf8mb4) + `osticket` (build: .), healthchecks + `depends_on`
- `.env.example` — config template
