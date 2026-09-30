import asyncio
import json
import unittest

from app import agent_sdk_client, llm_client
from app.agent_sdk_client import (
    _anchor,
    bridge_events,
    build_bridge_payload,
    build_prompt,
    image_blocks,
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

    def test_rate_limit_notices_go_to_the_thinking_panel(self):
        # 限流说明不是回复的一部分，不该混进正文。
        rows = ['data: {"type":"notice","message":"上游暂时不可用，等 8 秒"}']

        events = _run(_collect(bridge_events(_lines(rows))))

        self.assertEqual(events, [
            {"type": "thinking", "thinking": "（上游暂时不可用，等 8 秒）\n"},
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
        anchor, size = _anchor(self.turns)
        self.state = {
            "sid": "sess-1",
            "model": "sonnet",
            "sys": turns_digest([("system", self.system)]),
            "anchor": anchor,
            "anchor_len": size,
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

    def test_a_sliding_window_still_resumes(self):
        """原文窗口聊满之后每轮都会挤掉最旧的几条，开头一直在变。

        早先的版本把指纹锚在开头，于是窗口一满就再也对不上——真实聊天里
        resume 从来没生效过，每轮都在重讲整段。
        """
        older = [("用户", f"旧的第{i}句") for i in range(5)]
        window_before = older + self.turns
        anchor, size = _anchor(window_before)
        state = {
            "sid": "sess-1", "model": "sonnet",
            "sys": turns_digest([("system", self.system)]),
            "anchor": anchor, "anchor_len": size,
        }
        # 下一轮：又说了两句，最旧的两条被挤出窗口
        window_after = window_before[2:] + [("助手", "在"), ("用户", "再说一句")]

        sid, outgoing = plan_turn(state, "sonnet", self.system, window_after)

        self.assertEqual(sid, "sess-1")
        self.assertEqual(outgoing, [("用户", "再说一句")])

    def test_state_written_by_an_older_version_just_starts_over(self):
        stale = {"sid": "sess-1", "model": "sonnet",
                 "sys": turns_digest([("system", self.system)]),
                 "n": 2, "turns": turns_digest(self.turns)}

        sid, outgoing = plan_turn(stale, "sonnet", self.system, self.turns)

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, self.turns)

    def test_nothing_new_to_say_starts_from_scratch(self):
        # 重新生成：没有新的用户轮次，续上去会让它对着空气说话。
        turns = self._next([("助手", "在")])

        sid, outgoing = plan_turn(self.state, "sonnet", self.system, turns)

        self.assertEqual(sid, "")
        self.assertEqual(outgoing, turns)


class ImageBlocksTest(unittest.TestCase):
    """之前图片被整个丢掉了：只取文字，image_url 块无声消失。"""

    IMG = {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}}

    def test_data_urls_become_base64_sources(self):
        blocks = image_blocks([{"role": "user", "content": [
            {"type": "text", "text": "这是什么"}, self.IMG,
        ]}])

        self.assertEqual(blocks, [
            {"type": "base64", "media_type": "image/jpeg", "data": "QUJD"},
        ])

    def test_http_urls_pass_through(self):
        blocks = image_blocks([{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": "https://example.test/a.png"}},
        ]}])

        self.assertEqual(blocks, [{"type": "url", "url": "https://example.test/a.png"}])

    def test_only_the_latest_user_turn_counts(self):
        # 原图只进这一轮的请求，历史里本来就没有图。
        blocks = image_blocks([
            {"role": "user", "content": [self.IMG]},
            {"role": "assistant", "content": "嗯"},
            {"role": "user", "content": "那这个呢"},
        ])

        self.assertEqual(blocks, [])

    def test_plain_text_turns_have_none(self):
        self.assertEqual(image_blocks([{"role": "user", "content": "在吗"}]), [])

    def test_payload_carries_them_and_keeps_the_text(self):
        payload = build_bridge_payload("sonnet", [{"role": "user", "content": [
            {"type": "text", "text": "这是什么"}, self.IMG,
        ]}])

        self.assertEqual(payload["prompt"], "这是什么")
        self.assertEqual(len(payload["images"]), 1)

    def test_an_image_with_no_words_is_still_a_message(self):
        payload = build_bridge_payload(
            "sonnet", [{"role": "user", "content": [self.IMG]}],
        )

        self.assertEqual(payload["prompt"], "")
        self.assertEqual(len(payload["images"]), 1)

    def test_payload_omits_the_field_when_there_is_no_picture(self):
        payload = build_bridge_payload("sonnet", [{"role": "user", "content": "在吗"}])

        self.assertNotIn("images", payload)


class BridgePayloadResumeTest(unittest.TestCase):
    def test_resuming_sends_only_the_new_turn(self):
        messages = [
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "user", "content": "在吗"},
            {"role": "assistant", "content": "在"},
            {"role": "user", "content": "再说一句"},
        ]
        anchor, size = _anchor([("用户", "在吗")])
        state = {
            "sid": "sess-1",
            "model": "sonnet",
            "sys": turns_digest([("system", "你是 Cloudy")]),
            "anchor": anchor,
            "anchor_len": size,
            "cards": agent_sdk_client.memory_pool_version(),
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


def _card_message(*cards):
    """和 main._memory_card_blocks 同形：开头、每张卡一块、结尾。"""
    key = agent_sdk_client.MEMORY_CARD_KEY
    return {"role": "system", "content": [
        {"type": "text", "text": "【本轮按需取回的记忆卡】\n<cards>"},
        *({"type": "text", "text": f"- {text}", key: cid} for cid, text in cards),
        {"type": "text", "text": "</cards>"},
    ]}


def _resumable(seen_cards=None):
    history = [
        {"role": "system", "content": "你是 Cloudy"},
        {"role": "user", "content": "在吗"},
        {"role": "assistant", "content": "在"},
    ]
    anchor, size = _anchor([("用户", "在吗")])
    state = {
        "sid": "sess-1",
        "model": "sonnet",
        "sys": turns_digest([("system", "你是 Cloudy")]),
        "anchor": anchor,
        "anchor_len": size,
        "cards": agent_sdk_client.memory_pool_version(),
    }
    if seen_cards is not None:
        state["seen_cards"] = seen_cards
    return history, state


class MemoryCardDedupeTest(unittest.TestCase):
    """续会话时 Claude Code 记着递过的卡，同一段会话里不再重递。"""

    def test_resuming_only_sends_cards_this_session_has_not_seen(self):
        history, state = _resumable(seen_cards=["c1"])
        messages = history + [
            {"role": "user", "content": "今天吃什么"},
            _card_message(("c1", "喜欢吃辣"), ("c2", "最近在减脂")),
        ]

        payload = build_bridge_payload("sonnet", messages, state=state)

        self.assertEqual(payload["resume"], "sess-1")
        self.assertNotIn("喜欢吃辣", payload["prompt"])
        self.assertIn("最近在减脂", payload["prompt"])
        self.assertIn("【本轮按需取回的记忆卡】", payload["prompt"])
        self.assertTrue(payload["prompt"].endswith("今天吃什么"))

    def test_when_every_card_was_seen_the_card_note_is_left_out(self):
        history, state = _resumable(seen_cards=["c1", "c2"])
        messages = history + [
            {"role": "user", "content": "今天吃什么"},
            {"role": "system", "content": "【用户设备时间】周二"},
            _card_message(("c1", "喜欢吃辣"), ("c2", "最近在减脂")),
        ]

        payload = build_bridge_payload("sonnet", messages, state=state)

        self.assertNotIn("记忆卡", payload["prompt"])
        self.assertNotIn("<cards>", payload["prompt"])
        # 别的临时上下文照常走
        self.assertIn("【用户设备时间】周二", payload["prompt"])

    def test_a_fresh_session_gets_every_card_regardless_of_old_bookkeeping(self):
        history, state = _resumable(seen_cards=["c1", "c2"])
        state["model"] = "opus"          # 换了模型，只能从头讲
        messages = history + [
            {"role": "user", "content": "今天吃什么"},
            _card_message(("c1", "喜欢吃辣"), ("c2", "最近在减脂")),
        ]

        payload = build_bridge_payload("sonnet", messages, state=state)

        self.assertNotIn("resume", payload)
        self.assertIn("喜欢吃辣", payload["prompt"])
        self.assertIn("最近在减脂", payload["prompt"])
        self.assertEqual(payload["_seen_cards"], ["c1", "c2"])

    def test_bookkeeping_adds_this_turn_s_cards_to_what_the_session_has_seen(self):
        history, state = _resumable(seen_cards=["c0", "c1"])
        messages = history + [
            {"role": "user", "content": "今天吃什么"},
            _card_message(("c1", "喜欢吃辣"), ("c2", "最近在减脂")),
        ]

        payload = build_bridge_payload("sonnet", messages, state=state)

        self.assertEqual(payload["_seen_cards"], ["c0", "c1", "c2"])
        sent = {k for k in payload if not k.startswith("_")}
        self.assertNotIn("_seen_cards", sent)

    def test_state_without_the_field_is_treated_as_nothing_seen(self):
        history, state = _resumable()          # 旧版本写下的状态没有这个字段
        messages = history + [
            {"role": "user", "content": "今天吃什么"},
            _card_message(("c1", "喜欢吃辣")),
        ]

        payload = build_bridge_payload("sonnet", messages, state=state)

        self.assertEqual(payload["resume"], "sess-1")
        self.assertIn("喜欢吃辣", payload["prompt"])

    def test_plain_messages_pass_through_untouched(self):
        messages = [
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "user", "content": [{"type": "text", "text": "看图"}]},
        ]
        self.assertEqual(agent_sdk_client.forget_seen_cards(messages, {"c1"}), messages)
        self.assertEqual(agent_sdk_client.offered_cards(messages), set())


