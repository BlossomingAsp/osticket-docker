#!/bin/sh
set -eu

# osTicket-docker bootstrap installer
#
# Downloads the repo source tarball for a release (default: the latest
# GitHub release) and runs its install.sh, forwarding all arguments.
#
# Usage (from anywhere):
#   curl -sSL https://github.com/BlossomingAsp/osticket-docker/releases/latest/download/get-osticket.sh | sh -s -- -y --auto
#
# If the repo is private, the one-liner needs a token (repo scope):
#   curl -sSL -H "Authorization: Bearer $GH_TOKEN" https://github.com/BlossomingAsp/osticket-docker/releases/latest/download/get-osticket.sh | sh -s -- -y --auto
#   (GH_TOKEN must be exported so this script's downloads are authorized too)
#
# To pin a specific release instead of "latest", set OSTICKET_RELEASE:
#   OSTICKET_RELEASE=v1.0.1 sh get-osticket.sh -y --auto

REPO="BlossomingAsp/osticket-docker"
DEFAULT_TAG="v1.0.1"

info()  { printf '==> %s\n' "$*"; }
die()   { printf '[x] %s\n' "$*" >&2; exit 1; }

# For private repos the API/tarball/asset requests need the token too.
if [ -n "${GH_TOKEN:-}" ]; then
    AUTH="Authorization: Bearer $GH_TOKEN"
fi
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL ${AUTH:+-H "$AUTH"} "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO- --header="${AUTH:-}" "$1"; }
else
    die "curl or wget is required to download the repo"
fi
command -v tar >/dev/null 2>&1 || die "tar is required to unpack the repo"

TAG="${OSTICKET_RELEASE:-latest}"
if [ "$TAG" = "latest" ]; then
    info "Resolving the latest release tag..."
    TAG="$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p')"
    [ -n "$TAG" ] || TAG="$DEFAULT_TAG"
    info "Latest release: $TAG"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

info "Downloading osTicket-docker $TAG ..."
fetch "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" > "$TMP/osticket-docker.tar.gz"
tar -xzf "$TMP/osticket-docker.tar.gz" -C "$TMP" --strip-components=1
cd "$TMP"

info "Starting install.sh (passing: $*)"
exec ./install.sh "$@"
