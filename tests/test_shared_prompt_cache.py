from pathlib import Path
import unittest


class SharedPromptCacheSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (
            Path(__file__).parents[1] / "app" / "main.py"
        ).read_text(encoding="utf-8")

    def test_chat_and_heartbeat_share_stable_prefix_builders(self):
        self.assertIn("def _chat_stable_message_parts(", self.source)
        self.assertIn(
            "return _chat_stable_messages(chat_id) + _chat_history_messages(chat_id) + [trigger]",
            self.source,
        )
        self.assertIn("_chat_history_messages_from_rows(history)", self.source)
        self.assertIn(
            "split_replies, instructions, format_preference, memory_message = (",
            self.source,
        )

    def test_chat_and_heartbeat_share_the_complete_tool_surface(self):
        self.assertEqual(self.source.count("await _chat_tools(chat_id)"), 2)
        self.assertIn('name not in readable_tools', self.source)
        self.assertIn('server == "builtin:search"', self.source)
        self.assertIn('server == "builtin:home"', self.source)

    def test_heartbeat_reuses_chat_sticky_session(self):
        heartbeat = self.source[
            self.source.index("async def _heartbeat_decide"):
            self.source.index("async def _heartbeat_once")
        ]
        self.assertIn('session_id=f"dwell-chat:{chat_id}" if cache_friendly else None', heartbeat)
        self.assertIn("prompt_cache_enabled(provider, selection[\"model_id\"])", heartbeat)

    def test_proactive_watch_keeps_dynamic_context_after_the_anchor(self):
        reply = self.source[
            self.source.index("async def _run_ai_reply"):
            self.source.index("@app.post(\"/api/send\"")
        ]
        self.assertNotIn("not proactive_watch\n        and provider", reply)
        self.assertIn("messages = stable_messages + history_messages", reply)
        self.assertIn("_transient_context_blocks(transient_messages)", reply)
        self.assertIn("messages.append({\"role\": \"user\", \"content\": proactive_content})", reply)

    def test_watch_context_preserves_structured_user_content(self):
        self.assertIn("if isinstance(existing, list)", self.source)
        self.assertIn('content.append({"type": "text", "text": note})', self.source)
        self.assertNotIn(
            'str(messages[index]["content"]) + note',
            self.source,
        )


if __name__ == "__main__":
    unittest.main()
