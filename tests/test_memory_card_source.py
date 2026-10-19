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
        self.assertIn(f"[{self.rowids[2]}] Morry：对了，我妈下周三生日", sent["user"])
        self.assertIn("单独读得懂", sent["system"])
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

    def test_the_card_model_sees_the_chat_summary_as_reference(self):
        db.chat_memory_save_overview(self.chat, "她最近在练游泳，每周去两次。")
        sent = self._stage([])
        summary, own = sent["user"].split("【这一段原文：从这里出卡】")
        self.assertIn("【已有的长期摘要：只作参照，不要从这里出卡】", summary)
        self.assertIn("她最近在练游泳，每周去两次。", summary)
        self.assertIn("我妈下周三生日", own)

    def test_no_summary_means_no_summary_section(self):
        sent = self._stage([])
        self.assertNotIn("已有的长期摘要", sent["user"])
        self.assertTrue(sent["user"].startswith("【这一段原文：从这里出卡】"))

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
        self.assertEqual(db.memory_card_stage_split(self.chat, "card", card["id"], proposals), 2)
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
        db.memory_card_stage_split(self.chat, "card", card["id"], [{**self.CARD, "content": "a"}, {**self.CARD, "content": "b"}])
        db.memory_card_stage_split(self.chat, "card", card["id"], [{**self.CARD, "content": "c"}, {**self.CARD, "content": "d"}])
        self.assertEqual(sorted(d["content"] for d in db.memory_card_draft_list(self.chat)), ["c", "d"])

    def test_split_task_stages_drafts_and_one_thing_cards_are_left_alone(self):
        card = db.memory_card_draft_accept(self.chat, self._one_draft(), main._memory_card_clean(self.CARD))
        model = ({"id": "m", "provider_id": "p", "model_id": "x"}, {"id": "p", "enabled": 1}, True)

        def run(cards):
            async def go():
                with mock.patch.object(main, "_long_context_model", return_value=model), \
                        mock.patch.object(main, "_memory_json_completion",
                                          mock.AsyncMock(return_value={"cards": cards})):
                    await main._split_memory_card(self.chat, "card", card["id"])
            asyncio.run(go())

        run([self.CARD])
        self.assertEqual(db.memory_card_draft_list(self.chat), [])
        self.assertIn("只有一件事", db.memory_card_state_get(self.chat)["note"])

        run([{**self.CARD, "content": "她最近在学游泳。", "evidence": [self.rowids[0]]},
             {**self.CARD, "content": "她想送妈妈围巾。", "evidence": [self.rowids[4], 999]}])
        drafts = db.memory_card_draft_list(self.chat)
        self.assertEqual(len(drafts), 2)
        self.assertEqual(drafts[1]["source_rowids"], [self.rowids[4]])

    def test_a_draft_can_be_split_before_it_is_adopted(self):
        draft_id = self._one_draft()
        count = db.memory_card_stage_split(self.chat, "draft", draft_id, [
            {**self.CARD, "content": "她在学游泳。", "source_rowids": [self.rowids[0]]},
            {**self.CARD, "content": "她想送妈妈围巾。", "source_rowids": [self.rowids[4]]},
        ])
        self.assertEqual(count, 2)
        drafts = db.memory_card_draft_list(self.chat)
        # 原来那条被换掉了，拆出来的还是普通的待确认，依据可以落在整段的任何地方。
        self.assertNotIn(draft_id, [d["id"] for d in drafts])
        self.assertEqual({d["action"] for d in drafts}, {"create"})
        self.assertEqual(sorted(d["source_rowids"][0] for d in drafts), [self.rowids[0], self.rowids[4]])

    def test_split_reads_the_whole_segment_even_when_the_card_is_narrow(self):
        self._stage([{**self.CARD, "evidence": [self.rowids[2]]}])
        draft = db.memory_card_draft_list(self.chat)[0]
        self.assertEqual(db.memory_source_span(self.chat, draft), (self.rowids[0], self.rowids[-1]))
        response = self.client.post(f"/api/chats/{self.chat}/memory-card-drafts/{draft['id']}/split")
        self.assertEqual(response.status_code, 200)

    def test_retag_suggestions_cannot_be_split(self):
        card = db.memory_card_draft_accept(self.chat, self._one_draft(), main._memory_card_clean(self.CARD))
        db.memory_card_stage_retags(self.chat, [{"card_id": card["id"], "topics": ["food"]}])
        retag = db.memory_card_draft_list(self.chat)[0]
        response = self.client.post(f"/api/chats/{self.chat}/memory-card-drafts/{retag['id']}/split")
        self.assertEqual(response.status_code, 400)

    def test_a_draft_can_be_edited_without_adopting_it(self):
        draft_id = self._one_draft()
        response = self.client.put(f"/api/chats/{self.chat}/memory-card-drafts/{draft_id}",
                                   json={"content": "  她妈妈的生日是下周三。  "})
        self.assertEqual(response.status_code, 200)
        drafts = db.memory_card_draft_list(self.chat)
        self.assertEqual(drafts[0]["content"], "她妈妈的生日是下周三。")
        self.assertEqual(db.memory_card_list(self.chat), [])
        empty = self.client.put(f"/api/chats/{self.chat}/memory-card-drafts/{draft_id}", json={"content": " "})
        self.assertEqual(empty.status_code, 400)

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


class MemoryCardReplaceTest(unittest.TestCase):
    """出卡时能看到相关的旧卡；旧状态过时了可以提「换成这张」，Morry 采用后旧卡才收起来。"""

    OLD = {"content": "Morry 打算送她妈妈一条围巾当生日礼物。", "memory_type": "plan",
           "topics": ["family_friends"], "importance": "normal",
           "retention": "long_term", "valid_until": None}

    CARD = MemoryCardSourceTest.CARD
    _stage = MemoryCardSourceTest._stage
    tearDown = MemoryCardSourceTest.tearDown

    def setUp(self):
        MemoryCardSourceTest.setUp(self)
        self.old = db.memory_card_add_manual(self.chat, self.OLD)

    def test_related_cards_are_shown_with_numbers(self):
        sent = self._stage([])
        self.assertIn("【已有的相关记忆卡", sent["user"])
        self.assertIn("K1 ", sent["user"])
        self.assertIn("围巾当生日礼物", sent["user"])
        self.assertIn("replaces", sent["system"])

    def test_a_replacing_card_waits_for_review_and_archives_the_old_one_when_accepted(self):
        self._stage([{**self.CARD, "content": "Morry 改主意了，送她妈妈一束花当生日礼物。",
                      "memory_type": "plan", "replaces": "K1"}])
        draft = db.memory_card_draft_list(self.chat)[0]
        self.assertEqual(draft["action"], "replace")
        self.assertEqual(draft["target_card_id"], self.old["id"])
        # 还没采用：旧卡照常生效。
        self.assertEqual(db.memory_card_get(self.chat, self.old["id"])["status"], "active")

        db.memory_card_draft_accept(self.chat, draft["id"], {**self.CARD, "content": draft["content"]})

        self.assertEqual(db.memory_card_get(self.chat, self.old["id"])["status"], "archived")

    def test_an_unknown_reference_is_just_a_new_card(self):
        self._stage([{**self.CARD, "replaces": "K9"}])
        draft = db.memory_card_draft_list(self.chat)[0]
        self.assertEqual(draft["action"], "create")
        self.assertIsNone(draft["target_card_id"])
