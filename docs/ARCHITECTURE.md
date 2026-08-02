# Architecture & Technical Reference

This document explains how the osTicket Docker stack works end to end: every
component, every environment variable, and the data flows that tie them
together. It is the companion to the user-facing `README.md` (install/config
guide) and `AGENTS.md` (agent/dev runbook). Read it top to bottom if you want
to *understand* the project; skip to a section if you want an answer.

> Note: this is the `main` (stable) version. The experimental Discord ticket
> bot lives on the `experimental` branch and is not part of this document.

---

## 1. What this project is

A self-hosted helpdesk stack built on [osTicket](https://osticket.com),
packaged as two Docker Compose services:

| Service | Image | Role |
|---------|-------|------|
| `db` | `mariadb:11.4` | osTicket's database |
| `osticket` | built from this repo (`Dockerfile`) | the helpdesk web app (PHP 8.3 + Apache) |

A single command can install osTicket **without a browser** by driving the
official web wizard internally (`OSTICKET_AUTOINSTALL=1`), and the image ships
community plugins for **OAuth/OIDC sign-in** (Pocket ID, Google, Discord) and
**two-factor authentication**.

> Experimental features (currently: a Discord ticket bot and the
> `experimental` release channel) are developed on the `experimental` branch
> and released as GitHub **prereleases**, not stable releases.

---

## 2. High-level architecture

```
                 ┌─────────────────────────────────────────────────┐
                 │                 docker network                  │
                 │                                                 │
   browser ──►   │   ┌────────────┐   ┌───────────────┐            │
  :8080/8085     │   │  osticket  │   │     db        │            │
                 │   │ PHP 8.3    │──►│  MariaDB 11.4 │            │
                 │   │ Apache:80  │   │  :3306        │            │
                 │   └────────────┘   └───────────────┘            │
                 └─────────────────────────────────────────────────┘
```

**Volumes** (named, persist across container recreation):

- `osticket_data` → mounted at `/var/www/html/include` in the `osticket` container.
  Holds `ost-config.php`, plugins, and language packs. *Shadows the image's
  `include/`* (see §10).
- `db_data` → mounted at `/var/lib/mysql` in the `db` container. The database.

---

## 3. Repository layout

| Path | Purpose |
|------|---------|
| `Dockerfile` | Builds the `osticket` image (two stages, see §4) |
| `docker-compose.yml` | Declares `db` and `osticket`; volumes, healthchecks, env passthrough |
| `.env.example` | Template for `.env`; documents every variable |
| `.env` | **gitignored** — your actual secrets/configuration |
| `install.sh` | Interactive/non-interactive installer: writes `.env`, builds, starts; checks for osTicket updates |
| `update.sh` | Checks the latest osTicket release, bumps `OSTICKET_VERSION` in `.env`, rebuilds |
| `get-osticket.sh` | Release bootstrap: downloads a tagged source tarball and runs its `install.sh`; honors `OSTICKET_CHANNEL`/`OSTICKET_RELEASE` |
| `docker/entrypoint.sh` | `osticket` container startup script (see §5) |
| `docker/provision.php` | Post-install provisioning: plugins, OAuth/2FA instances, system language, queue repair (see §6) |
| `docker/i18n/hu_HU/queue.yaml` | Corrected Hungarian queue data that overrides a defective upstream pack (see §11.1) |
| `docs/ARCHITECTURE.md` | This document |
| `README.md`, `AGENTS.md`, `CHANGELOG.md`, `LICENSE` | User guide, dev runbook, changelog, GPL v2 license |

---

## 4. Image build (`Dockerfile`)

### Stage 1 — `plugin-builder` (`php:8.3-cli-bookworm`)

Bundles the community plugins from the pinned
`osTicket/osTicket-plugins` commit (`PLUGINS_COMMIT`, default `adfef05` on the
1.17.x line). `make.php hydrate` resolves the plugins' composer dependencies
into each plugin's `lib/`:

- `auth-oauth2` — OAuth2/OIDC sign-in (deps: `league/oauth2-client`, Guzzle, …)
- `auth-2fa` — authenticator-app two-factor auth (deps: `sonata-project/google-authenticator`)

They are copied to `/opt/osticket-plugins/` in the runtime image.

### Stage 2 — runtime (`php:8.3-apache-bookworm`)

1. Installs the system libraries osTicket's PHP extensions need
   (`libc-client2007e-dev` for `imap`, `libicu-dev` for `intl`, `libzip-dev`,
   FreeType/JPEG for `gd`, …).
2. Builds/enables the PHP extensions: `gd`, `gettext`, `imap`, `intl`,
   `mysqli`, `pdo_mysql`, `zip`, plus `apcu` from PECL.
3. Enables Apache `mod_rewrite` + `mod_headers` (osTicket's `.htaccess` needs
   them) and sets `ServerName localhost`.
4. Downloads the osTicket release zip for `OSTICKET_VERSION` (default
   `1.18.4`) and copies its `upload/` directory into `/var/www/html`.
5. **Bundles the language pack** for `OSTICKET_LANG` (default `en_US`):
   - `en_US` ships as a directory in the source; nothing is downloaded.
   - Any other language downloads
     `https://s3.amazonaws.com/downloads.osticket.com/lang/<minor>.x/<short>.phar`
     (e.g. `hu.phar`) and stores it under the **full** code (`hu_HU.phar`),
     both in `/opt/osticket-i18n/` and in `include/i18n/`. The build **fails
     loudly** if the pack can't be fetched.
   - If a corrected default-data override exists for that language
     (`/opt/osticket-i18n/<LANG>/queue.yaml`), it is also copied into
     `include/i18n/<LANG>/queue.yaml`.
6. Copies in `/opt/osticket-plugins` (from stage 1), `docker/provision.php`
   (→ `/opt/osticket-provision.php`), and the entrypoint.
7. Entrypoint `osticket-entrypoint`, `CMD ["apache2-foreground"]`,
   `EXPOSE 80`.

**Build args**: `OSTICKET_VERSION`, `OSTICKET_LANG`, `PLUGINS_COMMIT` — all
wired from `.env`/compose build args.

---

## 5. Container startup (`docker/entrypoint.sh`)

Runs as `osticket-entrypoint` on every `osticket` container start, *before*
Apache starts. Sequence:

1. **Ensure a config exists** — if `include/ost-config.php` is missing (empty
   volume), copy `setup/inc/ost-sampleconfig.php` there and chown it to
   `www-data` so the wizard can rewrite it.
2. **Detect installation** — if the config contains
   `define('OSTINSTALLED',TRUE)`, mark installed.
3. **Auto-install** (only if `OSTICKET_AUTOINSTALL=1` **and** not yet
   installed): starts Apache in the background, then POSTs the official wizard
   (`s=prereq` → `s=config` → `s=install`) via `curl` using the `OSTICKET_*` /
   `MARIADB_*` values, then stops Apache. The `install` step sends the admin
   account, helpdesk name/email, language, timezone, DB host `db`, and
   `prefix=ost_`. If `OSTICKET_HELPDESK_URL` is set, the `Host` header (and
   `X-Forwarded-Proto: https` for https URLs) is faked so the wizard records
   the real public URL. Fails hard if required vars are missing or the install
   didn't produce `OSTINSTALLED`.
4. **Remove `/setup`** once installed — osTicket requires this for hardening;
   the image does it automatically.
5. **Inject `TRUSTED_PROXIES`** into `ost-config.php` from
   `OSTICKET_TRUSTED_PROXIES` (idempotent; empty env leaves the file alone).
6. **Provision plugin files** — copy each `OSTICKET_PLUGINS` entry from
   `/opt/osticket-plugins/<name>` into `include/plugins/` (the volume shadows
   the image, so this re-syncs on every start).
7. **Sync language packs** — copy `/opt/osticket-i18n/*.phar` **and** any
   `/opt/osticket-i18n/*/` override directories into `include/i18n/`.
8. **Run `php /opt/osticket-provision.php`** if installed (§6).
9. `exec "$@"` → starts Apache.

`set -e` is on: any failing step aborts the container (so misconfiguration is
loud).

---

## 6. Provisioning (`docker/provision.php`)

A PHP CLI script run on every start after installation. It boots osTicket the
same way `manage.php` does (`Bootstrap::loadConfig()` →
`defineTables()` → `loadCode()` → `connect()` → `osTicket::start()`), then
reconciles configuration **declaratively** (idempotent — safe to run every
start):

1. **Plugins** — install + activate each name in `OSTICKET_PLUGINS`
   (`PluginManager::install()` + `update(['isactive' => 1])`). If any OAuth
   client ID is set, `auth-oauth2` is force-added even if not listed.
2. **OAuth instances** — one `auth-oauth2` plugin *instance* per configured
   IdP:
   - **Pocket ID** (`OSTICKET_OIDC_URL` + `OSTICKET_OIDC_CLIENT_ID`) — generic
     OIDC; endpoints `<url>/authorize`, `<url>/oauth/token`,
     `<url>/userinfo`; scopes `openid profile email`.
   - **Google** (`OSTICKET_GOOGLE_CLIENT_ID`) — uses the plugin's built-in
     Google template (correct endpoints/scopes/mappings baked in).
   - **Discord** (`OSTICKET_DISCORD_CLIENT_ID`) — generic OAuth2 with
     `identify email` scopes.
   - Redirect URI for all is `<helpdesk URL>/api/auth/oauth2`
     (`OSTICKET_HELPDESK_URL`, else the configured base URL).
   - Client secrets are stored encrypted by the plugin config.
3. **2FA instance** — if `auth-2fa` is active and has no instances, create
   one ("Two Factor Auth").
4. **System language** — enforce `system_language = OSTICKET_LANG` (the osTicket
   installer never persists this; see §11.2).
5. **Queue cycle repair** — scan `ost_queue`; if any queue's `parent_id` chain
   is circular (a queue is its own ancestor), reset the node that *closes the
   cycle* to `parent_id = 0`. This is the safety net for the defective hu_HU
   language pack (see §11.1).

> Provisioning gotchas baked into the code: it sets
> `$_SERVER['REQUEST_METHOD']='POST'` (config forms merge empty saved config
> otherwise) and it reuses the `ensure_plugin()` return values rather than
> re-querying `PluginManager::allInstalled()` (osTicket's ORM caches stale
> rows right after activate).

---

## 7. osTicket integration points

### 7.1 REST API

osTicket exposes `POST /api/tickets.json` (also `.xml`, `.email`) for creating
tickets, routed by `api/http.php` via `api/.htaccess`. Auth is an `X-API-Key`
header; the key must be active and its IP must match the caller. Note: the
public API has no ticket-query/status endpoint.

### 7.2 Signal / event system (background)

osTicket's internal `Signal::send(...)` hook points (e.g. `ticket.created`,
`model.updated`) power its plugin ecosystem. This stack uses the plugin API
(`PluginManager`, `PluginConfig`) for OAuth/2FA provisioning.

