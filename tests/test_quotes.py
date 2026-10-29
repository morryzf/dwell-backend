"""引用：她引用任何一条，Cloudy 用 [[quote:那几个字]] 引用上下文里的一条；存原话副本，每轮都读得到。"""

import asyncio
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main
from app.reply_marks import MarkFilter, strip_marks
from app.llm_client import reply_language_ok


class MarkFilterTest(unittest.TestCase):
    def test_marks_are_taken_out_even_when_split(self):
        f = MarkFilter()
        out = f.feed("好呀[[quo") + f.feed("te:六点闹腾]]那个坏") + f.feed("小子[") + f.feed("[react:🥺]]") + f.flush()
        self.assertEqual(out, "好呀那个坏小子")
        self.assertEqual(f.take(), [("quote", "六点闹腾"), ("react", "🥺")])

    def test_other_markers_and_plain_brackets_stay(self):
        f = MarkFilter()
        out = f.feed("看这张\\n[[sigillo:abc]]\\n还有 [[ 这不是记号") + f.flush()
        self.assertEqual(out, "看这张\\n[[sigillo:abc]]\\n还有 [[ 这不是记号")
        self.assertEqual(f.take(), [])

    def test_language_check_ignores_quoted_chinese(self):
        self.assertTrue(reply_language_ok("[[quote:布丁这个坏小子在六点闹腾]]Ha, that little menace again.", "en"))
        self.assertEqual(strip_marks("a[[react:🥺]]b"), "ab")


class QuoteTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"quote-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("quotes")["id"]
        db.chat_switch(self.chat)
        self.early = db.message_add(self.chat, "user", "布丁这个坏小子在六点闹腾，我一直睡不好")
        self.his = db.message_add(self.chat, "assistant", "那我晚上把它关在客厅？")
        self.now = db.message_add(self.chat, "user", "算了，它乖的时候很治愈")
        self.sent = []
        self.rounds = []
        self.patched = {}

        async def fake_stream(provider, model_id, messages, *args, **kwargs):
            self.sent.append([dict(m) for m in messages])
            for event in (self.rounds.pop(0) if self.rounds else []):
                yield event

        for name, value in {"stream_chat": fake_stream, "prompt_cache_enabled": lambda *a, **k: False}.items():
            self.patched[name] = getattr(main, name)
            setattr(main, name, value)
        self.patched["chat_model_get"] = main.db.chat_model_get
        self.patched["provider_get"] = main.db.provider_get
        main.db.chat_model_get = lambda chat_id: {"provider_id": "p", "model_id": "m", "show_thinking": 1,
                                                  "reasoning_effort": "", "prompt_cache_ttl": ""}
        main.db.provider_get = lambda pid: {"id": "p", "name": "fake", "enabled": 1, "provider_type": "generic",
                                            "base_url": "http://fake", "api_key_box": "", "prompt_cache_ttl": "off"}
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

    def _reply(self):
        placeholder = db.message_add(self.chat, "assistant", "")
        asyncio.run(main._run_ai_reply(self.chat, placeholder["id"]))
        return db.message_get(placeholder["id"])

    def test_cloudy_quotes_by_a_few_words(self):
        self.rounds = [[{"type": "text", "text": "[[quote:六点闹腾]]那今晚我来当闹钟。"}]]
        reply = self._reply()
        self.assertEqual(reply["content"], "那今晚我来当闹钟。")
        quote = db.message_quote(reply)
        self.assertEqual((quote["message_id"], quote["role"]), (self.early["id"], "user"))
        listed = next(m for m in db.message_ui_list(self.chat)["msgs"] if m["id"] == reply["id"])
        self.assertIn("六点闹腾", listed["quote"]["content"])

    def test_words_that_match_nothing_are_dropped_quietly(self):
        self.rounds = [[{"type": "text", "text": "[[quote:根本没说过这句]]嗯。"}]]
        reply = self._reply()
        self.assertEqual(reply["content"], "嗯。")
        self.assertIsNone(db.message_quote(reply))

    def test_she_quotes_and_cloudy_reads_it_every_turn(self):
        original = main._run_ai_reply

        async def quiet(*args, **kwargs):
            return None

        main._run_ai_reply = quiet
        try:
            r = self.client.post("/api/send", json={"text": "你看你那时候说的", "chat_id": self.chat,
                                                    "quote_message_id": self.his["id"]})
        finally:
            main._run_ai_reply = original
        self.assertEqual(r.status_code, 200)
        mine = [m for m in db.message_ui_list(self.chat)["msgs"] if m["role"] == "user"][-1]
        self.assertEqual(mine["quote"]["message_id"], self.his["id"])
        # 原消息后来改了，引用里的原话不变。
        db.message_update(self.his["id"], "改过了")
        self.rounds = [[{"type": "text", "text": "嗯。"}]]
        self._reply()
        users = [m["content"] for m in self.sent[0] if m["role"] == "user"]
        self.assertTrue(any(c.startswith("（引用 Cloudy") and "那我晚上把它关在客厅？" in c
                            and c.endswith("你看你那时候说的") for c in users))

    def test_context_around_a_quoted_message(self):
        r = self.client.get(f"/api/messages/{self.his['id']}/context")
        cited = [m["content"] for m in r.json()["messages"] if m["cited"]]
        self.assertEqual(cited, ["那我晚上把它关在客厅？"])


if __name__ == "__main__":
    unittest.main()


class ResumeWithQuoteTest(unittest.TestCase):
    """Claude Code 续会话：它自己那条带了引用行、或者写过记号，仍认得出是它说的，不重复递。"""

    def test_own_reply_with_a_quote_line_is_recognised(self):
        from app import agent_sdk_client as a
        turns = [(a.SPEAKER_USER, "布丁吵我"), (a.SPEAKER_ASSISTANT, "（引用 Morry 10月20日 的话：布丁吵我）\n坏小子。"),
                 (a.SPEAKER_USER, "嗯")]
        state = {"sid": "s", "model": "m", "sys": a.turns_digest([("system", "")]), "cards": "",
                 "anchor": a.turns_digest(turns[:1]), "anchor_len": 1, "reply": "[[quote:布丁吵我]]坏小子。"}
        sid, fresh = a.plan_turn(state, "m", "", turns)
        self.assertEqual(sid, "s")
        self.assertEqual(fresh, [(a.SPEAKER_USER, "嗯")])
