import tempfile
import time
import unittest
from pathlib import Path

from app import db


class SharedMemoryTest(unittest.TestCase):
    """Cloudy 只有一个：新开的窗口该认得旧窗口记下的事。

    想要一个不留痕的窗口时，把「记忆互通」关掉——它只看自己的，
    自己的也不借给别人。
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "shared.db")
        db.init_db()

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def _chat(self, name):
        return db.chat_add(name)["id"]

    def _card(self, chat_id, content, status="active"):
        """直接落一张卡。正常路径是 stage → accept，这里只关心卡在不在池子里。"""
        message = db.message_add(chat_id, "user", content)
        now = int(time.time())
        with db.conn() as cx:
            rowid = cx.execute(
                "SELECT rowid FROM messages WHERE id=?", (message["id"],)
            ).fetchone()["rowid"]
            cx.execute(
                "INSERT INTO memory_cards (id,chat_id,content,memory_type,topics_json,"
                "importance,retention,status,source_start_rowid,source_end_rowid,made,updated) "
                "VALUES (?,?,?,'stable_fact','[]','normal','long_term',?,?,?,?,?)",
                (db.new_id(), chat_id, content, status, rowid, rowid, now, now),
            )

    def _pool(self, chat_id):
        return {card["content"] for card in db.memory_card_embeddings(chat_id)}

    def test_sharing_is_on_for_a_brand_new_chat(self):
        self.assertTrue(db.memory_shared_enabled(self._chat("默认开着")))

    def test_a_new_window_sees_what_an_older_one_remembered(self):
        old = self._chat("旧窗口")
        self._card(old, "她周四要去体检")
        fresh = self._chat("新窗口")

        self.assertIn("她周四要去体检", self._pool(fresh))

    def test_turning_it_off_stops_reading_other_windows(self):
        other = self._chat("别人的窗口")
        self._card(other, "别人的事")
        private = self._chat("不留痕的窗口")
        self._card(private, "自己的事")

        db.memory_shared_set(private, False)

        pool = self._pool(private)
        self.assertIn("自己的事", pool)
        self.assertNotIn("别人的事", pool)

    def test_turning_it_off_also_stops_lending_to_others(self):
        # 只读不写会漏：那个窗口说的话照样跑到别处去，「关掉」就不彻底。
        private = self._chat("关掉的窗口")
        self._card(private, "不该外流的事")
        db.memory_shared_set(private, False)
        listener = self._chat("在听的窗口")

        self.assertNotIn("不该外流的事", self._pool(listener))

    def test_switching_back_on_restores_both_directions(self):
        # 关掉是实时的筛选，不是把卡搬走；再打开应该原样回来。
        a = self._chat("来回切的窗口")
        self._card(a, "来回切的事")
        db.memory_shared_set(a, False)
        b = self._chat("旁观的窗口")
        self.assertNotIn("来回切的事", self._pool(b))

        db.memory_shared_set(a, True)

        self.assertIn("来回切的事", self._pool(b))

    def test_archived_cards_stay_out_of_the_shared_pool(self):
        owner = self._chat("归档来源")
        self._card(owner, "她亲手收起来的事", status="archived")
        listener = self._chat("看得到吗")

        self.assertNotIn("她亲手收起来的事", self._pool(listener))


class SharedOverviewTest(unittest.TestCase):
    """摘要也共用：新窗口一开就有那份「我们是谁」，不用等它自己长一版。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "overview.db")
        db.init_db()

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def _with_overview(self, name, text, made):
        chat_id = db.chat_add(name)["id"]
        with db.conn() as cx:
            cx.execute(
                "INSERT INTO chat_memory_state (chat_id,enabled,overview,generated_at) "
                "VALUES (?,1,?,?)",
                (chat_id, text, made),
            )
        return chat_id

    def test_the_newest_one_among_shared_chats_wins(self):
        now = int(time.time())
        self._with_overview("早的", "旧版总览", now - 1000)
        self._with_overview("晚的", "新版总览", now)

        self.assertEqual(db.shared_memory_overview()["overview"], "新版总览")

    def test_a_chat_that_opted_out_does_not_supply_it(self):
        now = int(time.time())
        self._with_overview("共用的", "共用的总览", now - 1000)
        private = self._with_overview("退出的", "不该外流的总览", now)

        db.memory_shared_set(private, False)

        self.assertEqual(db.shared_memory_overview()["overview"], "共用的总览")

    def test_no_overview_anywhere_is_not_an_error(self):
        db.chat_add("空的")
        self.assertEqual(db.shared_memory_overview(), {})


class SharedConsoleTest(unittest.TestCase):
    """控制台要跟模型看到的对得上。

    模型读公共池，控制台只列本窗口那几张的话，新窗口会显示成空的——
    看起来像记忆丢了，其实好好的。
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "console.db")
        db.init_db()

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def _card(self, chat_id, content, status="active"):
        message = db.message_add(chat_id, "user", content)
        now = int(time.time())
        with db.conn() as cx:
            rowid = cx.execute(
                "SELECT rowid FROM messages WHERE id=?", (message["id"],)
            ).fetchone()["rowid"]
            cx.execute(
                "INSERT INTO memory_cards (id,chat_id,content,memory_type,topics_json,"
                "importance,retention,status,source_start_rowid,source_end_rowid,made,updated) "
                "VALUES (?,?,?,'stable_fact','[]','normal','long_term',?,?,?,?,?)",
                (db.new_id(), chat_id, content, status, rowid, rowid, now, now),
            )

    def test_the_console_lists_the_whole_shared_pool(self):
        old = db.chat_add("旧窗口")["id"]
        self._card(old, "她周四要去体检")
        fresh = db.chat_add("新窗口")["id"]

        contents = [card["content"] for card in db.memory_card_list(fresh)]

        self.assertIn("她周四要去体检", contents)

    def test_each_card_says_which_window_wrote_it(self):
        # 前端拿 chat_id 决定把编辑发给谁，拿 chat_name 显示「来自 X」。
        old = db.chat_add("旧窗口")["id"]
        self._card(old, "她周四要去体检")
        fresh = db.chat_add("新窗口")["id"]

        card = next(
            item for item in db.memory_card_list(fresh)
            if item["content"] == "她周四要去体检"
        )

        self.assertEqual(card["chat_id"], old)
        self.assertEqual(card["chat_name"], "旧窗口")

    def test_a_window_that_opted_out_only_lists_its_own(self):
        other = db.chat_add("别人的窗口")["id"]
        self._card(other, "别人的事")
        private = db.chat_add("关掉的窗口")["id"]
        self._card(private, "自己的事")
        db.memory_shared_set(private, False)

        contents = [card["content"] for card in db.memory_card_list(private)]

        self.assertEqual(contents, ["自己的事"])

    def test_archived_cards_only_show_when_asked_for(self):
        old = db.chat_add("旧窗口")["id"]
        self._card(old, "归档的事", status="archived")
        fresh = db.chat_add("新窗口")["id"]

        self.assertNotIn("归档的事", [c["content"] for c in db.memory_card_list(fresh)])
        self.assertIn(
            "归档的事",
            [c["content"] for c in db.memory_card_list(fresh, include_archived=True)],
        )


if __name__ == "__main__":
    unittest.main()
