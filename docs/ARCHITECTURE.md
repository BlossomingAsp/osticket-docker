# Architecture & Technical Reference

This document explains how the osTicket Docker stack works end to end: every
component, every environment variable, and the data flows that tie them
together. It is the companion to the user-facing `README.md` (install/config
guide) and `AGENTS.md` (agent/dev runbook). Read it top to bottom if you want
to *understand* the project; skip to a section if you want an answer.

---

## 1. What this project is

A self-hosted helpdesk stack built on [osTicket](https://osticket.com),
packaged as two (optionally three) Docker Compose services:

| Service | Image | Role |
|---------|-------|------|
| `db` | `mariadb:11.4` | osTicket's database |
| `osticket` | built from this repo (`Dockerfile`) | the helpdesk web app (PHP 8.3 + Apache) |
| `discord-bot` | built from `docker/discord-bot/Dockerfile` (experimental) | turns Discord messages into tickets and mirrors ticket status back as Discord reactions |

A single command can install osTicket **without a browser** by driving the
official web wizard internally (`OSTICKET_AUTOINSTALL=1`), and the image ships
community plugins for **OAuth/OIDC sign-in** (Pocket ID, Google, Discord) and
**two-factor authentication**.

> The `discord-bot` service and the `experimental` release channel are the
> current experimental work. They live on the `experimental` branch and are
> released as GitHub **prereleases**, not stable releases.

---

## 2. High-level architecture

```
                 ┌─────────────────────────────────────────────────┐
                 │                 docker network                  │
                 │             (172.30.0.0/24)                     │
                 │                                                 │
   browser ──►   │   ┌────────────┐   ┌───────────────┐            │
  :8080/8085     │   │  osticket  │   │     db        │            │
                 │   │ PHP 8.3    │──►│  MariaDB 11.4 │            │
                 │   │ Apache:80  │   │  :3306        │            │
                 │   └─────┬──────┘   └──────▲────────┘            │
                 │         │ REST API       │ direct SQL           │
                 │         │ /api/tickets   │ (status reads)       │
                 │   ┌─────▼──────────────────┴────────┐            │
                 │   │          discord-bot            │            │
                 │   │        (Python 3.11)            │            │
                 │   │  Discord Gateway (WebSocket)    │            │
                 │   └────────────────────────────────┘            │
                 └─────────────────────────────────────────────────┘
                                  │
                          ┌───────▼────────┐
                          │    Discord     │
                          │ server/channel │
                          └────────────────┘
```

**Volumes** (named, persist across container recreation):

- `osticket_data` → mounted at `/var/www/html/include` in the `osticket` container.
  Holds `ost-config.php`, plugins, and language packs. *Shadows the image's
  `include/`* (see §10).
- `db_data` → mounted at `/var/lib/mysql` in the `db` container. The database.

**Networking**: a single custom bridge network `172.30.0.0/24`. The
`discord-bot` is pinned to a static IP `172.30.0.10` (see §11.6 for why).

---

## 3. Repository layout

| Path | Purpose |
|------|---------|
| `Dockerfile` | Builds the `osticket` image (two stages, see §4) |
| `docker-compose.yml` | Declares `db`, `osticket`, `discord-bot`; volumes, healthchecks, env passthrough, network |
| `.env.example` | Template for `.env`; documents every variable |
| `.env` | **gitignored** — your actual secrets/configuration |
| `install.sh` | Interactive/non-interactive installer: writes `.env`, builds, starts; checks for osTicket updates |
| `update.sh` | Checks the latest osTicket release, bumps `OSTICKET_VERSION` in `.env`, rebuilds |
| `get-osticket.sh` | Release bootstrap: downloads a tagged source tarball and runs its `install.sh`; honors `OSTICKET_CHANNEL`/`OSTICKET_RELEASE` |
| `docker/entrypoint.sh` | `osticket` container startup script (see §5) |
| `docker/provision.php` | Post-install provisioning: plugins, OAuth/2FA instances, system language, queue repair (see §6) |
| `docker/i18n/hu_HU/queue.yaml` | Corrected Hungarian queue data that overrides a defective upstream pack (see §11.1) |
| `docker/discord-bot/` | The Python Discord bot (see §7) |
| `docs/ARCHITECTURE.md` | This document |
| `README.md`, `AGENTS.md`, `CHANGELOG.md` | User guide, dev runbook, changelog |

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
   `mysqli`, `pdo_mysql`, `zip`, plus `apcu` from PECL. **OPcache** is loaded
   (the base image ships it) and tuned via `docker/php-opcache.ini`
   (`opcache.memory_consumption=128`, `opcache.max_accelerated_files=10000`,
   `opcache.validate_timestamps=0`); the same file sets `expose_php=Off`.
3. Enables Apache `mod_rewrite` + `mod_headers` (osTicket's `.htaccess` needs
   them), sets `ServerName localhost`, and enables
   `docker/apache-security.conf` (`ServerTokens Prod`, `ServerSignature Off`).
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
     `identify email` scopes. Staff are matched by **email** (`attr_username`
     = `email`, so the mapped identifier is Discord's verified email and
     `Staff::lookup()` routes it to `WHERE email = ...`). Discord only returns
     an email for accounts that have one verified; users without a verified
     Discord email can't sign in.
   - Redirect URI for all is `<helpdesk URL>/api/auth/oauth2`
     (`OSTICKET_HELPDESK_URL`, else the configured base URL).
   - **Declarative reconcile**: an existing instance is not left untouched —
     `create_instance()` calls `update_instance_config()` to re-sync the plain
     config fields (`redirectUri`, `clientId`, provider endpoints, scopes,
     attribute mappings) with the env-derived values whenever they differ, so
     changing `OSTICKET_HELPDESK_URL` (or a client ID) and recreating the
     container actually reaches the OAuth flow. `SectionBreakField` separators
     (no stored value) and the `clientSecret` `PasswordField` (ciphertext) are
     skipped.
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
> otherwise); it reuses the `ensure_plugin()` return values rather than
> re-querying `PluginManager::allInstalled()` (osTicket's ORM caches stale
> rows right after activate); and `ensure_plugin()` returns the plugin **impl
> subclass** (`$p->getImpl()`), not the base `Plugin` row that
> `PluginManager::install()` creates — that base row has a null `config_class`,
> so `addInstance()` would crash with "Call to a member function getForm() on
> null" on the very first start. Because the impl's `lookup()` can itself
> return a stale ORM row (`isactive=0`) right after install, provisioning
> re-asserts `$impl->set('isactive', 1)` before returning it.

