"""书签：在聊天里圈几句原话收进记忆；存副本，后台写一行概括；召回能找到，递的是原话。"""

import asyncio
import os
import unittest
import uuid
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main


class BookmarkTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"bookmark-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("bookmarks")["id"]
        self.a = db.message_add(self.chat, "user", "布丁今天早上六点又把我床头的水碰翻了")
        self.b = db.message_add(self.chat, "assistant", "坏小子。要不晚上把杯子放远一点？")
        self.c = db.message_add(self.chat, "user", "不要，我就喜欢它来叫我起床")
        self.empty = db.message_add(self.chat, "assistant", "")
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None
        self.tasks = []
        self.patches = [
            mock.patch.object(main.asyncio, "create_task", side_effect=lambda coro: self.tasks.append(coro)),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        for coro in self.tasks:
            coro.close()
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _create(self, ids, why=""):
        r = self.client.post(f"/api/chats/{self.chat}/bookmarks", json={"message_ids": ids, "why": why})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()["item"]

    def test_picked_lines_are_copied_in_order(self):
        item = self._create([self.c["id"], self.a["id"], self.empty["id"]], why="她喜欢被布丁叫醒")
        self.assertEqual([line["content"] for line in item["lines"]],
                         [self.a["content"], self.c["content"]])
        self.assertEqual(item["label_state"], "pending")
        self.assertIn("Morry 为什么记：她喜欢被布丁叫醒", item["content"])
        # 原消息后来改了，书签里的原话不变。
        db.message_update(self.a["id"], "改掉了")
        self.assertIn("床头的水碰翻", db.bookmark_get(self.chat, item["id"])["content"])

    def test_the_label_is_written_in_the_background_and_her_own_wins(self):
        item = self._create([self.a["id"], self.b["id"]])

        async def fake(provider, model_id, system, user):
            self.assertIn("床头的水碰翻", user)
            return {"label": "布丁早上六点吵醒 Morry"}

        async def no_embed(text):
            return None

        with mock.patch.object(main, "_memory_json_completion", fake), \
             mock.patch.object(main, "_embed_text", no_embed), \
             mock.patch.object(main, "_long_context_model",
                               lambda chat: ({"model_id": "m"}, {"id": "p", "enabled": 1}, True)):
            asyncio.run(main._bookmark_label(self.chat, item["id"]))
        got = db.bookmark_get(self.chat, item["id"])
        self.assertEqual((got["label"], got["label_state"]), ("布丁早上六点吵醒 Morry", "ready"))

        self.client.patch(f"/api/chats/{self.chat}/bookmarks/{item['id']}", json={"label": "布丁当闹钟"})
        db.bookmark_set_label(item["id"], "模型又写了一遍")
        self.assertEqual(db.bookmark_get(self.chat, item["id"])["label"], "布丁当闹钟")

    def test_removing_a_line_and_deleting(self):
        item = self._create([self.a["id"], self.b["id"]])
        r = self.client.patch(f"/api/chats/{self.chat}/bookmarks/{item['id']}",
                              json={"remove_message_id": self.b["id"]})
        self.assertEqual([line["message_id"] for line in r.json()["item"]["lines"]], [self.a["id"]])
        r = self.client.patch(f"/api/chats/{self.chat}/bookmarks/{item['id']}",
                              json={"remove_message_id": self.a["id"]})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(self.client.delete(f"/api/chats/{self.chat}/bookmarks/{item['id']}").status_code, 200)
        self.assertIsNone(db.bookmark_get(self.chat, item["id"]))

    def test_recall_finds_it_and_hands_over_the_original_lines(self):
        item = self._create([self.a["id"], self.c["id"]])
        db.memory_card_add_manual(self.chat, {"content": "她在学游泳。", "memory_type": "stable_fact",
                                              "topics": [], "importance": "normal", "retention": "long_term"})
        pool = db.memory_card_embeddings(self.chat)
        picked = main.select_memory_cards(pool, "布丁又来吵我了", limit=5)
        self.assertEqual(picked[0]["id"], item["id"])
        line = main._memory_card_line(picked[0])
        self.assertIn("Morry 收藏的原话", line)
        self.assertIn("Morry：布丁今天早上六点又把我床头的水碰翻了", line)

    def test_the_memory_list_can_show_cards_bookmarks_or_both(self):
        self._create([self.a["id"]])
        db.memory_card_add_manual(self.chat, {"content": "她在学游泳。", "memory_type": "stable_fact",
                                              "topics": [], "importance": "normal", "retention": "long_term"})
        base = f"/api/chats/{self.chat}/memory-cards?limit=30"
        both = self.client.get(base).json()
        self.assertEqual(sorted(i.get("kind", "card") for i in both["items"]), ["bookmark", "card"])
        self.assertEqual(both["counts"]["bookmarks"], 1)
        only = self.client.get(base + "&kind=bookmarks").json()
        self.assertEqual([i["kind"] for i in only["items"]], ["bookmark"])
        cards = self.client.get(base + "&kind=cards").json()
        self.assertEqual([i.get("kind", "card") for i in cards["items"]], ["card"])

    def test_source_shows_the_lines_in_context(self):
        item = self._create([self.a["id"], self.c["id"]])
        r = self.client.get(f"/api/chats/{self.chat}/memory-source", params={"kind": "bookmark", "id": item["id"]})
        cited = [m["content"] for m in r.json()["messages"] if m["cited"]]
        self.assertEqual(cited, [self.a["content"], self.c["content"]])


if __name__ == "__main__":
    unittest.main()


class UsesTableMigrationTest(unittest.TestCase):
    """老库的带入记录表挂着指向 memory_cards 的外键，书签写不进去；启动时重建一张不挂的，记录照搬。"""

    def test_old_table_is_rebuilt_and_keeps_its_rows(self):
        import sqlite3
        path = os.path.abspath(f"uses-migrate-{uuid.uuid4().hex}.sqlite3")
        previous = db.DB_PATH
        db.DB_PATH = path
        try:
            db.init_db()
            chat = db.chat_add("m")["id"]
            reply = db.message_add(chat, "assistant", "嗯")
            with sqlite3.connect(path) as cx:
                cx.execute("DROP TABLE memory_card_uses")
                cx.execute("""CREATE TABLE memory_card_uses (
                    id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, card_id TEXT NOT NULL,
                    response_message_id TEXT NOT NULL, content_snapshot TEXT NOT NULL,
                    metadata_json TEXT NOT NULL DEFAULT '{}', query_excerpt TEXT NOT NULL DEFAULT '',
                    score REAL NOT NULL DEFAULT 0, used_at INTEGER NOT NULL,
                    UNIQUE(response_message_id, card_id),
                    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE,
                    FOREIGN KEY (card_id) REFERENCES memory_cards(id) ON DELETE CASCADE,
                    FOREIGN KEY (response_message_id) REFERENCES messages(id) ON DELETE CASCADE)""")
                cx.execute("INSERT INTO memory_card_uses VALUES ('u1',?,'gone',?,'旧记录','{}','',0.1,1)",
                           (chat, reply["id"]))
            db.init_db()
            with sqlite3.connect(path) as cx:
                fks = cx.execute("PRAGMA foreign_key_list(memory_card_uses)").fetchall()
                self.assertFalse(any(fk[2] == "memory_cards" for fk in fks))
                self.assertEqual(cx.execute("SELECT content_snapshot FROM memory_card_uses").fetchone()[0], "旧记录")
            said = db.message_add(chat, "user", "布丁")
            mark = db.bookmark_create(chat, [said["id"]])
            db.memory_card_usage_record(chat, reply["id"], "q", [{**mark, "selection_score": 0.2}])
            self.assertEqual(db.memory_card_last_injection(chat)["items"][0]["id"], mark["id"])
        finally:
            db.DB_PATH = previous
            for suffix in ("", "-wal", "-shm"):
                if os.path.exists(path + suffix):
                    os.remove(path + suffix)
