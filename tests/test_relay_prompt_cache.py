"""OpenAI 兼容的中转上用 Claude 模型时，也能按聊天开缓存。

标记的写法和 OpenRouter 一样，放在消息内容块上，由中转往下转。中转不认这个
字段、回 400 时，去掉标记再发一次——这一轮只是没缓存，话照样说得出去。
"""

import asyncio
import json
import unittest
from pathlib import Path

import httpx

from app import main
from app.llm_client import _stream_openai, build_chat_payload, prompt_cache_enabled

RELAY = {"base_url": "https://relay.example/v1", "provider_type": "generic", "prompt_cache_ttl": "1h"}
UI = Path("static/index.html").read_text(encoding="utf-8")


def reply(text):
    chunk = {"choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}]}
    return httpx.Response(200, text=f"data: {json.dumps(chunk)}\n\ndata: [DONE]\n\n",
                          headers={"Content-Type": "text/event-stream"})


def run(responses):
    sent = []

    def handler(request):
        sent.append(json.loads(request.content))
        return responses[len(sent) - 1]

    async def collect():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return [event async for event in _stream_openai(
                client, RELAY, "key", "claude-sonnet-4",
                [{"role": "assistant", "content": "anchor"}], None,
                None, None, True, "dwell-chat:x",
            )]

    return asyncio.run(collect()), sent


class RelayPromptCacheTest(unittest.TestCase):
    def test_claude_models_on_a_relay_get_the_cache_marker(self):
        payload = build_chat_payload(
            "claude-sonnet-4", [{"role": "assistant", "content": "anchor"}],
            provider=RELAY, session_id="dwell-chat:x",
        )
        self.assertEqual(payload["messages"][0]["content"][0]["cache_control"],
                         {"type": "ephemeral", "ttl": "1h"})
        # session_id 只是 OpenRouter 的字段，不往中转发
        self.assertNotIn("session_id", payload)

    def test_other_models_on_a_relay_stay_untouched(self):
        self.assertFalse(prompt_cache_enabled(RELAY, "gpt-4o"))
        self.assertTrue(prompt_cache_enabled(RELAY, "claude-sonnet-4"))

    def test_per_chat_choice_is_kept_for_relays(self):
        selection = {"prompt_cache_ttl": "5m", "model_id": "claude-opus-4"}
        self.assertEqual(main._chat_prompt_cache_ttl(selection, RELAY), "5m")
        self.assertEqual(main._chat_prompt_cache_ttl({**selection, "model_id": "gpt-4o"}, RELAY), "off")

    def test_a_relay_that_rejects_the_marker_gets_the_turn_without_it(self):
        events, sent = run([httpx.Response(400, json={"error": "unknown field cache_control"}), reply("好")])
        self.assertEqual("".join(e.get("text", "") for e in events if e["type"] == "text"), "好")
        self.assertIn("cache_control", json.dumps(sent[0]))
        self.assertNotIn("cache_control", json.dumps(sent[1]))
        status = next(e for e in events if e["type"] == "cache_status")
        self.assertEqual(status["fallback_reason"], "relay_rejected_cache_control")

    def test_cache_picker_sits_at_the_top_of_the_model_panel(self):
        main_view = UI.split("if (pickerView === 'main') {", 1)[1].split("} else if", 1)[0]
        self.assertLess(main_view.index("renderPromptCachePicker()"), main_view.index("splitFavorites()"))
        self.assertNotIn("pickerView = 'cache'", UI)
        self.assertIn("const relayOrNative = ['claude_compatible', 'generic'];", UI)


if __name__ == "__main__":
    unittest.main()
