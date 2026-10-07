"""自己动手加记忆卡：分类自己选，正文原样存，直接生效，不带日期；两个助手各加各的。"""

import json
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main

CARD = {"content": "她不吃香菜", "memory_type": "preference", "topics": ["food"],
        "importance": "high", "retention": "long_term"}


class ManualMemoryCardTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"manual-card-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None
        self.embedded = []

        async def fake_embed(card_id, content):
            self.embedded.append((card_id, content))
        self.saved_embed = main._embed_memory_card
        main._embed_memory_card = fake_embed

    def tearDown(self):
        main._embed_memory_card = self.saved_embed
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _add(self, chat_id, card=CARD):
        return self.client.post(f"/api/chats/{chat_id}/memory-cards", json=card)

    def test_card_is_saved_verbatim_and_active(self):
        chat = db.chat_add("c", "cloudy")["id"]
        item = self._add(chat).json()["item"]
        self.assertEqual(item["content"], "她不吃香菜")
        self.assertEqual((item["status"], item["memory_type"], item["importance"]), ("active", "preference", "high"))
        self.assertEqual(item["topics"], ["food"])
        self.assertEqual(item["undated"], 1)
        self.assertEqual(self.embedded, [(item["id"], "她不吃香菜")])

    def test_injected_card_carries_no_date(self):
        chat = db.chat_add("c", "cloudy")["id"]
        self._add(chat)
        pool = db.memory_card_embeddings(chat)
        self.assertEqual(pool[0]["happened"], 0)
        line = main._memory_card_prompt(pool)
        self.assertIn("偏好", line)
        self.assertNotRegex(line, r"\[\d{4}-\d{2}-\d{2}")

    def test_bad_fields_are_refused(self):
        chat = db.chat_add("c", "cloudy")["id"]
        self.assertEqual(self._add(chat, {**CARD, "content": "  "}).status_code, 400)
        self.assertEqual(self._add(chat, {**CARD, "memory_type": "nope"}).status_code, 400)
        self.assertEqual(self._add(chat, {**CARD, "retention": "time_bound"}).status_code, 400)
        self.assertEqual(self._add("missing").status_code, 404)

    def test_each_assistant_keeps_its_own_manual_cards(self):
        cloudy = db.chat_add("c", "cloudy")["id"]
        gpt = db.chat_add("g", "chatgpt")["id"]
        self._add(gpt, {**CARD, "content": "她在学法语"})
        self.assertEqual([c["content"] for c in db.memory_card_embeddings(gpt)], ["她在学法语"])
        self.assertEqual(db.memory_card_embeddings(cloudy), [])


if __name__ == "__main__":
    unittest.main()


class MemoryToolbarStaticTest(unittest.TestCase):
    """记忆卡页：搜索、状态、添加并排一行；编辑表单里的日期框不超出卡片。"""

    def test_toolbar_is_one_row_with_add_button(self):
        from pathlib import Path
        html = Path("static/index.html").read_text(encoding="utf-8")
        bar = html.split('<div class="mc-toolbar mc-cards-bar">', 1)[1].split("</div>", 1)[0]
        self.assertLess(bar.index('id="memorySearch"'), bar.index('id="memoryFilter"'))
        self.assertLess(bar.index('id="memoryFilter"'), bar.index('id="memoryAdd"'))
        self.assertIn(".mc-toolbar:not(.mc-cards-bar) { align-items: stretch; flex-direction: column; }", html)
        self.assertIn('.mc-form input[type="date"] { display: block; width: 100%; min-width: 0;', html)
