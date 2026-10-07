"""心跳的两个毛病：把自己的分析当消息发出去，以及第二次主动时把第一次的话再说一遍。"""

import os
import unittest
import uuid
from datetime import datetime

from app import db, main


class HeartbeatReplyTest(unittest.TestCase):
    def test_reasoning_before_no_action_stays_quiet(self):
        raw = ("她妈今天回来，她可能正在收拾家里。54分钟不算久，"
               "不需要主动追，等她回就行。\n\n[NO_ACTION]")
        self.assertEqual(main._heartbeat_reply(raw), "")

    def test_only_the_tagged_part_is_sent(self):
        raw = "她应该到家了，问一句。\n<message>到家了吗？</message>"
        self.assertEqual(main._heartbeat_reply(raw), "到家了吗？")

    def test_tag_with_no_action_inside_is_quiet(self):
        self.assertEqual(main._heartbeat_reply("<message>[NO_ACTION]</message>"), "")
        self.assertEqual(main._heartbeat_reply("<message>  </message>"), "")

    def test_unclosed_tag_still_works(self):
        self.assertEqual(main._heartbeat_reply("想想。<message>吃饭了没"), "吃饭了没")

    def test_plain_message_is_still_accepted(self):
        self.assertEqual(main._heartbeat_reply("  吃饭了没  "), "吃饭了没")
        self.assertEqual(main._heartbeat_reply("[NO_ACTION]"), "")


class HeartbeatUnansweredTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"heartbeat-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat_id = db.chat_add("hb")["id"]

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _trigger(self):
        now = datetime.now(db.CN_TZ)
        return main._heartbeat_context(self.chat_id, now, 60)[-1]["content"]

    def test_lists_proactive_messages_she_has_not_answered(self):
        db.message_add(self.chat_id, "user", "妈妈今天就回来了")
        db.message_add(self.chat_id, "assistant", "什么时候到，晚上？")
        db.message_add(self.chat_id, "assistant", "到家了吗？", origin="heartbeat")
        pending = main._heartbeat_unanswered(self.chat_id)
        self.assertEqual([item["content"] for item in pending], ["到家了吗？"])
        trigger = self._trigger()
        self.assertIn("you've already sent her 1 message on your own, and she hasn't replied yet", trigger)
        self.assertIn("到家了吗？", trigger)
        # 她回复前 Cloudy 自己接的那句不算追发。
        self.assertNotIn("什么时候到", trigger)

    def test_her_reply_clears_the_list(self):
        db.message_add(self.chat_id, "assistant", "到家了吗？", origin="heartbeat")
        db.message_add(self.chat_id, "user", "到了")
        db.message_add(self.chat_id, "assistant", "那就好")
        self.assertEqual(main._heartbeat_unanswered(self.chat_id), [])
        self.assertNotIn("hasn't replied yet", self._trigger())

    def test_asks_for_tagged_output(self):
        db.message_add(self.chat_id, "user", "嗯")
        db.message_add(self.chat_id, "assistant", "好")
        trigger = self._trigger()
        self.assertIn("<message>", trigger)
        self.assertIn("[NO_ACTION]", trigger)


if __name__ == "__main__":
    unittest.main()
