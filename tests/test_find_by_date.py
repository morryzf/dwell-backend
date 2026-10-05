"""搜索里的日历：按日子翻聊天。日子按北京时间算。"""

import os
import unittest
import uuid
from datetime import datetime

from fastapi.testclient import TestClient

from app import auth, db, main


def _at(text: str) -> int:
    return int(datetime.fromisoformat(text + "+08:00").timestamp())


class FindByDateTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"find-date-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None
        with db.conn() as cx:
            cx.execute("INSERT INTO chats(id,name,made) VALUES ('a','海边',0),('b','晚饭',0)")
            rows = [
                ("m1", "a", "user", "去看海吗", "2026-10-04T23:50:00"),
                ("m2", "a", "assistant", "好呀", "2026-10-05T00:10:00"),   # 北京时间已经是 5 号
                ("m3", "b", "assistant", "吃了吗", "2026-10-05T18:00:00"),
                ("m4", "b", "user", "还没", "2026-10-05T18:05:00"),
                ("m5", "b", "system", "提示", "2026-10-05T18:06:00"),
            ]
            cx.executemany("INSERT INTO messages(id,chat_id,role,content,made) VALUES (?,?,?,?,?)",
                           [(i, c, r, t, _at(when)) for i, c, r, t, when in rows])

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def test_days_are_counted_in_beijing_time(self):
        self.assertEqual(db.chat_days("2026-10"), {"2026-10-04": 1, "2026-10-05": 3})
        self.assertEqual(db.chat_days("2026-09"), {})

    def test_day_lists_each_chat_with_its_first_line(self):
        chats = db.chat_day("2026-10-05")
        self.assertEqual([c["chat_id"] for c in chats], ["a", "b"])
        a, b = chats
        self.assertEqual((a["message_id"], a["count"], a["from"], a["snippet"]), ("m2", 1, "00:10", ""))
        self.assertEqual((b["message_id"], b["count"], b["from"], b["to"], b["snippet"]),
                         ("m3", 2, "18:00", "18:05", "还没"))

    def test_endpoints_check_the_date_shape(self):
        self.assertEqual(self.client.get("/api/find/days?month=2026-10").json()["days"]["2026-10-05"], 3)
        self.assertEqual(len(self.client.get("/api/find/day?date=2026-10-05").json()["chats"]), 2)
        self.assertEqual(self.client.get("/api/find/days?month=oct").status_code, 400)
        self.assertEqual(self.client.get("/api/find/day?date=2026-10").status_code, 400)


if __name__ == "__main__":
    unittest.main()