---

## 7. The Discord ticket bot (`docker/discord-bot/`)

A standalone Python 3.11 bot. It is **optional**: the compose service exits
cleanly (exit 0) when unconfigured, and `restart: on-failure` means it never
crash-loops.

| File | Responsibility |
|------|----------------|
| `config.py` | Reads every setting from environment variables into typed fields |
| `db.py` | MariaDB access: owns the `ost_discord_ticket_map` table, reads ticket status |
| `osticket_api.py` | Creates tickets via osTicket's REST API |
| `bot.py` | Discord Gateway client: listens for `!ticket`, parses messages, manages reactions, runs the poll loop |
| `Dockerfile` / `requirements.txt` / `.dockerignore` | Image packaging (discord.py, PyMySQL, requests) |

### 7.1 Message format

Messages in the configured channel that **start with the command word**
(default `!ticket`) are parsed as `Key: Value` lines (keys are
case-insensitive):

```
!ticket
Name: John Doe
Email: john@example.com
Phone: 555-1234
Channel: email
Message: I need help with my account
```

- **Required**: `name`, `email`, `message` (the `message` value may span
  multiple lines; subsequent non-`key:` lines are appended to it).
- **Optional**: `phone`, `channel` (preferred communication channel), and a
  `subject` override.
- Missing required fields → the bot reacts with ❌ and does nothing else.
- **Rate limiting**: a per-user cooldown (`RATE_LIMIT`, default 300s, `0` to
  disable) on ticket creation — a second `!ticket` from the same user within
  the window gets ⏳ and is ignored (spam/DoS guard).

### 7.2 Ticket creation flow

