#!/bin/sh
set -eu

# osTicket-docker bootstrap installer
#
# Downloads the repo source tarball for a release (default: the latest
# GitHub release) and runs its install.sh, forwarding all arguments.
#
# Usage (from anywhere) — interactive:
#   bash <(curl -sSL https://github.com/BlossomingAsp/osticket-docker/releases/latest/download/get-osticket.sh)
# Process substitution keeps stdin connected to your terminal, so install.sh
# can prompt for passwords, port, helpdesk details, etc.
#
# Non-interactive (auto-setup with defaults, no prompts):
#   bash <(curl -sSL https://github.com/BlossomingAsp/osticket-docker/releases/latest/download/get-osticket.sh) -y --auto
#   bash <(curl -sSL .../get-osticket.sh) -y --manual
#
# Piping this script (curl ... | sh) is NOT supported — stdin is consumed by
# the pipe, so interactive prompts cannot work. install.sh refuses to run
# without a terminal unless -y is given.
#
# If the repo is private, the one-liner needs a token (repo scope):
#   GH_TOKEN=xxx bash <(curl -sSL -H "Authorization: Bearer $GH_TOKEN" https://github.com/BlossomingAsp/osticket-docker/releases/latest/download/get-osticket.sh)
#   (GH_TOKEN must be exported so this script's downloads are authorized too)
#
# To pin a specific release instead of "latest", set OSTICKET_RELEASE:
#   OSTICKET_RELEASE=v1.0.6 bash <(curl -sSL .../get-osticket.sh)
#
# To pick a channel instead of "latest" (default `stable`, baked per release),
# set OSTICKET_CHANNEL:
#   OSTICKET_CHANNEL=experimental bash <(curl -sSL .../get-osticket.sh)
#   stable        -> latest stable release (default on stable release pages)
#   experimental  -> latest experimental prerelease (falls back to stable;
#                    default on experimental release pages, whose asset is
#                    baked with DEFAULT_CHANNEL=experimental)
# The experimental channel tracks the `experimental` branch's prerelease tags
# (e.g. v1.1.0-exp.4). Expect breakage; not for production.
#
# Files are downloaded and extracted into ./osticket-docker/ (in the current
# directory) and kept there, so you keep a local copy of the stack to update
# and manage afterwards. Override the location with OSTICKET_DIR. If the
# current directory is not writable, a temp directory is used and removed on
# exit instead.

REPO="BlossomingAsp/osticket-docker"
DEFAULT_TAG="v1.0.7"
# Default channel when OSTICKET_CHANNEL is unset. Stable release assets ship
# 'stable'; experimental release assets are cut with this flipped to
# 'experimental' (see AGENTS.md) so the one-liner on their release page
# installs the experimental prerelease by default.
DEFAULT_CHANNEL="${DEFAULT_CHANNEL:-stable}"
CHANNEL="${OSTICKET_CHANNEL:-$DEFAULT_CHANNEL}"

info()  { printf '==> %s\n' "$*"; }
die()   { printf '[x] %s\n' "$*" >&2; exit 1; }

# Piped installs consume stdin, so the installer could never prompt. Refuse
# up front unless the user explicitly opted into non-interactive (-y).
noninteractive=0
for _arg in "$@"; do
    [ "$_arg" = "-y" ] || [ "$_arg" = "--yes" ] && noninteractive=1
done
if ! [ -t 0 ] && [ "$noninteractive" = 0 ]; then
    die "piped installs are not supported. Run the interactive one-liner instead:
       bash <(curl -sSL https://github.com/$REPO/releases/latest/download/get-osticket.sh)
    or pass -y for non-interactive."
fi

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

TMP=""
DIR="${OSTICKET_DIR:-./osticket-docker}"
if ! mkdir -p "$DIR" 2>/dev/null; then
    # Current directory not writable (or OSTICKET_DIR invalid) — fall back to
    # a temp directory that is cleaned up on exit.
    TMP="$(mktemp -d)"
    DIR="$TMP"
    trap 'rm -rf "$TMP"' EXIT INT TERM
    info "Cannot write to ./osticket-docker; using temp dir $DIR"
fi

info "Downloading osTicket-docker $TAG ..."
fetch "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" > "$DIR/osticket-docker.tar.gz"
tar -xzf "$DIR/osticket-docker.tar.gz" -C "$DIR" --strip-components=1
rm -f "$DIR/osticket-docker.tar.gz"
cd "$DIR"

info "Starting install.sh (passing: $*)"
exec ./install.sh "$@"
