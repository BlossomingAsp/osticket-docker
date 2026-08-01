# osTicket Docker Compose stack

Self-hosted [osTicket](https://osticket.com) helpdesk: a custom PHP 8.3 Apache image + MariaDB 11.4, orchestrated with docker-compose.

## Quick start

Install straight from a [release](https://github.com/BlossomingAsp/osticket-docker/releases) — this downloads the repo and starts the installer (non-interactive auto-setup):

```sh
curl -sSL https://github.com/BlossomingAsp/osticket-docker/releases/latest/download/get-osticket.sh | sh -s -- -y --auto
# manual wizard:  ... | sh -s -- -y --manual
# pin a release:  OSTICKET_RELEASE=v1.0.0 ... | sh -s -- -y --auto
```

> **Private repo?** GitHub only serves `releases/latest/download/...` to public repos. For a private repo, `git clone` the repo (SSH or a token URL) and run `./install.sh` locally; the bootstrap script also honors an exported `GH_TOKEN` (repo scope) for its downloads.

Or clone and run the installer script, which asks whether to **auto-setup** (env-driven install + plugin/OAuth provisioning) or use the **manual web wizard**, then generates `.env`, builds the image, and starts the stack:

```sh
./install.sh
# non-interactive auto-setup: ./install.sh -y --auto
# non-interactive manual:     ./install.sh -y --manual
```

Auto-setup (`OSTICKET_AUTOINSTALL=1`) installs osTicket automatically on first boot — helpdesk name/email, primary language, and the admin account all come from `OSTICKET_*` vars — then provisions the plugins and OAuth/OIDC sign-in configured in `.env`. No browser wizard needed.

To do it by hand instead:

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

   The entrypoint pre-creates `include/ost-config.php` from the sample config, so the wizard form appears immediately (no manual config-file copy).

4. On the final wizard step, osTicket prompts you to delete the `setup/` folder. This image does it for you automatically on the next container start (once `include/ost-config.php` exists), so just restart:

   ```sh
   docker compose restart osticket
   ```

   Then log in at <http://localhost:8080/scp/> (the admin account you created in the wizard).

## Plugins and OAuth/OIDC sign-in

The image bundles two community plugins (osTicket-plugins, 1.17.x line): **auth-oauth2** (OAuth2/OIDC sign-in) and **auth-2fa** (authenticator-app two-factor auth). `OSTICKET_PLUGINS` (default `auth-oauth2,auth-2fa`) selects which are installed, activated, and provisioned on every container start.

Each IdP is a separate **instance** of the auth-oauth2 plugin, created automatically from `.env` when its client ID is set:

| Provider   | `.env` vars                              | Login button                  |
|------------|------------------------------------------|-------------------------------|
| Pocket ID  | `OSTICKET_OIDC_URL/CLIENT_ID/CLIENT_SECRET` (+ `AUTH_TARGET`) | "Sign in with Pocket ID" |
| Google     | `OSTICKET_GOOGLE_CLIENT_ID/CLIENT_SECRET` (+ `AUTH_TARGET`)   | "Sign in with Google" |
| Discord    | `OSTICKET_DISCORD_CLIENT_ID/CLIENT_SECRET` (+ `AUTH_TARGET`)  | "Sign in with Discord" |

`AUTH_TARGET` controls who can sign in: `agents` (staff only), `users` (end users only), `all`, or `none`. The OAuth redirect URI for every provider is your helpdesk URL + `/api/auth/oauth2` — register that callback in each IdP's app (Google Cloud Console OAuth client, Discord Developer Portal OAuth2, Pocket ID OIDC client).

Provider details baked in:

- **Pocket ID** — generic OIDC; endpoints `…/authorize`, `…/oauth/token`, `…/userinfo`; scopes `openid profile email`; username mapped from `preferred_username` (override with `OSTICKET_OIDC_ATTR_USERNAME`).
- **Google** — uses the plugin's built-in Google template (correct endpoints, scopes, `given_name`/`family_name` mapping); only the client ID/secret are required.
- **Discord** — generic OAuth2 with `identify email` scopes; username/email mapped from Discord's userinfo (`username`, `email`). Discord has no given/family-name claims.

OAuth client secrets are stored in `.env` (gitignored) and injected into the oauth2 plugin instance's config (stored encrypted in the `ost_config` table) by `docker/provision.php`.

## Useful commands

- Validate compose: `docker compose config`
- Check required PHP extensions: `docker compose exec osticket php -m`
- Follow logs: `docker compose logs -f`
- Rebuild after Dockerfile changes: `docker compose up -d --build`

## Reverse proxy / HTTPS

When osTicket is served from a public domain through a TLS-terminating reverse proxy, three things matter:

1. **Proxy headers.** Your proxy must forward the original request headers — osTicket reads `Host` for URL building, `X-Forwarded-Proto` for HTTPS detection, and `X-Forwarded-For` for the client IP. osTicket detects HTTPS purely from `X-Forwarded-Proto: https` (no config needed), which drives secure cookies and `https://` links.

2. **Trusted proxies.** osTicket only believes `X-Forwarded-For`/`X-Forwarded-Port` for the *client IP* if the connecting proxy is listed in `TRUSTED_PROXIES` in `include/ost-config.php`. Without it, every visitor is recorded as the proxy's IP in audit/login/spam logs. Set it in `.env`:

   ```env
   OSTICKET_TRUSTED_PROXIES=172.16.0.0/12
   ```

   Comma-separate multiple proxies/CIDRs (`1.2.3.4,10.0.0.0/8`). The `*` wildcard trusts every proxy and is discouraged. The `osticket` entrypoint injects this into the volume's `ost-config.php` on container start, so `docker compose up -d` re-applies `.env` changes. Leave it empty if not behind a proxy.

3. **Helpdesk URL.** During the web wizard, set the helpdesk URL to the real public address (e.g. `https://helpdesk.example.com`); email links and redirects use it. `ROOT_PATH` in `ost-config.php` is only needed if you serve osTicket under a subdirectory (e.g. `/support/`).

The container's internal Apache stays plain HTTP on port 80; the reverse proxy terminates TLS and forwards to the published port (`8080`) or the container directly on the compose network.

## Gotchas

- Do **not** use the official `osticket/osticket` hub image; it is stale (PHP 7 era) and osTicket v1.18.4 requires PHP 8.2–8.4. Use the repo `Dockerfile`.
- The image is pinned to `php:8.3-apache-bookworm`: the un-pinned `php:8.3-apache` tag now tracks Debian trixie, where `libc-client-dev` (needed to compile PHP's `imap` extension) no longer exists.
- DB must be MariaDB, not MySQL 8 — MySQL 8's `caching_sha2_password` auth breaks osTicket's installer.
- `include/` is a named volume (`osticket_data`), so `ost-config.php`, plugins, and language packs persist. The volume shadows the image's `include/`: rebuilding the image does **not** update files already in the volume.
- osTicket and PHP versions are controlled by `OSTICKET_VERSION` in `.env` and the `php:` base image tag in `Dockerfile` respectively.
- Secrets live in `.env` (gitignored); never commit it. Changes to `.env` require `docker compose up -d` to re-apply.

## Layout

- `Dockerfile` — PHP 8.3 Apache + osTicket extensions (gd, gettext, imap, intl, mysqli, pdo_mysql, zip, apcu); app source from the GitHub release zip (`upload/` → `/var/www/html`); a builder stage hydrates and bundles the `auth-oauth2` + `auth-2fa` plugins
- `docker/entrypoint.sh` — pre-creates `ost-config.php`, optionally auto-installs via the wizard (`OSTICKET_AUTOINSTALL=1`), removes `/var/www/html/setup` once installed, injects `TRUSTED_PROXIES`, copies plugins into the include volume, and runs `docker/provision.php`
- `docker/provision.php` — installs/activates the requested plugins and creates the OAuth2 instances (Pocket ID/Google/Discord) + 2FA instance from `OSTICKET_*` env vars
- `docker-compose.yml` — `db` (mariadb:11.4, utf8mb4) + `osticket` (build: .), healthchecks + `depends_on`, all `OSTICKET_*`/`MARIADB_*` env vars passed to the container
- `install.sh` — asks auto-setup vs manual wizard, creates `.env` (mode 600), builds the image, starts the stack
- `get-osticket.sh` — bootstrap installer: downloads a release source tarball and runs its `install.sh` (also attached to every release)
- `.env.example` — config template documenting every variable
