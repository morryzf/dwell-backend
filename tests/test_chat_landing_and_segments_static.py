from pathlib import Path
import unittest


class ChatLandingAndSegmentsStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).parents[1]
        cls.page = (root / "static" / "index.html").read_text(encoding="utf-8")

    def test_every_user_bubble_segment_carries_the_actions(self):
        # 分成几段就是几段，操作不能只挂在第一段上
        self.assertNotIn("if (i === 0 && message) attachMessageActions(b, message);", self.page)
        self.assertIn("if (message) attachMessageActions(b, message);", self.page)

    def test_history_load_keeps_holding_the_bottom(self):
        self.assertIn("function lockToBottom(ms = 1200)", self.page)
        self.assertIn("function releaseBottomLock()", self.page)
        self.assertIn("    scroll(true);\n    lockToBottom();", self.page)
        # 手一碰就松开，不跟用户抢滚动条
        self.assertIn("['wheel', 'touchstart', 'mousedown'].forEach(type => {", self.page)
        self.assertIn("log.addEventListener(type, releaseBottomLock, { passive: true });", self.page)
        self.assertIn("document.addEventListener('keydown', releaseBottomLock, { passive: true });", self.page)

    def test_jumping_to_a_searched_line_is_not_dragged_back_down(self):
        jump = self.page.split("var focusEl = document.querySelector('#log .row[data-message-id=\"'")[1]
        jump = jump.split("poll();")[0]
        self.assertEqual(jump.count("releaseBottomLock();"), 2)
        self.assertEqual(jump.count("scrollIntoView({ block: 'center' })"), 2)


if __name__ == "__main__":
    unittest.main()
