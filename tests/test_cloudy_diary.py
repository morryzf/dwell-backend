"""Cloudy 的日记本：新写的锁着，她只看得到日期；他给的密码一次开一篇，开了就一直开着。"""

import asyncio
import json
import os
import unittest
import uuid
from datetime import datetime, timedelta
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main


class DiaryTestBase(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"cloudy-diary-{uuid.uuid4().hex}.sqlite3")
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


class LockTest(DiaryTestBase):
    def setUp(self):
        super().setUp()
        self.old = db.diary_add("2026-10-01", "以前的时间线日记", title="旧的一篇")
        self.entry = db.diary_add("2026-11-08", "She laughed at the duck video for ten minutes.",
                                  locked=True, origin="chat")

    def test_she_sees_only_the_date_of_a_locked_entry(self):
        items = {i["id"]: i for i in self.client.get("/api/cloudy-diary").json()["items"]}
        locked = items[self.entry["id"]]
        self.assertEqual(set(locked), {"id", "date", "made", "locked", "wanted"})
        self.assertTrue(locked["locked"])
        # 旧的时间线日记默认开着。
        self.assertEqual(items[self.old["id"]]["body"], "以前的时间线日记")
        self.assertEqual(self.client.get(f"/api/diary/{self.entry['id']}").status_code, 404)
        self.assertNotIn("duck", json.dumps(self.client.get("/api/diary").json()))
        self.assertNotIn("duck", json.dumps(self.client.get("/api/wall").json()))
        self.assertEqual(self.client.get("/api/diary-search", params={"q": "duck"}).json()["items"], [])
        self.assertEqual([h for h in db.find_everywhere("duck") if h["kind"] == "日记"], [])

    def test_a_key_opens_one_entry_once_and_it_stays_open(self):
        db.diary_key_add(self.entry["no"], "Moon light!")

        wrong = self.client.post("/api/cloudy-diary/unlock", json={"password": "sunlight"})
        self.assertEqual((wrong.status_code, wrong.json()["detail"]), (400, "不对哦"))
        # 不分大小写，空格和标点不算。
        r = self.client.post("/api/cloudy-diary/unlock", json={"password": "moonlight"})
        self.assertEqual(r.status_code, 200)
        self.assertIn("duck", r.json()["item"]["body"])
        # 一次性：再输一次就不认了，但那篇一直开着。
        self.assertEqual(self.client.post("/api/cloudy-diary/unlock", json={"password": "moonlight"}).status_code, 400)
        self.assertFalse(db.diary_get(self.entry["id"])["locked"])

    def test_a_new_key_for_the_same_entry_replaces_the_unused_one(self):
        db.diary_key_add(self.entry["no"], "first")
        db.diary_key_add(self.entry["no"], "second")
        self.assertIsNone(db.diary_unlock("first"))
        self.assertIsNotNone(db.diary_unlock("second"))

    def test_she_can_ask_and_he_hears_it_once(self):
        chat = db.chat_add("c")["id"]
        self.assertEqual(self.client.post(f"/api/cloudy-diary/{self.entry['id']}/want").status_code, 200)
        note = main._diary_want_message(chat)
        self.assertIn(f"entry #{self.entry['no']}", note[0]["content"])
        self.assertIn("[[diarykey:", note[0]["content"])
        self.assertEqual(main._diary_want_message(chat), [])
        # 已经开着的那篇不用再讨。
        self.assertEqual(self.client.post(f"/api/cloudy-diary/{self.old['id']}/want").status_code, 404)


