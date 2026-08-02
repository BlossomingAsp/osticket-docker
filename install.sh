#!/usr/bin/env bash
set -euo pipefail

# osTicket Docker stack installer
#
# Creates .env, builds the osTicket image, then starts the stack with
# docker compose. Asks whether to auto-setup (env-driven install, plugins
# and OAuth via OSTICKET_* vars) or use the manual web wizard. In manual
# mode only the core vars (DB, port, version, trusted proxies) are
# written; add OSTICKET_* vars to .env later if needed.
#
# Safe to re-run: an existing .env is left untouched unless you confirm
# an overwrite.

cd "$(dirname "$0")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { printf "${GREEN}==>${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die()   { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

ASK=1
DRY_RUN=0
PORT=""
VERSION=""
TRUSTED_PROXIES="${OSTICKET_TRUSTED_PROXIES:-}"
SETUP_MODE=""   # auto | manual

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Creates .env, builds the osTicket image and starts the docker compose stack.

Options:
  -y, --yes        non-interactive: auto-generate DB passwords, skip prompts
  -p, --port PORT  host HTTP port (default 8080)
  -v, --version V  osTicket version to build (default 1.18.4)
  -t, --trusted-proxies P
                   comma-separated proxy IPs/CIDRs to trust for X-Forwarded-*
                   headers (reverse-proxy/HTTPS deployments; optional)
      --auto       force auto-setup mode (used with -y for scripting)
      --manual     force manual-wizard mode (skips OSTICKET_* prompts)
      --dry-run    generate .env and print the commands without running them
  -h, --help       show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)    ASK=0; shift ;;
        -p|--port)   PORT="${2:?--port needs a value}"; shift 2 ;;
        -v|--version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        -t|--trusted-proxies) TRUSTED_PROXIES="${2:?--trusted-proxies needs a value}"; shift 2 ;;
        --auto)      SETUP_MODE=auto; shift ;;
        --manual)    SETUP_MODE=manual; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1 (see --help)" ;;
    esac
done

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not available"

# When installed via a pipe (`curl ... | sh`), stdin is not a terminal, so
# every `read` prompt below would get EOF and silently fall back to defaults
# (or worse, appear to hang). Detect that and switch to non-interactive mode.
if [ "$ASK" = 1 ] && ! [ -t 0 ]; then
    ASK=0
    SETUP_MODE="${SETUP_MODE:-auto}"
    info "stdin is not a terminal; running non-interactively (pass -y explicitly to suppress)"
fi

gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
    fi
}

# Ask for a secret unless already supplied via the environment. Blank
# input -> random password.
secret() {
    local label="$1" val=""
    if [ "$ASK" = 1 ]; then
        read -r -s -p "$label (blank = auto-generate): " val || true
        printf '\n' >&2
    fi
    [ -n "$val" ] || val="$(gen_password)"
    printf '%s' "$val"
}

# Ask for an optional secret; blank input stays empty (used for OAuth
# client secrets, which must match the IdP app registration).
optional_secret() {
    local label="$1" val=""
    if [ "$ASK" = 1 ]; then
        read -r -s -p "$label (blank = skip): " val || true
        printf '\n' >&2
    fi
    printf '%s' "$val"
}

ask() {
    local label="$1" current="$2" v
    if [ "$ASK" = 1 ]; then
        read -r -p "$label [${current}]: " v || true
        [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$current"
    else
        printf '%s' "$current"
    fi
}

# Latest released osTicket version via the GitHub API. Emits just the version
# number (no leading "v"); empty on failure so callers can skip the check.
latest_osticket() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsSL --max-time 15 -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/osTicket/osTicket/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/p' | head -n 1
}

# 0 (true) if "$1" is a newer version than "$2". Dotted-version compare via
# sort -V; tolerates an optional leading "v" on either side.
ver_newer() {
    local a b
    a="${1#v}"; b="${2#v}"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] \
        && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" = "$a" ]
}

# --- existing .env handling -----------------------------------------------
SKIP_PROMPTS=0
if [ -f .env ]; then
    if [ "$ASK" = 1 ]; then
        read -r -p "Existing .env found. Overwrite it? [y/N] " ans || true
        case "$ans" in
            y|Y) info "Overwriting .env" ;;
            *)    warn "Keeping existing .env"; SKIP_PROMPTS=1 ;;
        esac
    else
        warn ".env exists; leaving it untouched (delete it first to regenerate)"
        SKIP_PROMPTS=1
    fi
