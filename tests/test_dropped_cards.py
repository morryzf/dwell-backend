"""出的卡被挡下时，别装作这一段已经处理过了。

以前：模型返回的卡只要有一个字段不在词表里就被 `continue` 掉，分段照样标成
「处理过」。结果是那批原文的卡永久丢失，而面板上看起来只是「跑了一趟，
什么也没出」——没有红条，没有数字，无从查起。
"""

import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from app import db, main


class DroppedCardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "drops.db")
        db.init_db()
        self.chat = db.chat_add("整理")["id"]
        db.message_add(self.chat, "user", "我搬到上海了")
        db.message_add(self.chat, "assistant", "我会记得")
        self.segment = db.chat_memory_add_segment(self.chat, 1, 2, "她搬到了上海。")

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def _stage(self, cards, drops=None):
        """跑一趟出卡，模型的返回由调用方给定。"""
        async def run():
            with mock.patch.object(main, "_memory_json_completion",
                                   mock.AsyncMock(return_value={"cards": cards})):
                await main._stage_memory_card_suggestions(
                    self.chat, {"id": "p", "enabled": 1}, "model",
                    [self.segment], drops,
                )
        asyncio.run(run())

    def _pending(self):
        return [item["id"] for item in db.memory_card_unprocessed_segments(self.chat)]

    GOOD = {
        "source": "S1", "content": "她现在住在上海。", "memory_type": "stable_fact",
        "topics": ["place"], "importance": "normal", "retention": "long_term",
        "valid_until": None,
    }

    def test_a_good_card_lands_and_the_segment_is_done(self):
        self._stage([self.GOOD])

        self.assertEqual(len(db.memory_card_draft_list(self.chat)), 1)
        self.assertEqual(self._pending(), [])
        self.assertEqual(db.memory_card_state_get(self.chat)["note"], "")

    def test_a_segment_whose_cards_were_all_blocked_stays_retryable(self):
        # 这一段不是「没什么值得记的」，是出的卡全被挡下了。标成处理过就再也
        # 救不回来——那批原文的卡永久丢失，而且没人知道。
        self._stage([{**self.GOOD, "topics": ["不在词表里的主题"]}])

        self.assertEqual(db.memory_card_draft_list(self.chat), [])
        self.assertEqual(self._pending(), [self.segment["id"]])

    def test_the_panel_is_told_what_was_dropped_and_why(self):
        self._stage([{**self.GOOD, "topics": ["不在词表里的主题"]},
                     {**self.GOOD, "memory_type": "不在词表里的类型"}])

        note = db.memory_card_state_get(self.chat)["note"]
        self.assertIn("2 张卡没留下", note)
        self.assertIn("记忆主题不在允许范围内", note)
        self.assertIn("记忆类型不在允许范围内", note)

    def test_nothing_worth_keeping_is_not_a_drop(self):
        # 模型看过了、认为没什么值得记——那是它的判断，标成处理过，别没完没了地重试。
        self._stage([])

        self.assertEqual(self._pending(), [])
        self.assertEqual(db.memory_card_state_get(self.chat)["note"], "")

    def test_one_good_card_is_enough_to_close_the_segment(self):
        # 挡下一张不该拖住整段：有卡留下就算这段看过了。
        self._stage([self.GOOD, {**self.GOOD, "importance": "非常重要"}])

        self.assertEqual(len(db.memory_card_draft_list(self.chat)), 1)
        self.assertEqual(self._pending(), [])
        self.assertIn("1 张卡没留下", db.memory_card_state_get(self.chat)["note"])

    def test_a_card_that_does_not_say_where_it_came_from_is_counted(self):
        self._stage([{**self.GOOD, "source": "S9"}])

        self.assertIn("卡片没说它来自哪一段", db.memory_card_state_get(self.chat)["note"])

    def test_the_note_counts_the_whole_run_not_just_the_last_batch(self):
        # 一趟分好几批送，面板上那句话要说的是整趟丢了多少。
        drops: dict[str, list[str]] = {}
        self._stage([{**self.GOOD, "topics": ["坏主题"]}], drops)
        self._stage([{**self.GOOD, "topics": ["坏主题"]}], drops)

        self.assertIn("2 张卡没留下", db.memory_card_state_get(self.chat)["note"])

    def test_a_later_error_clears_the_note_so_the_red_bar_stands_alone(self):
        self._stage([{**self.GOOD, "topics": ["坏主题"]}])
        self.assertTrue(db.memory_card_state_get(self.chat)["note"])

        async def run():
            with mock.patch.object(main, "_memory_json_completion",
                                   mock.AsyncMock(side_effect=ValueError("坏格式"))):
                await main._stage_memory_card_suggestions(
                    self.chat, {"id": "p", "enabled": 1}, "model", [self.segment],
                )
        asyncio.run(run())

        state = db.memory_card_state_get(self.chat)
        self.assertEqual(state["status"], "error")
        self.assertEqual(state["note"], "")


class NoteSurvivesRoutineRefreshTest(unittest.TestCase):
    """打开面板会顺手刷新状态。那一下不该把上一趟留下的话抹掉。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "note.db")
        db.init_db()
        self.chat = db.chat_add("整理")["id"]

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def test_a_status_only_write_keeps_the_note(self):
        db.memory_card_state_set(self.chat, "ready", note="丢了 3 张卡")

        db.memory_card_state_set(self.chat, "review")

        self.assertEqual(db.memory_card_state_get(self.chat)["note"], "丢了 3 张卡")

    def test_an_empty_string_really_clears_it(self):
        db.memory_card_state_set(self.chat, "ready", note="丢了 3 张卡")

        db.memory_card_state_set(self.chat, "ready", note="")

        self.assertEqual(db.memory_card_state_get(self.chat)["note"], "")

    def test_an_old_database_gains_the_column(self):
        # 她那台机器上的库早就建好了。CREATE TABLE IF NOT EXISTS 不会动已有的表，
        # 加字段只能靠迁移——漏了这一步，线上一开面板就 500。
        db.memory_card_state_set(self.chat, "ready", note="迁移前就有的一行")
        with db.conn() as cx:
            cx.execute("ALTER TABLE memory_card_state DROP COLUMN note")

        db.init_db()

        with db.conn() as cx:
            cols = {row["name"] for row in cx.execute(
                "PRAGMA table_info(memory_card_state)").fetchall()}
        self.assertIn("note", cols)
        self.assertEqual(db.memory_card_state_get(self.chat)["note"], "")


if __name__ == "__main__":
    unittest.main()
