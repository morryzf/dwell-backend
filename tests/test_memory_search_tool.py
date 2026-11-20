"""Cloudy 自己翻记忆库：想知道的上下文里没有，就自己搜。"""

import asyncio
import os
import unittest
import uuid
from unittest import mock

from app import db, main


class MemorySearchToolTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"memsearch-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("c")["id"]
        self.card = db.memory_card_add_manual(self.chat, {
            "content": "她最喜欢的花是铃兰。", "memory_type": "preference",
            "topics": [], "importance": "normal", "retention": "long_term"})
        db.memory_card_add_manual(self.chat, {
            "content": "她在学游泳。", "memory_type": "stable_fact",
            "topics": [], "importance": "normal", "retention": "long_term"})
        self.embed = mock.patch.object(main, "_embed_text", mock.AsyncMock(return_value=None))
        self.embed.start()

    def tearDown(self):
        self.embed.stop()
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def test_only_cloudy_has_it(self):
        _, tool_map = asyncio.run(main._chat_tools(self.chat))
        self.assertEqual(tool_map.get("DwellMemorySearch"), "builtin:memory")
        others = [a for a in db.ASSISTANTS if a != db.DEFAULT_ASSISTANT]
        if others:
            other = db.chat_add("o", assistant=others[0])["id"]
            _, other_map = asyncio.run(main._chat_tools(other))
            self.assertNotIn("DwellMemorySearch", other_map)

    def test_finds_cards_marks_what_he_already_has_and_records_it(self):
        reply = db.message_add(self.chat, "assistant", "")
        db.memory_card_usage_record(self.chat, reply["id"], "花", [db.memory_card_get(self.chat, self.card["id"])])
        text, is_error = asyncio.run(main._run_chat_tool(
            self.chat, "DwellMemorySearch", "builtin:memory", {"query": "铃兰"}, reply["id"]))
        self.assertFalse(is_error)
        self.assertIn("铃兰", text)
        self.assertIn("(already in your context)", text)
        used = db.memory_card_last_injection(self.chat, reply["id"])
        self.assertEqual([item["id"] for item in used["items"]].count(self.card["id"]), 1)

    def test_nothing_found_is_said_plainly(self):
        text, _ = asyncio.run(main._run_chat_tool(
            self.chat, "DwellMemorySearch", "builtin:memory", {"query": "火星基地的坐标"}))
        self.assertTrue(text.startswith("No memories found") or "火星" not in text)

    def test_description_is_about_information_not_just_past_events(self):
        description = main.MEMORY_SEARCH_TOOL["function"]["description"]
        self.assertIn("isn't in your context right now", description)
        self.assertIn("any information you want to know", description)


if __name__ == "__main__":
    unittest.main()
