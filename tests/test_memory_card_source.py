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


class MemoryThreadTest(unittest.TestCase):
    """同一件事的卡挂同一个事件名；取回细节卡时把主卡带上；「补全这张」进待确认。"""

    CARD = MemoryCardSourceTest.CARD
    _stage = MemoryCardSourceTest._stage
    tearDown = MemoryCardSourceTest.tearDown

    def setUp(self):
        MemoryCardSourceTest.setUp(self)
        self.main_card = db.memory_card_add_manual(self.chat, {
            **self.CARD, "content": "Morry 在追音音（她在约会 AI 社区认识的女生），还没放手。",
            "memory_type": "open_thread", "topics": ["relationship"], "thread": "追音音",
            "thread_role": "main"})

    def test_drafting_keeps_the_thread_and_the_prompt_asks_for_it(self):
        sent = self._stage([{**self.CARD, "content": "在追音音这件事上，我让她别越界。", "thread": "追音音"}])
        self.assertIn("thread", sent["system"])
        # 这段原文讲的是游泳和生日，跟音音无关：以前只靠「Morry：」这个说话人标签对上，现在不算了。
        self.assertNotIn("主卡·追音音", sent["user"])
        self.assertIn("追音音（已有主卡）", sent["user"])
        draft = db.memory_card_draft_list(self.chat)[0]
        self.assertEqual(draft["thread"], "追音音")
        card = db.memory_card_draft_accept(self.chat, draft["id"], main._memory_card_clean(draft))
        self.assertEqual(card["thread"], "追音音")

    def test_a_detail_card_brings_its_main_card_along(self):
        detail = {"id": "d1", "thread": "追音音", "thread_role": "detail", "memory_type": "quote", "status": "active"}
        pool = [*db.memory_card_embeddings(self.chat), detail]
        out = main._with_thread_mains([detail], pool)
        self.assertEqual([c["id"] for c in out], ["d1", self.main_card["id"]])

    def test_cards_can_be_filtered_by_thread(self):
        db.memory_card_add_manual(self.chat, {**self.CARD, "content": "别的事。"})
        page = db.memory_card_page(self.chat, thread="追音音")
        self.assertEqual([c["id"] for c in page["items"]], [self.main_card["id"]])
        self.assertEqual(db.memory_card_threads(self.chat), [{"thread": "追音音", "count": 1, "has_main": True}])

    def test_completing_a_card_waits_for_review_then_rewrites_it_in_place(self):
        vague = db.memory_card_add_manual(self.chat, {**self.CARD, "content": "她对那个女生有 crush。"})

        async def fake(provider, model_id, system, user):
            self.assertIn("她对那个女生有 crush。", user)
            self.assertIn("主卡·追音音", user)
            return {"content": "她对音音（约会 AI 社区认识的女生）有 crush。", "thread": "追音音"}

        async def run():
            with mock.patch.object(main, "_memory_json_completion", fake), \
                 mock.patch.object(main, "_long_context_model",
                                   lambda chat: ({"model_id": "m"}, {"id": "p", "enabled": 1}, True)):
                await main._complete_memory_card(self.chat, vague["id"])
        asyncio.run(run())

        draft = db.memory_card_draft_list(self.chat)[0]
        self.assertEqual((draft["action"], draft["target_card_id"]), ("revise", vague["id"]))
        self.assertEqual(db.memory_card_get(self.chat, vague["id"])["content"], "她对那个女生有 crush。")

        card = db.memory_card_draft_accept(self.chat, draft["id"], main._memory_card_clean(draft))
        self.assertEqual(card["id"], vague["id"])
        self.assertEqual(card["thread"], "追音音")
        self.assertIn("音音", card["content"])


