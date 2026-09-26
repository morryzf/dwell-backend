import tempfile
import unittest
from pathlib import Path

from app import db
from app.main import (
    CACHE_HISTORY_TARGET_MESSAGES,
    MEMORY_CARD_UPDATE_MIN_MESSAGES,
    MEMORY_TAIL_MESSAGES,
    _history_window,
    _memory_card_segmented_through,
    _memory_cutoff,
)


class StrandedTopupTest(unittest.TestCase):
    """原文窗口按「今天多少条」走，做卡按「攒够 50 条」走。

    两边节奏不一样，会漏出一个洞：今天一过 100 条，昨天那几句立刻滑出窗口，
    可它们又不够 50 条做不成卡——两头都不在，模型是真看不见了。
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(cls.tmp.name) / "topup.db")
        db.init_db()
        cls.day = db.day_start_ts()

    @classmethod
    def tearDownClass(cls):
        db.DB_PATH = cls.previous_path
        cls.tmp.cleanup()

    def _chat(self, name, older, yesterday, today):
        """建一间聊天：更早的都已经做过卡，昨天和今天各若干条。"""
        chat = db.chat_add(name)["id"]

        def add(count, made):
            ids = []
            for _ in range(count):
                message = db.message_add(chat, "user", "x")
                with db.conn() as cx:
                    cx.execute(
                        "UPDATE messages SET made=? WHERE id=?", (made, message["id"])
                    )
                ids.append(message["id"])
            return ids

        add(older, self.day - 200_000)
        yesterday_ids = add(yesterday, self.day - 40_000)
        add(today, self.day + 100)
        with db.conn() as cx:
            first = cx.execute(
                "SELECT rowid FROM messages WHERE id=?", (yesterday_ids[0],)
            ).fetchone()["rowid"]
            cx.execute(
                "INSERT INTO chat_memory_state (chat_id,enabled,through_rowid) VALUES (?,1,?)",
                (chat, first - 1),
            )
        return chat

    def _batch(self, chat):
        return db.chat_memory_source_messages(
            chat,
            _memory_card_segmented_through(chat),
            _memory_cutoff(chat),
            MEMORY_CARD_UPDATE_MIN_MESSAGES,
        )

    def test_a_quiet_yesterday_under_a_busy_today_still_gets_cards(self):
        chat = self._chat("昨天少今天多", 200, 20, 150)

        self.assertEqual(len(self._batch(chat)), MEMORY_CARD_UPDATE_MIN_MESSAGES)

    def test_the_raw_window_is_untouched_by_the_topup(self):
        # 这是整件事的前提：借今天的话去做卡，今天的原文一条都不能少。
        chat = self._chat("原文不受影响", 200, 20, 150)
        before = _history_window(chat, CACHE_HISTORY_TARGET_MESSAGES)

        _memory_cutoff(chat)

        self.assertEqual(_history_window(chat, CACHE_HISTORY_TARGET_MESSAGES), before)
        self.assertEqual(before, 150)

    def test_yesterday_is_left_alone_while_it_is_still_in_the_window(self):
        # 今天才 30 条，窗口 100，昨天的看得见——不用急着做卡。
        chat = self._chat("昨天还看得见", 200, 20, 30)

        self.assertEqual(self._batch(chat), [])

    def test_a_full_backlog_needs_no_help(self):
        chat = self._chat("积压本来就够", 200, 80, 150)

        batch = self._batch(chat)

        self.assertEqual(len(batch), MEMORY_CARD_UPDATE_MIN_MESSAGES)

    def test_half_a_batch_waits_rather_than_making_thin_cards(self):
        chat = self._chat("今天也没攒够", 200, 20, 20)

        self.assertEqual(self._batch(chat), [])

    def test_the_topup_never_crosses_the_recent_tail_lock(self):
        chat = self._chat("不碰最近的尾巴", 200, 20, 150)

        cutoff = _memory_cutoff(chat)
        tail = db.message_list(chat, limit=MEMORY_TAIL_MESSAGES)

        self.assertLess(cutoff, int(tail[0]["rowid"]))


if __name__ == "__main__":
    unittest.main()