fi

if [ "$SKIP_PROMPTS" = 1 ]; then
    . ./.env 2>/dev/null || true
    port="${PORT:-${OSTICKET_HTTP_PORT:-8080}}"
    root_pass="${MARIADB_ROOT_PASSWORD:-}"
    user_pass="${MARIADB_PASSWORD:-}"
    version="${VERSION:-${OSTICKET_VERSION:-1.18.4}}"
    TRUSTED_PROXIES="${TRUSTED_PROXIES:-${OSTICKET_TRUSTED_PROXIES:-}}"
    SETUP_MODE=""
else
    info "Creating .env"
    root_pass="${MARIADB_ROOT_PASSWORD:-$(secret 'MariaDB root password')}"
    user_pass="${MARIADB_PASSWORD:-$(secret 'osTicket DB user password')}"

    port="${PORT:-8080}"
    if [ "$ASK" = 1 ]; then
        read -r -p "Host HTTP port [${port}]: " p || true
        [ -n "$p" ] && port="$p"
    fi
    case "$port" in (*[!0-9]*|'') die "invalid port: $port";; esac
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || die "port out of range: $port"

    version="${VERSION:-1.18.4}"

    if [ "$ASK" = 1 ]; then
        read -r -p "Trusted proxy IPs/CIDRs for X-Forwarded-* (optional, blank to skip): " tp || true
        [ -n "$tp" ] && TRUSTED_PROXIES="$tp"
    fi

    # --- setup mode --------------------------------------------------------
    if [ -z "$SETUP_MODE" ]; then
        if [ "$ASK" = 1 ]; then
            read -r -p "Installation mode: [1] Auto-setup (recommended) / [2] Manual wizard [1]: " m || true
            case "$m" in
                2|manual|Manual) SETUP_MODE=manual ;;
                *) SETUP_MODE=auto ;;
            esac
        else
            SETUP_MODE=auto
        fi
    fi
fi

# --- osTicket update check -------------------------------------------------
# Compare the configured OSTICKET_VERSION against the latest upstream release
# and offer to bump it. Never blocks the install: network/rate-limit failures
# just warn, and non-interactive runs report without changing anything.
if [ -z "$VERSION" ]; then
    latest="$(latest_osticket)"
    if [ -z "$latest" ]; then
        warn "could not check for the latest osTicket release (offline or rate-limited); continuing with v${version}"
    elif ver_newer "$latest" "$version"; then
        if [ "$ASK" = 1 ] && [ "$DRY_RUN" = 0 ]; then
            read -r -p "osTicket v${latest} is available (you have v${version}). Update to v${latest}? [y/N] " up || true
            case "$up" in
                y|Y)
                    info "Using osTicket v${latest}"
                    version="$latest"
                    if [ "$SKIP_PROMPTS" = 1 ] && [ -f .env ]; then
                        sed -i "s/^OSTICKET_VERSION=.*/OSTICKET_VERSION=${latest}/" .env
                        info "Updated OSTICKET_VERSION to ${latest} in .env"
                    fi
                    ;;
                *) warn "Staying on osTicket v${version}" ;;
            esac
        else
            warn "osTicket v${latest} is available (you have v${version}); set OSTICKET_VERSION=${latest} in .env or run ./update.sh"
        fi
    else
        info "osTicket v${version} is the latest release"
    fi
else
    info "osTicket update check skipped (explicit version -v ${VERSION})"
fi

