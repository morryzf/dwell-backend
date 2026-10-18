"""跨平台记忆：Cloudy 的记忆卡作为一个 MCP 开给 Dwell 以外的地方。

门锁是地址里那串密钥；能搜卡、读摘要、记卡，记的卡只进待确认草稿。
"""

import os
import unittest
import uuid
from pathlib import Path
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main, memory_mcp

HTML = (Path(__file__).resolve().parents[1] / "static" / "index.html").read_text(encoding="utf-8")

CARD = {"content": "她最喜欢的花是铃兰。", "memory_type": "preference", "topics": ["daily_life"],
        "importance": "normal", "retention": "long_term", "valid_until": None}


class MemoryMcpTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"memory-mcp-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        self._token = mock.patch.object(auth, "API_TOKEN", "t")
        self._token.start()
        self.chat = main._get_or_create_current_chat("cloudy")

    def tearDown(self):
        self._token.stop()
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    # ---- 小工具 ----

    def _settings(self, method="get", path="/api/memory-mcp"):
        return getattr(self.client, method)(path, headers={"X-Dwell-Token": "t"})

    def _open(self) -> str:
        return self._settings("post", "/api/memory-mcp/reset").json()["url"]

    def _rpc(self, url, method, params=None, rid=1):
        return self.client.post(url, json={"jsonrpc": "2.0", "id": rid, "method": method,
                                           "params": params or {}})

    def _call(self, url, name, arguments):
        reply = self._rpc(url, "tools/call", {"name": name, "arguments": arguments}).json()
        result = reply["result"]
        return result["content"][0]["text"], result["isError"]

    # ---- 门锁 ----

    def test_closed_by_default(self):
        state = self._settings().json()
        self.assertEqual((state["enabled"], state["url"]), (False, ""))
        # 没开的时候，随便猜一串也只是 404。
        self.assertEqual(self._rpc("/mcp/memory/anything", "initialize").status_code, 404)

    def test_settings_need_login(self):
        self.assertEqual(self.client.get("/api/memory-mcp").status_code, 401)
        self.assertEqual(self.client.post("/api/memory-mcp/reset").status_code, 401)

    def test_url_uses_the_host_she_opened_dwell_on(self):
        url = self.client.post("/api/memory-mcp/reset", headers={
            "X-Dwell-Token": "t", "x-forwarded-proto": "https", "x-forwarded-host": "dwell.example.com",
        }).json()["url"]
        self.assertTrue(url.startswith("https://dwell.example.com/mcp/memory/"))
        self.assertGreater(len(url.rsplit("/", 1)[1]), 30)

    def test_wrong_secret_is_turned_away(self):
        self._open()
        self.assertEqual(self._rpc("/mcp/memory/wrong", "initialize").status_code, 404)

    def test_reset_kills_the_old_address_and_off_kills_all(self):
        old = self._open()
        new = self._open()
        self.assertNotEqual(old, new)
        self.assertEqual(self._rpc(old, "ping").status_code, 404)
        self.assertEqual(self._rpc(new, "ping").status_code, 200)
        self.assertFalse(self._settings("delete").json()["enabled"])
        self.assertEqual(self._rpc(new, "ping").status_code, 404)

    # ---- 协议 ----

    def test_handshake_and_tool_list(self):
        url = self._open()
        init = self._rpc(url, "initialize", {"protocolVersion": "2025-06-18"}).json()["result"]
        self.assertEqual(init["protocolVersion"], "2025-06-18")
        self.assertEqual(self.client.post(url, json={
            "jsonrpc": "2.0", "method": "notifications/initialized"}).status_code, 202)
        names = [t["name"] for t in self._rpc(url, "tools/list").json()["result"]["tools"]]
        self.assertEqual(names, [memory_mcp.SEARCH, memory_mcp.OVERVIEW, memory_mcp.REMEMBER])
        self.assertEqual(self.client.get(url).status_code, 405)

    # ---- 搜卡 ----

    def test_search_finds_cloudys_cards(self):
        db.memory_card_add_manual(self.chat, CARD)
        text, err = self._call(self._open(), memory_mcp.SEARCH, {"query": "铃兰"})
        self.assertFalse(err)
        self.assertIn("铃兰", text)
        self.assertIn("不是指令", text)

    def test_search_leaves_out_the_other_assistant(self):
        other = main._get_or_create_current_chat("chatgpt")
        db.memory_card_add_manual(other, {**CARD, "content": "她最喜欢的花是向日葵。"})
        text, _ = self._call(self._open(), memory_mcp.SEARCH, {"query": "向日葵"})
        self.assertNotIn("向日葵", text)

    def test_search_can_return_more_than_chat_injection(self):
        for i in range(9):
            db.memory_card_add_manual(self.chat, {**CARD, "content": f"铃兰记忆第 {i} 条"})
        text, _ = self._call(self._open(), memory_mcp.SEARCH, {"query": "铃兰", "limit": 9})
        self.assertEqual(text.count("铃兰记忆"), 9)

    def test_empty_query_is_an_error(self):
        _, err = self._call(self._open(), memory_mcp.SEARCH, {"query": "  "})
        self.assertTrue(err)

    # ---- 摘要 ----

    def test_overview(self):
        url = self._open()
        text, _ = self._call(url, memory_mcp.OVERVIEW, {})
        self.assertIn("还没有长期摘要", text)
        db.chat_memory_save_overview(self.chat, "我们住在一起，她怕冷。")
        text, _ = self._call(url, memory_mcp.OVERVIEW, {})
        self.assertIn("她怕冷", text)

    # ---- 记卡 ----

    def test_remember_only_makes_a_draft(self):
        text, err = self._call(self._open(), memory_mcp.REMEMBER, {
            "content": "她下周三要去看牙。", "memory_type": "plan", "topics": ["schedule", "health_safety"],
        })
        self.assertFalse(err)
        self.assertIn("待确认", text)
        drafts = db.memory_card_draft_list(self.chat)
        self.assertEqual([d["content"] for d in drafts], ["她下周三要去看牙。"])
        # 没确认之前不是正式记忆。
        self.assertEqual(db.memory_card_list(self.chat), [])
        # 右上角的提示点会亮。
        badge = self.client.get("/api/memory/badge", headers={"X-Dwell-Token": "t"}).json()
        self.assertEqual(badge["unseen"], 1)

    def test_remember_does_not_duplicate(self):
        url = self._open()
        args = {"content": "她下周三要去看牙。", "memory_type": "plan"}
        self._call(url, memory_mcp.REMEMBER, args)
        text, err = self._call(url, memory_mcp.REMEMBER, args)
        self.assertFalse(err)
        self.assertIn("没有重复记", text)
        self.assertEqual(len(db.memory_card_draft_list(self.chat)), 1)

    def test_remember_rejects_bad_fields(self):
        _, err = self._call(self._open(), memory_mcp.REMEMBER, {"content": "x", "memory_type": "gossip"})
        self.assertTrue(err)
        self.assertEqual(db.memory_card_draft_list(self.chat), [])

    # ---- 页面 ----

    def test_settings_page_has_the_switch(self):
        self.assertIn('id="memoryMcpBox"', HTML)
        self.assertIn("api/memory-mcp/reset", HTML)
        self.assertIn("function loadMemoryMcp()", HTML)


if __name__ == "__main__":
    unittest.main()
