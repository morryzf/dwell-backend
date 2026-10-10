import json
import os
import tempfile
import unittest
from datetime import datetime
from unittest.mock import patch

from app import db, focus_log


def ts(text: str) -> int:
    return int(datetime.strptime(text, "%Y-%m-%d %H:%M").replace(tzinfo=db.CN_TZ).timestamp())


class FocusLogTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_patch = patch.object(db, "DB_PATH", os.path.join(self.tmp.name, "dwell.db"))
        self.db_patch.start()
        db.init_db()

    def tearDown(self):
        self.db_patch.stop()
        self.tmp.cleanup()

    def test_only_one_session_runs_at_a_time(self):
        math = focus_log.subject_add("数学", "#7f9a84")
        english = focus_log.subject_add("英语")
        with patch.object(focus_log, "_now", return_value=ts("2026-10-10 09:00")):
            focus_log.start(math["id"])
        with patch.object(focus_log, "_now", return_value=ts("2026-10-10 09:30")):
            focus_log.start(english["id"])
            self.assertEqual(focus_log.running()["subject_id"], english["id"])
        with patch.object(focus_log, "_now", return_value=ts("2026-10-10 10:00")):
            day = focus_log.day("2026-10-10")
        self.assertEqual(day["by_subject"], {math["id"]: 1800, english["id"]: 1800})
        self.assertEqual(day["total"], 3600)

    def test_session_across_midnight_is_split(self):
        subject = focus_log.subject_add("读书")
        with patch.object(focus_log, "_now", return_value=ts("2026-10-11 02:00")):
            focus_log.log(subject["id"], ts("2026-10-10 23:00"), ts("2026-10-11 01:00"))
            rows = focus_log.days("2026-10-10", "2026-10-11")
        self.assertEqual([r["total"] for r in rows], [3600, 3600])

    def test_forgotten_timer_is_capped(self):
        subject = focus_log.subject_add("写作")
        with patch.object(focus_log, "_now", return_value=ts("2026-10-01 08:00")):
            focus_log.start(subject["id"])
        with patch.object(focus_log, "_now", return_value=ts("2026-10-03 08:00")):
            focus_log.stop()
            rows = focus_log.days("2026-10-01", "2026-10-03")
        self.assertEqual(sum(r["total"] for r in rows), focus_log.MAX_SESSION_SECONDS)

    def test_archived_subject_keeps_history_and_stops(self):
        subject = focus_log.subject_add("钢琴")
        with patch.object(focus_log, "_now", return_value=ts("2026-10-10 20:00")):
            focus_log.start(subject["id"])
        with patch.object(focus_log, "_now", return_value=ts("2026-10-10 20:45")):
            focus_log.subject_archive(subject["id"])
            self.assertIsNone(focus_log.running())
            self.assertEqual(focus_log.subjects(), [])
            self.assertEqual(focus_log.day("2026-10-10")["total"], 45 * 60)

    def test_context_respects_share_switch(self):
        subject = focus_log.subject_add("数学")
        now = int(datetime.now(db.CN_TZ).timestamp())
        with patch.object(focus_log, "_now", return_value=now):
            self.assertEqual(focus_log.context_text(), "")
            focus_log.log(subject["id"], now - 3600, now - 60)
            text = focus_log.context_text()
            self.assertIn("数学", text)
            self.assertIn("Today so far", text)
            focus_log.set_settings(share=False)
            self.assertEqual(focus_log.context_text(), "")

    def test_tool_reads_past_days(self):
        from app import main
        subject = focus_log.subject_add("数学")
        with patch.object(focus_log, "_now", return_value=ts("2026-10-10 12:00")):
            focus_log.log(subject["id"], ts("2026-10-09 10:00"), ts("2026-10-09 11:30"))
            week = json.loads(main.home_tool("DwellFocusLog", {"end": "2026-10-10"}))
            one = json.loads(main.home_tool("DwellFocusLog", {"date": "2026-10-09"}))
        self.assertEqual(week["total_minutes"], 90)
        self.assertEqual(len(week["days"]), 7)
        self.assertEqual(one["sessions"][0]["from"], "10:00")
        self.assertEqual(one["by_subject_minutes"], {"数学": 90})


if __name__ == "__main__":
    unittest.main()