```
Discord !ticket message
        │
        ▼
bot.py: parse_ticket() ──► {name, email, phone, channel, message}
        │
        ├─ missing required fields ─► react ❌, stop
        ├─ user in rate-limit cooldown ─► react ⏳, stop
        │
        ▼
osticket_api.create_ticket()  POST http://osticket/api/tickets.json
        │                     headers: X-API-Key: <key>
        │                     body:    {topicId, subject, name, email,
        │                              phone, message, alert:false,
        │                              autorespond:false}
        ▼
osTicket creates the ticket, returns the number (HTTP 201)
        │
        ▼
bot.py: db.get_status_by_number()  → current status name (e.g. "Megnyit")
        db.save_mapping()          → ost_discord_ticket_map row
        message.add_reaction(emoji)→ initial status emoji (or fallback 📥)
```

Details handled in `osticket_api.py`:

- **Subject is derived** from the first line of the message (osTicket's ticket
  form has a required `subject` field).
- **Preferred channel** — if `CHANNEL_FIELD` names an osTicket dynamic-form
  field, it is passed as that field; otherwise it is folded into the message
  body ("Preferred communication channel: …").
- **Phone** — validated against osTicket's rule (7–16 digits); a phone that
  fails validation is folded into the message body ("Phone (unverified
  format): …") so it never blocks ticket creation.
- The `source`/origin is **not** sent (osTicket only accepts
  `web|staff|api|email` and defaults to `API` for this endpoint).

### 7.3 Status → reaction flow

Every `POLL_INTERVAL` seconds (default 30) the bot:

```
poll_loop()
  │  SELECT m.ticket_number, m.discord_message_id, m.discord_channel_id,
  │        m.last_status, s.name AS status_name
  │  FROM ost_discord_ticket_map m
  │  JOIN ost_ticket t  ON t.number  = m.ticket_number
  │  JOIN ost_ticket_status s ON s.id = t.status_id
  ▼
for each mapped ticket whose status changed:
  update_reaction(channel, message, status)
    │  • remove every reaction this bot owns that matches a status emoji
    │  • add the emoji for the new status (STATUS_EMOJIS map)
    ▼
  db.update_status(id, status)
```

The emoji map keys are matched **case-insensitively against the osTicket
status `name`**, which is **language-dependent** (see §11.4). A ticket with no
matching emoji falls back to `FALLBACK_EMOJI` (default 📥) on creation and is
left unchanged by the poller.

### 7.4 Why the bot reads the database

osTicket's public REST API only supports **ticket creation** (and the cron
endpoint) — there is **no endpoint to read a ticket's status**. So the bot
reads `ost_ticket` / `ost_ticket_status` directly from MariaDB (same
credentials as the stack), and keeps its own mapping table
`ost_discord_ticket_map` (auto-created on start) to know which Discord message
belongs to which ticket.

---

## 8. osTicket integration points

### 8.1 REST API

- Endpoint: `POST /api/tickets.json` (also `.xml`, `.email`)
- Routed by `api/http.php` via `api/.htaccess` rewrite.
- Auth: `X-API-Key` header; the key must be active and its IP must match the
  caller (§11.6).
- Creates the ticket and returns the ticket **number** as the response body
  (HTTP 201).

### 8.2 Signal / event system (background)

osTicket's internal `Signal::send(...)` hook points (e.g. `ticket.created`,
`model.updated`) power its plugin ecosystem. This stack uses the plugin API
(`PluginManager`, `PluginConfig`) for OAuth/2FA provisioning but does not
install a custom osTicket plugin for the Discord integration — the bot polls
instead.

### 8.3 Database tables the stack reads/creates

| Table | Who | Why |
|-------|-----|-----|
| `ost_config` | `provision.php` | set/read `system_language`; plugin instance config |
| `ost_plugin`, `ost_plugin_instance` | `provision.php` | install/activate plugins and OAuth instances |
| `ost_queue` | `provision.php` | repair circular `parent_id` chains |
| `ost_api_key` | admin creates, bot uses | API key auth for ticket creation |
| `ost_ticket`, `ost_ticket_status` | `discord-bot` | read ticket status for reactions |
| `ost_discord_ticket_map` | `discord-bot` (creates it) | Discord message ↔ ticket mapping |

---

## 9. Environment variable reference

Everything is configured through `.env` (gitignored, mode 600). Compose
substitutes `${VAR}` from it. Changes require `docker compose up -d` to
re-apply (and `--build` for anything baked into the image).

### 9.1 MariaDB

