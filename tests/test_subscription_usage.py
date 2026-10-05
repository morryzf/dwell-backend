"""用量页的订阅额度：把桥接的回答整理成窗口；OpenRouter 不再只认当前聊天。"""

import os
import unittest
import uuid
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main, subscription_usage


PLAN = {
    "ok": True, "available": True, "subscription_type": "max", "fetched_at": 1791190000,
    "account": {"email": "m@example.com"},
    "rate_limits": {
        "five_hour": {"utilization": 5, "resets_at": "2026-10-05T13:30:00Z"},
        "seven_day": {"utilization": 44, "resets_at": "2026-10-06T14:59:00Z"},
        "seven_day_opus": {"utilization": None, "resets_at": None},
        "model_scoped": [{"display_name": "Fable", "utilization": 12.5, "resets_at": "2026-10-06T14:59:00Z"}],
        "extra_usage": {"is_enabled": True, "monthly_limit": 50, "used_credits": 3.2, "utilization": 6.4},
    },
    "observed": {"five_hour": {"utilization": 0.9, "resets_at": 1791200000, "observed_at": 1791100000}},
}


class SummarizeTest(unittest.TestCase):
    def test_plan_windows_in_page_order_with_reset_times(self):
        data = subscription_usage.summarize(PLAN)
        self.assertEqual(data["source"], "plan")
        self.assertEqual(data["plan"], "max")
        self.assertEqual(data["email"], "m@example.com")
        labels = [(w["group"], w["label"], w["used"]) for w in data["windows"]]
        self.assertEqual(labels, [
            ("session", "Current session", 5.0),
            ("weekly", "All models", 44.0),
            ("weekly", "Fable", 12.5),
            ("extra", "Extra usage", 6.4),
        ])
        self.assertEqual(data["windows"][0]["resets_at"], 1791207000)
        self.assertEqual(data["error"], "")

    def test_falls_back_to_what_the_last_chat_reported(self):
        body = {**PLAN, "available": False, "rate_limits": None, "error": "没有权限"}
        data = subscription_usage.summarize(body)
        self.assertEqual(data["source"], "observed")
        window = data["windows"][0]
        # 聊天时报来的是 0–1 的比例。
        self.assertEqual((window["label"], window["used"]), ("Current session", 90.0))
        self.assertEqual(window["observed_at"], 1791100000)
        self.assertEqual(data["error"], "没有权限")

    def test_nothing_at_all(self):
        data = subscription_usage.summarize({"available": False, "observed": {}, "error": "x"})
        self.assertEqual((data["source"], data["windows"]), ("", []))


class UsageEndpointTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"usage-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        self.client.headers["X-Dwell-Token"] = "t"
        self._token = mock.patch.object(auth, "API_TOKEN", "t")
        self._token.start()
        self.chat = main._get_or_create_current_chat()

    def tearDown(self):
        self._token.stop()
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def test_subscription_needs_a_bridge_provider(self):
        response = self.client.get("/api/subscription/usage")
        self.assertEqual(response.status_code, 409)

    def test_subscription_works_whatever_the_chat_is_using(self):
        db.provider_upsert("", "OR", "https://openrouter.ai/api/v1", "", provider_type="openrouter")
        sdk = db.provider_upsert("", "Claude Code", "http://127.0.0.1:8787", "", provider_type="claude_agent_sdk")
        seen = {}

        async def fake_fetch(provider, refresh=False):
            seen["provider"], seen["refresh"] = provider["id"], refresh
            return subscription_usage.summarize(PLAN)

        with mock.patch.object(subscription_usage, "fetch", fake_fetch):
            data = self.client.get("/api/subscription/usage", params={"refresh": "true"}).json()
        self.assertEqual(seen, {"provider": sdk["id"], "refresh": True})
        self.assertEqual(data["windows"][1]["label"], "All models")

    def test_bridge_errors_become_a_readable_502(self):
        db.provider_upsert("", "Claude Code", "http://127.0.0.1:8787", "", provider_type="claude_agent_sdk")

        async def broken(provider, refresh=False):
            raise RuntimeError("桥接服务还是旧版本，没有用量接口；在 VPS 上跑一次 deploy.sh")

        with mock.patch.object(subscription_usage, "fetch", broken):
            response = self.client.get("/api/subscription/usage")
        self.assertEqual(response.status_code, 502)
        self.assertIn("deploy.sh", response.json()["detail"])

    def test_openrouter_is_found_even_when_the_chat_uses_something_else(self):
        sdk = db.provider_upsert("", "Claude Code", "http://127.0.0.1:8787", "", provider_type="claude_agent_sdk")
        router = db.provider_upsert("", "OR", "https://openrouter.ai/api/v1", "", provider_type="openrouter")
        db.chat_model_set(self.chat, sdk["id"], "sonnet")   # 当前聊天用的是 Claude Code
        self.assertEqual(main._usage_provider("openrouter")["id"], router["id"])
        self.assertEqual(main._usage_provider("claude_agent_sdk")["id"], sdk["id"])


if __name__ == "__main__":
    unittest.main()
