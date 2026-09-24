import asyncio
import json
import unittest

from app import agent_sdk_client, llm_client
from app.agent_sdk_client import (
    bridge_events,
    build_bridge_payload,
    build_prompt,
    plan_turn,
    split_history,
    turns_digest,
)

REAL_STREAM_BRIDGE_CHAT = agent_sdk_client.stream_bridge_chat


async def _lines(rows):
    for row in rows:
        yield row


async def _collect(generator):
    return [event async for event in generator]


def _run(coro):
    return asyncio.run(coro)


class SplitHistoryTest(unittest.TestCase):
    def test_pulls_system_text_out_of_the_turns(self):
        system, turns, context = split_history([
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "system", "content": "说中文"},
            {"role": "user", "content": "在吗"},
        ])

        self.assertEqual(system, "你是 Cloudy\n\n说中文")
        self.assertEqual(turns, [("用户", "在吗")])
        self.assertEqual(context, [])

    def test_system_after_the_history_is_this_turn_s_context(self):
        # 设备时间这类每轮都变的东西排在历史之后，不能混进 system，
        # 否则会话指纹每轮都对不上，resume 永远不会生效。
        system, turns, context = split_history([
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "user", "content": "在吗"},
            {"role": "system", "content": "【用户设备时间】17:36"},
        ])

        self.assertEqual(system, "你是 Cloudy")
        self.assertEqual(turns, [("用户", "在吗")])
        self.assertEqual(context, ["【用户设备时间】17:36"])

    def test_keeps_tool_results_as_context_and_drops_empty_turns(self):
        _, turns, _ = split_history([
            {"role": "user", "content": "查一下"},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "1"}]},
            {"role": "tool", "content": "结果是 3", "tool_call_id": "1"},
            {"role": "assistant", "content": "是 3"},
        ])

        self.assertEqual(turns, [
            ("用户", "查一下"),
            ("工具结果", "结果是 3"),
            ("助手", "是 3"),
        ])

    def test_ignores_thinking_parts_and_unknown_roles(self):
        _, turns, _ = split_history([
            {"role": "developer", "content": "不该出现"},
            {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "先想想"},
                {"type": "text", "text": "想好了"},
            ]},
        ])

        self.assertEqual(turns, [("助手", "想好了")])


class BuildPromptTest(unittest.TestCase):
    def test_single_user_turn_is_sent_verbatim(self):
        self.assertEqual(build_prompt([("用户", "在吗")]), "在吗")

    def test_history_is_wrapped_and_the_latest_turn_stays_outside(self):
        prompt = build_prompt([
            ("用户", "在吗"),
            ("助手", "在"),
            ("用户", "那再说一句"),
        ])

        self.assertEqual(prompt, (
            "<对话记录>\n用户：在吗\n\n助手：在\n</对话记录>\n\n那再说一句"
        ))

    def test_asks_to_continue_when_the_last_turn_is_not_the_user(self):
        prompt = build_prompt([("用户", "在吗"), ("助手", "在")])

        self.assertTrue(prompt.endswith("请接着上面的对话继续回应。"))
        self.assertIn("助手：在", prompt)

    def test_empty_history_makes_no_prompt(self):
        self.assertEqual(build_prompt([]), "")


class BridgePayloadTest(unittest.TestCase):
    def test_builds_the_bridge_shape_from_neutral_history(self):
        payload = build_bridge_payload("sonnet", [
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "user", "content": "在吗"},
        ], reasoning_effort=" high ")

        self.assertEqual(payload["model"], "sonnet")
        self.assertEqual(payload["system"], "你是 Cloudy")
        self.assertEqual(payload["prompt"], "在吗")
        self.assertTrue(payload["include_thinking"])
        self.assertEqual(payload["max_turns"], 1)
        self.assertEqual(payload["effort"], "high")

    def test_tools_only_widen_the_turn_budget_and_are_not_forwarded(self):
        payload = build_bridge_payload(
            "sonnet",
            [{"role": "user", "content": "在吗"}],
            [{"type": "function", "function": {"name": "mcp__ombre__breath"}}],
        )

        self.assertEqual(payload["max_turns"], 8)
        self.assertNotIn("tools", payload)

    def test_disabled_thinking_still_carries_the_effort(self):
        # effort 关掉 thinking 时也管花多少 token；哪些组合能用由桥接判断。
        payload = build_bridge_payload(
            "sonnet", [{"role": "user", "content": "在吗"}],
            reasoning_effort="high", thinking_enabled=False,
        )

        self.assertFalse(payload["include_thinking"])
        self.assertEqual(payload["effort"], "high")

    def test_max_tokens_becomes_a_length_note_in_the_system_prompt(self):
        payload = build_bridge_payload(
            "sonnet",
            [{"role": "system", "content": "你是 Cloudy"},
             {"role": "user", "content": "总结一下"}],
            max_tokens=700,
        )

        self.assertEqual(payload["system"], "你是 Cloudy\n\n请把回复控制在大约 700 个 token 以内。")

    def test_length_note_is_skipped_when_no_budget_is_given(self):
        payload = build_bridge_payload(
            "sonnet", [{"role": "user", "content": "在吗"}], max_tokens=0,
        )

        self.assertEqual(payload["system"], "")


