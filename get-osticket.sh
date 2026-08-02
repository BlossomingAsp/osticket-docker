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
#   OSTICKET_RELEASE=v1.0.3 sh get-osticket.sh -y --auto
#
# To pick a channel instead of "latest" (stable default), set OSTICKET_CHANNEL:
#   OSTICKET_CHANNEL=experimental sh get-osticket.sh -y --auto
#   stable        -> latest stable release (default)
#   experimental  -> latest experimental prerelease (falls back to stable)
# The experimental channel tracks the `experimental` branch's prerelease tags
# (e.g. v1.1.0-exp.1). Expect breakage; not for production.

REPO="BlossomingAsp/osticket-docker"
DEFAULT_TAG="v1.0.3"
CHANNEL="${OSTICKET_CHANNEL:-stable}"

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
    case "$CHANNEL" in
        stable)
            info "Resolving the latest stable release tag..."
            TAG="$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
                | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
            ;;
        experimental)
            info "Resolving the latest experimental prerelease tag..."
            # List releases (newest first) and take the first prerelease.
            # Split records at each '{', then grab the tag_name of the first
            # record that also carries "prerelease": true.
            TAG="$(fetch "https://api.github.com/repos/$REPO/releases?per_page=100" 2>/dev/null \
                | awk -v RS='{' '
                    index($0, "\"prerelease\": true") {
                        if (match($0, /"tag_name": *"[^"]*"/)) {
                            v = substr($0, RSTART, RLENGTH);
                            sub(/^.*"tag_name": *"/, "", v);
                            sub(/"$/, "", v);
                            print v;
                            exit;
                        }
                    }')"
            if [ -z "$TAG" ]; then
                info "No experimental prerelease yet; falling back to the latest stable release"
                TAG="$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
                    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
            fi
            ;;
        *)
            die "unknown channel: $CHANNEL (expected 'stable' or 'experimental')"
            ;;
    esac
    [ -n "$TAG" ] || TAG="$DEFAULT_TAG"
    info "Channel '$CHANNEL' -> release $TAG"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

info "Downloading osTicket-docker $TAG ..."
fetch "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" > "$TMP/osticket-docker.tar.gz"
tar -xzf "$TMP/osticket-docker.tar.gz" -C "$TMP" --strip-components=1
cd "$TMP"

info "Starting install.sh (passing: $*)"
exec ./install.sh "$@"
