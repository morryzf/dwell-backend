"""今天说过的话一条都不压缩，模型读到的是原文。

「今天」和待办、提醒用同一个起点：早 6 点。凌晨两点还算前一天。
"""

import os
from datetime import datetime, timedelta
import unittest
import uuid

from app import db
from app import main


class DayStartTest(unittest.TestCase):
    def test_the_day_starts_at_six(self):
        noon = datetime(2026, 9, 25, 12, 0, tzinfo=db.CN_TZ)
        six = datetime(2026, 9, 25, 6, 0, tzinfo=db.CN_TZ)
        self.assertEqual(db.day_start_ts(noon), int(six.timestamp()))

    def test_past_midnight_still_belongs_to_yesterday(self):
        late = datetime(2026, 9, 26, 2, 0, tzinfo=db.CN_TZ)
        six = datetime(2026, 9, 25, 6, 0, tzinfo=db.CN_TZ)
        self.assertEqual(db.day_start_ts(late), int(six.timestamp()),
                         "凌晨两点，这一天是从昨天早 6 点开始的")


class CutoffTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"today-raw-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("cutoff test")
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
        with db.conn() as cx:
            got = cx.execute("SELECT rowid FROM messages WHERE id=?", (row["id"],)).fetchone()
        return int(got["rowid"])

    def test_nothing_is_compressed_while_the_chat_is_short(self):
        for i in range(10):
            self._say(f"第 {i} 句", self.day_start - 86400 * 3)
        self.assertEqual(main._memory_cutoff(self.chat["id"]), 0)

    def test_old_messages_are_still_compressed(self):
        old = [self._say(f"前几天第 {i} 句", self.day_start - 86400 * 3)
               for i in range(main.MEMORY_TAIL_MESSAGES + 20)]
        cutoff = main._memory_cutoff(self.chat["id"])
        self.assertGreater(cutoff, 0, "旧的该压还是要压")
        self.assertLess(cutoff, old[-1], "最新的那些不压")

    def test_todays_messages_are_never_compressed(self):
        for i in range(main.MEMORY_TAIL_MESSAGES + 20):
            self._say(f"前几天第 {i} 句", self.day_start - 86400 * 3)
        today = [self._say(f"今天第 {i} 句", self.day_start + 60 * i) for i in range(30)]
        cutoff = main._memory_cutoff(self.chat["id"])
        self.assertLess(cutoff, today[0],
                        "今天的第一句都不该越过压缩线")

    def test_a_message_right_at_six_counts_as_today(self):
        for i in range(main.MEMORY_TAIL_MESSAGES + 20):
            self._say(f"昨天第 {i} 句", self.day_start - 3600)
        first = self._say("整六点这句", self.day_start)
        self.assertLess(main._memory_cutoff(self.chat["id"]), first)

    def test_the_protected_run_never_outgrows_the_prompt_window(self):
        """聊疯了的那天：今天最早的几条还是会被折成分段。

        进分段、等着变成记忆卡，好过既没折成分段、也没进上下文地凭空消失。
        """
        heavy = main.CACHE_HISTORY_TARGET_MESSAGES + 40
        rows = [self._say(f"今天第 {i} 句", self.day_start + 60 * i) for i in range(heavy)]
        cutoff = main._memory_cutoff(self.chat["id"])
        self.assertGreater(cutoff, 0, "超出上下文窗口的那段必须被压走")
        window_floor = rows[-main.CACHE_HISTORY_TARGET_MESSAGES]
        self.assertLess(cutoff, window_floor, "压缩线不该咬进上下文窗口里")


if __name__ == "__main__":
    unittest.main()
