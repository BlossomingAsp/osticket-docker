# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **PHP OPcache** enabled and tuned in the image (`opcache.memory_consumption=128`, `opcache.max_accelerated_files=10000`) for a clear PHP performance win.
- **PHP/Apache hardening**: `expose_php=Off`, `ServerTokens Prod`, `ServerSignature Off`.
- **Discord bot rate limiting**: a per-user cooldown (`OSTICKET_DISCORD_RATE_LIMIT`, default 300s) on `!ticket` — spam/DoS guard that reacts with ⏳ and ignores the request during the cooldown.
- **Discord bot graceful shutdown**: the poll loop is cancelled and the DB connection closed on SIGTERM/SIGINT.
- README section and commented `deploy.resources` blocks in `docker-compose.yml` documenting optional container resource limits (db 2G/2cpu, osticket 1G/2cpu, discord-bot 256M/0.5cpu).

### Fixed

- **Piped installs no longer silently skip prompts**: when `install.sh` runs via `curl ... | sh`, stdin is not a terminal, so every `read` prompt got EOF and silently fell back to defaults. `install.sh` now detects a non-terminal stdin and switches to non-interactive mode (`SETUP_MODE=auto` unless `--manual` is passed) with a notice instead of pretending to prompt.
- **`get-osticket.sh` keeps its files**: the bootstrap used to extract into a `mktemp -d` temp directory that was deleted on exit, leaving no local copy of the stack. It now extracts into `./osticket-docker/` (override with `OSTICKET_DIR`) and keeps the files, so you can manage/update the stack afterwards; only a read-only current directory falls back to a cleaned-up temp dir.

## [v1.1.0-exp.1] - 2026-08-03

### Added

- **Release channels**: `get-osticket.sh` now supports `OSTICKET_CHANNEL=stable|experimental` (default `stable`). The `experimental` channel resolves the latest GitHub **prerelease** and falls back to stable until the first one exists; experimental features are developed on the `experimental` branch and cut as prerelease tags from it (e.g. `v1.1.0-exp.1`). `OSTICKET_RELEASE` still pins a specific tag regardless of channel.
- **Discord ticket bot** (experimental): a `discord-bot` compose service that turns `!ticket` messages in a Discord channel into osTicket tickets (via the REST API) and mirrors the ticket status back onto the message as reactions. The bot polls `ost_ticket`/`ost_ticket_status` on a configurable interval and updates reactions using a configurable `OSTICKET_DISCORD_STATUS_EMOJIS` map. Mapping (`discord message ↔ ticket`) is stored in a new `ost_discord_ticket_map` table, auto-created on start. See README for the full setup checklist.
- `docs/ARCHITECTURE.md`: a comprehensive technical reference covering every component, all environment variables, data flows, and known issues.

### Changed

- The `discord-bot` now runs on a static IP (`172.30.0.10`) on a dedicated compose subnet, because osTicket API keys are bound to an exact client IP (a CIDR/wildcard will not authenticate). The API key's IP field must be set to `172.30.0.10`.

### Fixed

- The one-liner bootstrap (`curl ... | sh -s -- -y --auto`) no longer fails with "helpdesk name required for auto-setup": the four required auto-setup fields now fall back to defaults (`Help Desk` / `helpdesk@localhost` / `admin@localhost` / `admin1`) when left blank, both non-interactively and when pressing Enter at an interactive prompt. Explicit `OSTICKET_*` exports still win.

## [v1.0.3] - 2026-08-02

### Added

- **Language packs**: `OSTICKET_LANG` (e.g. `hu_HU`) is now bundled into the image at build time — the matching pack is downloaded from `downloads.osticket.com` (as `<short-code>.phar`, stored under the full language code) and re-synced into the `include/` volume on every container start. A fresh install now registers the pack and persists `system_language`, and `docker/provision.php` enforces `system_language = OSTICKET_LANG` on every start (previously a non-English install silently stayed `en_US` because the osTicket installer never writes `system_language`). The build fails loudly if the pack cannot be fetched.
- `install.sh` now reports when the osTicket update check is skipped due to an explicit `-v` version.
- README section on where to obtain each OAuth provider's credentials (Pocket ID, Google, Discord) and the shared redirect-URI/HTTPS requirements.