### 7.3 Database tables the stack reads/creates

| Table | Who | Why |
|-------|-----|-----|
| `ost_config` | `provision.php` | set/read `system_language`; plugin instance config |
| `ost_plugin`, `ost_plugin_instance` | `provision.php` | install/activate plugins and OAuth instances |
| `ost_queue` | `provision.php` | repair circular `parent_id` chains |

---

## 8. Environment variable reference

Everything is configured through `.env` (gitignored, mode 600). Compose
substitutes `${VAR}` from it. Changes require `docker compose up -d` to
re-apply (and `--build` for anything baked into the image).

### 8.1 MariaDB

| Variable | Default | Used by | Purpose |
|----------|---------|---------|---------|
| `MARIADB_ROOT_PASSWORD` | — | db | MariaDB root password |
| `MARIADB_DATABASE` | `osticket` | db, osticket | database name |
| `MARIADB_USER` | `osticket` | db, osticket | osTicket DB user |
| `MARIADB_PASSWORD` | — | db, osticket | DB password |

### 8.2 osTicket

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_VERSION` | `1.18.4` | osTicket release to build (build arg) |
| `OSTICKET_HTTP_PORT` | `8080` | Host port → container port 80 |
| `OSTICKET_TRUSTED_PROXIES` | empty | Comma-separated proxy IPs/CIDRs trusted for `X-Forwarded-*` (see README §Reverse proxy) |

### 8.3 Auto-setup (used only when `OSTICKET_AUTOINSTALL=1`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_AUTOINSTALL` | `0` | `1` = drive the web wizard on first boot; `0` = manual wizard |
| `OSTICKET_HELPDESK_NAME` | — | Helpdesk name (required for auto-setup) |
| `OSTICKET_DEFAULT_EMAIL` | — | Default system email (required) |
| `OSTICKET_LANG` | `en_US` | Primary language; pack bundled at build time; enforced as system language on every start |
| `OSTICKET_TIMEZONE` | `UTC` | Default timezone |
| `OSTICKET_HELPDESK_URL` | — | Public helpdesk URL (no trailing slash); used for the wizard and OAuth redirect URIs |

