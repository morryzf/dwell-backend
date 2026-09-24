import asyncio
import json
import unittest

from app import agent_sdk_client, llm_client
from app.agent_sdk_client import (
    bridge_events,
    build_bridge_payload,
    build_prompt,
    split_history,
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
        system, turns = split_history([
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "system", "content": "说中文"},
            {"role": "user", "content": "在吗"},
        ])

        self.assertEqual(system, "你是 Cloudy\n\n说中文")
        self.assertEqual(turns, [("用户", "在吗")])

    def test_keeps_tool_results_as_context_and_drops_empty_turns(self):
        _, turns = split_history([
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
        _, turns = split_history([
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
        ], reasoning_effort=" high ", session_id="dwell-chat:abc")

        self.assertEqual(payload["model"], "sonnet")
        self.assertEqual(payload["system"], "你是 Cloudy")
        self.assertEqual(payload["prompt"], "在吗")
        self.assertTrue(payload["include_thinking"])
        self.assertEqual(payload["max_turns"], 1)
        self.assertEqual(payload["effort"], "high")
        self.assertEqual(payload["session_id"], "dwell-chat:abc")

    def test_tools_only_widen_the_turn_budget_and_are_not_forwarded(self):
        payload = build_bridge_payload(
            "sonnet",
            [{"role": "user", "content": "在吗"}],
            [{"type": "function", "function": {"name": "mcp__ombre__breath"}}],
        )

        self.assertEqual(payload["max_turns"], 8)
        self.assertNotIn("tools", payload)

    def test_disabled_thinking_drops_the_effort(self):
        payload = build_bridge_payload(
            "sonnet", [{"role": "user", "content": "在吗"}],
            reasoning_effort="high", thinking_enabled=False,
        )

        self.assertFalse(payload["include_thinking"])
        self.assertNotIn("effort", payload)

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

    def test_error_surfaces_as_text_and_stops_the_stream(self):
        rows = [
            'data: {"type":"error","message":"Claude Code 没起来"}',
            'data: {"type":"text","text":"不该出现"}',
        ]

        events = _run(_collect(bridge_events(_lines(rows))))

        self.assertEqual(events, [
            {"type": "text", "text": "[桥接错误] Claude Code 没起来"},
        ])

    def test_skips_blank_lines_and_broken_json(self):
        rows = ["", "data:", "data: {broken", 'data: {"type":"text","text":"在"}']

        events = _run(_collect(bridge_events(_lines(rows))))

        self.assertEqual(events, [{"type": "text", "text": "在"}])


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
                session_id="dwell-chat:abc",
            )))
        finally:
            agent_sdk_client.stream_bridge_chat = REAL_STREAM_BRIDGE_CHAT

        # 没有 api_key_box 也不该退化成「还没有保存 API 密钥」的配置错误。
        self.assertEqual(events, [{"type": "text", "text": "在"}])
        self.assertEqual(seen["model_id"], "sonnet")
        self.assertEqual(seen["kwargs"]["session_id"], "dwell-chat:abc")

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
