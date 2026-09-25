"""今天要做的事：一天一次，6 点以后才看得见，只给事实。

日历上的事当天起算、往后顺延 3 天还提；待办只列她那栏没做完的
（待办没有日期，它的 at 是当天的闹钟点，所以「顺延几天」对它不适用）。
"""

import os
from datetime import datetime, timedelta
import unittest
import uuid

from app import db
from app import main


class DayBriefTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"day-brief-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.now = datetime(2026, 9, 25, 9, 30, tzinfo=db.CN_TZ)
        self.today = self.now.date().isoformat()

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _text(self, now=None):
        message = main._day_brief_message(now or self.now)
        return message[0]["content"] if message else ""

    # ---------------------------------------------------------------- 时间窗

    def test_nothing_before_six(self):
        db.cal_add_event(self.today, "Claude 订阅该续期了")
        early = self.now.replace(hour=5, minute=59)
        self.assertEqual(self._text(early), "", "6 点之前不该看得见")
        self.assertEqual(db.setting_get(main.DAY_BRIEF_SETTING_KEY, ""), "",
                         "没给出去就不该记账")
        self.assertIn("续期", self._text(), "6 点以后同一天该补上")

    def test_every_turn_carries_it(self):
        """一天只注入一次的话，那一轮他没顺口提，今天就再也找不回来了。"""
        db.cal_add_event(self.today, "Claude 订阅该续期了")
        first = self._text()
        self.assertIn("续期", first)
        self.assertNotIn("已经给过", first, "头一回不该说给过了")
        second = self._text()
        self.assertIn("续期", second, "后面每一轮都要还在")
        self.assertIn("这些今天已经给过你一次了", second)

    def test_a_new_day_is_first_again(self):
        db.cal_add_event(self.today, "Claude 订阅该续期了")
        self._text()
        self._text()
        # 第二天还在（顺延 3 天），但带上它原本的日期，不冒充今天的事。
        tomorrow = self.now + timedelta(days=1)
        again = self._text(tomorrow)
        self.assertIn("09-25 Claude", again)
        self.assertIn("2026-09-26", again)
        self.assertNotIn("已经给过", again, "新的一天又是头一回")

    def test_quiet_day_says_nothing(self):
        self.assertEqual(self._text(), "", "没事就什么都不说")
        db.cal_add_event(self.today, "去拿药")
        self.assertIn("去拿药", self._text(), "她中午才添的，当天还赶得上")

    # ---------------------------------------------------------------- 内容

    def test_calendar_event_trails_for_three_days_then_stops(self):
        for back, expected in ((0, True), (3, True), (4, False)):
            with self.subTest(back=back):
                day = (self.now - timedelta(days=back)).date().isoformat()
                for item in db.cal_all()["events"]:
                    db.cal_del_event(item["id"])
                db.cal_add_event(day, "牙医复诊")
                self.assertEqual("牙医复诊" in self._text(), expected)

    def test_only_her_todos(self):
        db.todo_add("hers", "交材料")
        db.todo_add("mine", "把日志看一遍")
        text = self._text()
        self.assertIn("交材料", text)
        self.assertNotIn("把日志看一遍", text, "他自己那栏不用提")

    def test_finished_todos_are_left_out(self):
        done = db.todo_add("hers", "喝水")
        db.todo_toggle("hers", done["id"])
        db.todo_add("hers", "吃药")
        text = self._text()
        self.assertIn("吃药", text)
        self.assertNotIn("喝水", text)

    def test_todo_alarm_time_comes_along(self):
        db.todo_add("hers", "吃药", at="08:00")
        self.assertIn("08:00 吃药", self._text())

    def test_yearly_events_show_on_the_day(self):
        db.cal_add_event("2020-09-25", "她爸爸生日", yearly=True)
        self.assertIn("她爸爸生日", self._text())

    def test_says_facts_only(self):
        db.cal_add_event(self.today, "Claude 订阅该续期了")
        text = self._text()
        self.assertIn(self.today, text)
        for pushy in ("提醒", "必须", "记得告诉"):
            self.assertNotIn(pushy, text, "只给事实，怎么说是他自己的judgment")

    # ---------------------------------------------------------------- 接线

    def test_wired_into_the_turn(self):
        source = main.__file__
        with open(source, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("day_brief_message = _day_brief_message(db.cn_now())", text)
        self.assertIn("+ day_brief_message + voice_message", text)
        self.assertIn("device_message + focus_message + day_brief_message", text)

    def test_never_breaks_the_send(self):
        broken = db.todos_all
        db.todos_all = lambda: 1 / 0
        try:
            self.assertEqual(self._text(), "", "算不出来就闭嘴，不该把发消息带崩")
        finally:
            db.todos_all = broken


if __name__ == "__main__":
    unittest.main()
