# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[v1.0.1]: https://github.com/BlossomingAsp/osticket-docker/releases/tag/v1.0.1
[v1.0.0]: https://github.com/BlossomingAsp/osticket-docker/releases/tag/v1.0.0
