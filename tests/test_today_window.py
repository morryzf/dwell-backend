"""模型这一轮读到的原文，要覆盖今天说过的每一句。

这是 Morry 真正要的那件事：上下文的条数上限跟着「今天」走，
而不是反过来把「今天」砍到上限。
"""

import os
import unittest
import uuid

from app import db
from app import main


class HistoryWindowTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"today-window-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("window test")
        self.day_start = db.day_start_ts()

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _say(self, text, made):
        row = db.message_add(self.chat["id"], "user", text)
        with db.conn() as cx:
            cx.execute("UPDATE messages SET made=? WHERE id=?", (int(made), row["id"]))
        return row

    def _fill(self, count, made):
        for i in range(count):
            self._say(f"第 {i} 句", made)

    def test_a_quiet_day_keeps_the_ordinary_window(self):
        self._fill(5, self.day_start + 60)
        self.assertEqual(
            main._history_window(self.chat["id"], main.CACHE_HISTORY_TARGET_MESSAGES),
            main.CACHE_HISTORY_TARGET_MESSAGES,
            "今天说得少的时候，窗口还是原来那么大",
        )

    def test_a_long_day_stretches_the_window(self):
        talky = main.CACHE_HISTORY_TARGET_MESSAGES + 60
        self._fill(talky, self.day_start + 60)
        self.assertEqual(
            main._history_window(self.chat["id"], main.CACHE_HISTORY_TARGET_MESSAGES),
            talky,
            "今天聊了多少，就带多少",
        )

    def test_yesterday_does_not_stretch_it(self):
        self._fill(200, self.day_start - 7200)
        self.assertEqual(
            main._history_window(self.chat["id"], main.CACHE_HISTORY_TARGET_MESSAGES),
            main.CACHE_HISTORY_TARGET_MESSAGES,
            "撑大窗口的只有今天",
        )

    def test_there_is_a_hard_ceiling(self):
        self._fill(main.MAX_RAW_HISTORY_MESSAGES + 30, self.day_start + 60)
        self.assertEqual(
            main._history_window(self.chat["id"], main.CACHE_HISTORY_TARGET_MESSAGES),
            main.MAX_RAW_HISTORY_MESSAGES,
            "防爆硬顶还在",
        )

    def test_every_word_of_today_actually_reaches_the_model(self):
        self._fill(300, self.day_start - 86400)          # 昨天的一堆
        talky = main.CACHE_HISTORY_TARGET_MESSAGES + 45
        for i in range(talky):
            self._say(f"今天第 {i} 句", self.day_start + 60 * i)
        rows = main._chat_history_rows(self.chat["id"], cache_friendly=False)
        texts = [str(r.get("content") or "") for r in rows]
        self.assertIn("今天第 0 句", texts, "今天的第一句也要在")
        self.assertIn(f"今天第 {talky - 1} 句", texts)

    def test_the_cutoff_never_bites_into_the_window(self):
        """折成分段的那条线，不能咬进模型真正读得到的范围里。"""
        self._fill(300, self.day_start - 86400)
        talky = main.CACHE_HISTORY_TARGET_MESSAGES + 45
        for i in range(talky):
            self._say(f"今天第 {i} 句", self.day_start + 60 * i)
        cutoff = main._memory_cutoff(self.chat["id"])
        rows = main._chat_history_rows(self.chat["id"], cache_friendly=False)
        self.assertLess(cutoff, int(rows[0]["rowid"]),
                        "窗口里的东西不该同时被折走")
        self.assertGreater(cutoff, 0, "昨天那 300 条还是要折")


if __name__ == "__main__":
    unittest.main()
