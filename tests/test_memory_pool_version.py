"""她把一张卡收起来了，它得真的忘掉。

走 Claude Code 那条通道时，记忆卡是每轮随 prompt 递过去的，而 Claude Code
把整段会话都记着——删卡、改卡、归档都追不回已经递出去的那几份。唯一的办法
是让会话指纹对不上，下一轮重开一段。
"""

import tempfile
import time
import unittest
from pathlib import Path

from app import db
from app.agent_sdk_client import _anchor, build_bridge_payload, turns_digest


class MemoryPoolVersionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "pool.db")
        db.init_db()
        self.chat = db.chat_add("聊天")["id"]

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def _card(self, content="她周四要去体检"):
        message = db.message_add(self.chat, "user", content)
        now = int(time.time())
        with db.conn() as cx:
            rowid = cx.execute(
                "SELECT rowid FROM messages WHERE id=?", (message["id"],)
            ).fetchone()["rowid"]
            card_id = db.new_id()
            cx.execute(
                "INSERT INTO memory_cards (id,chat_id,content,memory_type,topics_json,"
                "importance,retention,status,source_start_rowid,source_end_rowid,made,updated) "
                "VALUES (?,?,?,'stable_fact','[]','normal','long_term','active',?,?,?,?)",
                (card_id, self.chat, content, rowid, rowid, now, now),
            )
        return card_id

    def _card_payload(self, card_id):
        card = db.memory_card_get(self.chat, card_id)
        return {**card, "content": card["content"], "status": card["status"]}

    def test_a_fresh_install_has_a_version(self):
        self.assertEqual(db.memory_pool_version(), "0")

    def test_accepting_a_draft_moves_it(self):
        before = db.memory_pool_version()
        segment = db.chat_memory_add_segment(self.chat, 1, 1, "分段")
        db.memory_card_stage(self.chat, [{
            "content": "她住在上海。", "memory_type": "stable_fact", "topics": ["place"],
            "importance": "normal", "retention": "long_term", "valid_until": None,
            "source_segment_id": segment["id"],
        }])
        draft = db.memory_card_draft_list(self.chat)[0]

        db.memory_card_draft_accept(self.chat, draft["id"], draft)

        self.assertNotEqual(db.memory_pool_version(), before)

    def test_staging_a_draft_alone_does_not(self):
        # 草稿还没进池子，模型看不到它。为一份草稿重开会话是白花一次缓存。
        segment = db.chat_memory_add_segment(self.chat, 1, 1, "分段")
        before = db.memory_pool_version()

        db.memory_card_stage(self.chat, [{
            "content": "她住在上海。", "memory_type": "stable_fact", "topics": ["place"],
            "importance": "normal", "retention": "long_term", "valid_until": None,
            "source_segment_id": segment["id"],
        }])

        self.assertEqual(db.memory_pool_version(), before)

    def test_archiving_moves_it(self):
        card_id = self._card()
        before = db.memory_pool_version()

        db.memory_card_archive(self.chat, card_id)

        self.assertNotEqual(db.memory_pool_version(), before)

    def test_editing_moves_it(self):
        card_id = self._card()
        before = db.memory_pool_version()

        db.memory_card_update(self.chat, card_id,
                              {**self._card_payload(card_id), "content": "改过的内容"})

        self.assertNotEqual(db.memory_pool_version(), before)

    def test_deleting_moves_it(self):
        card_id = self._card()
        db.memory_card_archive(self.chat, card_id)
        before = db.memory_pool_version()

        db.memory_card_delete_permanently(self.chat, card_id)

        self.assertNotEqual(db.memory_pool_version(), before)

    def test_a_delete_that_found_nothing_does_not(self):
        before = db.memory_pool_version()

        self.assertFalse(db.memory_card_delete_permanently(self.chat, "不存在的卡"))

        self.assertEqual(db.memory_pool_version(), before)

    def test_the_sharing_switch_moves_it(self):
        # 互通决定池子里有谁。
        before = db.memory_pool_version()
        db.memory_shared_set(self.chat, False)
        self.assertNotEqual(db.memory_pool_version(), before)

    def test_the_injection_switch_moves_it(self):
        # 关掉之后不再递新的卡，但已经递出去的还在它脑子里。
        before = db.memory_pool_version()
        db.memory_card_injection_set(self.chat, False)
        self.assertNotEqual(db.memory_pool_version(), before)


class ResumeFollowsThePoolTest(unittest.TestCase):
    """指纹里带上池子版本，改过卡就不续会话。"""

    MESSAGES = [
        {"role": "system", "content": "你是 Cloudy"},
        {"role": "user", "content": "在吗"},
        {"role": "assistant", "content": "在"},
        {"role": "user", "content": "再说一句"},
    ]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "resume.db")
        db.init_db()
        self.chat = db.chat_add("聊天")["id"]

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def _state(self, cards=None):
        anchor, size = _anchor([("Morry", "在吗")])
        return {
            "sid": "sess-1", "model": "sonnet",
            "sys": turns_digest([("system", "你是 Cloudy")]),
            "anchor": anchor, "anchor_len": size,
            "cards": db.memory_pool_version() if cards is None else cards,
        }

    def test_an_untouched_pool_still_resumes(self):
        payload = build_bridge_payload("sonnet", self.MESSAGES, state=self._state())

        self.assertEqual(payload["resume"], "sess-1")
        self.assertEqual(payload["prompt"], "再说一句")

    def test_touching_the_pool_starts_a_fresh_session(self):
        state = self._state()

        db.memory_pool_touch()
        payload = build_bridge_payload("sonnet", self.MESSAGES, state=state)

        self.assertNotIn("resume", payload)
        self.assertIn("对话记录", payload["prompt"])

    def test_the_new_version_is_what_gets_saved(self):
        # 存回去的必须是这一轮真正用的那个版本，否则下一轮又对不上，永远重讲。
        db.memory_pool_touch()

        payload = build_bridge_payload("sonnet", self.MESSAGES, state=self._state())

        self.assertEqual(payload["_cards"], db.memory_pool_version())

    def test_a_state_saved_before_this_change_resets_once(self):
        # 她机器上存着的旧状态没有 cards 这一项。重讲一次是对的：那段会话里
        # 确实躺着一堆来历不明的卡。
        state = self._state()
        state.pop("cards")

        payload = build_bridge_payload("sonnet", self.MESSAGES, state=state)

        self.assertNotIn("resume", payload)

    def test_an_unreadable_pool_does_not_block_the_reply(self):
        # 版本号只是个优化。读不到就当没变，照常续会话，别因此把话卡住。
        db.DB_PATH = "/不存在的路径/没有这个库.db"

        payload = build_bridge_payload("sonnet", self.MESSAGES, state=self._state(cards=""))

        self.assertEqual(payload["resume"], "sess-1")


if __name__ == "__main__":
    unittest.main()