### Fixed

- **hu_HU language pack `queue.yaml` is defective upstream**: the root queues get a non-zero `parent_id` (the "Open" queue points to itself, and My Tickets/Closed point to Open instead of being roots), which made `CustomQueue::getHierarchicalQueues()` recurse forever and the staff panel die with a memory-exhaustion 500 right after login. The image now ships a corrected `queue.yaml` override (osTicket's `DataTemplate` prefers a directory over the phar), re-synced into the `include/` volume on every start; `docker/provision.php` also repairs any circular/dangling queue `parent_id` on every start.

## [v1.0.2] - 2026-08-01

### Added

- `install.sh` now checks the configured `OSTICKET_VERSION` against the latest osTicket release from the GitHub API and prompts to bump to it when newer. With an explicit `-v`, non-interactively, and in `--dry-run` it only reports availability — never prompts or modifies `.env`. Existing `.env` is updated in place when the update is accepted.
- New `update.sh`: queries the latest osTicket release, shows the configured vs latest version, and on approval bumps `OSTICKET_VERSION` in `.env` and rebuilds the stack. Supports `-y` and `--dry-run`.

## [v1.0.1] - 2026-08-01

### Added

- `CHANGELOG.md` for this project.
- Full `.env` configuration reference in the README (every `MARIADB_*`/`OSTICKET_*` variable, its default, and purpose).
- Auto-setup section documenting required variables and constraints (reserved admin usernames, admin email must differ from the default system email).
- `install.sh` flag reference (`-y`, `-p`, `-v`, `-t`, `--auto`, `--manual`, `--dry-run`, `-h`).
- Updating and Backups sections (version bumps + volume rebuild caveat; `mariadb-dump` + volume backup).

### Changed

- Rewrote `README.md` as a complete human-facing user guide, split from the agent/dev runbook in `AGENTS.md`.
- `AGENTS.md` now explicitly scopes itself to development, release workflow, and implementation gotchas.
- `get-osticket.sh` `DEFAULT_TAG` fallback bumped to `v1.0.1`.

## [v1.0.0] - 2026-08-01

### Added

- Env-driven **auto-install** of osTicket: `docker/entrypoint.sh` POSTs the official setup wizard (`prereq` → `config` → `install`) on first boot when `OSTICKET_AUTOINSTALL=1`, using `OSTICKET_*`/`MARIADB_*` variables. No browser required.
- Automatic removal of `/var/www/html/setup` on the next container start once installed.
- **Plugin + OAuth/OIDC provisioning** (`docker/provision.php`): installs/activates the bundled `auth-oauth2` and `auth-2fa` plugins and creates per-provider OAuth instances (Pocket ID, Google, Discord) from `.env`, re-run idempotently on every start.
- `OSTICKET_PLUGINS`, `OSTICKET_OIDC_*`, `OSTICKET_GOOGLE_*`, `OSTICKET_DISCORD_*` configuration variables.
- Reverse-proxy support via `OSTICKET_TRUSTED_PROXIES`, injected into `include/ost-config.php`'s `TRUSTED_PROXIES` define on container start.
- `install.sh` with auto-setup vs manual-wizard modes, non-interactive flags, and `--dry-run`.
- `get-osticket.sh` release bootstrap installer (downloads a release source tarball and runs its `install.sh`), honoring `GH_TOKEN` for private-repo downloads and `OSTICKET_RELEASE` for pinning.
- README user guide covering quick start, OAuth/OIDC sign-in, reverse-proxy/HTTPS, gotchas, and layout.

### Changed

- Initial tagged release of the custom PHP 8.3 Apache image + MariaDB stack.

[v1.1.0-exp.1]: https://github.com/BlossomingAsp/osticket-docker/releases/tag/v1.1.0-exp.1
[v1.0.3]: https://github.com/BlossomingAsp/osticket-docker/releases/tag/v1.0.3
[v1.0.2]: https://github.com/BlossomingAsp/osticket-docker/releases/tag/v1.0.2
[v1.0.1]: https://github.com/BlossomingAsp/osticket-docker/releases/tag/v1.0.1
[v1.0.0]: https://github.com/BlossomingAsp/osticket-docker/releases/tag/v1.0.0
