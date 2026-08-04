import json
import os


def _int(name, default):
    try:
        return int(os.environ.get(name) or default)
    except (TypeError, ValueError):
        return default


def _bool(name, default):
    v = os.environ.get(name, "").strip().lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    return default


class Config:
    """Loads all discord-bot settings from environment variables."""

    def __init__(self):
        # Discord
        self.bot_token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
        self.channel_id = _int("DISCORD_CHANNEL_ID", 0)
        self.ticket_command = os.environ.get("DISCORD_TICKET_COMMAND", "!ticket").strip()

        # osTicket
        self.osticket_base_url = os.environ.get("OSTICKET_BASE_URL", "http://osticket:80").rstrip("/")
        self.osticket_api_key = os.environ.get("OSTICKET_API_KEY", "").strip()
        self.osticket_topic_id = _int("OSTICKET_TOPIC_ID", 1)
        self.channel_field = os.environ.get("CHANNEL_FIELD", "").strip()

        # Polling + reactions
        self.poll_interval = _int("POLL_INTERVAL", 30)
        self.rate_limit = _int("RATE_LIMIT", 300)
        default_emojis = {
            "open": "\U0001f7e2",       # 🟢
            "assigned": "\U0001f535",   # 🔵
            "answered": "\U0001f4ac",   # 💬
            "closed": "\u2705",         # ✅
        }
        raw = os.environ.get("STATUS_EMOJIS", "").strip()
        if raw:
            try:
                parsed = json.loads(raw)
                default_emojis = {str(k).lower(): str(v) for k, v in parsed.items()}
            except json.JSONDecodeError:
                raise SystemExit(f"STATUS_EMOJIS is not valid JSON: {raw!r}")
        self.status_emojis = default_emojis
        self.emoji_to_status = {v: k for k, v in default_emojis.items()}
        self.fallback_emoji = os.environ.get("FALLBACK_EMOJI", "\U0001f4e5")  # 📥

        # Thread sync
        self.thread_enabled = _bool("DISCORD_THREAD_ENABLED", True)
        self.thread_prefix = os.environ.get("DISCORD_THREAD_PREFIX", "ticket-").strip()
        # Staff matching for assignee notifications on client replies
        self.staff_match = _bool("DISCORD_STAFF_MATCH", False)
        self.staff_discord_map = {}
        raw_staff = os.environ.get("DISCORD_STAFF_MAP", "").strip()
        if raw_staff:
            try:
                self.staff_discord_map = json.loads(raw_staff)
            except json.JSONDecodeError:
                raise SystemExit(f"DISCORD_STAFF_MAP is not valid JSON: {raw_staff!r}")

        # Database (MariaDB on the compose network)
        self.db_host = os.environ.get("DB_HOST", "db")
        self.db_port = _int("DB_PORT", 3306)
        self.db_name = os.environ.get("DB_NAME", "osticket")
        self.db_user = os.environ.get("DB_USER", "osticket")
        self.db_password = os.environ.get("DB_PASSWORD", "")

    @property
    def configured(self):
        return bool(self.bot_token) and self.channel_id > 0