| Variable | Default | Used by | Purpose |
|----------|---------|---------|---------|
| `MARIADB_ROOT_PASSWORD` | — | db | MariaDB root password |
| `MARIADB_DATABASE` | `osticket` | db, osticket, discord-bot | database name |
| `MARIADB_USER` | `osticket` | db, osticket, discord-bot | osTicket DB user |
| `MARIADB_PASSWORD` | — | db, osticket, discord-bot | DB password |

### 9.2 osTicket

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_VERSION` | `1.18.4` | osTicket release to build (build arg) |
| `OSTICKET_HTTP_PORT` | `8080` | Host port → container port 80 |
| `OSTICKET_TRUSTED_PROXIES` | empty | Comma-separated proxy IPs/CIDRs trusted for `X-Forwarded-*` (see README §Reverse proxy) |

### 9.3 Auto-setup (used only when `OSTICKET_AUTOINSTALL=1`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_AUTOINSTALL` | `0` | `1` = drive the web wizard on first boot; `0` = manual wizard |
| `OSTICKET_HELPDESK_NAME` | `Help Desk` | Helpdesk name (falls back to default if blank) |
| `OSTICKET_DEFAULT_EMAIL` | `helpdesk@localhost` | Default system email (falls back to default if blank) |
| `OSTICKET_LANG` | `en_US` | Primary language; pack bundled at build time; enforced as system language on every start |
| `OSTICKET_TIMEZONE` | `UTC` | Default timezone |
| `OSTICKET_HELPDESK_URL` | — | Public helpdesk URL (no trailing slash); used for the wizard and OAuth redirect URIs |

### 9.4 Admin account (auto-setup only)

`OSTICKET_ADMIN_FNAME` (default `Admin`), `OSTICKET_ADMIN_LNAME` (default
`User`), `OSTICKET_ADMIN_EMAIL` (default `admin@localhost`), `OSTICKET_ADMIN_USERNAME`
(default `admin1`), `OSTICKET_ADMIN_PASSWORD` (always randomly generated when blank).
Constraints: admin email ≠ default system email; admin username not one of
`admin`/`admins`/`username`/`osticket`.

### 9.5 Plugins & OAuth

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

### 9.6 Discord ticket bot (experimental)

These `.env` names map to the bot container's internal variables.

| `.env` variable | Bot env | Default | Purpose |
|-----------------|---------|---------|---------|
| `OSTICKET_DISCORD_BOT_TOKEN` | `DISCORD_BOT_TOKEN` | — | Discord bot token (unset ⇒ bot exits cleanly) |
| `OSTICKET_DISCORD_CHANNEL_ID` | `DISCORD_CHANNEL_ID` | — | Channel to monitor |
| `OSTICKET_DISCORD_TICKET_COMMAND` | `DISCORD_TICKET_COMMAND` | `!ticket` | Command word that opens a ticket |
| `OSTICKET_DISCORD_API_KEY` | `OSTICKET_API_KEY` | — | osTicket API key for ticket creation |
| `OSTICKET_TOPIC_ID` | `OSTICKET_TOPIC_ID` | `1` | Help topic id for new tickets |
| `OSTICKET_DISCORD_CHANNEL_FIELD` | `CHANNEL_FIELD` | empty | osTicket dynamic-field name for the preferred channel; empty folds it into the message |
| `OSTICKET_DISCORD_POLL_INTERVAL` | `POLL_INTERVAL` | `30` | Seconds between status polls |
| `OSTICKET_DISCORD_RATE_LIMIT` | `RATE_LIMIT` | `300` | Minimum seconds between ticket creations per Discord user (spam/DoS guard; `0` disables) |
| `OSTICKET_DISCORD_STATUS_EMOJIS` | `STATUS_EMOJIS` | `{"open":"🟢","assigned":"🔵","answered":"💬","closed":"✅"}` | JSON map status-name → emoji (see §11.4) |
| `OSTICKET_DISCORD_FALLBACK_EMOJI` | `FALLBACK_EMOJI` | `📥` | Emoji used when a new ticket's status has no mapping |

Internal, not settable via `.env`: `OSTICKET_BASE_URL` (`http://osticket:80`),
`DB_HOST`/`DB_PORT` (`db`/`3306`), `DB_NAME`/`DB_USER`/`DB_PASSWORD` (from
`MARIADB_*`).

