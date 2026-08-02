import asyncio
import logging

import discord

from config import Config
from db import Database
from osticket_api import OsticketApi, OsticketApiError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("discord-bot")

REQUIRED_FIELDS = ("name", "email", "message")


def parse_ticket(text, command):
    """Parse a `!ticket` message into a fields dict.

    Format (Key: Value lines, case-insensitive keys, `message` may span
    multiple lines):
        !ticket
        Name: John Doe
        Email: john@example.com
        Phone: 555-1234
        Channel: email
        Message: I need help with my account
    """
    text = text.strip()
    if not text.startswith(command):
        return {}
    body = text[len(command):].strip()
    fields = {}
    message_lines = []
    in_message = False
    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            continue
        if in_message:
            message_lines.append(line)
        elif ":" in line:
            key, _, value = line.partition(":")
            key = key.strip().lower()
            value = value.strip()
            if not key:
                continue
            if key == "message":
                fields["message"] = value
                in_message = True
            else:
                fields[key] = value
    if in_message and message_lines:
        fields["message"] = (fields.get("message", "") + "\n" + "\n".join(message_lines)).strip()
    return fields


class TicketBot(discord.Client):
    def __init__(self, cfg, db, api):
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(intents=intents)
        self.cfg = cfg
        self.db = db
        self.api = api
        self._poll_task = None

    # --- lifecycle -----------------------------------------------------
    async def setup_hook(self):
        self._poll_task = asyncio.create_task(self.poll_loop())

    async def on_ready(self):
        log.info("Logged in as %s (channel %s)", self.user, self.cfg.channel_id)

    # --- inbound messages ----------------------------------------------
    async def on_message(self, message):
        if message.author.id == self.user.id:
            return
        if message.channel.id != self.cfg.channel_id:
            return
        if not message.content.startswith(self.cfg.ticket_command):
            return

        fields = parse_ticket(message.content, self.cfg.ticket_command)
        missing = [k for k in REQUIRED_FIELDS if not (fields.get(k) or "").strip()]
        if missing:
            log.info("ticket request missing fields %s from %s", missing, message.author)
            await self._react(message, "\u274c")  # ❌
            return

        try:
            ticket_number = await asyncio.to_thread(self.api.create_ticket, fields)
        except OsticketApiError as ex:
            log.error("failed to create ticket from message %s: %s", message.id, ex)
            await self._react(message, "\u274c")
            return

        status = await asyncio.to_thread(self.db.get_status_by_number, ticket_number)
        await asyncio.to_thread(
            self.db.save_mapping, ticket_number, message.id,
            message.channel.id, message.author.id, status,
        )
        emoji = self.emoji_for(status) or self.cfg.fallback_emoji
        await self._react(message, emoji)
        log.info("created ticket %s from message %s", ticket_number, message.id)

    # --- status polling ------------------------------------------------
    async def poll_loop(self):
        while True:
            try:
                for row in await asyncio.to_thread(self.db.get_mapped):
                    status = row["status_name"]
                    if status == row["last_status"]:
                        continue
                    await self.update_reaction(
                        row["discord_channel_id"], row["discord_message_id"], status)
                    await asyncio.to_thread(self.db.update_status, row["id"], status)
            except Exception as ex:  # keep the loop alive
                log.error("status poll failed: %s", ex)
            await asyncio.sleep(self.cfg.poll_interval)

    # --- reactions -----------------------------------------------------
    def emoji_for(self, status):
        if not status:
            return None
        return self.cfg.status_emojis.get(status.lower())

    async def update_reaction(self, channel_id, message_id, status):
        channel = self.get_channel(int(channel_id))
        if channel is None:
            try:
                channel = await self.fetch_channel(int(channel_id))
            except discord.NotFound:
                return
        try:
            msg = await channel.fetch_message(int(message_id))
        except discord.NotFound:
            return
        # Remove every reaction this bot owns that matches a known status emoji
        for emoji in set(self.cfg.status_emojis.values()):
            for reaction in msg.reactions:
                if str(reaction.emoji) == emoji:
                    try:
                        await reaction.remove(self.user)
                    except discord.HTTPException:
                        pass
        emoji = self.emoji_for(status)
        if emoji:
            await self._react(msg, emoji)

    async def _react(self, message, emoji):
        try:
            await message.add_reaction(emoji)
        except discord.HTTPException as ex:
            log.warning("could not react with %s on %s: %s", emoji, message.id, ex)


def main():
    cfg = Config()
    if not cfg.configured:
        log.error(
            "Discord bot not configured: set DISCORD_BOT_TOKEN and "
            "DISCORD_CHANNEL_ID in .env and run 'docker compose up -d'")
        raise SystemExit(0)

    db = Database(cfg)
    db.connect()
    api = OsticketApi(cfg)
    client = TicketBot(cfg, db, api)
    client.run(cfg.bot_token)


if __name__ == "__main__":
    main()