### 8.4 Admin account (auto-setup only)

`OSTICKET_ADMIN_FNAME` (default `Admin`), `OSTICKET_ADMIN_LNAME` (default
`User`), `OSTICKET_ADMIN_EMAIL`, `OSTICKET_ADMIN_USERNAME`, `OSTICKET_ADMIN_PASSWORD`.
Constraints: admin email ≠ default system email; admin username not one of
`admin`/`admins`/`username`/`osticket`.

### 8.5 Plugins & OAuth

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_PLUGINS` | `auth-oauth2,auth-2fa` | Comma-separated plugins to install/activate/provision |
| `OSTICKET_OIDC_NAME` | `Pocket ID` | Pocket ID login-button name |
| `OSTICKET_OIDC_URL` | — | Pocket ID issuer base URL |
| `OSTICKET_OIDC_CLIENT_ID` | — | Pocket ID client ID |
| `OSTICKET_OIDC_CLIENT_SECRET` | — | Pocket ID client secret (encrypted in DB) |
| `OSTICKET_OIDC_AUTH_TARGET` | `agents` | `none`/`agents`/`users`/`all` |
| `OSTICKET_OIDC_ATTR_USERNAME` | `preferred_username` | Userinfo claim used as the osTicket username |
| `OSTICKET_GOOGLE_NAME` | `Google` | Google login-button name |
| `OSTICKET_GOOGLE_CLIENT_ID` | — | Google OAuth client ID |
| `OSTICKET_GOOGLE_CLIENT_SECRET` | — | Google OAuth client secret |
| `OSTICKET_GOOGLE_AUTH_TARGET` | `agents` | see above |
| `OSTICKET_DISCORD_NAME` | `Discord` | Discord login-button name |
| `OSTICKET_DISCORD_CLIENT_ID` | — | Discord OAuth client ID |
| `OSTICKET_DISCORD_CLIENT_SECRET` | — | Discord OAuth client secret |
| `OSTICKET_DISCORD_AUTH_TARGET` | `agents` | see above |

### 8.6 `get-osticket.sh` (release bootstrap)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_CHANNEL` | `stable` | `stable` = latest stable release; `experimental` = latest prerelease |
| `OSTICKET_RELEASE` | `latest` | Pin an exact tag (wins over channel) |
| `GH_TOKEN` | — | GitHub token for private-repo downloads |

