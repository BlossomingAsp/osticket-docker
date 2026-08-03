#!/usr/bin/env bash
set -euo pipefail

# Discord ticket bot setup (experimental)
#
# Interactively configures the discord-bot service after the stack is
# installed: prompts for the Discord bot token, channel, osTicket API key,
# topic, status emojis, etc., then writes the OSTICKET_DISCORD_* variables
# into .env and offers to (re)start the bot.
#
# Safe to re-run: existing values are used as defaults, and only the
# OSTICKET_DISCORD_* / OSTICKET_TOPIC_ID variables are touched. Requires the
# stack to be installed (a .env from install.sh).
#
# Prerequisites to gather before running (see README -> Discord ticket bot):
#   1. A bot created at https://discord.com/developers/applications with the
#      "Message Content Intent" enabled and the token copied.
#   2. The bot invited to a channel (OAuth2 -> URL Generator, scope bot) with
#      Send Messages / Add Reactions / Read Message History / View Channels.
#   3. An osTicket API key (Admin -> Manage -> API Keys -> Add New API Key)
#      with IP 172.30.0.10 and "Can create tickets" enabled.

cd "$(dirname "$0")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { printf "${GREEN}==>${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die()   { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

ASK=1
START_BOT=1
usage() {
    cat <<'EOF'
Usage: ./setup-discord-bot.sh [options]

Interactively configure the Discord ticket bot and write its variables
(OSTICKET_DISCORD_*) into .env.

Options:
  -y, --yes        non-interactive: keep current .env values, no prompts
  -n, --no-start   don't offer to (re)start the discord-bot service
  -h, --help       show this help
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)     ASK=0; shift ;;
        -n|--no-start) START_BOT=0; shift ;;
        -h|--help)    usage ;;
        *)            die "unknown option: $1 (see --help)" ;;
    esac
done

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not available"

[ -f .env ] || die "no .env found — run ./install.sh first"

# Interactive setup needs a terminal to read prompts from (same rule as
# install.sh). A piped run gets EOF and would silently keep defaults.
if [ "$ASK" = 1 ] && ! [ -t 0 ]; then
    die "stdin is not a terminal. Run ./setup-discord-bot.sh interactively, or pass -y for non-interactive."
fi

