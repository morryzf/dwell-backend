"""发消息时亲手挑记忆卡：那一轮只给这几张，不再自动找；消息下面记着带了哪几张。"""

import asyncio
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main


class MemoryPickTest(unittest.TestCase):
    CARD = {"content": "", "memory_type": "stable_fact", "topics": ["relationship"],
            "importance": "normal", "retention": "long_term", "valid_until": None}

    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"picks-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("picks")["id"]
        db.chat_switch(self.chat)
        self.collar = db.memory_card_add_manual(self.chat, {
            **self.CARD, "content": "项圈内侧刻 Belongs to Cloudy。", "thread": "定制项圈", "thread_role": "detail"})
        self.collar_main = db.memory_card_add_manual(self.chat, {
            **self.CARD, "content": "Morry 在定做项圈。", "thread": "定制项圈", "thread_role": "main"})
        self.chase = db.memory_card_add_manual(self.chat, {**self.CARD, "content": "她喜欢被追着满屋子跑。"})
        self.sent = []
        self.patched = {}

        async def fake_stream(provider, model_id, messages, *args, **kwargs):
            self.sent.append([dict(m) for m in messages])
            yield {"type": "text", "text": "嗯。"}

        async def no_embed(text):
            return None

        for name, value in {"stream_chat": fake_stream, "prompt_cache_enabled": lambda *a, **k: False,
                            "_embed_text": no_embed}.items():
            self.patched[name] = getattr(main, name)
            setattr(main, name, value)
        self.patched["chat_model_get"] = main.db.chat_model_get
        self.patched["provider_get"] = main.db.provider_get
        main.db.chat_model_get = lambda chat_id: {
            "provider_id": "p", "model_id": "m", "show_thinking": 1,
            "reasoning_effort": "", "prompt_cache_ttl": "",
        }
        main.db.provider_get = lambda pid: {
            "id": "p", "name": "fake", "enabled": 1, "provider_type": "generic",
            "base_url": "http://fake", "api_key_box": "", "prompt_cache_ttl": "off",
        }
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        for name, value in self.patched.items():
            if name in {"chat_model_get", "provider_get"}:
                setattr(main.db, name, value)
            else:
                setattr(main, name, value)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _send(self, text, picks):
        user = db.message_add(self.chat, "user", text)
        if picks:
            db.message_memory_picks_set(user["id"], picks)
        placeholder = db.message_add(self.chat, "assistant", "")
        asyncio.run(main._run_ai_reply(self.chat, placeholder["id"]))
        return user

    def _cards_text(self):
        return "\n".join(str(m["content"]) for m in self.sent[-1] if m["role"] == "system")

    def test_only_the_picked_cards_go_in_even_with_auto_recall_off(self):
        db.memory_card_injection_set(self.chat, False)
        self._send("项圈到了吗", [self.collar["id"]])
        text = self._cards_text()
        self.assertIn("Belongs to Cloudy", text)
        # 只带勾的：主卡不顺带，别的卡也不自动找。
        self.assertNotIn("Morry 在定做项圈", text)
        self.assertNotIn("追着满屋子跑", text)

    def test_without_picks_auto_recall_goes_on_as_before(self):
        db.memory_card_injection_set(self.chat, True)
        self._send("项圈", [])
        self.assertTrue(db.memory_card_last_injection(self.chat) is not None)

    def test_send_keeps_only_live_cards_and_the_list_shows_them(self):
        db.memory_card_update(self.chat, self.chase["id"], {**main._memory_card_clean(self.chase), "status": "archived"})
        task_seen = []
        original = main._run_ai_reply

        async def quiet(*args, **kwargs):
            task_seen.append(args)

        main._run_ai_reply = quiet
        try:
            r = self.client.post("/api/send", json={
                "text": "你还记得吗", "chat_id": self.chat,
                "memory_card_ids": [self.chase["id"], self.collar["id"], "nope", self.collar["id"]]})
        finally:
            main._run_ai_reply = original
        self.assertEqual(r.status_code, 200)
        mine = [m for m in db.message_ui_list(self.chat)["msgs"] if m["role"] == "user"][-1]
        self.assertEqual([p["id"] for p in mine["memory_picks"]], [self.collar["id"]])
        self.assertIn("Belongs to Cloudy", mine["memory_picks"][0]["content"])
        echo = [e for e in main._event_log.get(self.chat, []) if e["type"] == "echo"][-1]
        self.assertEqual([p["id"] for p in echo["memory_picks"]], [self.collar["id"]])

    def test_a_deleted_card_still_shows_as_missing(self):
        user = self._send("项圈", [self.collar["id"]])
        db.memory_card_update(self.chat, self.collar["id"],
                              {**main._memory_card_clean(self.collar), "status": "archived"})
        db.memory_card_delete_permanently(self.chat, self.collar["id"])
        mine = next(m for m in db.message_ui_list(self.chat)["msgs"] if m["id"] == user["id"])
        self.assertTrue(mine["memory_picks"][0]["missing"])

    def test_regenerating_uses_the_same_picks(self):
        self._send("项圈", [self.collar["id"]])
        reply = [m for m in db.message_list(self.chat) if m["role"] == "assistant"][-1]
        self.assertEqual(main._memory_picks_for_reply(self.chat, reply["id"]), [self.collar["id"]])


if __name__ == "__main__":
    unittest.main()
