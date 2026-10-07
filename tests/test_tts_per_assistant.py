"""两位助手各用各的音色和朗读方式；ElevenLabs 连接和音色库共用。"""

import json
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main

LIBRARY = [
    {"id": "voice-a", "name": "睡前声音", "voice_id": "adam", "provider_name": "Adam"},
    {"id": "voice-b", "name": "早安", "voice_id": "rachel", "provider_name": "Rachel",
     "preview_url": "https://example.com/rachel.mp3"},
]


class TtsPerAssistantTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"tts-assistant-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        # 改版前存下的样子：只有顶层字段
        db.setting_set(main.TTS_CONFIG_KEY, json.dumps({
            "voices": LIBRARY, "active_voice_id": "voice-a", "model_id": "eleven_v3",
            "model_name": "Eleven v3", "auto_play": True, "read_mode": "plain_and_italic",
        }, ensure_ascii=False))
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def test_cloudy_keeps_what_was_saved_before(self):
        cfg = main._tts_config("cloudy")
        self.assertEqual((cfg["voice_id"], cfg["model_id"], cfg["read_mode"], cfg["auto_play"]),
                         ("adam", "eleven_v3", "plain_and_italic", True))

    def test_chatgpt_starts_with_cloudys_settings_but_no_voice(self):
        cfg = main._tts_config("chatgpt")
        self.assertEqual(cfg["voice_id"], "")
        self.assertEqual((cfg["model_id"], cfg["read_mode"]), ("eleven_v3", "plain_and_italic"))

    def test_choices_are_saved_separately(self):
        self.client.post("/api/tts/config", json={
            "assistant": "chatgpt", "active_voice_id": "voice-b", "read_mode": "plain", "auto_play": False,
        })
        gpt, cloudy = main._tts_config("chatgpt"), main._tts_config("cloudy")
        self.assertEqual((gpt["voice_id"], gpt["read_mode"], gpt["auto_play"]), ("rachel", "plain", False))
        self.assertEqual((cloudy["voice_id"], cloudy["read_mode"], cloudy["auto_play"]), ("adam", "plain_and_italic", True))
        public = self.client.get("/api/tts/config?assistant=cloudy").json()
        self.assertEqual(public["profiles"]["chatgpt"]["active_voice_id"], "voice-b")
        self.assertEqual(public["active_voice_id"], "voice-a")

    def test_library_is_shared_and_keeps_preview(self):
        self.client.post("/api/tts/config", json={"assistant": "chatgpt", "voices": LIBRARY[1:]})
        cloudy = main._tts_config("cloudy")
        self.assertEqual([v["id"] for v in cloudy["voices"]], ["voice-b"])
        self.assertEqual(cloudy["voices"][0]["preview_url"], "https://example.com/rachel.mp3")
        # Cloudy 原来那个被删了，就退回音色库第一个
        self.assertEqual(cloudy["voice_id"], "rachel")

    def test_playback_uses_the_voice_of_the_chats_assistant(self):
        self.client.post("/api/tts/config", json={"assistant": "chatgpt", "active_voice_id": "voice-b"})
        gpt_chat = db.chat_add("g", "chatgpt")
        db.chat_switch(gpt_chat["id"])
        reply = db.message_add(gpt_chat["id"], "assistant", "早上好")
        cfg = main._tts_config(db.chat_assistant(main._get_or_create_current_chat()))
        details = main._tts_message_cache_details(gpt_chat["id"], reply["id"], cfg)
        self.assertEqual(cfg["voice_id"], "rachel")
        self.assertEqual(details["spoken"], "早上好")


if __name__ == "__main__":
    unittest.main()
