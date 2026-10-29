"""整理模型不再写卡，改成圈原话、推荐书签：进待确认，她调整圈中的句子、收下或忽略。"""

import asyncio
import os
import unittest
import uuid
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main


class BookmarkSuggestionTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"bookmark-suggest-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("推荐书签")["id"]
        texts = [
            ("user", "早"),
            ("assistant", "早呀"),
            ("user", "布丁六点又把我闹醒了"),
            ("assistant", "坏小子"),
            ("user", "不过我其实喜欢它叫我起床"),
            ("assistant", "那就让它叫吧"),
            ("user", "晚安"),
        ]
        self.msgs = [db.message_add(self.chat, role, text) for role, text in texts]
        self.rowids = [self._rowid(m["id"]) for m in self.msgs]
        self.segment = db.chat_memory_add_segment(self.chat, self.rowids[0], self.rowids[-1], "早上的事")
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None
        self.tasks = []
        self.patch = mock.patch.object(main.asyncio, "create_task",
                                       side_effect=lambda coro: self.tasks.append(coro))
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        for coro in self.tasks:
            coro.close()
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _rowid(self, message_id):
        with db.conn() as cx:
            return cx.execute("SELECT rowid FROM messages WHERE id=?", (message_id,)).fetchone()[0]

    def _stage(self, items):
        self.prompts = []

        async def fake(provider, model_id, system, user):
            self.prompts.append((system, user))
            return {"bookmarks": items}

        async def run():
            with mock.patch.object(main, "_memory_json_completion", fake), \
                    mock.patch.object(main, "_memory_related_cards", mock.AsyncMock(return_value=[])):
                await main._generate_unprocessed_memory_card_suggestions(
                    self.chat, {"id": "p", "enabled": 1}, "model")
        asyncio.run(run())

    def _drafts(self):
        return self.client.get(f"/api/chats/{self.chat}/memory-cards?limit=20").json()["drafts"]

    def test_the_model_picks_lines_and_they_land_in_review(self):
        r = self.rowids
        self._stage([{"lines": [r[2], r[4]], "label": "布丁当闹钟，她其实喜欢"}])

        drafts = self._drafts()
        self.assertEqual(len(drafts), 1)
        draft = drafts[0]
        self.assertEqual(draft["action"], "bookmark")
        self.assertEqual(draft["content"], "布丁当闹钟，她其实喜欢")
        self.assertEqual(draft["source_rowids"], [r[2], r[4]])
        # 圈中的两句、夹在中间的一句、前后各两句。
        self.assertEqual([line["rowid"] for line in draft["lines"]], r[0:7])
        self.assertEqual([line["rowid"] for line in draft["lines"] if line["picked"]], [r[2], r[4]])
        self.assertEqual(db.memory_card_unprocessed_segments(self.chat), [])
        self.assertEqual(db.memory_card_list(self.chat), [])

    def test_it_does_not_write_cards_unless_switched_back(self):
        db.setting_set(main.MEMORY_DRAFTING_KEY, "cards")

        async def run():
            with mock.patch.object(main, "_stage_memory_card_suggestions", mock.AsyncMock()) as cards:
                await main._generate_unprocessed_memory_card_suggestions(
                    self.chat, {"id": "p", "enabled": 1}, "model")
                return cards
        self.assertEqual(asyncio.run(run()).await_count, 1)

    def test_lines_outside_the_segment_are_ignored(self):
        self._stage([{"lines": [99999], "label": "编出来的"}, {"lines": [self.rowids[2]], "label": ""}])

        self.assertEqual(self._drafts(), [])
        # 推荐全被挡下：这一段还留着，下次再试。
        self.assertEqual(len(db.memory_card_unprocessed_segments(self.chat)), 1)
        self.assertIn("2 个书签没留下", db.memory_card_state_get(self.chat)["note"])

    def test_the_model_sees_what_she_already_bookmarked(self):
        mark = db.bookmark_create(self.chat, [self.msgs[2]["id"], self.msgs[3]["id"]], label="布丁闹人")
        r = self.rowids
        # 模型还是圈了她已经收过的那两句：不再推荐。
        self._stage([{"lines": [r[2], r[3]], "label": "布丁闹人"}, {"lines": [r[4]], "label": "她喜欢被叫醒"}])

        self.assertIn(f"书签「布丁闹人」：{r[2]}, {r[3]}", self.prompts[0][1])
        self.assertEqual([d["content"] for d in self._drafts()], ["她喜欢被叫醒"])
        self.assertTrue(mark)

    def test_she_adjusts_the_lines_and_the_label_then_keeps_it(self):
        r = self.rowids
        self._stage([{"lines": [r[2]], "label": "布丁闹人"}])
        draft = self._drafts()[0]

        res = self.client.put(f"/api/chats/{self.chat}/memory-card-drafts/{draft['id']}",
                              json={"rowids": [r[2], r[4]], "label": "布丁当闹钟"})
        self.assertEqual(res.status_code, 200, res.text)
        item = res.json()["item"]
        self.assertEqual(item["source_rowids"], [r[2], r[4]])
        self.assertEqual(item["content"], "布丁当闹钟")
        # 圈到边上，窗口跟着往外扩。
        self.assertEqual(item["lines"][-1]["rowid"], r[6])

        res = self.client.post(f"/api/chats/{self.chat}/memory-card-drafts/{draft['id']}/accept",
                               json={"rowids": [r[2], r[3], r[4]]})
        self.assertEqual(res.status_code, 200, res.text)
        bookmark = res.json()["item"]
        self.assertEqual([line["content"] for line in bookmark["lines"]],
                         ["布丁六点又把我闹醒了", "坏小子", "不过我其实喜欢它叫我起床"])
        self.assertEqual(bookmark["label"], "布丁当闹钟")
        self.assertEqual(bookmark["label_state"], "ready")
        self.assertEqual(self._drafts(), [])
        self.assertEqual(len(db.bookmark_list(self.chat)), 1)

    def test_she_cannot_empty_the_selection(self):
        self._stage([{"lines": [self.rowids[2]], "label": "布丁闹人"}])
        draft = self._drafts()[0]
        res = self.client.put(f"/api/chats/{self.chat}/memory-card-drafts/{draft['id']}", json={"rowids": []})
        self.assertEqual(res.status_code, 400)

    def test_accept_all_keeps_the_bookmarks_too(self):
        r = self.rowids
        self._stage([{"lines": [r[2]], "label": "布丁闹人"}, {"lines": [r[4]], "label": "她喜欢被叫醒"}])

        res = self.client.post(f"/api/chats/{self.chat}/memory-card-drafts/accept-all")

        self.assertEqual(res.status_code, 200, res.text)
        self.assertEqual(self._drafts(), [])
        self.assertEqual(sorted(b["label"] for b in db.bookmark_list(self.chat)), ["她喜欢被叫醒", "布丁闹人"])

    def test_a_bookmark_suggestion_cannot_be_split(self):
        self._stage([{"lines": [self.rowids[2]], "label": "布丁闹人"}])
        draft = self._drafts()[0]
        res = self.client.post(f"/api/chats/{self.chat}/memory-card-drafts/{draft['id']}/split")
        self.assertEqual(res.status_code, 400)


if __name__ == "__main__":
    unittest.main()
