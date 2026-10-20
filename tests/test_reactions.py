"""消息上的表情：Cloudy 用 React 贴在她的消息上，她在 Cloudy 的消息上贴；一条只留一个。"""

import asyncio
import json
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main


class ReactionTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"reaction-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("reaction test")["id"]
        db.chat_switch(self.chat)
        self.earlier = db.message_add(self.chat, "assistant", "早呀")
        self.photo = db.message_add(self.chat, "user", "（发来了一张图片）")
        self.words = db.message_add(self.chat, "user", "今天的晚霞")
        self.rounds = []
        self.sent = []
        self.patched = {}

        async def fake_stream(provider, model_id, messages, *args, **kwargs):
            self.sent.append([dict(m) for m in messages])
            for event in (self.rounds.pop(0) if self.rounds else []):
                yield event

        for name, value in {
            "stream_chat": fake_stream,
            "prompt_cache_enabled": lambda *a, **k: False,
        }.items():
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
        for name in ("stream_chat", "prompt_cache_enabled"):
            setattr(main, name, self.patched[name])
        main.db.chat_model_get = self.patched["chat_model_get"]
        main.db.provider_get = self.patched["provider_get"]
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _events(self, kind):
        return [e for e in main._event_log.get(self.chat, []) if e["type"] == kind]

    def _react_call(self, emoji, back=None):
        args = {"emoji": emoji} if back is None else {"emoji": emoji, "back": back}
        return [{"type": "tool_calls", "calls": [
            {"id": "c1", "name": "React", "arguments": json.dumps(args, ensure_ascii=False)},
        ]}]

    def _reply(self):
        placeholder = db.message_add(self.chat, "assistant", "")
        asyncio.run(main._run_ai_reply(self.chat, placeholder["id"]))
        return placeholder["id"]

    # ------------------------------------------------------------ 工具

    def test_only_one_emoji_counts(self):
        self.assertEqual(db.clean_reaction(" ❤️ "), "❤️")
        self.assertEqual(db.clean_reaction(""), "")
        for bad in ("好", "ok", "❤️ 🥺", "1", "🥺" * 20):
            with self.assertRaises(ValueError):
                db.clean_reaction(bad)

    def test_react_goes_on_her_latest_message_past_the_reply_in_progress(self):
        db.message_add(self.chat, "assistant", "")

        result = main.react_tool(self.chat, {"emoji": "🥰"})

        self.assertIn("今天的晚霞", result)
        self.assertEqual(db.message_get(self.words["id"])["reaction"], "🥰")
        self.assertEqual(self._events("reaction")[-1]["message_id"], self.words["id"])

    def test_back_reaches_the_photo_before_it(self):
        main.react_tool(self.chat, {"emoji": "😍", "back": 1})

        self.assertEqual(db.message_get(self.photo["id"])["reaction"], "😍")
        self.assertEqual(db.message_get(self.words["id"])["reaction"], "")

    def test_back_stops_at_what_cloudy_last_said(self):
        with self.assertRaises(ValueError):
            main.react_tool(self.chat, {"emoji": "😍", "back": 2})

    def test_a_new_emoji_replaces_the_old_one(self):
        main.react_tool(self.chat, {"emoji": "😍"})
        main.react_tool(self.chat, {"emoji": "😂"})

        self.assertEqual(db.message_get(self.words["id"])["reaction"], "😂")

    def test_every_chat_has_the_tool_but_heartbeat_does_not(self):
        tools, tool_map = asyncio.run(main._chat_tools(self.chat))
        react = next(t for t in tools if t["function"]["name"] == "React")

        self.assertEqual(tool_map["React"], "builtin:react")
        self.assertFalse(main._heartbeat_tool_allowed(react, "builtin:react"))

    # ------------------------------------------------------------ 一轮回复

    def test_a_reaction_alone_leaves_no_empty_bubble(self):
        self.rounds = [self._react_call("🥺"), []]

        reply = self._reply()

        self.assertIsNone(db.message_get(reply))
        self.assertEqual(db.message_get(self.words["id"])["reaction"], "🥺")
        self.assertEqual(self._events("assistant_removed")[-1]["message_id"], reply)

    def test_a_reaction_with_words_keeps_the_reply(self):
        self.rounds = [self._react_call("🥺"), [{"type": "text", "text": "好看"}]]

        reply = self._reply()

        self.assertEqual(db.message_get(reply)["content"], "好看")
        self.assertEqual(db.message_get(self.words["id"])["reaction"], "🥺")

    def test_cloudy_sees_reactions_without_the_messages_changing(self):
        db.message_reaction_set(self.words["id"], "🥺")
        db.message_reaction_set(self.earlier["id"], "❤️")
        self.rounds = [[{"type": "text", "text": "嗯"}]]

        self._reply()

        sent = self.sent[0]
        note = next(m["content"] for m in sent if m["role"] == "system" and "[Reactions]" in str(m["content"]))
        self.assertIn('You reacted 🥺 to her message "今天的晚霞"', note)
        self.assertIn('Morry reacted ❤️ to your message "早呀"', note)
        self.assertIn({"role": "user", "content": "今天的晚霞"}, sent)

    def test_regenerating_takes_back_the_old_reaction(self):
        reply = db.message_add(self.chat, "assistant", "好看")
        db.message_reaction_set(self.words["id"], "🥺")
        self.rounds = [[{"type": "text", "text": "真好看"}]]

        r = self.client.post(f"/api/messages/{reply['id']}/regenerate")

        self.assertEqual(r.status_code, 200)
        self.assertEqual(db.message_get(self.words["id"])["reaction"], "")

    # ------------------------------------------------------------ 她贴的

    def test_she_reacts_to_cloudy(self):
        r = self.client.put(f"/api/messages/{self.earlier['id']}/reaction", json={"emoji": "❤️"})

        self.assertEqual(r.status_code, 200)
        self.assertEqual(db.message_get(self.earlier["id"])["reaction"], "❤️")
        listed = {m["id"]: m for m in db.message_ui_list(self.chat)["msgs"]}
        self.assertEqual(listed[self.earlier["id"]]["reaction"], "❤️")
        self.assertEqual(self._events("reaction")[-1]["emoji"], "❤️")

        r = self.client.put(f"/api/messages/{self.earlier['id']}/reaction", json={"emoji": ""})
        self.assertEqual(db.message_get(self.earlier["id"])["reaction"], "")

    def test_she_cannot_change_the_one_on_her_own_message(self):
        r = self.client.put(f"/api/messages/{self.words['id']}/reaction", json={"emoji": "❤️"})
        self.assertEqual(r.status_code, 404)

    def test_she_cannot_send_words(self):
        r = self.client.put(f"/api/messages/{self.earlier['id']}/reaction", json={"emoji": "爱你"})
        self.assertEqual(r.status_code, 400)


if __name__ == "__main__":
    unittest.main()
