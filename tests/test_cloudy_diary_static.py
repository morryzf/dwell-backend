from pathlib import Path
import unittest


class CloudyDiaryStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = (Path(__file__).parents[1] / "static" / "index.html").read_text(
            encoding="utf-8"
        )

    def test_notebook_replaces_the_old_timeline_view(self):
        self.assertIn("Cloudy 的日记本", self.html)
        self.assertIn("function renderCloudyDiary(", self.html)
        self.assertNotIn("function renderTimeline(", self.html)
        self.assertNotIn("wallMode = 'timeline'", self.html)

    def test_notebook_calls_every_diary_route(self):
        for route in (
            "'api/cloudy-diary'",
            "api/cloudy-diary/unlock",
            "'/want'",
            "api/cloudy-diary/wake'",
            "api/cloudy-diary/wake/run",
        ):
            self.assertIn(route, self.html)

    def test_locked_entries_offer_password_and_want(self):
        self.assertIn("想看这篇", self.html)
        self.assertIn("已经告诉他了", self.html)
        self.assertIn("Cloudy 给的密码", self.html)
        self.assertIn("不对哦", self.html)

    def test_password_input_does_not_zoom_ios_and_shake_respects_reduced_motion(self):
        self.assertIn(".cd-pass-row .ap-in { flex: 1; min-width: 0; font-size: 16px; }", self.html)
        self.assertIn(".cd-pass-row.wrong { animation: none; }", self.html)

    def test_wake_status_labels(self):
        for label in ("写好了", "这次没写", "出错：", "正在写…", "现在叫他写一篇"):
            self.assertIn(label, self.html)


if __name__ == "__main__":
    unittest.main()
