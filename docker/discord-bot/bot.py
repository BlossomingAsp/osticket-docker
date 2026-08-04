import asyncio
import logging
import time

import discord

from config import Config
from db import Database
from osticket_api import OsticketApi, OsticketApiError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("discord-bot")

REQUIRED_FIELDS = ("name", "email", "message")


def parse_ticket(text, command):
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
        self._last_ticket_at = {}

    # --- lifecycle -----------------------------------------------------
    async def setup_hook(self):
        self._poll_task = asyncio.create_task(self.poll_loop())

    async def close(self):
        log.info("shutting down")
        if self._poll_task:
            self._poll_task.cancel()
            try:
                await self._poll_task
            except asyncio.CancelledError:
                pass
        if self.db.conn:
            try:
                self.db.conn.close()
            except Exception:
                pass
        await super().close()

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
            await self._react(message, "\u274c")
            return

        now = time.monotonic()
        last = self._last_ticket_at.get(message.author.id)
        if last is not None and now - last < self.cfg.rate_limit:
            remaining = int(self.cfg.rate_limit - (now - last))
            log.info("rate-limited ticket request from %s (cooldown %ss)", message.author, remaining)
            await self._react(message, "\u23f3")
            return

        try:
            ticket_number = await asyncio.to_thread(self.api.create_ticket, fields)
        except OsticketApiError as ex:
            log.error("failed to create ticket from message %s: %s", message.id, ex)
            await self._react(message, "\u274c")
            return
        self._last_ticket_at[message.author.id] = now

        status = await asyncio.to_thread(self.db.get_status_by_number, ticket_number)
        await asyncio.to_thread(
            self.db.save_mapping, ticket_number, message.id,
            message.channel.id, message.author.id, status,
        )
        emoji = self.emoji_for(status) or self.cfg.fallback_emoji
        await self._react(message, emoji)

        if self.cfg.thread_enabled:
            thread = await self._ensure_thread(message, ticket_number, status)
            if thread:
                await asyncio.to_thread(
                    self.db.save_thread_id, ticket_number, str(thread.id))
                log.info("created thread %s for ticket %s", thread.id, ticket_number)

        log.info("created ticket %s from message %s", ticket_number, message.id)

    # --- osTicket -> Discord: new ticket detection --------------------
    async def _post_new_ticket(self, ticket):
        channel = self.get_channel(self.cfg.channel_id)
        if channel is None:
            try:
                channel = await self.fetch_channel(self.cfg.channel_id)
            except discord.NotFound:
                log.error("channel %s not found", self.cfg.channel_id)
                return

        staff_email = ticket.get("staff_email")
        user_email = ticket.get("user_email") or "unknown"
        user_name = ticket.get("user_name") or "Unknown"
        status_name = ticket.get("status_name", "open")
        emoji = self.emoji_for(status_name) or self.cfg.fallback_emoji

        lines = [
            f"**Ticket #{ticket['number']}**",
            f"Status: {emoji} {status_name}",
            f"Requester: {user_name} <{user_email}>",
        ]
        if staff_email:
            lines.append(f"Assigned: {staff_email}")

        msg = await channel.send("\n".join(lines))
        await self._react(msg, emoji)

        thread = None
        if self.cfg.thread_enabled:
            thread = await self._ensure_thread(msg, ticket["number"], status_name)
            if thread:
                await asyncio.to_thread(
                    self.db.save_thread_id, ticket["number"], str(thread.id))
                log.info("created thread %s for new ticket %s", thread.id, ticket["number"])

        await asyncio.to_thread(
            self.db.save_mapping, ticket["number"], str(msg.id),
            str(channel.id), "0", status_name,
            str(thread.id) if thread else None,
        )
        log.info("mirrored ticket %s to Discord message %s", ticket["number"], msg.id)

    async def _ensure_thread(self, message, ticket_number, status_name):
        try:
            existing = await message.create_thread(
                name=f"{self.cfg.thread_prefix}{ticket_number}",
                auto_archive_duration=1440,
            )
            return existing
        except discord.HTTPException as ex:
            log.warning("could not create thread for ticket %s: %s", ticket_number, ex)
            return None

    # --- osTicket -> Discord: new thread entries ----------------------
    async def _post_new_entries(self, mapping, entries):
        if not entries:
            return

        channel = self.get_channel(int(mapping["discord_channel_id"]))
        if channel is None:
            try:
                channel = await self.fetch_channel(int(mapping["discord_channel_id"]))
            except discord.NotFound:
                log.error("channel %s not found", mapping["discord_channel_id"])
                return

        thread_id = mapping.get("discord_thread_id")
        thread = None
        if thread_id:
            try:
                thread = await channel.fetch_channel(int(thread_id))
            except (discord.NotFound, discord.HTTPException):
                thread = None

        if thread is None:
            try:
                msg = await channel.fetch_message(int(mapping["discord_message_id"]))
            except discord.NotFound:
                log.error("original message %s not found for ticket %s",
                          mapping["discord_message_id"], mapping["ticket_number"])
                return
            try:
                thread = await msg.create_thread(
                    name=f"{self.cfg.thread_prefix}{mapping['ticket_number']}",
                    auto_archive_duration=1440,
                )
            except discord.HTTPException as ex:
                log.warning("could not create thread for ticket %s: %s",
                            mapping["ticket_number"], ex)
                return
            await asyncio.to_thread(
                self.db.save_thread_id, mapping["ticket_number"], str(thread.id))

        for entry in entries:
            content = self._format_entry(entry)
            try:
                await thread.send(content)
            except discord.HTTPException as ex:
                log.warning("could not post entry %s to thread: %s", entry["id"], ex)

        latest_id = max(e["id"] for e in entries)
        await asyncio.to_thread(
            self.db.update_last_thread_entry_id, mapping["id"], latest_id)
        log.info("posted %d thread entries for ticket %s", len(entries), mapping["ticket_number"])

    def _format_entry(self, entry):
        staff_email = entry.get("staff_email")
        staff_username = entry.get("staff_username")
        staff_name = entry.get("staff_firstname") or entry.get("staff_lastname")
        user_name = entry.get("user_name")
        user_email = entry.get("user_email")
        entry_type = entry.get("type", "M")
        body = (entry.get("body") or "").strip()

        if entry_type == "R" and staff_email:
            mention = self._staff_mention(staff_email)
            if mention:
                prefix = f"{mention} (staff)"
            elif staff_name:
                prefix = f"{staff_name} (staff)"
            elif staff_username:
                prefix = f"{staff_username} (staff)"
            else:
                prefix = "Staff"
        elif entry_type == "M" and user_name:
            prefix = f"{user_name}"
        else:
            prefix = "Unknown"

        if user_email and entry_type == "M":
            prefix = f"{prefix} <{user_email}>"
        elif staff_email and entry_type == "R":
            prefix = f"{prefix} <{staff_email}>"

        return f"**{prefix}:** {body}"

    def _staff_mention(self, staff_email):
        discord_id = self.cfg.staff_discord_map.get(staff_email)
        if discord_id:
            return f"<@{discord_id}>"
        return None

    # --- Discord -> osTicket: reaction-based status change -----------
    async def on_reaction_add(self, reaction, user):
        if user.id == self.user.id:
            return
        if reaction.message.channel.id != self.cfg.channel_id:
            return

        emoji_str = str(reaction.emoji)
        status_name = self.cfg.emoji_to_status.get(emoji_str)
        if status_name is None:
            return

        mapping = await asyncio.to_thread(self.db.get_mapping_by_message, str(reaction.message.id))
        if mapping is None:
            return

        current_status = mapping.get("last_status")
        if current_status and current_status.lower() == status_name.lower():
            return

        log.info("reaction %s on message %s -> status %s for ticket %s",
                 emoji_str, reaction.message.id, status_name, mapping["ticket_number"])

        await asyncio.to_thread(
            self.db.update_os_ticket_status,
            mapping["ticket_number"], status_name,
        )
        await self.update_reaction(
            mapping["discord_channel_id"],
            mapping["discord_message_id"],
            status_name,
        )
        await asyncio.to_thread(self.db.update_status, mapping["id"], status_name)

    # --- status polling ------------------------------------------------
    async def poll_loop(self):
        while True:
            try:
                for row in await asyncio.to_thread(self.db.get_mapped):
                    status = row["status_name"]
                    if status == row["last_status"]:
                        pass
                    else:
                        await self.update_reaction(
                            row["discord_channel_id"], row["discord_message_id"], status)
                        await asyncio.to_thread(self.db.update_status, row["id"], status)

                unmapped = await asyncio.to_thread(self.db.get_unmapped_tickets)
                for ticket in unmapped:
                    await self._post_new_ticket(ticket)

                for row in await asyncio.to_thread(self.db.get_mapped):
                    thread_id = row.get("discord_thread_id")
                    if not thread_id:
                        continue
                    last_id = row.get("last_thread_entry_id") or 0
                    entries = await asyncio.to_thread(
                        self.db.get_new_thread_entries,
                        row["ticket_number"], last_id,
                    )
                    if entries:
                        await self._post_new_entries(row, entries)

            except Exception as ex:
                log.error("poll failed: %s", ex)
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