"""自己动手加记忆卡：分类自己选，正文原样存，直接生效，不带日期；两个助手各加各的。"""

import json
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main

CARD = {"content": "她不吃香菜", "memory_type": "preference", "topics": ["food"],
        "importance": "high", "retention": "long_term"}


class ManualMemoryCardTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"manual-card-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None
        self.embedded = []

        async def fake_embed(card_id, content):
            self.embedded.append((card_id, content))
        self.saved_embed = main._embed_memory_card
        main._embed_memory_card = fake_embed

    def tearDown(self):
        main._embed_memory_card = self.saved_embed
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _add(self, chat_id, card=CARD):
        return self.client.post(f"/api/chats/{chat_id}/memory-cards", json=card)

    def test_card_is_saved_verbatim_and_active(self):
        chat = db.chat_add("c", "cloudy")["id"]
        item = self._add(chat).json()["item"]
        self.assertEqual(item["content"], "她不吃香菜")
        self.assertEqual((item["status"], item["memory_type"], item["importance"]), ("active", "preference", "high"))
        self.assertEqual(item["topics"], ["food"])
        self.assertEqual(item["undated"], 1)
        self.assertEqual(self.embedded, [(item["id"], "她不吃香菜")])

    def test_injected_card_carries_no_date(self):
        chat = db.chat_add("c", "cloudy")["id"]
        self._add(chat)
        pool = db.memory_card_embeddings(chat)
        self.assertEqual(pool[0]["happened"], 0)
        line = main._memory_card_prompt(pool)
        self.assertIn("偏好", line)
        self.assertNotRegex(line, r"\[\d{4}-\d{2}-\d{2}")

    def test_bad_fields_are_refused(self):
        chat = db.chat_add("c", "cloudy")["id"]
        self.assertEqual(self._add(chat, {**CARD, "content": "  "}).status_code, 400)
        self.assertEqual(self._add(chat, {**CARD, "memory_type": "nope"}).status_code, 400)
        self.assertEqual(self._add(chat, {**CARD, "retention": "time_bound"}).status_code, 400)
        self.assertEqual(self._add("missing").status_code, 404)

    def test_each_assistant_keeps_its_own_manual_cards(self):
        cloudy = db.chat_add("c", "cloudy")["id"]
        gpt = db.chat_add("g", "chatgpt")["id"]
        self._add(gpt, {**CARD, "content": "她在学法语"})
        self.assertEqual([c["content"] for c in db.memory_card_embeddings(gpt)], ["她在学法语"])
        self.assertEqual(db.memory_card_embeddings(cloudy), [])


if __name__ == "__main__":
    unittest.main()


class MemoryHeaderButtonsStaticTest(unittest.TestCase):
    """记忆页右上角两个按钮：🔍 展开搜索和状态筛选，＋ 摊开一张空卡；编辑表单里的日期框不超出卡片。"""

    def test_search_and_add_live_in_the_header(self):
        from pathlib import Path
        html = Path("static/index.html").read_text(encoding="utf-8")
        head = html.split('<div class="sheetWrap" id="longContextSheet">', 1)[1].split('<div class="body"', 1)[0]
        self.assertLess(head.index('<div class="ht">记忆</div>'), head.index('id="memorySearchBtn"'))
        self.assertLess(head.index('id="memorySearchBtn"'), head.index('id="memoryAddBtn"'))
        self.assertNotIn("mc-cards-bar", html)
        self.assertIn("${memorySearchOpen?`<div class=\"mc-search-panel\">", html)
        # 状态在搜索框左边，类别在下面一排
        self.assertIn('<form class="mc-search-box" id="memorySearchForm" role="search"><select id="memoryStatus"', html)
        self.assertIn('data-mc-topic="${key}"', html)
        # 打字不搜，点 🔍 或键盘上的「搜索」才搜
        self.assertIn("if(search)search.oninput=()=>{ memorySearchDraft=search.value; };", html)
        self.assertIn('<button type="submit" class="mc-search-go" aria-label="搜索">', html)
        # 收起搜索时清掉关键词和筛选
        self.assertIn("if (!memorySearchOpen) { memoryConsoleQuery = ''; memorySearchDraft = ''; memoryConsoleFilter = 'all'; memoryConsoleTopic = ''; }", html)
        self.assertIn('.mc-form input[type="date"] { display: block; width: 100%; min-width: 0;', html)


class MemoryCardPagingTest(unittest.TestCase):
    """卡多了以后控制台分页拿；搜索和筛选对全部卡片做；向量不发给界面。"""

    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"card-page-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None
        self.chat = db.chat_add("c", "cloudy")["id"]
        for i in range(75):
            card = db.memory_card_add_manual(self.chat, main._memory_card_clean({
                **CARD, "content": f"第{i}张卡" + ("·芒果" if i == 3 else ""),
                "importance": "high" if i % 10 == 0 else "normal",
            }))
            db.memory_card_set_embedding(card["id"], [0.1] * 1536)
        with db.conn() as cx:   # 让编号大的更新得晚，排在前面
            cx.execute("UPDATE memory_cards SET updated=made+CAST(substr(content,2,instr(content,'张')-2) AS INTEGER)")
        old = db.memory_card_page(self.chat, limit=200)["items"][-1]
        db.memory_card_archive(self.chat, old["id"])

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _get(self, **params):
        return self.client.get(f"/api/chats/{self.chat}/memory-cards", params={"limit": 30, **params}).json()

    def test_first_page_is_the_most_recent_thirty_without_vectors(self):
        data = self._get()
        self.assertEqual(len(data["items"]), 30)
        self.assertEqual(data["items"][0]["content"], "第74张卡")
        self.assertEqual((data["total"], data["counts"]), (74, {"active": 74, "archived": 1}))
        self.assertNotIn("embedding_json", data["items"][0])
        self.assertNotIn("embedding_json", json.dumps(data))

    def test_more_pages_and_search_reach_every_card(self):
        self.assertEqual(len(self._get(limit=60)["items"]), 60)
        found = self._get(q="芒果")["items"]
        self.assertEqual([c["content"] for c in found], ["第3张卡·芒果"])
        self.assertEqual(self._get(q="%")["total"], 0)   # 通配符当普通字

    def test_status_filters_match_the_old_rules(self):
        self.assertEqual(self._get(filter="archived")["total"], 1)
        self.assertEqual(self._get(filter="high")["total"], 7)   # 0,10,…,70，不算归档
        db.memory_card_update(self.chat, self._get()["items"][0]["id"], {**main._memory_card_clean(CARD), "status": "hidden"})
        self.assertEqual(self._get(filter="hidden")["total"], 1)
        self.assertEqual(self._get(filter="active")["total"], 73)

    def test_topic_filter_combines_with_status_and_search(self):
        target = self._get(q="芒果")["items"][0]
        db.memory_card_update(self.chat, target["id"], {
            **main._memory_card_clean({**CARD, "content": target["content"], "topics": ["health_safety"]}),
            "importance": "high"})
        self.assertEqual([c["content"] for c in self._get(topic="health_safety")["items"]], ["第3张卡·芒果"])
        self.assertEqual(self._get(topic="health_safety", filter="high")["total"], 1)
        self.assertEqual(self._get(topic="health_safety", q="第4")["total"], 0)
        self.assertEqual(self._get(topic="not_a_topic")["total"], 74)   # 不认识的类别不筛

    def test_old_unpaged_call_still_works(self):
        data = self.client.get(f"/api/chats/{self.chat}/memory-cards?include_archived=true").json()
        self.assertEqual(len(data["items"]), 75)
        self.assertNotIn("embedding_json", data["items"][0])