# --- auto-setup values (only prompted/written in auto mode) ---------------
AUTOINSTALL=0
HELPDESK_NAME="${OSTICKET_HELPDESK_NAME:-}"
DEFAULT_EMAIL="${OSTICKET_DEFAULT_EMAIL:-}"
LANG_CODE="${OSTICKET_LANG:-en_US}"
TIMEZONE="${OSTICKET_TIMEZONE:-UTC}"
HELPDESK_URL="${OSTICKET_HELPDESK_URL:-}"
ADMIN_FNAME="${OSTICKET_ADMIN_FNAME:-Admin}"
ADMIN_LNAME="${OSTICKET_ADMIN_LNAME:-User}"
ADMIN_EMAIL="${OSTICKET_ADMIN_EMAIL:-}"
ADMIN_USERNAME="${OSTICKET_ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${OSTICKET_ADMIN_PASSWORD:-}"
PLUGINS="${OSTICKET_PLUGINS:-auth-oauth2,auth-2fa}"
OIDC_NAME="${OSTICKET_OIDC_NAME:-Pocket ID}"
OIDC_URL="${OSTICKET_OIDC_URL:-}"
OIDC_CLIENT_ID="${OSTICKET_OIDC_CLIENT_ID:-}"
OIDC_CLIENT_SECRET="${OSTICKET_OIDC_CLIENT_SECRET:-}"
OIDC_AUTH_TARGET="${OSTICKET_OIDC_AUTH_TARGET:-agents}"
OIDC_ATTR_USERNAME="${OSTICKET_OIDC_ATTR_USERNAME:-preferred_username}"
GOOGLE_NAME="${OSTICKET_GOOGLE_NAME:-Google}"
GOOGLE_CLIENT_ID="${OSTICKET_GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${OSTICKET_GOOGLE_CLIENT_SECRET:-}"
GOOGLE_AUTH_TARGET="${OSTICKET_GOOGLE_AUTH_TARGET:-agents}"
DISCORD_NAME="${OSTICKET_DISCORD_NAME:-Discord}"
DISCORD_CLIENT_ID="${OSTICKET_DISCORD_CLIENT_ID:-}"
DISCORD_CLIENT_SECRET="${OSTICKET_DISCORD_CLIENT_SECRET:-}"
DISCORD_AUTH_TARGET="${OSTICKET_DISCORD_AUTH_TARGET:-agents}"

# Sensible defaults for the required auto-setup fields, so an empty prompt
# (pressing Enter interactively or a bare non-interactive run) still produces
# a working install. Explicit OSTICKET_* exports or typed input always win.
if [ "$SETUP_MODE" = auto ]; then
    : "${HELPDESK_NAME:=Help Desk}"
    : "${DEFAULT_EMAIL:=helpdesk@localhost}"
    : "${ADMIN_EMAIL:=admin@localhost}"
    : "${ADMIN_USERNAME:=admin1}"
fi

