"""重写规则：它说完、还没交出来之前拦一道。

规则是全局的——这是 Cloudy 怎么说话的事，不属于某一个窗口。
"""

import asyncio
import tempfile
import unittest
from pathlib import Path

from app import db
from app.agent_sdk_client import bridge_events, build_bridge_payload

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "bridge" / "server.mjs").read_text(encoding="utf-8")
HTML = (ROOT / "static" / "index.html").read_text(encoding="utf-8")
MAIN = (ROOT / "app" / "main.py").read_text(encoding="utf-8")


class RewriteRuleStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = db.DB_PATH
        db.DB_PATH = str(Path(self.tmp.name) / "rules.db")
        db.init_db()

    def tearDown(self):
        db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def test_a_saved_rule_comes_back_whole(self):
        rule = db.rewrite_rule_upsert("", ["我就在这里", "哪也不去"], "别用现成的安慰句。")

        stored = db.rewrite_rule_list()

        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]["phrases"], ["我就在这里", "哪也不去"])
        self.assertEqual(stored[0]["reason"], "别用现成的安慰句。")
        self.assertTrue(stored[0]["enabled"])
        self.assertEqual(stored[0]["id"], rule["id"])

    def test_editing_keeps_the_same_rule(self):
        rule = db.rewrite_rule_upsert("", ["我就在这里"], "太现成了。")

        db.rewrite_rule_upsert(rule["id"], ["哪也不去"], "换一句。", enabled=False)

        stored = db.rewrite_rule_list()
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]["phrases"], ["哪也不去"])
        self.assertFalse(stored[0]["enabled"])

    def test_a_rule_without_phrases_is_refused(self):
        # 空短语的规则会拦下每一句话——它谁都不放过。
        with self.assertRaises(ValueError):
            db.rewrite_rule_upsert("", ["", "   "], "随便写点什么")

    def test_a_rule_without_a_reason_is_refused(self):
        # 只说「不许这么讲」，它不知道往哪儿改，多半换个同样现成的说法。
        with self.assertRaises(ValueError):
            db.rewrite_rule_upsert("", ["我就在这里"], "  ")

    def test_duplicate_phrases_collapse(self):
        rule = db.rewrite_rule_upsert("", ["我就在这里", "我就在这里"], "别用现成的安慰句。")
        self.assertEqual(rule["phrases"], ["我就在这里"])

    def test_the_off_switch_keeps_the_rule_but_stops_it_firing(self):
        rule = db.rewrite_rule_upsert("", ["我就在这里"], "别用现成的安慰句。")
        db.rewrite_rule_upsert(rule["id"], ["我就在这里"], "别用现成的安慰句。", enabled=False)

        self.assertEqual(len(db.rewrite_rule_list()), 1)
        self.assertEqual(db.rewrite_rule_list(enabled_only=True), [])

    def test_deleting_says_whether_it_found_anything(self):
        rule = db.rewrite_rule_upsert("", ["我就在这里"], "别用现成的安慰句。")

        self.assertTrue(db.rewrite_rule_delete(rule["id"]))
        self.assertFalse(db.rewrite_rule_delete(rule["id"]))
        self.assertEqual(db.rewrite_rule_list(), [])

    def test_there_is_a_ceiling(self):
        for index in range(db.REWRITE_RULE_MAX):
            db.rewrite_rule_upsert("", [f"第{index}句"], "理由")

        with self.assertRaises(ValueError):
            db.rewrite_rule_upsert("", ["再来一条"], "理由")


class RewriteRulePayloadTest(unittest.TestCase):
    """规则每轮都重新带过去，改完下一句就生效。"""

    MESSAGES = [
        {"role": "system", "content": "你是 Cloudy。"},
        {"role": "user", "content": "在吗"},
    ]

    def test_rules_ride_along_with_the_turn(self):
        payload = build_bridge_payload(
            "sonnet", self.MESSAGES,
            rewrite_rules=[{"phrases": ["我就在这里"], "reason": "别用现成的安慰句。"}],
        )

        self.assertEqual(payload["rewrite_rules"],
                         [{"phrases": ["我就在这里"], "reason": "别用现成的安慰句。"}])

    def test_no_rules_means_the_key_is_absent(self):
        payload = build_bridge_payload("sonnet", self.MESSAGES)
        self.assertNotIn("rewrite_rules", payload)

    def test_a_half_written_rule_never_leaves_dwell(self):
        # 没短语的会拦下一切，没理由的它不知道往哪儿改——两种都别送过去。
        payload = build_bridge_payload("sonnet", self.MESSAGES, rewrite_rules=[
            {"phrases": [], "reason": "有理由但没触发词"},
            {"phrases": ["有触发词但没理由"], "reason": "  "},
        ])
        self.assertNotIn("rewrite_rules", payload)

    def test_rules_do_not_touch_the_system_prompt_or_the_digest(self):
        # 规则是收尾时的一道关卡，不是上下文。混进 system 就会每改一次规则
        # 都重建一次缓存，而且续会话再也对不上。
        plain = build_bridge_payload("sonnet", self.MESSAGES)
        guarded = build_bridge_payload(
            "sonnet", self.MESSAGES,
            rewrite_rules=[{"phrases": ["我就在这里"], "reason": "别用现成的安慰句。"}],
        )

        self.assertEqual(plain["system"], guarded["system"])
        self.assertEqual(plain["prompt"], guarded["prompt"])
        self.assertEqual(plain["_turns"], guarded["_turns"])