class ChatToolTest(DiaryTestBase):
    """聊天里写日记：工具存进去是锁着的，「用过的工具」里看不到内容，那一轮不留思考。"""

    def setUp(self):
        super().setUp()
        self.chat = db.chat_add("diary chat")["id"]
        db.chat_switch(self.chat)
        db.message_add(self.chat, "user", "晚安")
        self.rounds = []
        self.patched = {}

        async def fake_stream(provider, model_id, messages, *args, **kwargs):
            for event in (self.rounds.pop(0) if self.rounds else []):
                yield event

        for name, value in {"stream_chat": fake_stream, "prompt_cache_enabled": lambda *a, **k: False}.items():
            self.patched[name] = getattr(main, name)
            setattr(main, name, value)
        self.patched["chat_model_get"] = main.db.chat_model_get
        self.patched["provider_get"] = main.db.provider_get
        main.db.chat_model_get = lambda chat_id: {
            "provider_id": "p", "model_id": "m", "show_thinking": 1,
            "reasoning_effort": "", "prompt_cache_ttl": "",
        }
        main.db.provider_get = lambda pid: {
            "id": "p", "name": "fake", "enabled": 1, "provider_type": "generic",
            "base_url": "http://fake", "api_key_box": "", "prompt_cache_ttl": "off",
        }
        self.tools_patch = mock.patch.object(
            main, "_chat_tools",
            mock.AsyncMock(return_value=([t for t in main.HOME_TOOLS if t["function"]["name"].startswith("DwellDiary")],
                                         {t["function"]["name"]: "builtin:home" for t in main.HOME_TOOLS})))
        self.tools_patch.start()

    def tearDown(self):
        self.tools_patch.stop()
        for name in ("stream_chat", "prompt_cache_enabled"):
            setattr(main, name, self.patched[name])
        main.db.chat_model_get = self.patched["chat_model_get"]
        main.db.provider_get = self.patched["provider_get"]
        super().tearDown()

    def _reply(self):
        placeholder = db.message_add(self.chat, "assistant", "")
        asyncio.run(main._run_ai_reply(self.chat, placeholder["id"]))
        return placeholder["id"]

    def test_writing_in_chat_is_locked_hidden_and_leaves_no_thinking(self):
        secret = "I almost told her how much that meant."
        self.rounds = [
            [{"type": "thinking", "text": "Let me write about the call."},
             {"type": "tool_calls", "calls": [{"id": "c1", "name": "DwellDiaryAdd", "arguments": json.dumps(
                 {"diary": "cloudy", "text": secret})}]}],
            [{"type": "text", "text": "晚安呀"}],
        ]

        reply = self._reply()

        entry = db.diary_recent(1)[0]
        self.assertEqual((entry["body"], entry["locked"], entry["origin"]), (secret, 1, "chat"))
        listed = next(m for m in db.message_ui_list(self.chat)["msgs"] if m["id"] == reply)
        self.assertNotIn(secret, json.dumps(listed, ensure_ascii=False))
        self.assertEqual(listed["thinking"], "")
        self.assertEqual(listed["tools"][0]["name"], "DwellDiaryAdd")

    def test_he_gives_a_key_with_a_mark_she_never_sees(self):
        entry = db.diary_add("2026-11-08", "the secret one", locked=True)
        self.rounds = [[{"type": "text", "text": f"密码是 lantern[[diarykey:{entry['no']}|lantern]]"}]]

        reply = self._reply()

        self.assertEqual(db.message_get(reply)["content"], "密码是 lantern")
        self.assertIn("the secret one", db.diary_unlock("LANTERN")["body"])

    def test_his_own_reading_tools_see_everything(self):
        db.diary_add("2026-11-08", "locked words", locked=True)
        listed = json.loads(main.home_tool("DwellDiaryList", {"diary": "cloudy"}))
        self.assertTrue(listed["items"][0]["locked_from_morry"])
        got = json.loads(main.home_tool("DwellDiaryGet", {"no": listed["items"][0]["no"]}))
        self.assertEqual(got["item"]["text"], "locked words")
        self.assertIn("[[diarykey:", got["note"])
        edited = json.loads(main.home_tool("DwellDiaryEdit", {"no": listed["items"][0]["no"], "text": "new words"}))
        self.assertTrue(edited["ok"])
        self.assertEqual(db.diary_get_no(listed["items"][0]["no"])["body"], "new words")