class BridgeEventsTest(unittest.TestCase):
    def test_translates_text_thinking_and_usage(self):
        rows = [
            'data: {"type":"text","text":"你"}',
            "",
            'data: {"type":"thinking","thinking":"先想想"}',
            'data: {"type":"text","text":"好"}',
            'data: {"type":"usage","usage":{"input_tokens":10,"output_tokens":4,'
            '"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}',
            "data: [DONE]",
        ]

        events = _run(_collect(bridge_events(_lines(rows))))

        self.assertEqual(events[0], {"type": "text", "text": "你"})
        self.assertEqual(events[1], {"type": "thinking", "thinking": "先想想"})
        self.assertEqual(events[2], {"type": "text", "text": "好"})
        usage = events[3]["usage"]
        self.assertEqual(usage["input_tokens"], 10)
        self.assertEqual(usage["output_tokens"], 4)
        self.assertEqual(usage["cached_tokens"], 2)
        self.assertEqual(usage["cache_write_tokens"], 1)
        self.assertEqual(usage["total_tokens"], 17)

    def test_subscription_cost_never_reaches_dwell_accounting(self):
        row = "data: " + json.dumps({
            "type": "usage",
            "usage": {"input_tokens": 10, "output_tokens": 4, "cost": 0.42},
        })

        events = _run(_collect(bridge_events(_lines([row]))))

        self.assertNotIn("cost", events[0]["usage"])
        self.assertNotIn("upstream_cost", events[0]["usage"])

    def test_error_stops_the_stream_and_stays_internal(self):
        rows = [
            'data: {"type":"error","message":"Claude Code 没起来"}',
            'data: {"type":"text","text":"不该出现"}',
        ]

        events = _run(_collect(bridge_events(_lines(rows))))

        # bridge_error 由上层决定是重试还是显示，不直接变成气泡。
        self.assertEqual(events, [
            {"type": "bridge_error", "message": "Claude Code 没起来"},
        ])

    def test_session_id_comes_through_as_an_internal_event(self):
        rows = ['data: {"type":"session","session_id":"abc-123"}']

        events = _run(_collect(bridge_events(_lines(rows))))

        self.assertEqual(events, [
            {"type": "agent_session", "session_id": "abc-123"},
        ])

    def test_skips_blank_lines_and_broken_json(self):
        rows = ["", "data:", "data: {broken", 'data: {"type":"text","text":"在"}']

        events = _run(_collect(bridge_events(_lines(rows))))

        self.assertEqual(events, [{"type": "text", "text": "在"}])


