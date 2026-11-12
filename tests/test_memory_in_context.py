"""挑卡时的记号：走 Claude Code 的聊天里，这段会话递过的卡还在他上下文里。"""

import os
import unittest
import uuid
from unittest import mock

from fastapi.testclient import TestClient

from app import agent_sdk_client, auth, db, main


class MemoryInContextTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"in-context-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("c")["id"]
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _get(self, provider_type):
        with mock.patch.object(main.db, "chat_model_get", lambda chat_id: {"provider_id": "p", "model_id": "opus"}), \
                mock.patch.object(main.db, "provider_get", lambda pid: {"id": "p", "provider_type": provider_type}):
            return self.client.get(f"/api/chats/{self.chat}/memory-in-context").json()

    def test_claude_code_session_reports_what_it_has_seen(self):
        agent_sdk_client.save_state(f"dwell-chat:{self.chat}", "sess", "opus", "sys", [("Morry", "hi")],
                                    cards=agent_sdk_client.memory_pool_version(), seen_cards=["c1", "c2"])
        self.assertEqual(self._get("claude_agent_sdk"), {"ok": True, "tracked": True, "ids": ["c1", "c2"]})
        # 卡池动过：会话会重开，什么都不在了。
        db.memory_pool_touch()
        self.assertEqual(self._get("claude_agent_sdk")["ids"], [])

    def test_other_providers_keep_nothing(self):
        self.assertEqual(self._get("generic"), {"ok": True, "tracked": False, "ids": []})


if __name__ == "__main__":
    unittest.main()
