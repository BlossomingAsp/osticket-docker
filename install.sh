#!/usr/bin/env bash
set -euo pipefail

# osTicket Docker stack installer
#
# Creates .env from defaults, prompts for the DB secrets, builds the
# osTicket image, then starts the stack with docker compose.
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
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1 (see --help)" ;;
    esac
done

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not available"

gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
    fi
}

# Ask for a secret unless already supplied via the environment (e.g.
# MARIADB_ROOT_PASSWORD=... ./install.sh). Blank input -> random password.
secret() {
    local label="$1" val=""
    if [ "$ASK" = 1 ]; then
        read -r -s -p "$label (blank = auto-generate): " val || true
        # Cosmetic newline for the silent read; keep stdout clean so the
        # captured value has no leading line break.
        printf '\n' >&2
    fi
    [ -n "$val" ] || val="$(gen_password)"
    printf '%s' "$val"
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

if [ "$SKIP_PROMPTS" = 0 ]; then
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
    } > .env
    info ".env written (mode 600, gitignored)"
else
    . ./.env 2>/dev/null || true
    port="${PORT:-${OSTICKET_HTTP_PORT:-8080}}"
    root_pass="${MARIADB_ROOT_PASSWORD:-}"
    user_pass="${MARIADB_PASSWORD:-}"
    version="${VERSION:-${OSTICKET_VERSION:-1.18.4}}"
    TRUSTED_PROXIES="${TRUSTED_PROXIES:-${OSTICKET_TRUSTED_PROXIES:-}}"
fi

info "osTicket v${version} on host port ${port}"
if [ "$DRY_RUN" = 1 ]; then
    cat <<EOF
Dry run complete. To start the stack:

  docker compose build
  docker compose up -d

Then open http://localhost:${port}/setup/ (MySQL host: db, user: osticket).
EOF
    exit 0
fi

info "Building image (osTicket v${version})"
docker compose build

info "Starting the stack"
docker compose up -d

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
