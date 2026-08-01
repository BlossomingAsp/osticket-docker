# osTicket Docker Compose stack

Self-hosted [osTicket](https://osticket.com) helpdesk: a custom PHP 8.3 Apache image + MariaDB 11.4, orchestrated with docker-compose. Supports one-command auto-setup (no browser) or the official manual web wizard, plus optional OAuth/OIDC single sign-on (Pocket ID, Google, Discord) and two-factor authentication.

## Quick start

Install straight from a [release](https://github.com/BlossomingAsp/osticket-docker/releases) — this downloads the repo and starts the installer (non-interactive auto-setup):

```sh
curl -sSL https://github.com/BlossomingAsp/osticket-docker/releases/latest/download/get-osticket.sh | sh -s -- -y --auto
# manual wizard:  ... | sh -s -- -y --manual
# pin a release:  OSTICKET_RELEASE=v1.0.2 ... | sh -s -- -y --auto
```

> **Private repo?** GitHub only serves `releases/latest/download/...` to public repos. For a private repo, `git clone` the repo (SSH or a token URL) and run `./install.sh` locally; the bootstrap script also honors an exported `GH_TOKEN` (repo scope) for its downloads.

Or clone and run the installer script, which asks whether to **auto-setup** (env-driven install + plugin/OAuth provisioning) or use the **manual web wizard**, then generates `.env`, builds the image, and starts the stack:

```sh
./install.sh
# non-interactive auto-setup: ./install.sh -y --auto
# non-interactive manual:     ./install.sh -y --manual
```

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

## install.sh options

`install.sh` generates `.env`, builds the image, and starts the stack. It is safe to re-run: an existing `.env` is left untouched unless you confirm an overwrite (`-y` also keeps it).

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Non-interactive: auto-generate DB passwords, skip prompts |
| `-p`, `--port PORT` | Host HTTP port (default `8080`) |
| `-v`, `--version V` | osTicket version to build (default `1.18.4`) |
| `-t`, `--trusted-proxies P` | Comma-separated proxy IPs/CIDRs to trust for `X-Forwarded-*` headers (reverse-proxy/HTTPS deployments; optional) |
| `--auto` | Force auto-setup mode (used with `-y` for scripting) |
| `--manual` | Force manual-wizard mode (skips `OSTICKET_*` prompts) |
| `--dry-run` | Generate `.env` and print the commands without running them |
| `-h`, `--help` | Show help |

`OSTICKET_*` and `MARIADB_*` environment variables are honored as defaults when set, so existing values are kept when `.env` is regenerated.

## Configuration reference

All configuration lives in `.env` (gitignored, mode 600). See `.env.example` for the latest template. Changes require `docker compose up -d` to re-apply.

### MariaDB

| Variable | Default | Purpose |
|----------|---------|---------|
| `MARIADB_ROOT_PASSWORD` | — | MariaDB root password |
| `MARIADB_DATABASE` | `osticket` | osTicket database name |
| `MARIADB_USER` | `osticket` | osTicket database user |
| `MARIADB_PASSWORD` | — | osTicket database user's password (used in the wizard) |

### osTicket

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_VERSION` | `1.18.4` | osTicket version to build (build arg) |
| `OSTICKET_HTTP_PORT` | `8080` | Host port published to `http://localhost` |
| `OSTICKET_TRUSTED_PROXIES` | empty | Comma-separated proxy IPs/CIDRs trusted for `X-Forwarded-*` headers (reverse-proxy/HTTPS deployments only; leave empty otherwise) |

### Auto-setup

Used only when `OSTICKET_AUTOINSTALL=1` (auto-setup mode).

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_AUTOINSTALL` | `0` | `1` = auto-install on first boot, `0` = manual web wizard |
| `OSTICKET_HELPDESK_NAME` | — | Helpdesk name (required for auto-setup) |
| `OSTICKET_DEFAULT_EMAIL` | — | Default system email (required) |
| `OSTICKET_LANG` | `en_US` | Primary language (e.g. `en_US`, `de_DE`) |
| `OSTICKET_TIMEZONE` | `UTC` | Default timezone (e.g. `UTC`, `Europe/Berlin`) |
| `OSTICKET_HELPDESK_URL` | — | Public URL of the helpdesk, no trailing slash (e.g. `https://helpdesk.example.com`); used for the wizard's Helpdesk URL and OAuth redirect URI |

### Admin account (created only by auto-setup)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_ADMIN_FNAME` | `Admin` | Admin first name |
| `OSTICKET_ADMIN_LNAME` | `User` | Admin last name |
| `OSTICKET_ADMIN_EMAIL` | — | Admin email (required; must differ from `OSTICKET_DEFAULT_EMAIL`) |
| `OSTICKET_ADMIN_USERNAME` | — | Admin username (required; not `admin`/`admins`/`username`/`osticket`) |
| `OSTICKET_ADMIN_PASSWORD` | — | Admin password (required) |

### Plugins

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_PLUGINS` | `auth-oauth2,auth-2fa` | Comma-separated plugins to install/activate/provision. Bundled: `auth-oauth2` (OAuth2/OIDC sign-in), `auth-2fa` (authenticator-app two-factor auth) |

### Pocket ID (OIDC)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_OIDC_NAME` | `Pocket ID` | Login-button display name |
| `OSTICKET_OIDC_URL` | — | Issuer base URL (enable by setting this plus a client ID) |
| `OSTICKET_OIDC_CLIENT_ID` | — | OIDC client ID |
| `OSTICKET_OIDC_CLIENT_SECRET` | — | OIDC client secret (stored encrypted in the DB) |
| `OSTICKET_OIDC_AUTH_TARGET` | `agents` | Who can sign in: `none`/`agents`/`users`/`all` |
| `OSTICKET_OIDC_ATTR_USERNAME` | `preferred_username` | Userinfo claim used as the osTicket username |

### Google OAuth

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_GOOGLE_NAME` | `Google` | Login-button display name |
| `OSTICKET_GOOGLE_CLIENT_ID` | — | Google OAuth client ID |
| `OSTICKET_GOOGLE_CLIENT_SECRET` | — | Google OAuth client secret |
| `OSTICKET_GOOGLE_AUTH_TARGET` | `agents` | Who can sign in: `none`/`agents`/`users`/`all` |

### Discord OAuth

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_DISCORD_NAME` | `Discord` | Login-button display name |
| `OSTICKET_DISCORD_CLIENT_ID` | — | Discord OAuth client ID |
| `OSTICKET_DISCORD_CLIENT_SECRET` | — | Discord OAuth client secret |
| `OSTICKET_DISCORD_AUTH_TARGET` | `agents` | Who can sign in: `none`/`agents`/`users`/`all` |

## Auto-setup

When `OSTICKET_AUTOINSTALL=1`, the container installs osTicket automatically on first boot — no browser wizard needed. It POSTs the official setup wizard (`prereq` → `config` → `install`) using the `OSTICKET_*` and `MARIADB_*` values above, then provisions the plugins and OAuth/OIDC sign-in configured in `.env`.

Requirements:

- `OSTICKET_HELPDESK_NAME`, `OSTICKET_DEFAULT_EMAIL`, `OSTICKET_ADMIN_EMAIL`, `OSTICKET_ADMIN_USERNAME`, `OSTICKET_ADMIN_PASSWORD` (plus the `MARIADB_*` vars) must be set.
- Admin username must not be `admin`, `admins`, `username`, or `osticket` (reserved by osTicket).
- Admin email must differ from the default system email.
- The install uses `prefix=ost_` and `dbhost=db` automatically.

Give the container a minute or two on first boot, then log in at <http://localhost:PORT/scp/> with the admin account. The `setup/` folder is removed automatically on the next container start, and plugin/OAuth provisioning re-runs on every start (idempotent — safe to restart any time).

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

To **add or change a provider later**: edit `.env`, then `docker compose up -d` — provisioning re-runs on container start and reconciles the instances.

## Updating

`install.sh` checks the configured `OSTICKET_VERSION` against the latest osTicket release and prompts to bump it when newer (with an explicit `-v`, non-interactively, and in `--dry-run` it only reports — never prompts or changes `.env`). To check and update explicitly:

```sh
./update.sh            # interactive: prompt before updating
./update.sh -y         # accept the update without prompting
./update.sh --dry-run  # report what would change, change nothing
```

`update.sh` queries the latest release, bumps `OSTICKET_VERSION` in `.env` on approval, and rebuilds. Equivalent manual steps:

1. Bump `OSTICKET_VERSION` in `.env` (or change the `php:` base image tag in `Dockerfile`).
2. Rebuild and restart:

   ```sh
   docker compose up -d --build
   ```

Plugin files are re-copied into the `include/` volume on container start, so plugin updates ship on rebuild. Other files already in the volume (e.g. `ost-config.php`, language packs) are **not** overwritten by a rebuild — the volume shadows the image's `include/`. Secrets live in `.env`; never commit it, and re-apply `.env` changes with `docker compose up -d`.

## Backups

- **Database**: `docker compose exec db mariadb-dump -u root -p osticket > osticket.sql` (prompts for `MARIADB_ROOT_PASSWORD`).
- **Configuration & plugins**: the `osticket_data` named volume holds `include/` (config, plugins, language packs). Back it up with a volume backup (e.g. a `tar` from a temporary container mounted on the volume).

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

3. **Helpdesk URL.** During the web wizard (or via `OSTICKET_HELPDESK_URL` in auto-setup), set the helpdesk URL to the real public address (e.g. `https://helpdesk.example.com`); email links and redirects use it. `ROOT_PATH` in `ost-config.php` is only needed if you serve osTicket under a subdirectory (e.g. `/support/`).

The container's internal Apache stays plain HTTP on port 80; the reverse proxy terminates TLS and forwards to the published port (`8080`) or the container directly on the compose network.

## Gotchas

- Do **not** use the official `osticket/osticket` hub image; it is stale (PHP 7 era) and osTicket v1.18.4 requires PHP 8.2–8.4. Use the repo `Dockerfile`.
- The image is pinned to `php:8.3-apache-bookworm`: the un-pinned `php:8.3-apache` tag now tracks Debian trixie, where `libc-client-dev` (needed to compile PHP's `imap` extension) no longer exists.
- DB must be MariaDB, not MySQL 8 — MySQL 8's `caching_sha2_password` auth breaks osTicket's installer.
- `include/` is a named volume (`osticket_data`), so `ost-config.php`, plugins, and language packs persist. The volume shadows the image's `include/`: rebuilding the image does **not** update files already in the volume.

## Layout

- `Dockerfile` — PHP 8.3 Apache + osTicket extensions (gd, gettext, imap, intl, mysqli, pdo_mysql, zip, apcu); app source from the GitHub release zip (`upload/` → `/var/www/html`); a builder stage hydrates and bundles the `auth-oauth2` + `auth-2fa` plugins
- `docker/entrypoint.sh` — pre-creates `ost-config.php`, optionally auto-installs via the wizard (`OSTICKET_AUTOINSTALL=1`), removes `/var/www/html/setup` once installed, injects `TRUSTED_PROXIES`, copies plugins into the include volume, and runs `docker/provision.php`
- `docker/provision.php` — installs/activates the requested plugins and creates the OAuth2 instances (Pocket ID/Google/Discord) + 2FA instance from `OSTICKET_*` env vars
- `docker-compose.yml` — `db` (mariadb:11.4, utf8mb4) + `osticket` (build: .), healthchecks + `depends_on`, all `OSTICKET_*`/`MARIADB_*` env vars passed to the container
- `install.sh` — asks auto-setup vs manual wizard, creates `.env` (mode 600), builds the image, starts the stack; checks the configured osTicket version against the latest release and offers to bump it
- `update.sh` — queries the latest osTicket release, bumps `OSTICKET_VERSION` in `.env` on approval, and rebuilds the stack
- `get-osticket.sh` — bootstrap installer: downloads a release source tarball and runs its `install.sh` (also attached to every release)
- `.env.example` — config template documenting every variable
