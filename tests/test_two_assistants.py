"""家里住着两个助手：Cloudy 和 ChatGPT。

功能大多两边都有，但写下的东西各归各的：聊天、记忆、他自己那栏待办、心跳。
「你的」待办和日历两边共用。Journal（日记、收藏、悄悄话）只有 Cloudy 有。
"""

import asyncio
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main


class TwoAssistantsTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"two-assistants-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _switch(self, assistant):
        response = self.client.post("/api/assistant", json={"assistant": assistant})
        self.assertEqual(response.status_code, 200)
        return response.json()

    # ------------------------------------------------------------ 聊天

    def test_existing_chats_belong_to_cloudy(self):
        with db.conn() as cx:
            cx.execute("INSERT INTO chats(id,name,made) VALUES ('old','以前的',0)")
        self.assertEqual(db.chat_assistant("old"), "cloudy")
        self.assertEqual(db.current_assistant(), "cloudy")

    def test_each_assistant_lists_only_its_own_chats(self):
        cloudy = db.chat_add("和 Cloudy", "cloudy")
        chatgpt = db.chat_add("和 ChatGPT", "chatgpt")

        names = lambda a: [c["name"] for c in self.client.get(f"/api/chats?assistant={a}").json()["items"]]
        self.assertEqual(names("cloudy"), ["和 Cloudy"])
        self.assertEqual(names("chatgpt"), ["和 ChatGPT"])
        self.assertNotIn(chatgpt["id"], [c["id"] for c in db.chat_list("", "", "cloudy")])
        self.assertNotIn(cloudy["id"], [c["id"] for c in db.chat_list("", "", "chatgpt")])

    def test_switching_assistant_returns_to_where_each_one_left_off(self):
        first = db.chat_add("Cloudy 的那间", "cloudy")
        db.chat_switch(first["id"])

        moved = self._switch("chatgpt")
        self.assertEqual(moved["name"], "ChatGPT")
        self.assertEqual(db.chat_assistant(moved["chat_id"]), "chatgpt")
        # 新聊天开在 ChatGPT 名下
        made = self.client.post("/api/chats", json={"action": "new", "name": "第二间"}).json()
        self.assertEqual(db.chat_assistant(made["id"]), "chatgpt")

        back = self._switch("cloudy")
        self.assertEqual(back["chat_id"], first["id"])
        again = self._switch("chatgpt")
        self.assertEqual(again["chat_id"], made["id"])

    def test_opening_a_chat_switches_to_its_assistant(self):
        chatgpt = db.chat_add("推送点进来", "chatgpt")
        self.assertEqual(db.current_assistant(), "cloudy")
        self.client.post("/api/chats", json={"action": "switch", "id": chatgpt["id"]})
        self.assertEqual(db.current_assistant(), "chatgpt")
        self.assertEqual(main._get_or_create_current_chat(), chatgpt["id"])

    def test_branch_stays_with_the_same_assistant(self):
        chat = db.chat_add("原聊天", "chatgpt")
        message = db.message_add(chat["id"], "user", "从这里分")
        branch = db.chat_branch_from_message(chat["id"], message["id"])
        self.assertEqual(db.chat_assistant(branch["id"]), "chatgpt")

    def test_unknown_assistant_is_refused(self):
        response = self.client.post("/api/assistant", json={"assistant": "other"})
        self.assertEqual(response.status_code, 400)

    def test_search_and_dates_only_cover_the_current_assistant(self):
        cloudy = db.chat_add("c", "cloudy")
        chatgpt = db.chat_add("g", "chatgpt")
        db.message_add(cloudy["id"], "user", "海边的约定")
        db.message_add(chatgpt["id"], "user", "海边的作业")
        db.diary_add("", "海边的日记")

        cloudy_hits = [h["snippet"] for h in db.find_everywhere("海边", assistant="cloudy")]
        chatgpt_hits = [h["snippet"] for h in db.find_everywhere("海边", assistant="chatgpt")]
        self.assertIn("海边的约定", cloudy_hits)
        self.assertNotIn("海边的作业", cloudy_hits)
        self.assertEqual(chatgpt_hits, ["海边的作业"])
        today = db.today_str()
        self.assertEqual([c["chat_id"] for c in db.chat_day(today, "chatgpt")], [chatgpt["id"]])

    # ------------------------------------------------------------ 记忆

    def test_memory_pools_do_not_cross_assistants(self):
        cloudy = db.chat_add("c", "cloudy")["id"]
        chatgpt = db.chat_add("g", "chatgpt")["id"]
        self.assertEqual(db.memory_shared_chat_ids("cloudy"), [cloudy])
        self.assertEqual(db.memory_shared_chat_ids("chatgpt"), [chatgpt])
        with db.conn() as cx:
            cx.execute(
                "INSERT INTO chat_memory_state (chat_id,enabled,overview,generated_at) VALUES (?,1,?,1)",
                (cloudy, "Cloudy 的总览"),
            )
        self.assertEqual(db.shared_memory_overview("cloudy")["overview"], "Cloudy 的总览")
        self.assertEqual(db.shared_memory_overview("chatgpt"), {})

    def test_memory_is_written_in_each_assistants_own_voice(self):
        chatgpt = db.chat_add("g", "chatgpt")["id"]
        cloudy = db.chat_add("c", "cloudy")["id"]
        self.assertIn("你是ChatGPT", main._memory_voice_prompt(chatgpt))
        self.assertNotIn("Cloudy", main._memory_voice_prompt(chatgpt))
        self.assertIn("你是Cloudy", main._memory_voice_prompt(cloudy))
        rows = [{"rowid": 1, "role": "assistant", "content": "嗯"}]
        self.assertIn("ChatGPT：嗯", main._memory_transcript(rows, "ChatGPT"))

    # ------------------------------------------------------------ 待办

    def test_hers_is_shared_and_mine_is_per_assistant(self):
        db.todo_add("hers", "买牛奶")
        db.todo_add("mine", "Cloudy 的事", assistant="cloudy")
        db.todo_add("mine", "ChatGPT 的事", assistant="chatgpt")

        cloudy = db.todos_all(assistant="cloudy")
        chatgpt = db.todos_all(assistant="chatgpt")
        self.assertEqual([t["text"] for t in cloudy["hers"]], ["买牛奶"])
        self.assertEqual([t["text"] for t in chatgpt["hers"]], ["买牛奶"])
        self.assertEqual([t["text"] for t in cloudy["mine"]], ["Cloudy 的事"])
        self.assertEqual([t["text"] for t in chatgpt["mine"]], ["ChatGPT 的事"])

    def test_one_assistant_cannot_tick_the_others_list(self):
        item = db.todo_add("mine", "Cloudy 的事", assistant="cloudy")
        self.assertFalse(db.todo_toggle("mine", item["id"], "chatgpt"))
        self.assertFalse(db.todo_del("mine", item["id"], "chatgpt"))
        self.assertTrue(db.todo_toggle("mine", item["id"], "cloudy"))

    def test_todo_page_follows_the_current_assistant(self):
        self._switch("chatgpt")
        self.client.post("/api/todos", json={"action": "add", "list": "mine", "text": "写周报"})
        self.assertEqual([t["text"] for t in self.client.get("/api/todos").json()["mine"]], ["写周报"])
        self._switch("cloudy")
        self.assertEqual(self.client.get("/api/todos").json()["mine"], [])

    # ------------------------------------------------------------ 工具

    def test_chatgpt_has_no_journal_tools(self):
        names = {tool["function"]["name"] for tool in main._home_tools_for("chatgpt")}
        self.assertIn("DwellTodoAdd", names)
        self.assertIn("DwellCalendarAdd", names)
        self.assertFalse(any(name.startswith(("DwellDiary", "DwellQuote", "DwellWhisper")) for name in names))
        self.assertEqual(main._home_tools_for("cloudy"), main.HOME_TOOLS)
        with self.assertRaises(ValueError):
            main.home_tool("DwellDiaryList", {"diary": "cloudy"}, "chatgpt")

    def test_todo_tool_writes_to_the_calling_assistants_list(self):
        main.home_tool("DwellTodoAdd", {"list": "mine", "text": "查资料"}, "chatgpt")
        self.assertEqual([t["text"] for t in db.todos_all(assistant="chatgpt")["mine"]], ["查资料"])
        self.assertEqual([t["by"] for t in db.todos_all(assistant="chatgpt")["mine"]], ["chatgpt"])
        self.assertEqual(db.todos_all(assistant="cloudy")["mine"], [])

    # ------------------------------------------------------------ 心跳

    def test_heartbeat_settings_are_kept_per_assistant(self):
        self.assertTrue(self.client.get("/api/heartbeat?assistant=cloudy").json()["on"])
        # 新来的助手默认不主动找你
        self.assertFalse(self.client.get("/api/heartbeat?assistant=chatgpt").json()["on"])

        self.client.post("/api/heartbeat", json={"assistant": "chatgpt", "on": True, "daily_limit": 2})
        self.assertEqual(self.client.get("/api/heartbeat?assistant=chatgpt").json()["config"]["daily_limit"], 2)
        self.assertEqual(self.client.get("/api/heartbeat?assistant=cloudy").json()["config"]["daily_limit"],
                         main.HEARTBEAT_DEFAULTS["daily_limit"])

    def test_heartbeat_target_must_be_the_assistants_own_chat(self):
        cloudy = db.chat_add("c", "cloudy")
        chatgpt = db.chat_add("g", "chatgpt")
        self.client.post("/api/wake-target", json={"chat_id": chatgpt["id"]})
        self.assertEqual(self.client.get("/api/wake-target?assistant=chatgpt").json()["chat_id"], chatgpt["id"])
        self.assertEqual(self.client.get("/api/wake-target?assistant=cloudy").json()["chat_id"], cloudy["id"])

        # 目标被指到别人的聊天上时，心跳不会去那里说话
        db.setting_set("wake_target_chat_id:chatgpt", cloudy["id"])
        result = asyncio.run(main._heartbeat_once(force=True, assistant="chatgpt"))
        self.assertEqual(result["status"], "no_target")

    def test_chatgpt_heartbeat_is_off_until_turned_on(self):
        result = asyncio.run(main._heartbeat_once(assistant="chatgpt"))
        self.assertEqual(result["status"], "off")


if __name__ == "__main__":
    unittest.main()
