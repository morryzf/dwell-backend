import unittest
from pathlib import Path


class ChatDrawerStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = (
            Path(__file__).resolve().parents[1] / "static" / "index.html"
        ).read_text(encoding="utf-8")

    def test_old_full_page_chat_list_is_removed(self):
        self.assertNotIn('id="chatsSheet"', self.html)
        self.assertNotIn("sheets.chats", self.html)
        self.assertNotIn('id="newSession"', self.html)

    def test_assistants_are_separate_from_recent_conversations(self):
        assistants = self.html.index('class="assistant-switch"')
        recents = self.html.index('id="drawerChatHeading"')
        history = self.html.index('id="drawerChats"')
        self.assertLess(assistants, recents)
        self.assertLess(recents, history)
        self.assertIn('id="recGu"', self.html)
        self.assertIn('id="recGong"', self.html)

    def test_drawer_history_keeps_chat_actions(self):
        self.assertIn("rename.onclick = () => renameChat(it)", self.html)
        self.assertIn("del.onclick = (e) => deleteChat(it, e)", self.html)
        self.assertIn("bindChatRowSwipe(row, b)", self.html)
        self.assertIn('id="drawerNewChat"', self.html)
        self.assertIn('id="drawerChatScope"', self.html)

    def test_chat_swipe_does_not_compete_with_drawer_dismissal(self):
        self.assertIn(
            "'.nav button, .drawer-foot, .drawer-chat-list'",
            self.html,
        )


if __name__ == "__main__":
    unittest.main()
