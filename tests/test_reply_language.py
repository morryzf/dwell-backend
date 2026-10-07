"""「+」里选的回复语言：每间聊天自己记着，排在这一轮最后；没照做就打回重说。"""

import asyncio
import json
import os
from pathlib import Path
import unittest
import uuid

from fastapi.testclient import TestClient

from app import agent_sdk_client, auth, db, main
from app.llm_client import reply_language_ok


ROOT = Path(__file__).parents[1]
HTML = (ROOT / "static" / "index.html").read_text(encoding="utf-8")
BRIDGE = (ROOT / "bridge" / "server.mjs").read_text(encoding="utf-8")


class LanguageCheckTest(unittest.TestCase):
    def test_english(self):
        self.assertTrue(reply_language_ok("Hey, missed you today.", "en"))
        self.assertTrue(reply_language_ok("Did 小橘 eat already? Tell me.", "en"))
        self.assertFalse(reply_language_ok("今天好累呀，你呢？", "en"))
        self.assertFalse(reply_language_ok("好的 sure 我知道了啦，晚点再说", "en"))

    def test_chinese(self):
        self.assertTrue(reply_language_ok("今天看了 Dune，还挺好看的。", "zh"))
        self.assertFalse(reply_language_ok("Sounds good, see you tonight!", "zh"))

    def test_code_links_and_empty_do_not_count(self):
        self.assertTrue(reply_language_ok("看这个 https://example.com/some/long/english/path", "zh"))
        self.assertTrue(reply_language_ok("```python\nprint('hello world')\n```\n这样就行。", "zh"))
        self.assertTrue(reply_language_ok("", "en"))
        self.assertTrue(reply_language_ok("😊👍", "zh"))
        self.assertTrue(reply_language_ok("随便", "auto"))


class LanguageReplyFlowTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"lang-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("lang test")
        db.chat_switch(self.chat["id"])
        db.message_add(self.chat["id"], "user", "今天好累")
        self.sent = []
        self.kwargs = []
        self.replies = []
        self.provider_type = "generic"
        self.patched = {}

        async def fake_stream(provider, model_id, messages, *args, **kwargs):
            self.sent.append([dict(m) for m in messages])
            self.kwargs.append(kwargs)
            yield {"type": "text", "text": self.replies.pop(0) if self.replies else "Okay."}

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
            "id": "p", "name": "fake", "enabled": 1, "provider_type": self.provider_type,
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

    def _reply(self, voice=False):
        placeholder = db.message_add(self.chat["id"], "assistant", "")
        if voice:
            db.message_voice_set(placeholder["id"], True)
        asyncio.run(main._run_ai_reply(self.chat["id"], placeholder["id"]))
        return db.message_get(placeholder["id"])

    def _tail(self, index=0):
        last = self.sent[index][-1]
        content = last["content"]
        return content[-1]["text"] if isinstance(content, list) else content

    # ------------------------------------------------------------ 设置

    def test_default_is_auto_and_each_chat_keeps_its_own(self):
        other = db.chat_add("另一间", "chatgpt")
        self.assertEqual(db.chat_reply_language(self.chat["id"]), "auto")
        r = self.client.put(f"/api/chats/{self.chat['id']}/reply-language", json={"language": "en"})
        self.assertEqual(r.json()["language"], "en")
        self.assertEqual(self.client.get(f"/api/chats/{self.chat['id']}/reply-language").json()["language"], "en")
        self.assertEqual(db.chat_reply_language(other["id"]), "auto")
        bad = self.client.put(f"/api/chats/{self.chat['id']}/reply-language", json={"language": "fr"})
        self.assertEqual(bad.status_code, 400)

    def test_send_carries_the_switches_so_a_quick_send_does_not_lose_them(self):
        async def no_reply(*a, **k):
            return None
        original = main._run_ai_reply
        main._run_ai_reply = no_reply
        try:
            self.client.post("/api/send", json={
                "text": "hi", "chat_id": self.chat["id"], "voice": True, "reply_language": "zh",
            })
        finally:
            main._run_ai_reply = original
        self.assertTrue(db.chat_voice_mode(self.chat["id"]))
        self.assertEqual(db.chat_reply_language(self.chat["id"]), "zh")
        placeholder = db.message_ui_list(self.chat["id"])["msgs"][-1]
        self.assertTrue(db.message_is_voice(placeholder["id"]))

    def test_send_from_a_stale_page_does_not_touch_another_chat(self):
        async def no_reply(*a, **k):
            return None
        original = main._run_ai_reply
        main._run_ai_reply = no_reply
        try:
            self.client.post("/api/send", json={"text": "hi", "chat_id": "elsewhere", "voice": True})
        finally:
            main._run_ai_reply = original
        self.assertFalse(db.chat_voice_mode(self.chat["id"]))

    # ------------------------------------------------------------ 提示

    def test_auto_adds_nothing(self):
        self._reply()
        flat = json.dumps(self.sent[0], ensure_ascii=False)
        self.assertNotIn("来自系统提示", flat)
        self.assertNotIn("From the system prompt", flat)

    def test_tail_comes_last_in_its_own_language(self):
        db.chat_reply_language_set(self.chat["id"], "en")
        self.replies = ["You poor thing."]
        self._reply()
        self.assertEqual(self._tail(), "[From the system prompt] Please reply in English.")
        db.chat_reply_language_set(self.chat["id"], "zh")
        db.message_add(self.chat["id"], "user", "再说一次")
        self.replies = ["辛苦了。"]
        self._reply()
        self.assertEqual(self._tail(1), "【来自系统提示】请用中文回复。")

    def test_voice_wins_over_the_chosen_language(self):
        db.chat_reply_language_set(self.chat["id"], "zh")
        self.replies = ["Come here, let me hug you."]
        message = self._reply(voice=True)
        self.assertEqual(len(self.sent), 1, "语音那轮不该因为不是中文被打回")
        self.assertEqual(self._tail(), main.VOICE_REPLY_PROMPT)
        self.assertNotIn("来自系统提示", json.dumps(self.sent[0], ensure_ascii=False))
        self.assertEqual(self.kwargs[0]["agent_require_language"], "")
        self.assertEqual(message["content"], "Come here, let me hug you.")

    # ------------------------------------------------------------ 打回

    def test_wrong_language_is_sent_back_and_only_the_redo_is_kept(self):
        db.chat_reply_language_set(self.chat["id"], "en")
        self.replies = ["辛苦啦，抱抱。", "Aw, come here. Long day?"]
        message = self._reply()
        self.assertEqual(len(self.sent), 2)
        retry = self.sent[1]
        self.assertEqual(retry[-2], {"role": "assistant", "content": "辛苦啦，抱抱。"})
        self.assertEqual(retry[-1]["content"], main.REPLY_LANGUAGE_RETRY["en"])
        self.assertEqual(message["content"], "Aw, come here. Long day?")
        self.assertIn("打回重说：回复不是英文", message.get("thinking") or "")

    def test_it_gives_up_after_two_redos(self):
        db.chat_reply_language_set(self.chat["id"], "zh")
        self.replies = ["One.", "Two.", "Three.", "Four."]
        message = self._reply()
        self.assertEqual(len(self.sent), 1 + main.REPLY_LANGUAGE_MAX_RETRIES)
        self.assertEqual(message["content"], "Three.")

    def test_agent_sdk_leaves_the_check_to_the_bridge(self):
        self.provider_type = "claude_agent_sdk"
        db.chat_reply_language_set(self.chat["id"], "zh")
        self.replies = ["Not Chinese."]
        self._reply()
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.kwargs[0]["agent_require_language"], "zh")
        tail = self.sent[0][-1]
        self.assertEqual(tail["content"], "【来自系统提示】请用中文回复。")
        self.assertTrue(tail.get(agent_sdk_client.PROMPT_TAIL_KEY))