---

## 9. Volumes and the `include/` shadowing problem

`include/` in the osTicket container is the named volume `osticket_data`. This
is great for persistence (`ost-config.php`, plugins, language packs survive
container recreation) but it means **the volume shadows the image's `include/`**
— rebuilding the image does **not** update files that already exist in the
volume.

The stack works around this by **re-syncing from the image on every start**:

- Plugin files: copied from `/opt/osticket-plugins/<name>` → `include/plugins/`.
- Language packs: copied from `/opt/osticket-i18n/*.phar` and override
  directories → `include/i18n/`.

So plugin and language-pack updates do ship on rebuild — but files that are
*only* written once (like `ost-config.php`, or the whole `include/` after the
installer runs) are never overwritten by a rebuild. When in doubt, back up and
start from a clean volume (`docker compose down -v`) rather than fighting a
stale volume.

---

## 10. Known issues, decisions & how they were solved

This section is the "journey" — real problems hit while building the stack and
how each is handled so you don't re-trip over them.

### 10.1 hu_HU language pack breaks the staff panel (500 after login)

**Symptom**: with `OSTICKET_LANG=hu_HU`, logging into `/scp/` returns an empty
HTTP 500. `docker compose logs` shows nothing.

**Root cause**: the official `hu_HU` pack's `queue.yaml` sets the root ticket
queues to a non-zero `parent_id` — the "Open" queue (`id: 1`) points to
itself, and My Tickets/Closed point to Open instead of being roots.
`CustomQueue::getHierarchicalQueues()` (include/class.queue.php) recursively
walks the parent tree and **infinite-loops** on the self-reference, exhausting
PHP memory (128 MB default) → Apache returns a generic 500.

