"""走 Claude Agent SDK 时，家里的工具改由 Claude Code 通过 MCP 回调 Dwell。

模型跑在桥接那台机器上，Dwell 的 function tools 交不过去——之前接上 SDK 以后，
Cloudy 就再也碰不到待办、日记和日历了。
"""

import json
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import agent_sdk_client, db, home_mcp, main


def _rpc(method, params=None, rid=1):
    body = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        body["params"] = params
    return body


class HomeMcpTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"home-mcp-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat_id = main._get_or_create_current_chat()
        db.chat_home_todos_set(self.chat_id, True)
        self.client = TestClient(main.app)
        self.previous_env = os.environ.pop("DWELL_PUBLIC_URL", None)

    def tearDown(self):
        db.DB_PATH = self.previous_path
        if self.previous_env is not None:
            os.environ["DWELL_PUBLIC_URL"] = self.previous_env
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _post(self, body, grant):
        return self.client.post(
            home_mcp.ENDPOINT_PATH, json=body,
            headers={"Authorization": f"Bearer {grant}"},
        )

    def _call(self, grant, name, arguments):
        resp = self._post(_rpc("tools/call", {"name": name, "arguments": arguments}), grant)
        self.assertEqual(resp.status_code, 200)
        return resp.json()["result"]

    def test_rejects_requests_without_a_valid_grant(self):
        resp = self.client.post(home_mcp.ENDPOINT_PATH, json=_rpc("tools/list"))
        self.assertEqual(resp.status_code, 401)
        resp = self._post(_rpc("tools/list"), "forged")
        self.assertEqual(resp.status_code, 401)

    def test_handshake_and_tool_list(self):
        grant = home_mcp.make_grant(self.chat_id)
        init = self._post(_rpc("initialize", {"protocolVersion": "2025-06-18"}), grant).json()
        self.assertEqual(init["result"]["protocolVersion"], "2025-06-18")
        self.assertIn("tools", init["result"]["capabilities"])

        note = self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, grant)
        self.assertEqual(note.status_code, 202)

        tools = self._post(_rpc("tools/list"), grant).json()["result"]["tools"]
        names = {tool["name"] for tool in tools}
        for name in ("DwellCalendarAdd", "DwellTodoAdd", "DwellDiaryAdd", "DwellCalendarList"):
            self.assertIn(name, names)
        self.assertTrue(all("inputSchema" in tool for tool in tools))

    def test_calendar_todo_and_diary_round_trip(self):
        grant = home_mcp.make_grant(self.chat_id)

        added = self._call(grant, "DwellCalendarAdd", {"date": "2026-10-05", "text": "去看海"})
        self.assertFalse(added["isError"])
        listed = json.loads(self._call(grant, "DwellCalendarList", {"date": "2026-10-05"})["content"][0]["text"])
        self.assertEqual([event["text"] for event in listed["events"]], ["去看海"])

        self._call(grant, "DwellTodoAdd", {"list": "mine", "text": "订餐厅"})
        self.assertIn("订餐厅", [item["text"] for item in db.todos_all()["mine"]])

        self._call(grant, "DwellDiaryAdd", {"diary": "cloudy", "text": "今天她笑了好几次"})
        self.assertTrue(any("她笑了" in json.dumps(item, ensure_ascii=False)
                            for item in db.diary_list(lite=True, limit=5)))

    def test_bad_arguments_come_back_as_tool_errors(self):
        grant = home_mcp.make_grant(self.chat_id)
        result = self._call(grant, "DwellTodoAdd", {"list": "nobody", "text": "x"})
        self.assertTrue(result["isError"])

    def test_calls_are_recorded_under_the_reply(self):
        reply = db.message_add(self.chat_id, "assistant", "")
        grant = home_mcp.make_grant(self.chat_id, reply["id"])
        self._call(grant, "DwellTodoList", {})
        with db.conn() as cx:
            rows = cx.execute(
                "SELECT name FROM tool_calls WHERE assistant_message_id=?", (reply["id"],)
            ).fetchall()
        self.assertEqual([row["name"] for row in rows], ["DwellTodoList"])

    def test_read_only_grant_cannot_write(self):
        grant = home_mcp.make_grant(self.chat_id, read_only=True)
        names = {tool["name"] for tool in self._post(_rpc("tools/list"), grant).json()["result"]["tools"]}
        self.assertIn("DwellCalendarList", names)
        self.assertNotIn("DwellCalendarAdd", names)
        result = self._call(grant, "DwellCalendarAdd", {"date": "2026-10-05", "text": "x"})
        self.assertTrue(result["isError"])
        self.assertEqual(db.cal_events_on("2026-10-05"), [])

    def test_turning_home_tools_off_closes_the_door(self):
        grant = home_mcp.make_grant(self.chat_id)
        db.chat_home_todos_set(self.chat_id, False)
        tools = self._post(_rpc("tools/list"), grant).json()["result"]["tools"]
        self.assertEqual(tools, [])

    def test_agent_sdk_chat_gets_the_server_config(self):
        os.environ["DWELL_PUBLIC_URL"] = "https://dwell.example.com/"
        sdk = {"provider_type": "claude_agent_sdk"}
        config = main._agent_home_mcp(sdk, self.chat_id, "m1")
        self.assertEqual(config["dwell"]["type"], "http")
        self.assertEqual(config["dwell"]["url"], "https://dwell.example.com/mcp/home")
        grant = home_mcp.bearer(config["dwell"]["headers"]["Authorization"])
        self.assertEqual(home_mcp.read_grant(grant)["message_id"], "m1")

        self.assertIsNone(main._agent_home_mcp({"provider_type": "openai"}, self.chat_id))
        db.chat_home_todos_set(self.chat_id, False)
        self.assertIsNone(main._agent_home_mcp(sdk, self.chat_id))

    def test_public_url_is_learned_from_logged_in_requests_only(self):
        self.client.get("/api/health", headers={"host": "evil.example", "x-forwarded-proto": "https"})
        self.assertEqual(main._public_url(), "")


class BridgePayloadMcpTest(unittest.TestCase):
    def test_mcp_servers_ride_along_but_stay_out_of_the_prompt(self):
        servers = {"dwell": {"type": "http", "url": "https://d/mcp/home",
                             "headers": {"Authorization": "Bearer secret-grant"}}}
        payload = agent_sdk_client.build_bridge_payload(
            "sonnet", [{"role": "user", "content": "明天提醒我买花"}], mcp_servers=servers,
        )
        self.assertEqual(payload["mcp_servers"], servers)
        self.assertGreater(payload["max_turns"], 1)
        self.assertNotIn("secret-grant", payload["prompt"] + payload["system"])


if __name__ == "__main__":
    unittest.main()
