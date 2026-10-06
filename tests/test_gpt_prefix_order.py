"""GPT 这类自己按「开头相同」缓存的模型：每轮都变的东西（设备时间、今日提醒……）
排到最后，稳定的人设和聊天记录在前，开头才能一轮轮对得上。不加 Claude 的缓存标记。"""

import asyncio
import json
import os
import unittest
import uuid

from app import db, main
from app.llm_client import build_chat_payload


class GptPrefixOrderTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"gpt-order-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("gpt", "chatgpt")
        db.message_add(self.chat["id"], "user", "在吗")
        db.message_add(self.chat["id"], "assistant", "在")
        db.message_add(self.chat["id"], "user", "今天好累")
        self.sent = []
        self.patched = {"stream_chat": main.stream_chat,
                        "chat_model_get": main.db.chat_model_get,
                        "provider_get": main.db.provider_get}
        self.model = "openai/gpt-5.6-sol"

        async def fake_stream(provider, model_id, messages, *args, **kwargs):
            self.sent.append((provider, messages, kwargs))
            yield {"type": "text", "text": "抱抱"}

        main.stream_chat = fake_stream
        main.db.chat_model_get = lambda chat_id: {
            "provider_id": "p", "model_id": self.model, "show_thinking": 1,
            "reasoning_effort": "", "prompt_cache_ttl": "5m",
        }
        main.db.provider_get = lambda pid: {
            "id": "p", "name": "or", "enabled": 1, "provider_type": "openrouter",
            "base_url": "https://openrouter.ai/api/v1", "api_key_box": "", "prompt_cache_ttl": "off",
        }

    def tearDown(self):
        main.stream_chat = self.patched["stream_chat"]
        main.db.chat_model_get = self.patched["chat_model_get"]
        main.db.provider_get = self.patched["provider_get"]
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _reply(self, local):
        placeholder = db.message_add(self.chat["id"], "assistant", "")
        asyncio.run(main._run_ai_reply(
            self.chat["id"], placeholder["id"],
            device_time={"local": local, "iso": "", "time_zone": "Asia/Shanghai"},
        ))
        return self.sent[-1]

    def test_device_time_moves_behind_the_history(self):
        provider, messages, kwargs = self._reply("2026-10-07 01:21")
        text = json.dumps(messages, ensure_ascii=False)
        self.assertNotIn("设备时间", json.dumps(messages[0], ensure_ascii=False))
        self.assertLess(text.index("在吗"), text.index("2026-10-07 01:21"))
        # 仍然告诉模型现在几点，只是挪到了这一轮的最后
        self.assertIn("2026-10-07 01:21", json.dumps(messages[-1], ensure_ascii=False))

    def test_two_turns_share_the_same_opening(self):
        _, first, _ = self._reply("2026-10-07 01:21")
        db.message_add(self.chat["id"], "user", "嗯")
        _, second, _ = self._reply("2026-10-07 01:25")
        shared = first[:-1]
        self.assertEqual(second[:len(shared)], shared)

    def test_no_claude_cache_marker_is_added(self):
        provider, messages, kwargs = self._reply("2026-10-07 01:21")
        self.assertEqual(provider["prompt_cache_ttl"], "off")
        payload = build_chat_payload(self.model, messages, provider=provider,
                                     session_id=kwargs.get("session_id"))
        self.assertNotIn("cache_control", json.dumps(payload))
        self.assertNotIn("session_id", payload)

    def test_which_models_count_as_auto_cached(self):
        relay = {"provider_type": "generic"}
        for model in ("gpt-5.6-sol", "[J3按量]gpt-5.6-sol", "openai/gpt-4o", "o3-mini"):
            self.assertTrue(main._auto_prefix_cache(relay, model), model)
        for model in ("claude-opus-4-6", "gemini-2.5-pro", "deepseek-chat"):
            self.assertFalse(main._auto_prefix_cache(relay, model), model)
        self.assertFalse(main._auto_prefix_cache({"provider_type": "claude_agent_sdk"}, "gpt-5"))


if __name__ == "__main__":
    unittest.main()
