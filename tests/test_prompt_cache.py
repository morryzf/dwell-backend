import os
from pathlib import Path
import unittest
import uuid

from app import db


class ProviderPromptCacheDatabaseTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"provider-cache-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            path = self.path + suffix
            if os.path.exists(path):
                os.remove(path)

    def test_existing_provider_defaults_remain_generic_and_uncached(self):
        saved = db.provider_upsert(
            "", "Existing relay", "https://relay.example/v1", "encrypted", True
        )

        self.assertEqual(saved["provider_type"], "generic")
        self.assertEqual(saved["prompt_cache_ttl"], "off")

    def test_openrouter_cache_settings_round_trip_through_public_list(self):
        saved = db.provider_upsert(
            "", "OpenRouter", "https://openrouter.ai/api/v1", "encrypted", True,
            provider_type="openrouter", prompt_cache_ttl="1h",
        )
        public = next(item for item in db.provider_list() if item["id"] == saved["id"])

        self.assertEqual(public["provider_type"], "openrouter")
        self.assertEqual(public["prompt_cache_ttl"], "1h")
        self.assertTrue(public["has_key"])

    def test_generic_provider_cannot_retain_a_cache_ttl(self):
        saved = db.provider_upsert(
            "", "Relay", "https://relay.example/v1", "encrypted", True,
            provider_type="generic", prompt_cache_ttl="1h",
        )

        self.assertEqual(saved["prompt_cache_ttl"], "off")

    def test_claude_compatible_relay_retains_cache_ttl(self):
        saved = db.provider_upsert(
            "", "Claude relay", "https://relay.example/v1", "encrypted", True,
            provider_type="claude_compatible", prompt_cache_ttl="1h",
        )

        self.assertEqual(saved["provider_type"], "claude_compatible")
        self.assertEqual(saved["prompt_cache_ttl"], "1h")

    def test_chat_cache_ttl_round_trips_independently(self):
        first = db.chat_add("First")
        second = db.chat_add("Second")

        db.chat_model_set(first["id"], prompt_cache_ttl="1h")
        db.chat_model_set(second["id"], prompt_cache_ttl="5m")

        self.assertEqual(db.chat_model_get(first["id"])["prompt_cache_ttl"], "1h")
        self.assertEqual(db.chat_model_get(second["id"])["prompt_cache_ttl"], "5m")


class PromptCacheIntegrationSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).parents[1]
        cls.main = (root / "app" / "main.py").read_text(encoding="utf-8")
        cls.ui = (root / "static" / "index.html").read_text(encoding="utf-8")

    def test_ordinary_chat_places_transient_context_after_stable_history(self):
        self.assertIn("def _cache_friendly_chat_messages(", self.main)
        self.assertIn("return stable + history[:-1] + [current]", self.main)
        self.assertIn(
            "transient_messages = private_message + memory_card_message + device_message",
            self.main,
        )
        self.assertIn('session_id=f"dwell-chat:{chat_id}" if cache_friendly else None', self.main)

    def test_provider_ui_exposes_explicit_openrouter_cache_controls(self):
        self.assertIn('id="apProviderType"', self.ui)
        self.assertIn('id="apCacheTtl"', self.ui)
        self.assertIn('value="5m">5 分钟（推荐）', self.ui)
        self.assertIn('value="claude_compatible">Claude 缓存中转', self.ui)
        self.assertIn("https://openrouter.ai/api/v1", self.ui)

    def test_chat_cache_ttl_is_exposed_and_applied_to_both_request_paths(self):
        self.assertIn('"prompt_cache_ttl": _chat_prompt_cache_ttl(selection, provider)', self.main)
        self.assertEqual(self.main.count("_chat_cache_provider(provider, selection)"), 2)
        self.assertIn("prompt_cache_ttl=prompt_cache_ttl", self.main)
        self.assertIn("function renderPromptCachePicker()", self.ui)
        self.assertIn("function setChatPromptCacheTtl(ttl, button)", self.ui)
        self.assertIn("{id: '5m', name: '5 分钟'}", self.ui)
        self.assertIn("{id: '1h', name: '1 小时'}", self.ui)
        self.assertIn('"cache_write_tokens"', self.main)
        self.assertIn("缓存写入", self.ui)
        self.assertIn("缓存读取", self.ui)


if __name__ == "__main__":
    unittest.main()
