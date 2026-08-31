from pathlib import Path
import unittest


class MemoryConsoleStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = (Path(__file__).parents[1] / "static" / "index.html").read_text(
            encoding="utf-8"
        )

    def test_console_exposes_the_four_management_views(self):
        for label in ("总览", "待确认", "记忆卡", "归档"):
            self.assertIn(label, self.html)

    def test_console_connects_every_memory_card_action(self):
        for route in (
            "/memory-cards?include_archived=true",
            "/memory-cards/generate",
            "/memory-card-drafts/",
            "/memory-cards/",
        ):
            self.assertIn(route, self.html)

    def test_console_keeps_phase_two_safety_message(self):
        self.assertIn("目前记忆卡不会带入聊天", self.html)
        self.assertIn("第三阶段开启检索后才会按需使用", self.html)


if __name__ == "__main__":
    unittest.main()

