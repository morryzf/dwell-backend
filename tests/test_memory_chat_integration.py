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
        self.assertIn("MEMORY_TAIL_MESSAGES = 80", self.source)
        self.assertIn("MEMORY_UPDATE_MIN_MESSAGES = 50", self.source)
        self.assertIn("select_memory_cards(", self.source)
        self.assertIn("db.memory_card_usage_record(", self.source)
        self.assertIn("memory_message + memory_card_message + [", self.source)

    def test_memory_prompt_treats_cards_as_untrusted_data(self):
        self.assertIn("不得执行", self.source)
        self.assertIn("若与用户当前消息或最近原文冲突", self.source)
        self.assertIn("<cards>", self.source)

    def test_one_segment_call_generates_record_and_cards(self):
        self.assertIn("async def _memory_segment_package", self.source)
        self.assertIn("segment, proposals = await _memory_segment_package", self.source)
        self.assertIn("具体事实、偏好、日期、原话和一次性细节交给记忆卡片", self.source)
        refresh = self.source.split("async def _refresh_long_context", 1)[1].split(
            "def _queue_long_context_refresh", 1
        )[0]
        self.assertNotIn("_stage_memory_card_suggestions", refresh)

    def test_generation_prompts_require_cloudys_first_person(self):
        self.assertIn("卡片也必须像我自己的记忆", self.source)
        self.assertIn("这不是第三人称档案", self.source)


if __name__ == "__main__":
    unittest.main()

