from pathlib import Path
import unittest


class MemoryConsoleStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = (Path(__file__).parents[1] / "static" / "index.html").read_text(
            encoding="utf-8"
        )

    def test_console_exposes_the_four_management_views(self):
        # 标签按「系统」分，不再按卡片状态分：归档降级成记忆卡里的筛选项。
        for label in ("记忆卡", "待确认", "摘要", "设置", "已归档"):
            self.assertIn(label, self.html)

    def test_console_connects_every_memory_card_action(self):
        for route in (
            "/memory-cards?include_archived=true",
            "/memory-cards/generate",
            "/memory-cards/injection",
            "/memory-card-drafts/",
            "/memory-cards/",
        ):
            self.assertIn(route, self.html)

    def test_console_explains_and_controls_phase_three_injection(self):
        self.assertIn("按需记忆已开启", self.html)
        self.assertIn("隐藏、归档和过期内容会自动排除", self.html)
        self.assertIn("'memoryInjectionToggle'", self.html)
        self.assertIn("mc-switch-row", self.html)
        self.assertIn("wireMemorySwitch(", self.html)
        self.assertIn("最近一次带入", self.html)

    def test_summary_typography_is_compact(self):
        self.assertIn(
            "#longContextDraft, #longContextOverview { font-size: 14px;",
            self.html,
        )
        self.assertIn(
            ".mc-summary-history-text { font-size: 12.5px;",
            self.html,
        )

    def test_summary_and_cards_keep_compact_scrollable_hierarchy(self):
        self.assertIn("max-height: min(42dvh, 340px); overflow-y: auto;", self.html)
        self.assertIn('.mc-summary-history > summary { color: var(--dim); font-size: 12px;', self.html)
        self.assertIn(
            ".mc-summary-primary-actions { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));",
            self.html,
        )
        self.assertIn('class="mc-stack mc-used-scroll"', self.html)
        self.assertIn(
            "mc-actions${state.enabled ? ' mc-summary-primary-actions' : ''}",
            self.html,
        )

    def test_openrouter_decimal_claude_ids_are_normalized(self):
        self.assertIn("function modelSlug(id)", self.html)
        self.assertIn("s.split('/').pop()", self.html)
        self.assertIn("leaf.replace(/(\\d)\\.(\\d)/g, '$1-$2')", self.html)

    def test_drawer_uses_ten_pixel_frost(self):
        self.assertIn(
            "-webkit-backdrop-filter: blur(10px) saturate(1.45) brightness(1.05);",
            self.html,
        )
        self.assertNotIn(
            "-webkit-backdrop-filter: blur(30px) saturate(1.45) brightness(1.05);",
            self.html,
        )

    def test_manual_generation_only_checks_new_segments(self):
        self.assertIn("生成未处理分段的记忆卡草稿", self.html)
        self.assertIn("尚未处理的新分段", self.html)


if __name__ == "__main__":
    unittest.main()

