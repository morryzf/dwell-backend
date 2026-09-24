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


class VoiceCacheDirTest(unittest.TestCase):
    """语音缓存目录搬家回归。

    Zeabur 时代跑在 Docker 里，/data 是挂载卷；搬到普通服务器上
    以后没有这个卷，服务又不是 root 跑的，往根目录底下建文件夹会被拒。
    合成完的音频落不下盘，前端只能显示一句什么都没说的「语音没能生成」。
    """

    SOURCE = (ROOT / "app" / "main.py").read_text(encoding="utf-8")

    def test_default_cache_dir_follows_the_repo(self):
        self.assertIn(
            'os.environ.get("DWELL_TTS_CACHE_DIR", "./data/tts-cache")',
            self.SOURCE,
            "语音缓存目录的默认值必须是相对路径，"
            "和 DWELL_DB 一样跟着仓库走，不能再指根目录底下的 /data",
        )

    def test_unwritable_cache_dir_says_where_it_failed(self):
        import tempfile

        blocker = tempfile.NamedTemporaryFile(delete=False)
        blocker.close()
        # 把缓存目录指到一个普通文件底下：mkdir 必失败，跟权限不够一个性质。
        doomed = Path(blocker.name) / "tts-cache" / "m-abc.mp3"

        class FakeResponse:
            status_code = 200
            content = b"ID3fake-audio"

        class FakeClient:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return False

            async def post(self, *args, **kwargs):
                return FakeResponse()

        saved = {
            name: getattr(main, name)
            for name in ("_get_or_create_current_chat", "_tts_config",
                         "_tts_message_cache_details", "_tts_api_key")
        }
        saved_client = main.httpx.AsyncClient
        main._get_or_create_current_chat = lambda: "chat"
        main._tts_config = lambda: {
            "base_url": "https://api.elevenlabs.io", "voice_id": "v", "model_id": "m",
        }
        main._tts_message_cache_details = lambda *a, **k: {"spoken": "hi", "path": doomed}
        main._tts_api_key = lambda cfg: "key"
        main.httpx.AsyncClient = lambda *a, **k: FakeClient()
        try:
            with self.assertRaises(main.HTTPException) as caught:
                asyncio.run(main.tts_message_audio("m"))
        finally:
            for name, value in saved.items():
                setattr(main, name, value)
            main.httpx.AsyncClient = saved_client
            os.remove(blocker.name)

        self.assertEqual(caught.exception.status_code, 500)
        detail = str(caught.exception.detail)
        self.assertIn("DWELL_TTS_CACHE_DIR", detail, "得告诉人怎么改")
        self.assertIn(str(doomed.parent), detail, "得说清楚是哪个目录写不了")


class VoiceErrorMessageFrontendTest(unittest.TestCase):
    def test_bare_server_errors_carry_their_status_code(self):
        self.assertIn(
            "throw new Error(data.detail || ('语音没能生成（' + response.status + '）'));",
            HTML,
            "服务器没给 detail 时，至少要把状态码显给人看",
        )


if __name__ == "__main__":
    unittest.main()