class CompactionBookkeepingTest(unittest.TestCase):
    def test_bridge_compaction_becomes_an_internal_event(self):
        rows = ['data: {"type": "compacted"}', 'data: {"type": "text", "text": "在"}']
        events = _run(_collect(bridge_events(_lines(rows))))
        self.assertEqual(events, [{"type": "agent_compacted"}, {"type": "text", "text": "在"}])

    def _run_turn(self, bridge_rows):
        history, state = _resumable(seen_cards=["c1"])
        messages = history + [
            {"role": "user", "content": "今天吃什么"},
            _card_message(("c2", "最近在减脂")),
        ]
        saved = {}
        originals = (agent_sdk_client._attempt, agent_sdk_client.load_state,
                     agent_sdk_client.save_state)

        async def fake_attempt(client, url, headers, payload, box):
            for row in bridge_rows:
                yield row

        def fake_save(chat_key, sid, model_id, system, turns, cards="", seen_cards=None):
            saved["sid"] = sid
            saved["seen_cards"] = seen_cards

        agent_sdk_client._attempt = fake_attempt
        agent_sdk_client.load_state = lambda key: state
        agent_sdk_client.save_state = fake_save
        try:
            events = _run(_collect(agent_sdk_client.stream_bridge_chat(
                {"base_url": "http://127.0.0.1:8787", "api_key_box": ""},
                "sonnet", messages, session_key="dwell-chat:abc",
            )))
        finally:
            (agent_sdk_client._attempt, agent_sdk_client.load_state,
             agent_sdk_client.save_state) = originals
        return events, saved

    def test_a_normal_turn_remembers_every_card_the_session_now_holds(self):
        events, saved = self._run_turn([
            {"type": "agent_session", "session_id": "sess-1"},
            {"type": "text", "text": "吃点清淡的"},
        ])
        self.assertEqual(events, [{"type": "text", "text": "吃点清淡的"}])
        self.assertEqual(saved["seen_cards"], ["c1", "c2"])

    def test_after_compaction_every_card_is_offered_again(self):
        events, saved = self._run_turn([
            {"type": "agent_session", "session_id": "sess-1"},
            {"type": "agent_compacted"},
            {"type": "text", "text": "吃点清淡的"},
        ])
        # 压缩是内部记账，不该漏给前端
        self.assertEqual(events, [{"type": "text", "text": "吃点清淡的"}])
        self.assertEqual(saved["seen_cards"], [])


if __name__ == "__main__":
    unittest.main()
