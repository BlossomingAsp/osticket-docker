import re

import requests


class OsticketApiError(Exception):
    pass


class OsticketApi:
    """Minimal client for osTicket's ticket-creation REST API."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.session = requests.Session()
        self.session.headers.update({
            "X-API-Key": cfg.osticket_api_key,
            "Content-Type": "application/json",
        })

    def create_ticket(self, fields):
        """Create a ticket and return its number. Raises OsticketApiError."""
        message = (fields.get("message") or "").strip()
        subject = (fields.get("subject") or "").strip() or self._derive_subject(message)
        phone = (fields.get("phone") or "").strip()
        preferred = (fields.get("channel") or "").strip()

        # Extra context that osTicket has no dedicated field for (or that would
        # fail its validation) is folded into the message body so nothing the
        # user typed is ever dropped.
        context = []
        if preferred and not self.cfg.channel_field:
            context.append(f"Preferred communication channel: {preferred}")
        if phone and not self._valid_phone(phone):
            context.append(f"Phone (unverified format): {phone}")
            phone = ""
        if context:
            message = ("\n".join(context) + "\n\n" + message).strip()

        payload = {
            "topicId": self.cfg.osticket_topic_id,
            "subject": subject,
            "name": fields.get("name"),
            "email": fields.get("email"),
            "phone": phone or None,
            "message": message,
            # origin is intentionally not set: osTicket requires one of
            # web|staff|api|email and defaults to "API" for this endpoint.
            "alert": False,
            "autorespond": False,
        }
        if self.cfg.channel_field and preferred:
            payload[self.cfg.channel_field] = preferred

        try:
            resp = self.session.post(
                f"{self.cfg.osticket_base_url}/api/tickets.json",
                json=payload,
                timeout=30,
            )
        except requests.RequestException as ex:
            raise OsticketApiError(f"network error: {ex}") from ex

        if resp.status_code == 201:
            return resp.text.strip()
        raise OsticketApiError(
            f"osTicket API {resp.status_code}: {resp.text[:200]}"
        )

    @staticmethod
    def _valid_phone(phone):
        # Mirrors osTicket's Validator::is_phone: 7-16 digits after stripping
        # separators.
        digits = re.sub(r"[^0-9]", "", phone)
        return 7 <= len(digits) <= 16

    @staticmethod
    def _derive_subject(message):
        """osTicket requires a subject; fall back to the first line."""
        first = message.splitlines()[0].strip() if message.splitlines() else "Discord ticket"
        return first[:100]
