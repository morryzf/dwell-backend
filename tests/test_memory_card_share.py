"""记忆卡共享：复制一张给另一位助手，之后两边各改各的。"""

import os
from pathlib import Path
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main

HTML = (Path(__file__).resolve().parents[1] / "static" / "index.html").read_text(encoding="utf-8")


class MemoryCardShareTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"share-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None
        self.cloudy = db.chat_add("c", "cloudy")["id"]
        self.gpt = db.chat_add("g", "chatgpt")["id"]
        self.card = db.memory_card_add_manual(self.cloudy, {
            "content": "她不吃香菜", "memory_type": "preference", "topics": ["food"],
            "importance": "normal", "retention": "long_term", "valid_until": None,
        })

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _share(self, chat_id=None, card_id=None):
        return self.client.post(
            f"/api/chats/{chat_id or self.cloudy}/memory-cards/{card_id or self.card['id']}/share")

    def test_share_copies_the_card_to_the_other_assistant(self):
        response = self._share()
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["to_name"], "ChatGPT")
        copy = data["item"]
        self.assertEqual(copy["chat_id"], self.gpt)
        self.assertEqual(copy["content"], "她不吃香菜")
        self.assertEqual(copy["shared_from"], self.card["id"])
        # 对方的检索和记忆页都看得到
        self.assertIn(copy["id"], [c["id"] for c in db.memory_card_embeddings(self.gpt)])
        page = db.memory_card_page(self.cloudy)["items"]
        self.assertEqual(page[0]["shared_count"], 1)

    def test_the_two_copies_change_independently(self):
        copy = self._share().json()["item"]
        self.client.put(f"/api/chats/{self.gpt}/memory-cards/{copy['id']}", json={"content": "她不吃香菜和葱"})
        self.assertEqual(db.memory_card_get(self.cloudy, self.card["id"])["content"], "她不吃香菜")
        self.assertEqual(db.memory_card_get(self.gpt, copy["id"])["content"], "她不吃香菜和葱")

    def test_no_double_share_and_no_sharing_back(self):
        copy = self._share().json()["item"]
        self.assertEqual(self._share().status_code, 400)
        self.assertEqual(self._share(self.gpt, copy["id"]).status_code, 400)
        # 对方把那张归档了，可以再共享一次
        db.memory_card_archive(self.gpt, copy["id"])
        self.assertEqual(self._share().status_code, 200)

    def test_goes_to_the_other_assistants_current_chat(self):
        second = db.chat_add("g2", "chatgpt")["id"]
        db.chat_add("g3", "chatgpt")
        db.chat_switch(second)
        db.chat_switch(self.cloudy)
        self.assertEqual(self._share().json()["item"]["chat_id"], second)

    def test_no_chat_on_the_other_side(self):
        with db.conn() as cx:
            cx.execute("DELETE FROM chats WHERE id=?", (self.gpt,))
        response = self._share()
        self.assertEqual(response.status_code, 400)
        self.assertIn("还没有聊天", response.json()["detail"])

    def test_confirmed_cards_offer_share_not_split(self):
        start = HTML.index("  else actions = `<button class=\"mc-btn\" data-memory-edit=")
        line = HTML[start:HTML.index("\n", start)]
        self.assertIn("data-memory-share", line)
        self.assertNotIn("data-memory-split", line)
        # 待确认里的拆开还在
        draft = HTML[HTML.index("if (kind === 'draft') actions ="):]
        self.assertIn("data-memory-split", draft[:draft.index("\n")])


if __name__ == "__main__":
    unittest.main()
