import unittest
from pathlib import Path


HTML = (Path(__file__).resolve().parents[1] / "static" / "index.html").read_text(encoding="utf-8")


class CacheGlowOnlyForFiveMinutesTest(unittest.TestCase):
    """那圈光画的就是 5 分钟那条线，选 1h 或关掉缓存时它没有意义。"""

    def test_gate_exists_and_reads_the_chat_setting(self):
        self.assertIn("function cacheGlowApplies()", HTML)
        self.assertIn("return curPromptCacheTtl === '5m';", HTML)

    def test_every_entry_point_is_gated(self):
        start = HTML.index("function cacheGlowStart()")
        self.assertIn("if (!cacheGlowApplies())", HTML[start:start + 200])

        restore = HTML.index("function cacheGlowSetChat(")
        self.assertIn("if (!cacheGlowApplies())", HTML[restore:restore + 300])

    def test_switching_away_from_five_minutes_clears_a_running_countdown(self):
        switch = HTML.index("async function setChatPromptCacheTtl(")
        section = HTML[switch:switch + 800]
        self.assertIn("if (!cacheGlowApplies()) cacheGlowStop(true, false);", section)


class BorderWidthStepTest(unittest.TestCase):
    def test_border_width_is_adjustable_in_tenths(self):
        self.assertIn(
            "{ key: 'borderWidth', label: '边框宽度', type: 'range', min: 0, max: 3, step: .1 }",
            HTML,
        )

    def test_the_readout_still_shows_one_decimal(self):
        self.assertIn("if (key === 'borderWidth') return Number(value).toFixed(1) + ' px';", HTML)


class ComposerPaddingFollowsItsHeightTest(unittest.TestCase):
    """输入卡撑高之后留白要跟上，否则最后一条会被玻璃压住。"""

    def test_composer_height_is_observed(self):
        observer = HTML.index("new ResizeObserver(() => {\n  if (sheetIsOpen()) return;\n  const wasBottom = atBottom();")
        section = HTML[observer:observer + 300]
        self.assertIn("fitLogTail();", section)
        self.assertIn("}).observe(composerEl);", section)

    def test_tail_is_measured_from_the_card_not_the_whole_footer(self):
        # 底栏里还装着「↓」按钮，按底栏量，它一出一收留白就跟着跳。
        self.assertNotIn("footerEl.offsetHeight", HTML)
        self.assertIn("setLogTail(log.getBoundingClientRect().bottom - composerEl.getBoundingClientRect().top + gap);", HTML)


class KeyboardKeepsHerPlaceTest(unittest.TestCase):
    """没停在最底下时点输入框，消息也要跟着输入卡一起上去。"""

    def test_messages_follow_the_card_not_only_at_bottom(self):
        self.assertNotIn("const stick = atBottom();", HTML)
        # 输入卡走了多少，消息就滚多少。
        self.assertIn("else log.scrollTop = Math.max(0, kbKeep.top + kbKeep.card - composerEl.getBoundingClientRect().top);", HTML)
        for caller in ("  rememberLogPosition();\n  const lift = kbGuess();",
                       "  rememberLogPosition();\n  const tick = () => {",
                       "box.addEventListener('blur', () => { rememberLogPosition();"):
            self.assertIn(caller, HTML)

    def test_rows_skipped_by_the_observer_are_drawn_after_the_keyboard_settles(self):
        self.assertIn("function unfarNearRows() {", HTML)
        self.assertIn("      restoreLogPosition();\n      unfarNearRows();", HTML)


if __name__ == "__main__":
    unittest.main()