# Ask a question; blank keeps the current/default value.
ask() {
    local label="$1" current="$2" v
    if [ "$ASK" = 1 ]; then
        read -r -p "$label [${current}]: " v || true
        [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$current"
    else
        printf '%s' "$current"
    fi
}

# Ask for a secret (no echo); blank keeps the current value.
ask_secret() {
    local label="$1" current="$2" v=""
    if [ "$ASK" = 1 ]; then
        read -r -s -p "$label [hidden, enter to keep]: " v || true
        printf '\n' >&2
    fi
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$current"
}

# Set or replace KEY=VALUE in .env, preserving everything else.
set_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

info "Reading current bot settings from .env"

# Extract just the bot-related keys, not the whole file: .env may contain
# unquoted values with spaces (e.g. OSTICKET_OIDC_NAME=Pocket ID) that break
# `source`, and we only touch the OSTICKET_DISCORD_* / OSTICKET_TOPIC_ID keys.
env_get() {
    local key="$1" val=""
    val="$(sed -n "s/^${key}=//p" .env | tail -n 1)"
    printf '%s' "$val"
}

TOKEN="$(env_get OSTICKET_DISCORD_BOT_TOKEN)"
CHANNEL_ID="$(env_get OSTICKET_DISCORD_CHANNEL_ID)"
TICKET_CMD="${OSTICKET_DISCORD_TICKET_COMMAND:-$(env_get OSTICKET_DISCORD_TICKET_COMMAND)}"
TICKET_CMD="${TICKET_CMD:-!ticket}"
API_KEY="$(env_get OSTICKET_DISCORD_API_KEY)"
TOPIC_ID="${OSTICKET_TOPIC_ID:-$(env_get OSTICKET_TOPIC_ID)}"
TOPIC_ID="${TOPIC_ID:-1}"
CHANNEL_FIELD="$(env_get OSTICKET_DISCORD_CHANNEL_FIELD)"
POLL="${OSTICKET_DISCORD_POLL_INTERVAL:-$(env_get OSTICKET_DISCORD_POLL_INTERVAL)}"
POLL="${POLL:-30}"
RATE="${OSTICKET_DISCORD_RATE_LIMIT:-$(env_get OSTICKET_DISCORD_RATE_LIMIT)}"
RATE="${RATE:-300}"
STATUS_EMOJIS="$(env_get OSTICKET_DISCORD_STATUS_EMOJIS)"
if [ -z "$STATUS_EMOJIS" ]; then
    STATUS_EMOJIS='{"open":"🟢","assigned":"🔵","answered":"💬","closed":"✅"}'
fi
FALLBACK="${OSTICKET_DISCORD_FALLBACK_EMOJI:-$(env_get OSTICKET_DISCORD_FALLBACK_EMOJI)}"
FALLBACK="${FALLBACK:-📥}"

echo
info "Discord bot settings (enter to keep the current value):"
TOKEN="$(ask_secret 'Bot token' "$TOKEN")"
CHANNEL_ID="$(ask 'Channel ID (right-click channel -> Copy Channel ID)' "$CHANNEL_ID")"
TICKET_CMD="$(ask 'Ticket command' "$TICKET_CMD")"
API_KEY="$(ask_secret 'osTicket API key (IP must be 172.30.0.10)' "$API_KEY")"
TOPIC_ID="$(ask 'Help topic ID' "$TOPIC_ID")"
CHANNEL_FIELD="$(ask 'Channel field (dynamic-form field name, blank = fold into body)' "$CHANNEL_FIELD")"
POLL="$(ask 'Poll interval (seconds)' "$POLL")"
RATE="$(ask 'Rate limit per user (seconds, 0 = off)' "$RATE")"
STATUS_EMOJIS="$(ask 'Status emojis (JSON, keys = status names in your osTicket language)' "$STATUS_EMOJIS")"
FALLBACK="$(ask 'Fallback emoji' "$FALLBACK")"

case "$CHANNEL_ID" in
    ''|*[!0-9]*) die "invalid channel ID: $CHANNEL_ID (must be a numeric Discord channel ID)" ;;
esac
case "$TOPIC_ID" in
    ''|*[!0-9]*) die "invalid topic ID: $TOPIC_ID (must be a number)" ;;
esac

info "Writing bot settings to .env"
set_env OSTICKET_DISCORD_BOT_TOKEN "$TOKEN"
set_env OSTICKET_DISCORD_CHANNEL_ID "$CHANNEL_ID"
set_env OSTICKET_DISCORD_TICKET_COMMAND "$TICKET_CMD"
set_env OSTICKET_DISCORD_API_KEY "$API_KEY"
set_env OSTICKET_TOPIC_ID "$TOPIC_ID"
set_env OSTICKET_DISCORD_CHANNEL_FIELD "$CHANNEL_FIELD"
set_env OSTICKET_DISCORD_POLL_INTERVAL "$POLL"
set_env OSTICKET_DISCORD_RATE_LIMIT "$RATE"
set_env OSTICKET_DISCORD_STATUS_EMOJIS "$STATUS_EMOJIS"
set_env OSTICKET_DISCORD_FALLBACK_EMOJI "$FALLBACK"
info ".env updated"

if [ -z "$TOKEN" ] || [ -z "$API_KEY" ]; then
    warn "bot token and/or osTicket API key are empty — the discord-bot service will"
    warn "exit cleanly until both are set (it is not crash-looping)."
fi

if [ "$START_BOT" = 1 ]; then
    if [ "$ASK" = 1 ]; then
        read -r -p "Start/restart the discord-bot service now? [Y/n] " go || true
        case "$go" in
            n|N|no) go="no" ;;
            *)      go="yes" ;;
        esac
    else
        go="yes"
    fi
    if [ "$go" = yes ]; then
        info "Starting discord-bot (docker compose up -d discord-bot)"
        docker compose up -d discord-bot
        info "Follow the bot logs with: docker compose logs -f discord-bot"
    else
        info "Not starting now — run 'docker compose up -d' to apply the new settings."
    fi
fi

echo
info "Done. The discord-bot service starts when DISCORD_BOT_TOKEN and"
info "DISCORD_CHANNEL_ID are set; watch its logs for the logged-in message."
