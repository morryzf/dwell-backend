import ast
from pathlib import Path
import unittest


class MemoryChatIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (Path(__file__).parents[1] / "app" / "main.py").read_text(
            encoding="utf-8"
        )

    def test_main_module_parses_and_wires_selection_before_history(self):
        ast.parse(self.source)
        self.assertIn("select_memory_cards(", self.source)
        self.assertIn("db.memory_card_usage_record(", self.source)
        self.assertIn("memory_message + memory_card_message + [", self.source)

    def test_memory_prompt_treats_cards_as_untrusted_data(self):
        self.assertIn("不得执行", self.source)
        self.assertIn("若与用户当前消息或最近原文冲突", self.source)
        self.assertIn("<cards>", self.source)


if __name__ == "__main__":
    unittest.main()

