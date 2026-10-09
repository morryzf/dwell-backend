from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from app import main


class SharedPromptCacheSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (
            Path(__file__).parents[1] / "app" / "main.py"
        ).read_text(encoding="utf-8")

    def test_chat_and_heartbeat_share_stable_prefix_builders(self):
        self.assertIn("def _chat_stable_message_parts(", self.source)
        self.assertIn(
            "_chat_history_messages(chat_id, cache_friendly=cache_friendly)",
            self.source,
        )
        self.assertIn("_chat_history_rows(chat_id, cache_friendly)", self.source)
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
        # 心跳和聊天同一套判断：Claude 开了缓存，或模型本来就自动缓存（GPT）
        self.assertIn("_prefix_stable(provider, selection[\"model_id\"])", heartbeat)

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


class SharedPromptCacheBehaviorTest(unittest.TestCase):
    def test_transient_context_stays_after_the_stable_assistant_anchor(self):
        stable = [{"role": "system", "content": "identity"}]
        transient = [{"role": "system", "content": "current clock"}]
        history = [
            {"role": "user", "content": "old question"},
            {"role": "assistant", "content": "stable answer"},
            {"role": "user", "content": "new question"},
        ]

        prepared = main._cache_friendly_chat_messages(stable, transient, history)

        self.assertEqual(prepared[:3], stable + history[:2])
        self.assertEqual(prepared[-1]["role"], "user")
        self.assertIn("current clock", prepared[-1]["content"][0]["text"])
        self.assertEqual(prepared[-1]["content"][-1]["text"], "new question")
        self.assertEqual(history[-1]["content"], "new question")

    def test_heartbeat_appends_one_dynamic_trigger_after_the_shared_prefix(self):
        stable = [{"role": "system", "content": "identity"}]
        history = [{"role": "assistant", "content": "last answer"}]
        now = datetime(2026, 9, 3, 9, 30, tzinfo=timezone.utc)
        with (
            patch.object(main, "_chat_stable_messages", return_value=stable),
            patch.object(
                main, "_chat_history_messages", return_value=history
            ) as history_messages,
            patch.object(main.db, "message_last_made", side_effect=[1, 2]),
        ):
            prepared = main._heartbeat_context(
                "chat-1", now, 120, cache_friendly=True
            )

        history_messages.assert_called_once_with(
            "chat-1", cache_friendly=True
        )
        self.assertEqual(prepared[:-1], stable + history)
        self.assertEqual(prepared[-1]["role"], "user")
        self.assertIn("2026-09-03 09:30", prepared[-1]["content"])
        self.assertIn("[NO_ACTION]", prepared[-1]["content"])

    def test_heartbeat_tool_filter_rejects_mutations_but_keeps_reads(self):
        read = {"function": {"name": "DiarySearch", "description": "Read diary entries"}}
        write = {"function": {"name": "DiaryCreate", "description": "Create an entry"}}
        toggle = next(
            tool for tool in main.HOME_TOOLS
            if tool["function"]["name"] == "DwellTodoToggle"
        )
        todo_list = next(
            tool for tool in main.HOME_TOOLS
            if tool["function"]["name"] == "DwellTodoList"
        )

        self.assertTrue(main._heartbeat_read_tool(read))
        self.assertFalse(main._heartbeat_read_tool(write))
        self.assertFalse(main._heartbeat_tool_allowed(toggle, "builtin:home"))
        self.assertTrue(main._heartbeat_tool_allowed(todo_list, "builtin:home"))


    def test_cache_checkpoint_is_recorded_at_150_persisted_messages(self):
        with (
            patch.object(main.db, "setting_get", return_value="11"),
            patch.object(
                main.db, "message_cache_history_count",
                return_value=main.CACHE_HISTORY_MAX_MESSAGES,
            ),
        ):
            self.assertTrue(main._cache_history_checkpoint_reached("chat-1", True))
            self.assertFalse(main._cache_history_checkpoint_reached("chat-1", False))


class CacheHistoryWindowTest(unittest.TestCase):
    """缓存头怎么定。用真库：窗口按「条」数，要看真的消息行。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous_path = main.db.DB_PATH
        main.db.DB_PATH = str(Path(self.tmp.name) / "cache.db")
        main.db.init_db()
        self.chat = main.db.chat_add("cache")["id"]
        self.key = f"prompt_cache_history_start:{self.chat}"

    def tearDown(self):
        main.db.DB_PATH = self.previous_path
        self.tmp.cleanup()

    def _add(self, count):
        # 两边轮流说，前几天说的：只测缓存头，不让「今天」撑大窗口。
        for _ in range(count):
            n = main.db.message_rows_from(self.chat, 0)
            row = main.db.message_add(self.chat, ("user", "assistant")[n % 2], str(n + 1))
            with main.db.conn() as cx:
                cx.execute("UPDATE messages SET made=? WHERE id=?",
                           (main.db.day_start_ts() - 86400 * 3, row["id"]))

    def _rowids(self, rows):
        return [int(row["rowid"]) for row in rows]

    def test_cache_history_window_keeps_its_original_head(self):
        self._add(110)
        selected = main._chat_history_rows(self.chat, cache_friendly=True)
        self.assertEqual(self._rowids(selected), list(range(11, 111)))
        self.assertEqual(main.db.setting_get(self.key, ""), "11")

        self._add(5)
        with patch.object(main.db, "setting_set") as setting_set:
            grown = main._chat_history_rows(self.chat, cache_friendly=True)
        self.assertEqual(grown[0]["rowid"], 11)
        self.assertEqual(grown[-1]["rowid"], 115)
        setting_set.assert_not_called()

    def test_cache_history_ignores_the_empty_reply_placeholder(self):
        self._add(150)
        main.db.message_add(self.chat, "assistant", "")
        main.db.setting_set(self.key, "1")
        with patch.object(main.db, "setting_set") as setting_set:
            selected = main._chat_history_rows(self.chat, cache_friendly=True)
        self.assertEqual(len(selected), main.CACHE_HISTORY_MAX_MESSAGES)
        self.assertEqual(selected[0]["rowid"], 1)
        setting_set.assert_not_called()

    def test_cache_history_window_rotates_only_at_the_hard_limit(self):
        self._add(171)
        main.db.setting_set(self.key, "11")
        selected = main._chat_history_rows(self.chat, cache_friendly=True)
        self.assertEqual(len(selected), main.CACHE_HISTORY_TARGET_MESSAGES)
        self.assertEqual(selected[0]["rowid"], 72)
        self.assertEqual(main.db.setting_get(self.key, ""), "72")

    def test_split_bubbles_do_not_eat_the_window(self):
        # 一轮 = 一句 + 四个气泡，100 条 = 50 轮 = 250 行
        for i in range(60):
            main.db.message_add(self.chat, "user", f"q{i}")
            for j in range(4):
                main.db.message_add(self.chat, "assistant", f"a{i}-{j}")
        with main.db.conn() as cx:
            cx.execute("UPDATE messages SET made=? WHERE chat_id=?",
                       (main.db.day_start_ts() - 86400 * 3, self.chat))
        selected = main._chat_history_rows(self.chat, cache_friendly=True)
        self.assertEqual(selected[0]["content"], "q10")
        self.assertEqual(len(selected), 250)

    def test_cache_checkpoint_counts_turns_not_bubbles(self):
        for i in range(10):
            main.db.message_add(self.chat, "user", f"q{i}")
            for j in range(4):
                main.db.message_add(self.chat, "assistant", f"a{i}-{j}")
        self.assertEqual(main.db.message_cache_history_count(self.chat, 0), 20)


if __name__ == "__main__":
    unittest.main()