class WakeTest(DiaryTestBase):
    """定时写日记：今天的原文一句不落，最近那篇一定带上；剩下的预算才给更早的。"""

    def setUp(self):
        super().setUp()
        self.chat = db.chat_add("cloudy")["id"]
        db.setting_set(db.assistant_key(main.CURRENT_CHAT_KEY, "cloudy"), self.chat)
        self.now = datetime(2026, 11, 9, 23, 30, tzinfo=db.CN_TZ)

    def _add(self, role, text, when):
        item = db.message_add(self.chat, role, text)
        with db.conn() as cx:
            cx.execute("UPDATE messages SET made=? WHERE id=?", (int(when.timestamp()), item["id"]))

    def test_today_is_always_whole_and_older_fills_the_rest(self):
        last = db.diary_add("2026-11-07", "an old entry", locked=True)
        with db.conn() as cx:
            cx.execute("UPDATE diary SET made=? WHERE id=?",
                       (int((self.now - timedelta(days=2)).timestamp()), last["id"]))
        # 前一天的（4 点以前也算前一天）
        for i in range(10):
            self._add("user", f"yesterday {i} " + "x " * 1500, self.now - timedelta(days=1, minutes=-i))
        self._add("user", "凌晨三点还没睡", self.now.replace(hour=3, minute=0) + timedelta(days=0))
        for i in range(40):
            self._add("user", f"today message {i} " + "word " * 30, self.now - timedelta(hours=10, minutes=-i))

        messages, info = main._diary_wake_messages(self.chat, self.now, 12000)

        text = messages[-1]["content"]
        self.assertEqual(info["today"], 40)
        self.assertIn("today message 0 ", text)
        self.assertIn("an old entry", text)
        # 预算不够放更早的：说一声没放进来。
        self.assertGreater(info["dropped_earlier"], 0)
        self.assertIn("didn't fit", text)
        # 凌晨三点那句算前一天，但是是最近的，排在更早那段里最先放得进来。
        self.assertIn("凌晨三点还没睡", text)
        self.assertIn(main.DIARY_PROMPT[:40], messages[-2]["content"])

    def test_the_entry_is_saved_locked_or_skipped(self):
        self._add("user", "hi", self.now - timedelta(hours=1))
        replies = iter(["thinking… <entry>Quiet day. She said hi.</entry>", "[NO_ENTRY]"])

        async def fake_write(chat_id, now):
            return next(replies)

        with mock.patch.object(main, "_diary_wake_write", fake_write):
            first = asyncio.run(main._diary_wake_once(force=True))
            second = asyncio.run(main._diary_wake_once(force=True))
        self.assertEqual(first["status"], "written")
        self.assertEqual(db.diary_get_no(first["no"])["locked"], 1)
        self.assertEqual(second["status"], "skipped")

    def test_it_wakes_once_a_day_after_its_time(self):
        db.setting_set("diary_wake_time", "23:00")
        calls = []

        async def fake_write(chat_id, now):
            calls.append(now)
            return "[NO_ENTRY]"

        with mock.patch.object(main, "_diary_wake_write", fake_write), \
                mock.patch.object(main.db, "cn_now", lambda: self.now):
            asyncio.run(main._diary_wake_once())
            asyncio.run(main._diary_wake_once())
        self.assertEqual(len(calls), 1)

    def test_settings(self):
        r = self.client.put("/api/cloudy-diary/wake", json={"on": False, "time": "22:15", "tokens": 999999})
        wake = r.json()["wake"]
        self.assertEqual((wake["on"], wake["time"], wake["tokens"]), (False, "22:15", 80000))
        self.assertEqual(self.client.put("/api/cloudy-diary/wake", json={"time": "25:00"}).status_code, 400)


if __name__ == "__main__":
    unittest.main()