class BridgePayloadTest(unittest.TestCase):
    def test_payload_carries_the_language(self):
        messages = [{"role": "user", "content": "hi"}]
        self.assertEqual(agent_sdk_client.build_bridge_payload("sonnet", messages, require_language="en")
                         ["require_language"], "en")
        self.assertNotIn("require_language", agent_sdk_client.build_bridge_payload("sonnet", messages))

    def test_bridge_hook_checks_the_language_and_voice_wins(self):
        self.assertIn('const requireLanguage = requireEnglish ? "" : String(request.require_language || "");', BRIDGE)
        self.assertIn("} else if (checkLanguage && !replyLanguageOk(text, requireLanguage)) {", BRIDGE)


class LanguageFrontendTest(unittest.TestCase):
    def test_switch_is_the_last_row_of_the_plus_sheet(self):
        sheet = HTML[HTML.index('<div class="sheetWrap" id="addSheet">'):]
        sheet = sheet[:sheet.index('<input type="file" id="fCamera"')]
        self.assertGreater(sheet.index('id="langRow"'), sheet.index('id="fileBtn"'))
        for label in ('回复语言', '>自动<', '>中文<', '>English<'):
            self.assertIn(label, sheet)

    def test_send_carries_the_switches_of_the_chat_they_belong_to(self):
        self.assertIn("Object.assign(payload, { chat_id: switchesChatId, voice: voiceMode, reply_language: replyLanguage });", HTML)
        # 换窗口时跟着重读，不然发出去的是上一间的开关。
        self.assertIn("if (typeof loadChatSwitches === 'function') loadChatSwitches();", HTML)

    def test_voice_toggle_says_what_happened(self):
        self.assertIn("note(next ? '语音回复已开启，接下来会用英文语音回你' : '语音回复已关闭');", HTML)


if __name__ == "__main__":
    unittest.main()