class PlanTurnTest(unittest.TestCase):
    def setUp(self):
        self.turns = [("用户", "在吗"), ("助手", "在")]
        self.system = "你是 Cloudy"
        self.state = {
            "sid": "sess-1",
            "model": "sonnet",
            "sys": turns_digest([("system", self.system)]),
            "n": 2,
            "turns": turns_digest(self.turns),
        }

    def _next(self, extra):
        return self.turns + extra

    def test_resumes_and_only_sends_the_new_user_turn(self):
        turns = self._next([("助手", "在"), ("用户", "再说一句")])

        sid, outgoing = plan_turn(self.state, "sonnet", self.system, turns)

        self.assertEqual(sid, "sess-1")
        # 它自己那条回复它已经记着了，不该再抄回去。
        self.assertEqual(outgoing, [("用户", "再说一句")])

    def test_no_state_starts_from_scratch(self):
        sid, outgoing = plan_turn(None, "sonnet", self.system, self.turns)

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, self.turns)

    def test_changed_model_starts_from_scratch(self):
        turns = self._next([("助手", "在"), ("用户", "再说一句")])

        sid, outgoing = plan_turn(self.state, "claude-opus-4-6", self.system, turns)

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, turns)

    def test_changed_system_starts_from_scratch(self):
        # system 里有记忆卡，续上的会话看不到新的，所以必须重讲。
        turns = self._next([("助手", "在"), ("用户", "再说一句")])

        sid, outgoing = plan_turn(self.state, "sonnet", "你是 Cloudy，她刚体检", turns)

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, turns)

    def test_edited_history_starts_from_scratch(self):
        turns = [("用户", "在吗吗吗"), ("助手", "在"), ("用户", "再说一句")]

        sid, outgoing = plan_turn(self.state, "sonnet", self.system, turns)

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, turns)

    def test_deleted_history_starts_from_scratch(self):
        sid, outgoing = plan_turn(self.state, "sonnet", self.system, [("用户", "在吗")])

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, [("用户", "在吗")])

    def test_nothing_new_to_say_starts_from_scratch(self):
        # 重新生成：没有新的用户轮次，续上去会让它对着空气说话。
        turns = self._next([("助手", "在")])

        sid, outgoing = plan_turn(self.state, "sonnet", self.system, turns)

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, turns)


class BridgePayloadResumeTest(unittest.TestCase):
    def test_resuming_sends_only_the_new_turn(self):
        messages = [
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "user", "content": "在吗"},
            {"role": "assistant", "content": "在"},
            {"role": "user", "content": "再说一句"},
        ]
        state = {
            "sid": "sess-1",
            "model": "sonnet",
            "sys": turns_digest([("system", "你是 Cloudy")]),
            "n": 1,
            "turns": turns_digest([("用户", "在吗")]),
        }

        payload = build_bridge_payload("sonnet", messages, state=state)

        self.assertEqual(payload["resume"], "sess-1")
        self.assertEqual(payload["prompt"], "再说一句")
        self.assertNotIn("对话记录", payload["prompt"])

    def test_without_state_the_whole_history_is_flattened(self):
        messages = [
            {"role": "user", "content": "在吗"},
            {"role": "assistant", "content": "在"},
            {"role": "user", "content": "再说一句"},
        ]

        payload = build_bridge_payload("sonnet", messages)

        self.assertNotIn("resume", payload)
        self.assertIn("对话记录", payload["prompt"])

    def test_bookkeeping_fields_are_stripped_before_sending(self):
        payload = build_bridge_payload("sonnet", [{"role": "user", "content": "在吗"}])

        self.assertIn("_turns", payload)
        self.assertIn("_system", payload)
        sent = {k: v for k, v in payload.items() if not k.startswith("_")}
        self.assertNotIn("_turns", sent)
        self.assertNotIn("_system", sent)


class StreamChatDispatchTest(unittest.TestCase):
    def test_agent_sdk_provider_skips_the_api_key_requirement(self):
        seen = {}

        async def fake_bridge(provider, model_id, messages, tools=None, **kwargs):
            seen["provider"] = provider
            seen["model_id"] = model_id
            seen["kwargs"] = kwargs
            yield {"type": "text", "text": "在"}

        agent_sdk_client.stream_bridge_chat = fake_bridge
        try:
            events = _run(_collect(llm_client.stream_chat(
                {"provider_type": "claude_agent_sdk",
                 "base_url": "http://127.0.0.1:8787",
                 "api_key_box": ""},
                "sonnet",
                [{"role": "user", "content": "在吗"}],
                agent_session_key="dwell-chat:abc",
            )))
        finally:
            agent_sdk_client.stream_bridge_chat = REAL_STREAM_BRIDGE_CHAT

        # 没有 api_key_box 也不该退化成「还没有保存 API 密钥」的配置错误。
        self.assertEqual(events, [{"type": "text", "text": "在"}])
        self.assertEqual(seen["model_id"], "sonnet")
        self.assertEqual(seen["kwargs"]["session_key"], "dwell-chat:abc")

    def test_other_providers_still_require_a_key(self):
        events = _run(_collect(llm_client.stream_chat(
            {"provider_type": "generic", "base_url": "https://example.test/v1",
             "api_key_box": ""},
            "example/model",
            [{"role": "user", "content": "在吗"}],
        )))

        self.assertEqual(len(events), 1)
        self.assertIn("还没有保存 API 密钥", events[0]["text"])


if __name__ == "__main__":
    unittest.main()
