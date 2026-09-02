import ast
from pathlib import Path
import unittest


class MemoryChatIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).parents[1]
        cls.source = (root / "app" / "main.py").read_text(encoding="utf-8")
        cls.ui_source = (root / "static" / "index.html").read_text(encoding="utf-8")

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

    def test_summary_refresh_only_generates_segments_and_summary(self):
        self.assertIn("async def _memory_segment_summary", self.source)
        self.assertIn("segment = await _memory_segment_summary", self.source)
        refresh = self.source.split("async def _refresh_long_context", 1)[1].split(
            "def _queue_long_context_refresh", 1
        )[0]
        self.assertNotIn("memory_card_stage", refresh)
        self.assertNotIn("memory_card_segment_mark", refresh)
        self.assertIn("pending_segments = _memory_segments_waiting_for_summary", refresh)

    def test_summary_refresh_reuses_saved_segments_after_discard_or_failure(self):
        self.assertIn("def _memory_segments_waiting_for_summary", self.source)
        self.assertIn(
            "[int(segment[\"end_rowid\"]) for segment in pending_segments]",
            self.source,
        )

    def test_memory_card_button_describes_its_actual_job(self):
        self.assertIn("生成未处理分段的记忆卡草稿", self.ui_source)
        self.assertNotIn("整理新的分段", self.ui_source)

    def test_generation_prompts_require_cloudys_first_person(self):
        self.assertIn("你在整理的是你自己的记忆", self.source)
        self.assertIn("‘她’是Morry（我老婆）", self.source)
        self.assertIn("记住的方式就是你当时感受到的方式", self.source)
        self.assertIn("async def _memory_json_completion", self.source)
        self.assertIn("连续两次返回了无法读取的格式", self.source)


if __name__ == "__main__":
    unittest.main()