**Why it was silent**: the image ships **no `php.ini`**, so PHP's web SAPI
defaults apply (`display_errors`/`log_errors` off) and fatal errors vanish.

**Fix (layered)**:
1. The image ships a corrected override at
   `docker/i18n/hu_HU/queue.yaml` (root queues → `parent_id: 0`), staged into
   `/opt/osticket-i18n/hu_HU/` and synced into the volume on every start.
   osTicket's `DataTemplate` (include/class.i18n.php) **prefers a directory**
   (`include/i18n/<lang>/queue.yaml`) over the `.phar`, so the override wins at
   install time without touching the phar.
2. `docker/provision.php` also **repairs any circular/dangling `parent_id`**
   on every start — a self-healing safety net (only the node that closes the
   cycle is demoted to root, so children keep their parent).

### 10.2 `system_language` silently stays `en_US`

The wizard's `Install::install()` builds `new Internationalization($lang)`
but never writes `system_language`; without an installed pack,
`Internationalization::__construct()` keeps only `en_US` and
`loadDefaultData()` writes `system_language=en_US`. Because the pack is now
bundled at build time this is fixed automatically at install; for existing
installs, `provision.php` enforces `system_language = OSTICKET_LANG` on every
start.

### 10.3 PHP image pinning / MySQL vs MariaDB

- `php:8.3-apache-bookworm` is pinned. The floating `php:8.3-apache` tag
  tracks Debian trixie, where `libc-client-dev` (needed for `imap`) no longer
  exists. `imap` is bundled in PHP 8.3 but moved to PECL in 8.4.
- The DB is **MariaDB**, not MySQL 8 — MySQL 8's `caching_sha2_password` auth
  breaks osTicket's installer.
- Do **not** use the stale official `osticket/osticket` hub image (PHP 7 era);
  v1.18.4 needs PHP 8.2–8.4.

### 10.4 osTicket REST API notes

- The public API only supports **ticket creation** (and the cron endpoint) —
  there is **no** endpoint to read/query ticket status.
- API keys are bound to an **exact client IP**: `ApiController::getKey()`
  looks the key up with `WHERE apikey=? AND ipaddr=<REMOTE_ADDR>`. A CIDR or
  `0.0.0.0/0` does **not** authenticate.
