"""三个点上的提示点：有新的待确认记忆卡就亮，打开过记忆面板就灭。"""

import os
import time
import unittest
import uuid
from pathlib import Path
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main

HTML = (Path(__file__).resolve().parents[1] / "static" / "index.html").read_text(encoding="utf-8")

CARD = {"content": "她喜欢灰色。", "memory_type": "preference", "topics": ["other"],
        "importance": "normal", "retention": "long_term", "valid_until": None}


class MemoryBadgeTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"badge-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        self.client.headers["X-Dwell-Token"] = "t"
        self._token = mock.patch.object(auth, "API_TOKEN", "t")
        self._token.start()
        self.chat = main._get_or_create_current_chat()

    def tearDown(self):
        self._token.stop()
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _badge(self):
        return self.client.get("/api/memory/badge").json()

    def test_new_drafts_light_the_dot_and_opening_clears_it(self):
        self.assertEqual(self._badge()["unseen"], 0)
        db.memory_card_stage(self.chat, [CARD])
        badge = self._badge()
        self.assertEqual((badge["chat_id"], badge["unseen"]), (self.chat, 1))

        self.client.post("/api/memory/badge/seen", json={"chat_id": self.chat})
        # 没采用也一样灭。
        self.assertEqual(len(db.memory_card_draft_list(self.chat)), 1)
        self.assertEqual(self._badge()["unseen"], 0)

    def test_only_drafts_after_the_last_look_count(self):
        db.setting_set(main.MEMORY_DRAFTS_SEEN_PREFIX + self.chat, str(int(time.time()) - 10))
        with mock.patch.object(db.time, "time", return_value=time.time() - 60):
            db.memory_card_stage(self.chat, [CARD])
        db.memory_card_stage(self.chat, [{**CARD, "content": "她喜欢下雨天。"}])
        self.assertEqual(self._badge()["unseen"], 1)

    def test_badge_reports_the_injection_switch(self):
        db.memory_card_injection_set(self.chat, False)
        self.assertFalse(self._badge()["injection_enabled"])
        db.memory_card_injection_set(self.chat, True)
        self.assertTrue(self._badge()["injection_enabled"])

    def test_the_menu_has_the_dot_and_the_switch(self):
        self.assertIn('id="memInjectSw" role="switch"', HTML)
        self.assertIn('<i class="mem-dot"', HTML)
        self.assertIn("event.stopPropagation();", HTML)
        self.assertIn("markMemorySeen(chat.id);", HTML)


if __name__ == "__main__":
    unittest.main()
