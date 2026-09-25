"""摘要改从记忆卡总结，而且每一版都从头重写。

旧写法是「旧摘要 + 新分段 → 新摘要」，聊得越久，早期内容被转述的次数越多，
最后剩下的是转述的转述。卡片是定死的记录，不参与这个传话游戏。
"""

import asyncio
import os
import time
from pathlib import Path
import unittest
import uuid

from app import db
from app import main


HTML = (Path(__file__).parents[1] / "static" / "index.html").read_text(encoding="utf-8")


def add_card(chat_id, content, status="active", valid_until=None,
             importance="normal", made=None):
    """直接落一张正式卡。走草稿流程只会让测试绕远路。"""
    row = {
        "id": db.new_id(), "chat_id": chat_id, "content": content,
        "memory_type": "fact", "topics_json": "[]", "importance": importance,
        "retention": "time_bound" if valid_until else "long_term",
        "valid_until": valid_until, "surface_scope": "chat_only", "status": status,
        "source_segment_id": None, "source_start_rowid": 0, "source_end_rowid": 0,
        "made": int(made or time.time()), "updated": int(made or time.time()),
    }
    with db.conn() as cx:
        cx.execute(
            """INSERT INTO memory_cards
               (id,chat_id,content,memory_type,topics_json,importance,retention,
                valid_until,surface_scope,status,source_segment_id,
                source_start_rowid,source_end_rowid,made,updated)
               VALUES (:id,:chat_id,:content,:memory_type,:topics_json,:importance,
                :retention,:valid_until,:surface_scope,:status,:source_segment_id,
                :source_start_rowid,:source_end_rowid,:made,:updated)""",
            row,
        )
    return row


class OverviewSourceTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"summary-cards-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("summary test")
        self.today = "2026-09-25"

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _cards(self):
        return main._memory_overview_cards(self.chat["id"], self.today)

    def test_hidden_archived_and_expired_are_left_out(self):
        add_card(self.chat["id"], "还在生效的")
        add_card(self.chat["id"], "她收起来的", status="hidden")
        add_card(self.chat["id"], "她归档的", status="archived")
        add_card(self.chat["id"], "上周就过期了", valid_until="2026-09-18")
        self.assertEqual([c["content"] for c in self._cards()], ["还在生效的"])

    def test_a_card_that_expires_today_still_counts(self):
        add_card(self.chat["id"], "今天到期", valid_until=self.today)
        self.assertEqual(len(self._cards()), 1, "到期当天还算数")

    def test_cards_come_in_the_order_things_happened(self):
        base = 1_700_000_000
        add_card(self.chat["id"], "第三件", made=base + 300)
        add_card(self.chat["id"], "第一件", made=base + 100)
        add_card(self.chat["id"], "第二件", made=base + 200)
        self.assertEqual([c["content"] for c in self._cards()],
                         ["第一件", "第二件", "第三件"],
                         "按时间顺序给，模型才看得出一条线")

    def test_source_text_carries_date_weight_and_content(self):
        add_card(self.chat["id"], "她爸爸的生日是 5 月 12 日", importance="high")
        text = main._memory_overview_source(self._cards())
        self.assertIn("她爸爸的生日是 5 月 12 日", text)
        self.assertIn("固定保留", text, "固定保留的卡要标出来")
        self.assertTrue(text.startswith("1. ["))


class OverviewRebuildTest(unittest.TestCase):
    """每次都从卡片重新长出来，不继承上一版。"""

    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"summary-rebuild-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("rebuild test")
        self.seen = []

        async def fake_completion(provider, model_id, system, user):
            self.seen.append({"system": system, "user": user})
            return "第 %d 版总览" % len(self.seen)

        self.patched = {
            "_memory_completion": main._memory_completion,
            "_long_context_model": main._long_context_model,
            "_memory_cutoff": main._memory_cutoff,
        }
        main._memory_completion = fake_completion
        main._long_context_model = lambda chat_id: (
            {"model_id": "m"}, {"id": "p", "name": "fake", "enabled": 1}, False,
        )
        main._memory_cutoff = lambda chat_id: 1

    def tearDown(self):
        for name, value in self.patched.items():
            setattr(main, name, value)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _refresh(self):
        asyncio.run(main._refresh_long_context(self.chat["id"]))

    def test_no_cards_is_an_honest_error(self):
        self._refresh()
        state = db.chat_memory_get(self.chat["id"])
        self.assertEqual(state["status"], "error")
        self.assertIn("记忆卡", str(state.get("error") or ""))
        self.assertFalse(self.seen, "没有材料就不该去调模型")

    def test_the_previous_version_is_never_fed_back_in(self):
        add_card(self.chat["id"], "我们约好腻了会回来")
        self._refresh()
        db.chat_memory_accept_draft(
            self.chat["id"], db.chat_memory_get(self.chat["id"])["draft_overview"])
        self.assertTrue(str(db.chat_memory_get(self.chat["id"])["overview"]).strip())

        self._refresh()
        self.assertEqual(len(self.seen), 2)
        second = self.seen[1]["user"]
        self.assertIn("我们约好腻了会回来", second, "材料还是那些卡")
        self.assertNotIn("第 1 版总览", second, "上一版不该再喂回去——那就是传话游戏")

    def test_it_regenerates_even_when_no_new_segments_arrived(self):
        add_card(self.chat["id"], "她最近在备考")
        self._refresh()
        db.chat_memory_accept_draft(
            self.chat["id"], db.chat_memory_get(self.chat["id"])["draft_overview"])
        self._refresh()
        self.assertEqual(len(self.seen), 2, "没有新原文也该能重写一版")

    def test_the_prompt_forbids_relisting_the_cards(self):
        add_card(self.chat["id"], "她爸爸的生日是 5 月 12 日")
        self._refresh()
        system = self.seen[0]["system"]
        self.assertIn("不要把卡片再列一遍", system)
        self.assertIn("写卡片之间的那层东西", system)
        self.assertNotIn("新分段", system)


class SummaryPanelCopyTest(unittest.TestCase):
    def test_the_panel_says_where_the_summary_comes_from(self):
        self.assertIn("摘要从生效中的记忆卡总结", HTML)
        self.assertIn("不在上一版上叠", HTML)

    def test_rebuild_button_is_named_for_what_it_does(self):
        # 它重建的是分段（记忆卡的原料），不是摘要。
        self.assertIn(">重新切分原文</button>", HTML)
        self.assertNotIn(">从原文重建</button>", HTML)


if __name__ == "__main__":
    unittest.main()
