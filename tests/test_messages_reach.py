"""搜索里点开很早的一句：只拿它前后各 30 条，中间不拿；往下再一段段接到最新。"""

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

    def test_around_takes_only_the_neighbourhood_and_after_walks_down(self):
        target = self.msgs[50]
        page = self.client.get("/api/messages", params={"chat_id": self.chat, "around": target["id"]}).json()
        ids = [m["id"] for m in page["msgs"]]
        self.assertEqual(ids[0], self.msgs[20]["id"])
        self.assertEqual(ids[-1], self.msgs[80]["id"])
        self.assertTrue(page["more"])
        self.assertTrue(page["newer"])
        down = self.client.get("/api/messages", params={
            "chat_id": self.chat, "after": page["msgs"][-1]["seq"], "limit": 400}).json()
        self.assertEqual(down["msgs"][0]["id"], self.msgs[81]["id"])
        self.assertEqual(down["msgs"][-1]["id"], self.msgs[399]["id"])
        self.assertFalse(down["newer"])


if __name__ == "__main__":
    unittest.main()
