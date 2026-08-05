#!/usr/bin/env bash
set -euo pipefail

# osTicket Docker stack updater
#
# Queries the latest released osTicket version and, if the version configured
# in .env is older, offers to update OSTICKET_VERSION and rebuild the stack.
#
#   ./update.sh            interactive: query + prompt before updating
#   ./update.sh -y         accept the update without prompting
#   ./update.sh --dry-run  report what would change without modifying anything

cd "$(dirname "$0")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { printf "${GREEN}==>${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die()   { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

YES=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./update.sh [options]

Checks the configured OSTICKET_VERSION against the latest osTicket release
and, if newer, updates .env and rebuilds the stack.

Options:
  -y, --yes       accept the update without prompting
      --dry-run   show what would change without modifying anything
  -h, --help      show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)    YES=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1 (see --help)" ;;
    esac
done

latest_osticket() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsSL --max-time 15 -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/osTicket/osTicket/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/p' | head -n 1
}

ver_newer() {
    local a b
    a="${1#v}"; b="${2#v}"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] \
        && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" = "$a" ]
}

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"

# Emits `--profile mail` (with trailing space) when the optional Stalwart mail
# server is enabled in .env, so the rebuild also updates it and the cron service.
compose_profiles() {
    local on
    on="$(sed -n 's/^OSTICKET_MAIL_ENABLED=//p' .env 2>/dev/null | tail -n 1 | tr -d '\r')"
    case "${on,,}" in
        1|yes|true|on) printf '%s ' '--profile mail' ;;
    esac
}

current="${OSTICKET_VERSION:-1.18.4}"
if [ -f .env ]; then
    . ./.env 2>/dev/null || true
    current="${OSTICKET_VERSION:-$current}"
fi

info "Checking for osTicket updates"
latest="$(latest_osticket)" || true
if [ -z "$latest" ]; then
    die "could not determine the latest osTicket release (offline or rate-limited)"
fi

info "Configured: osTicket v${current} | Latest: v${latest}"

if ! ver_newer "$latest" "$current"; then
    info "osTicket is up to date"
    exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
    info "dry run: would update .env OSTICKET_VERSION=${current} -> ${latest} and run 'docker compose up -d --build'"
    exit 0
fi

[ -f .env ] || die "no .env found; run ./install.sh first"

if [ "$YES" = 1 ]; then
    answer=y
else
    read -r -p "Update to osTicket v${latest} and rebuild the stack? [y/N] " answer || true
fi

case "$answer" in
    y|Y) ;;
    *)   warn "Staying on osTicket v${current}"; exit 0 ;;
esac

sed -i "s/^OSTICKET_VERSION=.*/OSTICKET_VERSION=${latest}/" .env
info "Updated OSTICKET_VERSION to ${latest} in .env"

info "Rebuilding the stack (osTicket v${latest})"
docker compose $(compose_profiles)up -d --build