if [ "$SKIP_PROMPTS" = 0 ] && [ "$SETUP_MODE" = auto ]; then
    AUTOINSTALL=1
    info "Auto-setup selected; prompting for installation details"
    HELPDESK_NAME="$(ask 'Helpdesk name' "$HELPDESK_NAME")"
    DEFAULT_EMAIL="$(ask 'Default system email' "$DEFAULT_EMAIL")"
    LANG_CODE="$(ask 'Primary language (e.g. en_US, de_DE)' "$LANG_CODE")"
    TIMEZONE="$(ask 'Default timezone (e.g. UTC, Europe/Berlin)' "$TIMEZONE")"
    HELPDESK_URL="$(ask 'Helpdesk public URL (optional, no trailing slash)' "$HELPDESK_URL")"
    ADMIN_FNAME="$(ask 'Admin first name' "$ADMIN_FNAME")"
    ADMIN_LNAME="$(ask 'Admin last name' "$ADMIN_LNAME")"
    ADMIN_EMAIL="$(ask 'Admin email' "$ADMIN_EMAIL")"
    ADMIN_USERNAME="$(ask 'Admin username' "$ADMIN_USERNAME")"
    ADMIN_PASSWORD="$(secret 'Admin password')"
    PLUGINS="$(ask 'Plugins (comma-separated)' "$PLUGINS")"

    if [ -n "$OIDC_CLIENT_ID" ] || [ "$ASK" = 1 ]; then
        OIDC_CLIENT_ID="$(ask 'Pocket ID client ID (blank to skip)' "$OIDC_CLIENT_ID")"
    fi
    if [ -n "$OIDC_CLIENT_ID" ]; then
        OIDC_NAME="$(ask 'Pocket ID display name' "$OIDC_NAME")"
        OIDC_URL="$(ask 'Pocket ID URL (blank to skip)' "$OIDC_URL")"
        [ -n "$OIDC_URL" ] || OIDC_CLIENT_ID=""
        if [ -n "$OIDC_URL" ]; then
            OIDC_CLIENT_SECRET="$(optional_secret 'Pocket ID client secret')"
            OIDC_AUTH_TARGET="$(ask 'Pocket ID auth target (none/agents/users/all)' "$OIDC_AUTH_TARGET")"
        fi
    fi

    if [ -n "$GOOGLE_CLIENT_ID" ] || [ "$ASK" = 1 ]; then
        GOOGLE_CLIENT_ID="$(ask 'Google client ID (blank to skip)' "$GOOGLE_CLIENT_ID")"
    fi
    if [ -n "$GOOGLE_CLIENT_ID" ]; then
        GOOGLE_NAME="$(ask 'Google display name' "$GOOGLE_NAME")"
        GOOGLE_CLIENT_SECRET="$(optional_secret 'Google client secret')"
        GOOGLE_AUTH_TARGET="$(ask 'Google auth target (none/agents/users/all)' "$GOOGLE_AUTH_TARGET")"
    fi

    if [ -n "$DISCORD_CLIENT_ID" ] || [ "$ASK" = 1 ]; then
        DISCORD_CLIENT_ID="$(ask 'Discord client ID (blank to skip)' "$DISCORD_CLIENT_ID")"
    fi
    if [ -n "$DISCORD_CLIENT_ID" ]; then
        DISCORD_NAME="$(ask 'Discord display name' "$DISCORD_NAME")"
        DISCORD_CLIENT_SECRET="$(optional_secret 'Discord client secret')"
        DISCORD_AUTH_TARGET="$(ask 'Discord auth target (none/agents/users/all)' "$DISCORD_AUTH_TARGET")"
    fi

    # --- validation --------------------------------------------------------
    [ -n "$HELPDESK_NAME" ] || die "helpdesk name required for auto-setup"
    [ -n "$DEFAULT_EMAIL" ] || die "default system email required for auto-setup"
    [ -n "$ADMIN_EMAIL" ] || die "admin email required for auto-setup"
    [ -n "$ADMIN_USERNAME" ] || die "admin username required for auto-setup"
    if [ "$ADMIN_EMAIL" = "$DEFAULT_EMAIL" ]; then
        die "admin email must differ from the default system email"
    fi
    case "${ADMIN_USERNAME,,}" in
        admin|admins|username|osticket) die "admin username '$ADMIN_USERNAME' is reserved by osTicket" ;;
    esac
fi

