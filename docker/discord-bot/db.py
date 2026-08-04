import pymysql

CREATE_MAP_TABLE = """
CREATE TABLE IF NOT EXISTS ost_discord_ticket_map (
    id INT PRIMARY KEY AUTO_INCREMENT,
    ticket_number VARCHAR(20) NOT NULL,
    discord_message_id VARCHAR(32) NOT NULL,
    discord_channel_id VARCHAR(32) NOT NULL,
    discord_thread_id VARCHAR(32) DEFAULT NULL,
    discord_user_id VARCHAR(32) NOT NULL,
    last_status VARCHAR(64) DEFAULT NULL,
    last_thread_entry_id INT UNSIGNED DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_ticket_number (ticket_number),
    INDEX idx_discord_message (discord_message_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
"""

ADD_THREAD_COLUMNS = """
ALTER TABLE ost_discord_ticket_map
    ADD COLUMN IF NOT EXISTS discord_thread_id VARCHAR(32) DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS last_thread_entry_id INT UNSIGNED DEFAULT 0
"""

GET_UNMAPPED_TICKETS = """
SELECT t.ticket_id, t.number, t.status_id, t.staff_id,
       st.name AS status_name, st.state AS status_state,
       ue.address AS user_email, u.name AS user_name,
       s.email AS staff_email, s.username AS staff_username,
       s.firstname AS staff_firstname, s.lastname AS staff_lastname
FROM ost_ticket t
JOIN ost_ticket_status st ON st.id = t.status_id
LEFT JOIN ost_user u ON u.id = t.user_id
LEFT JOIN ost_user_email ue ON ue.id = t.user_email_id
LEFT JOIN ost_staff s ON s.staff_id = t.staff_id
WHERE t.number NOT IN (
    SELECT ticket_number FROM ost_discord_ticket_map
)
ORDER BY t.ticket_id
"""

GET_NEW_THREAD_ENTRIES = """
SELECT te.id, te.thread_id, te.type, te.staff_id, te.user_id,
       te.poster, te.body, te.created,
       s.email AS staff_email, s.username AS staff_username,
       s.firstname AS staff_firstname, s.lastname AS staff_lastname,
       u.name AS user_name, ue.address AS user_email
FROM ost_thread_entry te
JOIN ost_thread th ON th.id = te.thread_id
JOIN ost_ticket t ON t.ticket_id = th.object_id
LEFT JOIN ost_staff s ON s.staff_id = te.staff_id
LEFT JOIN ost_user u ON u.id = te.user_id
LEFT JOIN ost_user_email ue ON ue.id = t.user_email_id
WHERE th.object_type = 'T'
  AND t.number = %s
  AND te.id > %s
  AND te.type IN ('M', 'R')
ORDER BY te.id
"""

GET_LATEST_ENTRY_ID = """
SELECT MAX(te.id) AS max_id
FROM ost_thread_entry te
JOIN ost_thread th ON th.id = te.thread_id
WHERE th.object_type = 'T'
  AND th.object_id = (SELECT ticket_id FROM ost_ticket WHERE number = %s)
"""

GET_STATUS_ID_BY_NAME = """
SELECT id FROM ost_ticket_status WHERE name = %s
"""

GET_TICKET_BY_NUMBER = """
SELECT t.ticket_id, t.number, t.status_id, t.staff_id,
       st.name AS status_name, st.state AS status_state,
       ue.address AS user_email, u.name AS user_name,
       s.email AS staff_email, s.username AS staff_username,
       s.firstname AS staff_firstname, s.lastname AS staff_lastname
FROM ost_ticket t
JOIN ost_ticket_status st ON st.id = t.status_id
LEFT JOIN ost_user u ON u.id = t.user_id
LEFT JOIN ost_user_email ue ON ue.id = t.user_email_id
LEFT JOIN ost_staff s ON s.staff_id = t.staff_id
WHERE t.number = %s
"""

UPDATE_TICKET_STATUS = """
UPDATE ost_ticket t
JOIN ost_ticket_status s ON s.name = %s
SET t.status_id = s.id,
    t.closed = IF(s.state = 'closed', NOW(), t.closed),
    t.reopened = IF(s.state != 'closed' AND t.closed IS NOT NULL, NOW(), t.reopened)
WHERE t.number = %s
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
            cur.execute(ADD_THREAD_COLUMNS)

    def _cursor(self):
        try:
            self.conn.ping(reconnect=True)
        except Exception:
            self.connect()
        return self.conn.cursor()

    def save_mapping(self, ticket_number, message_id, channel_id, user_id, status, thread_id=None):
        with self._cursor() as cur:
            cur.execute(
                """INSERT INTO ost_discord_ticket_map
                     (ticket_number, discord_message_id, discord_channel_id,
                      discord_thread_id, discord_user_id, last_status, last_thread_entry_id)
                   VALUES (%s, %s, %s, %s, %s, %s, 0)
                   ON DUPLICATE KEY UPDATE
                     discord_message_id = VALUES(discord_message_id),
                     discord_channel_id = VALUES(discord_channel_id),
                     discord_thread_id = VALUES(discord_thread_id),
                     discord_user_id = VALUES(discord_user_id),
                     last_status = VALUES(last_status),
                     last_thread_entry_id = VALUES(last_thread_entry_id)""",
                (ticket_number, str(message_id), str(channel_id),
                 str(thread_id) if thread_id else None, str(user_id), status),
            )

    def save_thread_id(self, ticket_number, thread_id):
        with self._cursor() as cur:
            cur.execute(
                "UPDATE ost_discord_ticket_map SET discord_thread_id = %s WHERE ticket_number = %s",
                (str(thread_id), ticket_number),
            )

    def get_mapping_by_message(self, message_id):
        with self._cursor() as cur:
            cur.execute(
                "SELECT * FROM ost_discord_ticket_map WHERE discord_message_id = %s",
                (str(message_id),),
            )
            return cur.fetchone()

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

    def get_ticket_details(self, ticket_number):
        with self._cursor() as cur:
            cur.execute(GET_TICKET_BY_NUMBER, (ticket_number,))
            return cur.fetchone()

    def get_unmapped_tickets(self):
        with self._cursor() as cur:
            cur.execute(GET_UNMAPPED_TICKETS)
            return cur.fetchall()

    def get_new_thread_entries(self, ticket_number, last_entry_id):
        with self._cursor() as cur:
            cur.execute(GET_NEW_THREAD_ENTRIES, (ticket_number, last_entry_id))
            return cur.fetchall()

    def get_latest_entry_id(self, ticket_number):
        with self._cursor() as cur:
            cur.execute(GET_LATEST_ENTRY_ID, (ticket_number,))
            row = cur.fetchone()
            return row["max_id"] if row and row["max_id"] else 0

    def update_os_ticket_status(self, ticket_number, status_name):
        with self._cursor() as cur:
            cur.execute(UPDATE_TICKET_STATUS, (status_name, ticket_number))

    def get_status_id_by_name(self, status_name):
        with self._cursor() as cur:
            cur.execute(GET_STATUS_ID_BY_NAME, (status_name,))
            row = cur.fetchone()
            return row["id"] if row else None

    def get_mapped(self):
        with self._cursor() as cur:
            cur.execute(
                """SELECT m.id, m.ticket_number, m.discord_message_id,
                          m.discord_channel_id, m.discord_thread_id,
                          m.last_status, m.last_thread_entry_id,
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

    def update_last_thread_entry_id(self, mid, entry_id):
        with self._cursor() as cur:
            cur.execute(
                "UPDATE ost_discord_ticket_map SET last_thread_entry_id = %s WHERE id = %s",
                (entry_id, mid),
            )