### 9.7 `get-osticket.sh` (release bootstrap)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSTICKET_CHANNEL` | `stable` | `stable` = latest stable release; `experimental` = latest prerelease |
| `OSTICKET_RELEASE` | `latest` | Pin an exact tag (wins over channel) |
| `GH_TOKEN` | — | GitHub token for private-repo downloads |

---

## 10. Volumes and the `include/` shadowing problem

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

The Discord bot keeps **no** state in osTicket's `include/`; its mapping table
lives in the database, so it is unaffected by volume semantics.

---

## 11. Known issues, decisions & how they were solved

This section is the "journey" — real problems hit while building the stack and
how each is handled so you don't re-trip over them.

### 11.1 hu_HU language pack breaks the staff panel (500 after login)

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

### 11.2 `system_language` silently stays `en_US`

The wizard's `Install::install()` builds `new Internationalization($lang)`
but never writes `system_language`; without an installed pack,
`Internationalization::__construct()` keeps only `en_US` and
`loadDefaultData()` writes `system_language=en_US`. Because the pack is now
bundled at build time this is fixed automatically at install; for existing
installs, `provision.php` enforces `system_language = OSTICKET_LANG` on every
start.

### 11.3 PHP image pinning / MySQL vs MariaDB

- `php:8.3-apache-bookworm` is pinned. The floating `php:8.3-apache` tag
  tracks Debian trixie, where `libc-client-dev` (needed for `imap`) no longer
  exists. `imap` is bundled in PHP 8.3 but moved to PECL in 8.4.
- The DB is **MariaDB**, not MySQL 8 — MySQL 8's `caching_sha2_password` auth
  breaks osTicket's installer.
- Do **not** use the stale official `osticket/osticket` hub image (PHP 7 era);
  v1.18.4 needs PHP 8.2–8.4.

### 11.4 Status emoji matching is language-dependent

The bot matches the emoji map against the osTicket status **`name`**, which is
translated (e.g. hu_HU: `Megnyit`, `Megoldott`, `Lezárt`). The default map uses
English names. For a non-English install, set
`OSTICKET_DISCORD_STATUS_EMOJIS` to your status names, e.g.:
`{"Megnyit":"🟢","Megoldott":"✅","Lezárt":"✅"}`.

### 11.5 osTicket ticket creation quirks

- The ticket form has a **required `subject`**; the bot derives it from the
  message's first line.
- The API `source`/origin must be one of `web|staff|api|email`. Passing
  anything else (e.g. `"Discord"`) returns
  `Invalid ticket origin given`. The bot omits it and osTicket defaults to
  `API`.
- The user form's `phone` field validates 7–16 digits; the bot pre-validates
  and folds bad phones into the message instead of failing the ticket.

### 11.6 osTicket API keys are bound to an exact IP

`ApiController::getKey()` looks the key up with
`WHERE apikey=? AND ipaddr=<REMOTE_ADDR>` — an **exact string match**. A CIDR
or `0.0.0.0/0` does **not** authenticate. Consequently:

- The `discord-bot` is pinned to a **static IP** (`172.30.0.10`) on a
  dedicated compose subnet (`172.30.0.0/24`).
- The osTicket API key's IP field must be set to `172.30.0.10`.

### 11.7 `/usr/sbin/sendmail: not found`