class ResetEventTest(unittest.TestCase):
    """打回之后已经吐出去的那一版要抹掉，否则两版首尾相接。"""

    @staticmethod
    def _collect(lines):
        async def run():
            async def feed():
                for line in lines:
                    yield line
            return [event async for event in bridge_events(feed())]
        return asyncio.run(run())

    def test_reset_comes_through_as_its_own_event(self):
        events = self._collect([
            'data: {"type":"text","text":"我就在这里"}',
            'data: {"type":"reset"}',
            'data: {"type":"text","text":"周四那份体检报告我还记着"}',
        ])

        self.assertEqual([event["type"] for event in events], ["text", "reset", "text"])

    def test_the_notice_goes_to_the_thinking_panel_not_the_reply(self):
        events = self._collect(['data: {"type":"notice","message":"打回重说：撞到了「我就在这里」"}'])

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["type"], "thinking")
        self.assertIn("打回重说", events[0]["thinking"])


class ResetWipesTheFirstVersionTest(unittest.TestCase):
    """后端收到 reset 要把这一轮已经落库的气泡收回去，不能只清内存。"""

    def test_the_reply_loop_handles_reset(self):
        self.assertIn('elif event["type"] == "reset":\n                    reset_stream()', MAIN)

    def test_reset_takes_back_the_split_bubbles_too(self):
        body = MAIN[MAIN.index("    def reset_stream():"):MAIN.index("    def consume_stream_chunk(")]
        self.assertIn("for extra in reply_message_ids[1:]:", body)
        self.assertIn("db.message_delete(extra)", body)
        self.assertIn('db.message_update(msg_id, "")', body)
        self.assertIn('"type": "assistant_reset"', body)

    def test_the_guard_is_only_on_where_cloudy_is_speaking(self):
        # 生成摘要、出 JSON、写观影笔记的那几次调用不是说给她听的，不该被打回。
        self.assertEqual(MAIN.count("rewrite_guard=True"), 2)


class BridgeHookTest(unittest.TestCase):
    """桥接侧：Stop 钩子是这条通道独有的位置。"""

    def test_the_hook_is_wired_to_stop(self):
        self.assertIn("options.hooks = {", BRIDGE)
        self.assertIn("Stop: [{", BRIDGE)
        self.assertIn("reason = blockReason(breach);", BRIDGE)
        self.assertIn('return { decision: "block", reason };', BRIDGE)

    def test_voice_replies_are_held_to_english(self):
        self.assertIn("if (requireEnglish && hasCjk(text)) {", BRIDGE)
        self.assertIn("if (rules.length || requireEnglish) {", BRIDGE)

    def test_it_only_blocks_once(self):
        # 再拦下去就没完没了——它可能根本绕不开那句话。
        self.assertIn("if (input.stop_hook_active) return {};", BRIDGE)

    def test_blocking_costs_a_turn_and_maxturns_makes_room(self):
        self.assertIn("options.maxTurns += 1;", BRIDGE)

    def test_it_tells_dwell_to_wipe_the_first_version(self):
        self.assertIn('writeEvent(res, { type: "reset" });', BRIDGE)

    def test_half_written_rules_are_dropped_at_the_bridge_too(self):
        self.assertIn(".filter((rule) => rule.phrases.length && rule.reason);", BRIDGE)


class RewriteRuleConsoleTest(unittest.TestCase):
    """改一次规则就要改一次代码的话，这功能等于没有。"""

    def test_the_settings_menu_has_a_way_in(self):
        self.assertIn('id="rewriteRulesRow"', HTML)
        self.assertIn('id="rewriteRulesSheet"', HTML)
        self.assertIn("rewriteRules: document.getElementById('rewriteRulesSheet'),", HTML)

    def test_a_rule_is_a_phrase_list_plus_a_reason(self):
        self.assertIn("rewrite-phrases", HTML)
        self.assertIn("rewrite-reason", HTML)
        self.assertIn("＋ 加一条规则", HTML)

    def test_the_front_end_erases_the_first_version(self):
        self.assertIn("if (d.type === 'assistant_reset') {", HTML)
        self.assertIn("for (const r of turnBubbles) r.remove();", HTML)

    def test_the_bubbles_of_this_turn_are_tracked_and_cleared(self):
        self.assertIn("turnBubbles.push(r);", HTML)
        # 每轮收尾都要清空，否则下一轮的 reset 会把上一轮说过的话也抹掉。
        self.assertGreaterEqual(HTML.count("turnBubbles = [];"), 5)


if __name__ == "__main__":
    unittest.main()