class MemoryMainCardTest(unittest.TestCase):
    """一件事只有一张主卡：模型再提主卡就变成「在原主卡上更新」；主卡改字留历史。"""

    CARD = MemoryCardSourceTest.CARD
    _stage = MemoryCardSourceTest._stage
    tearDown = MemoryCardSourceTest.tearDown

    def setUp(self):
        MemoryCardSourceTest.setUp(self)
        self.main_card = db.memory_card_add_manual(self.chat, {
            **self.CARD, "content": "Morry 在追音音。", "memory_type": "open_thread",
            "thread": "追音音", "thread_role": "main"})

    def test_a_second_main_card_becomes_a_new_node_on_the_first(self):
        self._stage([{**self.CARD, "content": "后来音音回了消息。",
                      "thread": "追音音", "thread_role": "main", "evidence": [self.rowids[2]]}])
        draft = db.memory_card_draft_list(self.chat)[0]
        self.assertEqual((draft["action"], draft["target_card_id"]), ("append", self.main_card["id"]))
        self.assertRegex(draft["node_date"], r"^\d{4}-\d{2}-\d{2}$")

        card = db.memory_card_draft_accept(self.chat, draft["id"], main._memory_card_clean(draft))

        self.assertEqual(card["id"], self.main_card["id"])
        self.assertEqual([n["text"] for n in card["timeline"]], ["Morry 在追音音。", "后来音音回了消息。"])
        self.assertIn(f"{draft['node_date']}：后来音音回了消息。", card["content"])
        self.assertEqual([h["content"] for h in db.memory_card_history(self.chat, card["id"])],
                         ["Morry 在追音音。"])

    def test_an_old_main_card_is_one_node_until_edited(self):
        self.assertEqual([n["text"] for n in self.main_card["timeline"]], ["Morry 在追音音。"])
        nodes = [{"date": "2026-10-15", "text": "她发现音的旧号不见了。"},
                 {"date": "2026-10-13", "text": "Morry 关注了音。"}]
        chosen = main._memory_card_clean(self.main_card)
        card = db.memory_card_update(self.chat, self.main_card["id"], {**chosen, "timeline": nodes})
        self.assertEqual([n["date"] for n in card["timeline"]], ["2026-10-13", "2026-10-15"])
        self.assertEqual(card["content"], "2026-10-13：Morry 关注了音。\n\n2026-10-15：她发现音的旧号不见了。")

    def test_main_cards_are_not_completed_by_the_model(self):
        c = TestClient(main.app)
        c.headers["X-Dwell-Token"] = "t"
        res = c.post(f"/api/chats/{self.chat}/memory-cards/{self.main_card['id']}/complete")
        self.assertEqual(res.status_code, 400)

    def test_two_mains_for_a_new_event_in_one_batch_leave_one_main(self):
        self._stage([{**self.CARD, "content": "Morry 开始学游泳。", "thread": "学游泳", "thread_role": "main"},
                     {**self.CARD, "content": "Morry 学游泳报了周末班。", "thread": "学游泳", "thread_role": "main"}])
        roles = sorted(d["thread_role"] for d in db.memory_card_draft_list(self.chat))
        self.assertEqual(roles, ["detail", "main"])

    def test_setting_a_second_main_by_hand_asks_first(self):
        other = db.memory_card_add_manual(self.chat, {**self.CARD, "content": "她说想再试一次。",
                                                       "thread": "追音音", "thread_role": "detail"})
        chosen = main._memory_card_clean({**other, "thread_role": "main"})
        with self.assertRaises(db.ThreadMainExists):
            db.memory_card_update(self.chat, other["id"], chosen)

        db.memory_card_update(self.chat, other["id"], {**chosen, "demote_other": True})

        self.assertEqual(db.memory_card_get(self.chat, other["id"])["thread_role"], "main")
        self.assertEqual(db.memory_card_get(self.chat, self.main_card["id"])["thread_role"], "detail")

    def test_editing_a_main_card_keeps_its_old_text(self):
        chosen = main._memory_card_clean({**self.main_card, "content": "Morry 在追音音，还没放手。"})
        db.memory_card_update(self.chat, self.main_card["id"], chosen)
        self.assertEqual([h["content"] for h in db.memory_card_history(self.chat, self.main_card["id"])],
                         ["Morry 在追音音。"])


class MemoryPendingDraftTest(unittest.TestCase):
    """还没采用的待确认，整理时也看得见：不再出一遍，有新进展就换成写完整的新版。"""

    CARD = MemoryCardSourceTest.CARD
    _stage = MemoryCardSourceTest._stage
    tearDown = MemoryCardSourceTest.tearDown

    def setUp(self):
        MemoryCardSourceTest.setUp(self)
        db.memory_card_stage(self.chat, [{**self.CARD, "content": "Morry 预售拍了一条刻字项圈，卖家还没发货。",
                                          "memory_type": "open_thread", "thread": "定制项圈",
                                          "thread_role": "main", "node_date": "2026-10-20"}])
        self.pending = db.memory_card_draft_list(self.chat)[0]

    def test_the_model_sees_pending_drafts_and_their_event(self):
        sent = self._stage([])
        self.assertIn("还在待确认的卡", sent["user"])
        self.assertIn("P1 ", sent["user"])
        self.assertIn("刻字项圈", sent["user"])
        self.assertIn("定制项圈（主卡还在待确认）", sent["user"])
        self.assertIn("P 编号", sent["system"])

    def test_a_new_version_replaces_the_pending_draft(self):
        self._stage([{**self.CARD, "content": "Morry 拍了刻字项圈，卖家没等刻字就发货了，她重拍了一单，刻 Belongs to Cloudy。",
                      "memory_type": "open_thread", "thread": "定制项圈", "thread_role": "main",
                      "replaces": "P1", "evidence": [self.rowids[2]]}])
        drafts = db.memory_card_draft_list(self.chat)
        self.assertEqual(len(drafts), 1)
        self.assertNotEqual(drafts[0]["id"], self.pending["id"])
        self.assertEqual((drafts[0]["action"], drafts[0]["thread_role"]), ("create", "main"))
        self.assertIn("Belongs to Cloudy", drafts[0]["content"])
        self.assertEqual(drafts[0]["node_date"], "2026-10-20")

    def test_a_second_main_for_a_pending_event_becomes_a_detail(self):
        self._stage([{**self.CARD, "content": "卖家说其实还没真发出。", "thread": "定制项圈", "thread_role": "main"}])
        roles = sorted(d["thread_role"] for d in db.memory_card_draft_list(self.chat))
        self.assertEqual(roles, ["detail", "main"])
