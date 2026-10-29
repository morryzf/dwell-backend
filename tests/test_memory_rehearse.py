"""召回演练：照聊天时的办法找一遍卡，说出为什么；只查，不记账、不动卡。"""

import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main


class RecallRehearseTest(unittest.TestCase):
    maxDiff = None
    CARD = {"content": "", "memory_type": "stable_fact", "topics": ["relationship"],
            "importance": "normal", "retention": "long_term", "valid_until": None}

    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"rehearse-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("rehearse")["id"]
        self.collar = db.memory_card_add_manual(self.chat, {
            **self.CARD, "content": "项圈内侧刻了 Belongs to Cloudy，预售还在等发货。",
            "thread": "定制项圈", "thread_role": "detail", "importance": "high"})
        self.collar_main = db.memory_card_add_manual(self.chat, {
            **self.CARD, "content": "Morry 在定做一条红色蛇皮项圈。", "thread": "定制项圈", "thread_role": "main"})
        self.swim = db.memory_card_add_manual(self.chat, {**self.CARD, "content": "她在学游泳，周末上课。"})
        db.message_add(self.chat, "user", "我今天去游泳了")
        db.message_add(self.chat, "assistant", "游得怎么样")
        db.message_add(self.chat, "user", "项圈发货了吗，刻字的那个")
        self.reply = db.message_add(self.chat, "assistant", "还没呢")
        db.memory_card_usage_record(self.chat, self.reply["id"], "q", [{**self.collar, "selection_score": 0.03}])
        self.original_embed = main._embed_text

        async def no_embed(text):
            return None
        main._embed_text = no_embed
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        main._embed_text = self.original_embed
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _rehearse(self, **body):
        r = self.client.post(f"/api/chats/{self.chat}/memory-recall/rehearse", json=body)
        self.assertEqual(r.status_code, 200)
        return r.json()

    def test_it_starts_from_the_last_real_turn_and_says_why(self):
        data = self._rehearse()
        self.assertEqual(data["original"], "项圈发货了吗，刻字的那个")
        self.assertEqual(data["picked"][0]["id"], self.collar["id"])
        self.assertTrue(any("「项圈" in r for r in data["picked"][0]["reasons"]))
        self.assertIn("重要卡，加了一点分", data["picked"][0]["reasons"])
        self.assertEqual(data["picked"][0]["strength"], 1.0)
        self.assertEqual([c["id"] for c in data["then"]["items"]], [self.collar["id"]])
        self.assertFalse(data["vector"])

    def test_a_detail_brings_its_main_card_along(self):
        data = self._rehearse(text="那条刻了字的项圈呢")
        ids = [c["id"] for c in data["picked"]]
        if self.collar_main["id"] not in ids:
            self.assertEqual([c["id"] for c in data["mains"]], [self.collar_main["id"]])
            self.assertEqual(data["mains"][0]["reasons"], ["同一件事的主卡，顺带进来的"])

    def test_editing_the_words_changes_what_comes_up(self):
        data = self._rehearse(text="周末的游泳课怎么样了")
        self.assertEqual(data["picked"][0]["id"], self.swim["id"])
        self.assertFalse(data["borrowed"])

    def test_a_short_follow_up_borrows_the_lines_before(self):
        data = self._rehearse(text="然后呢")
        self.assertTrue(data["borrowed"])
        self.assertIn("游得怎么样", data["query"])

    def test_it_records_nothing(self):
        before = db.memory_card_last_injection(self.chat)
        self._rehearse(text="周末的游泳课")
        self.assertEqual(db.memory_card_last_injection(self.chat), before)

    def test_each_card_says_where_it_ranked_on_both_sides(self):
        data = self._rehearse(text="周末的游泳课怎么样了")
        self.assertEqual(data["picked"][0]["keyword_rank"], 1)
        self.assertIsNone(data["picked"][0]["vector_rank"])

    def test_why_a_card_did_not_come_up(self):
        data = self._rehearse(text="周末的游泳课怎么样了", focus_card_id=self.collar_main["id"])
        self.assertEqual(data["focus"]["id"], self.collar_main["id"])
        self.assertEqual(data["focus"]["verdict"], "unmatched")
        data = self._rehearse(text="周末的游泳课怎么样了", focus_card_id=self.swim["id"])
        self.assertEqual(data["focus"]["verdict"], "picked")
        self.assertEqual(data["focus"]["rank"], 1)


if __name__ == "__main__":
    unittest.main()