The image has no MTA, so any osTicket attempt to send email logs this warning
(and email features won't deliver unless you configure SMTP in the admin
panel). It is benign for the Discord bot (which doesn't send email) but means
outgoing email notifications require an SMTP setup in osTicket.

---

## 12. Release channels & workflow

- **`main`** — stable development; releases are normal GitHub releases.
- **`experimental`** — experimental features (e.g. the Discord bot); cut as
  GitHub **prereleases** from this branch (e.g. `v1.1.0-exp.1`).
- `get-osticket.sh` resolves `OSTICKET_CHANNEL` to either
  `/releases/latest` (stable, excludes prereleases) or the most recent
  `"prerelease": true` release (experimental), with a fallback to stable until
  the first prerelease exists. `OSTICKET_RELEASE` pins an exact tag.
- Every release attaches `get-osticket.sh` so the one-liner
  (`curl .../releases/latest/download/get-osticket.sh | sh -s -- -y --auto`)
  resolves.

---

## 13. Data flows (walkthroughs)

### First boot (auto-setup)

1. `install.sh` writes `.env`, `docker compose build`, `docker compose up -d`.
2. `db` initializes (MariaDB entrypoint creates database/user from `MARIADB_*`);
   its healthcheck is `mariadb -e "SELECT 1"` — a real query, because
   `mariadb-admin ping` reports alive before MariaDB actually accepts
   connections, which let `osticket` start (and the wizard DB step fail) too
   early. `osticket`'s `depends_on` waits for `service_healthy`.
3. `osticket` entrypoint: config doesn't exist → copy sample config → not
   installed + `OSTICKET_AUTOINSTALL=1` → run wizard POSTs → `ost-config.php`
   now has `OSTINSTALLED` → remove `/setup` → provision → Apache starts.
4. `provision.php` installs plugins, creates OAuth/2FA instances, sets
   `system_language`, repairs queues.
5. Log in at `http://localhost:PORT/scp/`.

### Discord message → ticket

See §7.2. Key point: the Discord user's identity is whatever the message body
says (`name`/`email`); the posting bot's Discord ID is only recorded in
`ost_discord_ticket_map.discord_user_id` for reaction tracking.

### Ticket status → reaction

See §7.3. Status changes made in osTicket (staff UI, API, email piping) are
picked up by the poller and mirrored onto the original Discord message.

### OAuth sign-in

1. User clicks the provider button on `/scp/login.php` (or the client portal).
2. Browser → provider (Google/Discord/Pocket ID) with the registered redirect
   URI `<helpdesk URL>/api/auth/oauth2`.
3. Provider → back to that URI with `code`/`state`; the `auth-oauth2` plugin's
   callback exchanges the code, loads the resource owner, and signs the agent
   in **only if a matching staff account already exists** — OAuth never
   auto-creates staff accounts.

---

## 14. Troubleshooting cheat-sheet

| Problem | Likely cause / fix |
|---------|--------------------|
| `/scp/` 500 after login | stale `ost_queue` cycle → `docker compose up -d` (provision repairs it); rebuild if on an old image |
| Discord bot not creating tickets | API key IP ≠ `172.30.0.10`; key missing "Can create tickets"; `OSTICKET_DISCORD_API_KEY` unset; message missing required fields (bot reacts ❌) |
| Bot not reacting to status changes | `STATUS_EMOJIS` keys don't match your language's status names; poll interval; bot lacks Add Reactions permission |
| Bot container exited | Unconfigured (`DISCORD_BOT_TOKEN`/`DISCORD_CHANNEL_ID` empty) — expected; add them and `docker compose up -d` |
| `sendmail: not found` | No MTA in the image; configure SMTP in osTicket if you need email |
| OAuth login → provider rejects `redirect_uri` ("Not a well formed URL", mismatch) | The plugin instance was provisioned with a stale `redirectUri` (e.g. `http://localhost/api/auth/oauth2` captured during auto-install before `OSTICKET_HELPDESK_URL` was set). Set `OSTICKET_HELPDESK_URL` in `.env` to the public URL, register exactly `<URL>/api/auth/oauth2` in the IdP app, then `docker compose up -d` — provisioning now reconciles the existing instance's `redirectUri` on start |
| osTicket version not updating | volume shadows `include/`; see §10 |
| Build fails fetching language pack | `OSTICKET_LANG` unsupported, or offline at build time (by design — loud) |
| `docker compose up` leaves services unhealthy | recreate cleanly: `docker compose down && docker compose up -d` |

---

## 15. Glossary

- **IdP** — Identity Provider (Pocket ID, Google, Discord).
- **OAuth2 / OIDC** — open authorization / OpenID Connect; used for sign-in.
- **2FA** — two-factor authentication (authenticator app).
- **Gateway** — Discord's WebSocket API that bots connect to for events.
- **Reaction** — a Discord emoji added to a message; used here as a status
  indicator.
- **`include/`** — osTicket's config/plugin/i18n directory (`ost-config.php`
  lives here); a named volume in this stack.
- **`ost_` prefix** — osTicket table prefix (`ost_ticket`, `ost_queue`, …).
- **API key** — osTicket credential for the REST API, bound to an exact IP.