- The ticket form has a **required `subject`**; ticket creation fails without
  it.

### 10.5 `/usr/sbin/sendmail: not found`

The image has no MTA, so any osTicket attempt to send email logs this warning
(and email features won't deliver unless you configure SMTP in the admin
panel). It is benign for the stack's operation but means outgoing email
notifications require an SMTP setup in osTicket.

---

## 11. Release channels & workflow

- **`main`** — stable development; releases are normal GitHub releases.
- **`experimental`** — experimental features; cut as GitHub **prereleases**
  from this branch (e.g. `v1.1.0-exp.1`).
- `get-osticket.sh` resolves `OSTICKET_CHANNEL` to either
  `/releases/latest` (stable, excludes prereleases) or the most recent
  `"prerelease": true` release (experimental), with a fallback to stable until
  the first prerelease exists. `OSTICKET_RELEASE` pins an exact tag.
- Every release attaches `get-osticket.sh` so the one-liner
  (`curl .../releases/latest/download/get-osticket.sh | sh -s -- -y --auto`)
  resolves.

---

## 12. Data flows (walkthroughs)

### First boot (auto-setup)

1. `install.sh` writes `.env`, `docker compose build`, `docker compose up -d`.
2. `db` initializes (MariaDB entrypoint creates database/user from `MARIADB_*`).
3. `osticket` entrypoint: config doesn't exist → copy sample config → not
   installed + `OSTICKET_AUTOINSTALL=1` → run wizard POSTs → `ost-config.php`
   now has `OSTINSTALLED` → remove `/setup` → provision → Apache starts.
4. `provision.php` installs plugins, creates OAuth/2FA instances, sets
   `system_language`, repairs queues.
5. Log in at `http://localhost:PORT/scp/`.

### Manual web wizard

1. `docker compose up -d` (no `OSTICKET_AUTOINSTALL`, or it's `0`).
2. Browse to `http://localhost:PORT/setup/` — the entrypoint pre-created
   `ost-config.php` from the sample config, so the wizard form appears.
3. Enter DB host `db`, database/user/password from `.env`; the wizard writes
   the final `ost-config.php` and creates the admin account.
4. Restart the container (`docker compose restart osticket`) — the entrypoint
   removes `/setup` and runs provisioning.

### OAuth sign-in

1. User clicks the provider button on `/scp/login.php` (or the client portal).
2. Browser → provider (Google/Discord/Pocket ID) with the registered redirect
   URI `<helpdesk URL>/api/auth/oauth2`.
3. Provider → back to that URI with `code`/`state`; the `auth-oauth2` plugin's
   callback exchanges the code, loads the resource owner, and signs the agent
   in **only if a matching staff account already exists** — OAuth never
   auto-creates staff accounts.

---

## 13. Troubleshooting cheat-sheet

| Problem | Likely cause / fix |
|---------|--------------------|
| `/scp/` 500 after login | stale `ost_queue` cycle → `docker compose up -d` (provision repairs it); rebuild if on an old image |
| `sendmail: not found` | No MTA in the image; configure SMTP in osTicket if you need email |
| osTicket version not updating | volume shadows `include/`; see §9 |
| Build fails fetching language pack | `OSTICKET_LANG` unsupported, or offline at build time (by design — loud) |
| `docker compose up` leaves services unhealthy | recreate cleanly: `docker compose down && docker compose up -d` |

---

## 14. Glossary

- **IdP** — Identity Provider (Pocket ID, Google, Discord).
- **OAuth2 / OIDC** — open authorization / OpenID Connect; used for sign-in.
- **2FA** — two-factor authentication (authenticator app).
- **`include/`** — osTicket's config/plugin/i18n directory (`ost-config.php`
  lives here); a named volume in this stack.
- **`ost_` prefix** — osTicket table prefix (`ost_ticket`, `ost_queue`, …).
- **API key** — osTicket credential for the REST API, bound to an exact IP.
