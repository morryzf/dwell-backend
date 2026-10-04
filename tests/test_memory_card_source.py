"""记忆卡直接读原文出卡、标出依据的那几条、点开看原文、拆开塞了几件事的卡。"""

import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from fastapi.testclient import TestClient

from app import auth, db, main


class MemoryCardSourceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "source.db")
        db.init_db()
        self.chat = db.chat_add("整理")["id"]
        texts = [("user", "我最近在学游泳"), ("assistant", "加油"),
                 ("user", "对了，我妈下周三生日"), ("assistant", "要准备礼物吗"),
                 ("user", "想送她一条围巾"), ("assistant", "好主意")]
        for role, text in texts:
            db.message_add(self.chat, role, text)
        self.rowids = [int(m["rowid"]) for m in db.message_list(self.chat)]
        self.segment = db.chat_memory_add_segment(self.chat, self.rowids[0], self.rowids[-1], "")
        self.client = TestClient(main.app)
        self.client.headers["X-Dwell-Token"] = "t"
        self._token = mock.patch.object(auth, "API_TOKEN", "t")
        self._token.start()

    def tearDown(self):
        self._token.stop()
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    CARD = {"content": "她妈妈的生日在下周三。", "memory_type": "stable_fact",
            "topics": ["family_friends"], "importance": "normal",
            "retention": "long_term", "valid_until": None}

    def _stage(self, cards):
        sent = {}

        async def fake(provider, model_id, system, user):
            sent["system"], sent["user"] = system, user
            return {"cards": cards}

        async def run():
            with mock.patch.object(main, "_memory_json_completion", fake):
                await main._stage_memory_card_suggestions(
                    self.chat, {"id": "p", "enabled": 1}, "model", self.segment)
        asyncio.run(run())
        return sent

    def test_the_card_model_reads_the_raw_messages_with_their_numbers(self):
        sent = self._stage([])
        self.assertIn(f"[{self.rowids[2]}] 用户：对了，我妈下周三生日", sent["user"])
        self.assertIn("一张卡只记一件事", sent["system"])
        self.assertIn("evidence", sent["system"])

    def test_the_previous_tail_comes_along_as_background_only(self):
        later = db.chat_memory_add_segment(self.chat, self.rowids[4], self.rowids[5], "")
        sent = {}

        async def fake(provider, model_id, system, user):
            sent["user"] = user
            return {"cards": []}

        async def run():
            with mock.patch.object(main, "_memory_json_completion", fake):
                await main._stage_memory_card_suggestions(
                    self.chat, {"id": "p", "enabled": 1}, "model", later)
        asyncio.run(run())
        background, own = sent["user"].split("【这一段原文：从这里出卡】")
        self.assertIn("不要从这里出卡", background)
        self.assertIn("我妈下周三生日", background)
        self.assertIn("围巾", own)
        self.assertNotIn("我妈下周三生日", own)

    def test_source_shows_the_cited_messages_with_context(self):
        self._stage([{**self.CARD, "evidence": [self.rowids[2]]}])
        draft = db.memory_card_draft_list(self.chat)[0]
        card = db.memory_card_draft_accept(self.chat, draft["id"], main._memory_card_clean(draft))
        self.assertEqual(card["source_rowids"], [self.rowids[2]])

        data = self.client.get(f"/api/chats/{self.chat}/memory-source",
                               params={"kind": "card", "id": card["id"]}).json()
        self.assertTrue(data["precise"])
        cited = [m["content"] for m in data["messages"] if m["cited"]]
        self.assertEqual(cited, ["对了，我妈下周三生日"])
        # 前后各三条上下文，这一段一共六条，全在里面。
        self.assertEqual(len(data["messages"]), 6)
        self.assertFalse(data["can_expand"])

    def test_old_cards_fall_back_to_the_whole_segment(self):
        self._stage([self.CARD])   # 没给 evidence，像旧卡一样只有整段范围
        draft = db.memory_card_draft_list(self.chat)[0]
        data = self.client.get(f"/api/chats/{self.chat}/memory-source",
                               params={"kind": "draft", "id": draft["id"]}).json()
        self.assertFalse(data["precise"])
        self.assertEqual(len(data["messages"]), 6)
        self.assertFalse(any(m["cited"] for m in data["messages"]))

    def test_split_drafts_replace_the_card_only_when_adopted(self):
        card = db.memory_card_draft_accept(self.chat, self._one_draft(), main._memory_card_clean(self.CARD))
        proposals = [
            {**self.CARD, "content": "她最近在学游泳。", "source_rowids": [self.rowids[0]]},
            {**self.CARD, "content": "她妈妈的生日在下周三。", "source_rowids": [self.rowids[2]]},
        ]
        self.assertEqual(db.memory_card_stage_split(self.chat, card["id"], proposals), 2)
        drafts = db.memory_card_draft_list(self.chat)
        self.assertEqual({d["action"] for d in drafts}, {"split"})
        self.assertEqual(db.memory_card_get(self.chat, card["id"])["status"], "active")

        db.memory_card_draft_accept(self.chat, drafts[0]["id"], main._memory_card_clean(drafts[0]))
        self.assertEqual(db.memory_card_get(self.chat, card["id"])["status"], "archived")
        # 第二条还能接着采用，原卡已经归档就不再动它。
        second = db.memory_card_draft_accept(self.chat, drafts[1]["id"], main._memory_card_clean(drafts[1]))
        self.assertEqual(second["source_rowids"], [self.rowids[2]])

    def test_a_new_split_replaces_the_old_unfinished_one(self):
        card = db.memory_card_draft_accept(self.chat, self._one_draft(), main._memory_card_clean(self.CARD))
        db.memory_card_stage_split(self.chat, card["id"], [{**self.CARD, "content": "a"}, {**self.CARD, "content": "b"}])
        db.memory_card_stage_split(self.chat, card["id"], [{**self.CARD, "content": "c"}, {**self.CARD, "content": "d"}])
        self.assertEqual(sorted(d["content"] for d in db.memory_card_draft_list(self.chat)), ["c", "d"])

    def test_split_task_stages_drafts_and_one_thing_cards_are_left_alone(self):
        card = db.memory_card_draft_accept(self.chat, self._one_draft(), main._memory_card_clean(self.CARD))
        model = ({"id": "m", "provider_id": "p", "model_id": "x"}, {"id": "p", "enabled": 1}, True)

        def run(cards):
            async def go():
                with mock.patch.object(main, "_long_context_model", return_value=model), \
                        mock.patch.object(main, "_memory_json_completion",
                                          mock.AsyncMock(return_value={"cards": cards})):
                    await main._split_memory_card(self.chat, card["id"])
            asyncio.run(go())

        run([self.CARD])
        self.assertEqual(db.memory_card_draft_list(self.chat), [])
        self.assertIn("只有一件事", db.memory_card_state_get(self.chat)["note"])

        run([{**self.CARD, "content": "她最近在学游泳。", "evidence": [self.rowids[0]]},
             {**self.CARD, "content": "她想送妈妈围巾。", "evidence": [self.rowids[4], 999]}])
        drafts = db.memory_card_draft_list(self.chat)
        self.assertEqual(len(drafts), 2)
        self.assertEqual(drafts[1]["source_rowids"], [self.rowids[4]])

    def _one_draft(self):
        db.memory_card_stage(self.chat, [{**self.CARD, "source_segment_id": self.segment["id"]}])
        return db.memory_card_draft_list(self.chat)[-1]["id"]

    def test_branching_keeps_the_cited_messages_pointing_at_the_branch(self):
        db.memory_shared_set(self.chat, False)
        draft_id = self._one_draft()
        with db.conn() as cx:
            cx.execute("UPDATE memory_card_drafts SET source_rowids_json=? WHERE id=?",
                       (json.dumps([self.rowids[2]]), draft_id))
        draft = next(d for d in db.memory_card_draft_list(self.chat) if d["id"] == draft_id)
        db.memory_card_draft_accept(self.chat, draft_id, main._memory_card_clean(draft))
        last = db.message_list(self.chat)[-1]
        branch = db.chat_branch_from_message(self.chat, last["id"])
        copied = db.memory_card_list(branch["id"])
        mine = [c for c in copied if c["chat_id"] == branch["id"]]
        self.assertEqual(len(mine), 1)
        branch_rows = {int(m["rowid"]): m["content"] for m in db.message_list(branch["id"])}
        self.assertEqual([branch_rows[r] for r in mine[0]["source_rowids"]], ["对了，我妈下周三生日"])


if __name__ == "__main__":
    unittest.main()
