import asyncio
import os
from pathlib import Path
import unittest
import uuid

from app import db
from app import main


ROOT = Path(__file__).parents[1]
HTML = (ROOT / "static" / "index.html").read_text(encoding="utf-8")


class VoiceReplyFlowTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"voice-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("voice test")
        # 分条回复开着：空行本来会把回复拆成多个气泡。
        db.chat_split_replies_set(self.chat["id"], True)
        db.message_add(self.chat["id"], "user", "想你了")

        self.sent = []
        self.patched = {}

        async def fake_stream(provider, model_id, messages, *args, **kwargs):
            self.sent.append(messages)
            yield {"type": "text", "text": "Hi there.\n\nMissed you."}

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

    def tearDown(self):
        for name in ("stream_chat", "prompt_cache_enabled"):
            setattr(main, name, self.patched[name])
        main.db.chat_model_get = self.patched["chat_model_get"]
        main.db.provider_get = self.patched["provider_get"]
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _reply(self, voice: bool) -> dict:
        placeholder = db.message_add(self.chat["id"], "assistant", "")
        if voice:
            db.message_voice_set(placeholder["id"], True)
        asyncio.run(main._run_ai_reply(self.chat["id"], placeholder["id"]))
        return placeholder

    def _assistant_rows(self):
        return [m for m in db.message_ui_list(self.chat["id"])["msgs"] if m["kind"] == "gu" and m["text"]]

    def test_voice_reply_stays_one_message_and_gets_spoken_english_instruction(self):
        placeholder = self._reply(voice=True)
        rows = self._assistant_rows()
        self.assertEqual(len(rows), 1, "语音回复被拆成了多条")
        self.assertEqual(rows[0]["id"], placeholder["id"])
        self.assertTrue(rows[0]["voice"])
        system_text = "\n".join(m["content"] for m in self.sent[0] if m["role"] == "system")
        self.assertIn("只用英文说", system_text)
        events = main._event_log.get(self.chat["id"], [])
        self.assertTrue(any(
            e.get("subtype") == "voice_reply" and e.get("message_id") == placeholder["id"]
            for e in events
        ))

    def test_text_reply_is_unchanged(self):
        self._reply(voice=False)
        rows = self._assistant_rows()
        self.assertEqual(len(rows), 2, "普通回复的分条行为不该被语音功能改变")
        self.assertFalse(any(r["voice"] for r in rows))
        system_text = "\n".join(m["content"] for m in self.sent[0] if m["role"] == "system")
        self.assertNotIn("只用英文说", system_text)

    def test_voice_mode_is_per_chat(self):
        other = db.chat_add("another")
        db.chat_voice_mode_set(self.chat["id"], True)
        self.assertTrue(db.chat_voice_mode(self.chat["id"]))
        self.assertFalse(db.chat_voice_mode(other["id"]))

    def test_user_messages_never_report_voice(self):
        user = [m for m in db.message_ui_list(self.chat["id"])["msgs"] if m["kind"] == "me"]
        self.assertTrue(user)
        self.assertFalse(any(m["voice"] for m in user))


class VoiceBubbleFrontendTest(unittest.TestCase):
    def test_toggle_sits_in_the_composer(self):
        self.assertIn('id="voiceBtn"', HTML)
        self.assertIn("#reasoningBtn.on, #voiceBtn.on", HTML)

    def test_transcript_is_collapsed_by_default(self):
        self.assertIn("#log .row.voice-row:not(.vt-open) > .gu { display: none !important; }", HTML)

    def test_history_and_stream_both_render_voice_bubbles(self):
        self.assertIn("if (m.voice) voiceDecorate(el, m.id, 'ready');", HTML)
        self.assertIn("voiceDecorate(el, voiceNextId, 'pending')", HTML)

    def test_voice_replies_are_not_read_twice(self):
        self.assertIn("if (last && last.id && !last.voice) await playTts(last.id);", HTML)


if __name__ == "__main__":
    unittest.main()
