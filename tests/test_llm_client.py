import unittest

from app.llm_client import _usage_dict, build_chat_payload


class ChatPayloadTest(unittest.TestCase):
    def test_builds_existing_provider_neutral_shape_without_enabling_cache(self):
        messages = [{"role": "user", "content": "hello"}]
        tools = [{"type": "function", "function": {"name": "Ping"}}]

        payload = build_chat_payload(
            "example/model",
            messages,
            tools,
            max_tokens=0,
            reasoning_effort=" high ",
        )

        self.assertEqual(payload["model"], "example/model")
        self.assertIs(payload["messages"], messages)
        self.assertIs(payload["tools"], tools)
        self.assertTrue(payload["stream"])
        self.assertEqual(payload["stream_options"], {"include_usage": True})
        self.assertEqual(payload["max_tokens"], 1)
        self.assertEqual(payload["reasoning_effort"], "high")
        self.assertNotIn("cache_control", payload)
        self.assertNotIn("session_id", payload)

    def test_omits_optional_fields_when_they_are_not_requested(self):
        payload = build_chat_payload("example/model", [])

        self.assertNotIn("tools", payload)
        self.assertNotIn("max_tokens", payload)
        self.assertNotIn("reasoning_effort", payload)


class UsageNormalizationTest(unittest.TestCase):
    def test_normalizes_openrouter_cache_and_cost_metrics(self):
        usage = _usage_dict({
            "prompt_tokens": 1200,
            "completion_tokens": 80,
            "total_tokens": 1280,
            "prompt_tokens_details": {
                "cached_tokens": 900,
                "cache_write_tokens": 250,
            },
            "completion_tokens_details": {"reasoning_tokens": 30},
            "cost": 0.01234567,
            "cost_details": {"upstream_inference_cost": 0.011},
        })

        self.assertEqual(usage, {
            "input_tokens": 1200,
            "output_tokens": 80,
            "total_tokens": 1280,
            "cached_tokens": 900,
            "cache_write_tokens": 250,
            "cache_write_5m_tokens": 0,
            "cache_write_1h_tokens": 0,
            "reasoning_tokens": 30,
            "cost": 0.01234567,
            "upstream_cost": 0.011,
        })

    def test_normalizes_anthropic_cache_breakdown(self):
        usage = _usage_dict({
            "input_tokens": 1000,
            "output_tokens": 20,
            "cache_read_input_tokens": 700,
            "cache_creation_input_tokens": 240,
            "cache_creation": {
                "ephemeral_5m_input_tokens": 40,
                "ephemeral_1h_input_tokens": 200,
            },
        })

        self.assertEqual(usage["total_tokens"], 1020)
        self.assertEqual(usage["cached_tokens"], 700)
        self.assertEqual(usage["cache_write_tokens"], 240)
        self.assertEqual(usage["cache_write_5m_tokens"], 40)
        self.assertEqual(usage["cache_write_1h_tokens"], 200)

    def test_does_not_invent_usage_when_provider_reports_no_tokens(self):
        self.assertEqual(_usage_dict({"cost": 1.5}), {})


if __name__ == "__main__":
    unittest.main()
