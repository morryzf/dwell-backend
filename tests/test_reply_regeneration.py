import ast
import os
from pathlib import Path
import unittest
import uuid

from app import db
from app.main import _split_reply_segments


ROOT = Path(__file__).parents[1]
MAIN_SOURCE = (ROOT / "app" / "main.py").read_text(encoding="utf-8")
HTML = (ROOT / "static" / "index.html").read_text(encoding="utf-8")


class ReplySegmentationTest(unittest.TestCase):
    def test_spaces_and_single_line_breaks_stay_in_one_bubble(self):
        self.assertEqual(_split_reply_segments("第一句。 第二句"), ["第一句。 第二句"])
        self.assertEqual(_split_reply_segments("第一行\n第二行"), ["第一行\n第二行"])

    def test_blank_lines_and_explicit_markers_split_bubbles(self):
        self.assertEqual(_split_reply_segments("第一条\n\n第二条"), ["第一条", "第二条"])
        self.assertEqual(
            _split_reply_segments("第一条<dwell-split>第二条"),
            ["第一条", "第二条"],
        )

    def test_blank_lines_inside_fenced_code_remain_intact(self):
        reply = "代码：\n```text\n第一行\n\n第二行\n```\n结束"
        self.assertEqual(_split_reply_segments(reply), [reply])


class ReplyTurnGroupingTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"reply-turn-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("reply turn test")
        db.message_add(self.chat["id"], "user", "问题")
        self.first = db.message_add(self.chat["id"], "assistant", "第一条")
        self.second = db.message_add(self.chat["id"], "assistant", "第二条")
        self.other = db.message_add(self.chat["id"], "assistant", "另一轮主动消息")
        db.message_usage_update(self.first["id"], {"tts_turn_id": self.first["id"]})
        db.message_usage_update(self.second["id"], {"tts_turn_id": self.first["id"]})
        db.message_usage_update(self.other["id"], {"tts_turn_id": self.other["id"]})

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            path = self.path + suffix
            if os.path.exists(path):
                os.remove(path)

    def test_clicking_any_split_bubble_resolves_the_whole_reply_only(self):
        grouped = db.message_assistant_reply_turn(self.second["id"])
        self.assertEqual([item["id"] for item in grouped], [self.first["id"], self.second["id"]])


class ReplyRegenerationWiringTest(unittest.TestCase):
    def test_server_replaces_the_group_and_browser_removes_all_rendered_rows(self):
        ast.parse(MAIN_SOURCE)
        self.assertIn("reply_messages = db.message_assistant_reply_turn(message_id)", MAIN_SOURCE)
        self.assertIn('"message_id": anchor["id"], "message_ids": reply_ids', MAIN_SOURCE)
        self.assertIn("db.message_delete_many(", MAIN_SOURCE)
        self.assertIn("const replacedIds = Array.isArray(d.message_ids)", HTML)
        self.assertIn("document.querySelectorAll('#log .row[data-message-id=", HTML)


if __name__ == "__main__":
    unittest.main()
