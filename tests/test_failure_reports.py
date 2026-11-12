"""出错时留下的现场：一句话的日志不够找问题，要有模型原样回了什么、坏在哪里、完整的调用栈。"""

import asyncio
import os
import time
import unittest
import uuid
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main


class FailureReportTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"failure-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("c")["id"]
        for i in range(4):
            db.message_add(self.chat, "user", f"第 {i} 句")
        self.segment = db.chat_memory_add_segment(self.chat, 1, 4, "")
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _error_logs(self):
        return self.client.get("/api/system-logs", params={"status": "error"}).json()["items"]

    def test_a_broken_reply_keeps_both_replies_and_where_they_broke(self):
        replies = iter(['{"bookmarks": [{"lines": [1], "label": "她说"好"了"}]}', "还是不对"])

        async def fake_completion(provider, model_id, system, user):
            return next(replies)

        with mock.patch.object(main, "_memory_completion", fake_completion), \
                mock.patch.object(main, "_memory_related_cards", mock.AsyncMock(return_value=[])):
            asyncio.run(main._stage_bookmark_suggestions(
                self.chat, {"id": "p", "name": "测试供应商", "enabled": 1}, "model-x", self.segment))

        log = self._error_logs()[0]
        self.assertEqual(log["action"], "bookmark_suggestion")
        self.assertTrue(log["report_id"])
        got = self.client.get(f"/api/failure-reports/{log['report_id']}").json()
        text = got["text"]
        self.assertIn("连续两次返回了无法读取的格式", text)
        self.assertIn('"label": "她说"好"了"', text)
        self.assertIn("⟦这里⟧", text)
        self.assertIn("还是不对", text)
        self.assertIn("model-x", text)
        self.assertIn("Traceback", text)
        facts = got["report"]["facts"]
        self.assertEqual(facts["first_error"]["line"], 1)

    def test_a_task_that_fails_outright_gets_a_report_too(self):
        log_id = main._start_system_log("memory_task", "summary_refresh", chat_id=self.chat)
        try:
            raise RuntimeError("Bearer sk-abcdefghijklmnopqrstu went wrong")
        except RuntimeError as exc:
            main._finish_system_log(log_id, "error", time.perf_counter(), detail=exc)
        log = next(item for item in self._error_logs() if item["id"] == log_id)
        report = self.client.get(f"/api/failure-reports/{log['report_id']}").json()
        self.assertIn("RuntimeError", report["text"])
        self.assertNotIn("sk-abcdefghijklmnopqrstu", report["report"]["traceback"])

    def test_only_the_latest_thirty_are_kept(self):
        ids = [db.failure_report_add({"task": str(i)}) for i in range(35)]
        self.assertIsNone(db.failure_report_get(ids[0]))
        self.assertIsNotNone(db.failure_report_get(ids[-1]))
        self.assertEqual(self.client.get(f"/api/failure-reports/{ids[0]}").status_code, 404)


if __name__ == "__main__":
    unittest.main()
