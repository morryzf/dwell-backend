"""搜索里点开很早的一句：一次拿到那句为止，不用一页页往上翻（以前翻 15 页就停了）。"""

import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main


class MessagesReachTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"reach-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("reach")["id"]
        self.msgs = [db.message_add(self.chat, "user", f"第 {i} 句") for i in range(400)]
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def test_one_request_reaches_the_old_message_with_some_lead_in(self):
        oldest_loaded = self.client.get("/api/messages", params={"chat_id": self.chat, "limit": 100}).json()["msgs"][0]
        target = self.msgs[50]
        page = self.client.get("/api/messages", params={
            "chat_id": self.chat, "limit": 100, "before": oldest_loaded["seq"], "reach": target["id"],
        }).json()
        ids = [m["id"] for m in page["msgs"]]
        self.assertIn(target["id"], ids)
        self.assertEqual(ids[-1], self.msgs[299]["id"])
        self.assertEqual(ids[0], self.msgs[20]["id"])
        self.assertTrue(page["more"])


if __name__ == "__main__":
    unittest.main()