# --- write .env ------------------------------------------------------------
if [ "$SKIP_PROMPTS" = 0 ]; then
    umask 077
    {
        printf '%s\n' '# --- MariaDB ---'
        printf 'MARIADB_ROOT_PASSWORD=%s\n' "$root_pass"
        printf '%s\n' 'MARIADB_DATABASE=osticket'
        printf '%s\n' 'MARIADB_USER=osticket'
        printf 'MARIADB_PASSWORD=%s\n' "$user_pass"
        printf '%s\n' ''
        printf '%s\n' '# --- osTicket ---'
        printf 'OSTICKET_VERSION=%s\n' "$version"
        printf 'OSTICKET_HTTP_PORT=%s\n' "$port"
        printf '%s\n' '# Comma-separated proxy IPs/CIDRs to trust for X-Forwarded-* headers (reverse-proxy/HTTPS only). Leave empty otherwise.'
        printf 'OSTICKET_TRUSTED_PROXIES=%s\n' "$TRUSTED_PROXIES"
        printf '%s\n' ''
        printf 'OSTICKET_AUTOINSTALL=%s\n' "$AUTOINSTALL"
        if [ "$SETUP_MODE" = auto ]; then
            printf '%s\n' '# --- Auto-setup ---'
            printf 'OSTICKET_HELPDESK_NAME=%s\n' "$HELPDESK_NAME"
            printf 'OSTICKET_DEFAULT_EMAIL=%s\n' "$DEFAULT_EMAIL"
            printf 'OSTICKET_LANG=%s\n' "$LANG_CODE"
            printf 'OSTICKET_TIMEZONE=%s\n' "$TIMEZONE"
            printf 'OSTICKET_HELPDESK_URL=%s\n' "$HELPDESK_URL"
            printf '%s\n' '# --- Admin account ---'
            printf 'OSTICKET_ADMIN_FNAME=%s\n' "$ADMIN_FNAME"
            printf 'OSTICKET_ADMIN_LNAME=%s\n' "$ADMIN_LNAME"
            printf 'OSTICKET_ADMIN_EMAIL=%s\n' "$ADMIN_EMAIL"
            printf 'OSTICKET_ADMIN_USERNAME=%s\n' "$ADMIN_USERNAME"
            printf 'OSTICKET_ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
            printf '%s\n' '# --- Plugins ---'
            printf 'OSTICKET_PLUGINS=%s\n' "$PLUGINS"
            printf '%s\n' '# --- Pocket ID (OIDC) ---'
            printf 'OSTICKET_OIDC_NAME=%s\n' "$OIDC_NAME"
            printf 'OSTICKET_OIDC_URL=%s\n' "$OIDC_URL"
            printf 'OSTICKET_OIDC_CLIENT_ID=%s\n' "$OIDC_CLIENT_ID"
            printf 'OSTICKET_OIDC_CLIENT_SECRET=%s\n' "$OIDC_CLIENT_SECRET"
            printf 'OSTICKET_OIDC_AUTH_TARGET=%s\n' "$OIDC_AUTH_TARGET"
            printf 'OSTICKET_OIDC_ATTR_USERNAME=%s\n' "$OIDC_ATTR_USERNAME"
            printf '%s\n' '# --- Google OAuth ---'
            printf 'OSTICKET_GOOGLE_NAME=%s\n' "$GOOGLE_NAME"
            printf 'OSTICKET_GOOGLE_CLIENT_ID=%s\n' "$GOOGLE_CLIENT_ID"
            printf 'OSTICKET_GOOGLE_CLIENT_SECRET=%s\n' "$GOOGLE_CLIENT_SECRET"
            printf 'OSTICKET_GOOGLE_AUTH_TARGET=%s\n' "$GOOGLE_AUTH_TARGET"
            printf '%s\n' '# --- Discord OAuth ---'
            printf 'OSTICKET_DISCORD_NAME=%s\n' "$DISCORD_NAME"
            printf 'OSTICKET_DISCORD_CLIENT_ID=%s\n' "$DISCORD_CLIENT_ID"
            printf 'OSTICKET_DISCORD_CLIENT_SECRET=%s\n' "$DISCORD_CLIENT_SECRET"
            printf 'OSTICKET_DISCORD_AUTH_TARGET=%s\n' "$DISCORD_AUTH_TARGET"
        else
            printf '%s\n' '# Add OSTICKET_* vars below (see .env.example) to enable auto-install,'
            printf '%s\n' '# plugin provisioning and OAuth/OIDC after a manual install.'
        fi
    } > .env
    info ".env written (mode 600, gitignored)"
fi

info "osTicket v${version} on host port ${port}"

if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "Dry run complete. .env would contain:"
    sed 's/^/  /' .env 2>/dev/null || true
    echo
    if [ "$SETUP_MODE" = auto ]; then
        cat <<EOF
To start the stack (auto-setup):

  docker compose build
  docker compose up -d
EOF
    else
        cat <<EOF
To start the stack (manual wizard):

  docker compose build
  docker compose up -d
  open http://localhost:${port}/setup/
EOF
    fi
    exit 0
fi

info "Building image (osTicket v${version})"
docker compose build

info "Starting the stack"
docker compose up -d

if [ "$SETUP_MODE" = auto ]; then
    cat <<EOF

osTicket is auto-installing on first boot. Give the container a minute or
two, then log in at:

  http://localhost:${port}/scp/
    username: ${ADMIN_USERNAME}
    password: <from .env / generated during install>
EOF
else
    cat <<EOF

osTicket is up. Complete the web wizard at:

  http://localhost:${port}/setup/

Use these values in the installer:
  MySQL Hostname: db
  MySQL Database: osticket
  MySQL Username: osticket
  MySQL Password: ${user_pass:-<from .env>}

Staff control panel: http://localhost:${port}/scp/
EOF
fi
