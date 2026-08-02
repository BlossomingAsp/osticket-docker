import pymysql

CREATE_MAP_TABLE = """
CREATE TABLE IF NOT EXISTS ost_discord_ticket_map (
    id INT PRIMARY KEY AUTO_INCREMENT,
    ticket_number VARCHAR(20) NOT NULL,
    discord_message_id VARCHAR(32) NOT NULL,
    discord_channel_id VARCHAR(32) NOT NULL,
    discord_user_id VARCHAR(32) NOT NULL,
    last_status VARCHAR(64) DEFAULT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_ticket_number (ticket_number),
    INDEX idx_discord_message (discord_message_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
"""


class Database:
    """Thin MariaDB wrapper for the Discord <-> osTicket mapping and status polls."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.conn = None

    def connect(self):
        self.conn = pymysql.connect(
            host=self.cfg.db_host,
            port=self.cfg.db_port,
            user=self.cfg.db_user,
            password=self.cfg.db_password,
            db=self.cfg.db_name,
            charset="utf8mb4",
            autocommit=True,
            cursorclass=pymysql.cursors.DictCursor,
        )
        with self.conn.cursor() as cur:
            cur.execute(CREATE_MAP_TABLE)

    def _cursor(self):
        # Reconnect if the connection dropped (e.g. db restart).
        try:
            self.conn.ping(reconnect=True)
        except Exception:
            self.connect()
        return self.conn.cursor()

    def save_mapping(self, ticket_number, message_id, channel_id, user_id, status):
        with self._cursor() as cur:
            cur.execute(
                """INSERT INTO ost_discord_ticket_map
                     (ticket_number, discord_message_id, discord_channel_id,
                      discord_user_id, last_status)
                   VALUES (%s, %s, %s, %s, %s)
                   ON DUPLICATE KEY UPDATE
                     discord_message_id = VALUES(discord_message_id),
                     discord_user_id = VALUES(discord_user_id),
                     last_status = VALUES(last_status)""",
                (ticket_number, str(message_id), str(channel_id),
                 str(user_id), status),
            )

    def get_status_by_number(self, ticket_number):
        with self._cursor() as cur:
            cur.execute(
                """SELECT s.name AS status_name
                   FROM ost_ticket t
                   JOIN ost_ticket_status s ON s.id = t.status_id
                   WHERE t.number = %s""",
                (ticket_number,),
            )
            row = cur.fetchone()
            return row["status_name"] if row else None

    def get_mapped(self):
        with self._cursor() as cur:
            cur.execute(
                """SELECT m.id, m.ticket_number, m.discord_message_id,
                          m.discord_channel_id, m.last_status,
                          s.name AS status_name
                   FROM ost_discord_ticket_map m
                   JOIN ost_ticket t ON t.number = m.ticket_number
                   JOIN ost_ticket_status s ON s.id = t.status_id
                   WHERE m.last_status IS NOT NULL""",
            )
            return cur.fetchall()

    def update_status(self, mid, status):
        with self._cursor() as cur:
            cur.execute(
                "UPDATE ost_discord_ticket_map SET last_status = %s WHERE id = %s",
                (status, mid),
            )
