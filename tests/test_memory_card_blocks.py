import unittest

from app import agent_sdk_client, main
from app.agent_sdk_client import _anchor, build_bridge_payload, turns_digest
from app.llm_client import content_texts

CARDS = [
    {"id": "c1", "memory_type": "preference", "topics": [], "content": "喜欢  吃\n辣"},
    {"id": "c2", "memory_type": "event", "topics": [], "content": "最近在减脂"},
]


class MemoryCardBlocksTest(unittest.TestCase):
    def test_other_channels_keep_the_numbered_text(self):
        prompt = main._memory_card_prompt(CARDS)
        self.assertTrue(prompt.startswith(main.MEMORY_CARD_PROMPT_HEAD + "\n1. "))
        self.assertIn("\n2. ", prompt)
        self.assertTrue(prompt.endswith("\n</cards>"))
        self.assertIn("喜欢 吃 辣", prompt)

    def test_blocks_read_the_same_and_tag_each_card(self):
        blocks = main._memory_card_blocks(CARDS)
        key = agent_sdk_client.MEMORY_CARD_KEY

        self.assertEqual([block.get(key) for block in blocks], [None, "c1", "c2", None])
        text = "\n".join(content_texts(blocks))
        self.assertTrue(text.startswith(main.MEMORY_CARD_PROMPT_HEAD + "\n- "))
        self.assertTrue(text.endswith("\n</cards>"))

    def test_the_real_blocks_are_what_the_bridge_payload_dedupes(self):
        anchor, size = _anchor([("Morry", "在吗")])
        state = {
            "sid": "sess-1", "model": "sonnet",
            "sys": turns_digest([("system", "你是 Cloudy")]),
            "anchor": anchor, "anchor_len": size,
            "cards": agent_sdk_client.memory_pool_version(),
            "seen_cards": ["c1"],
        }
        messages = [
            {"role": "system", "content": "你是 Cloudy"},
            {"role": "user", "content": "在吗"},
            {"role": "assistant", "content": "在"},
            {"role": "user", "content": "今天吃什么"},
            {"role": "system", "content": main._memory_card_blocks(CARDS)},
        ]

        payload = build_bridge_payload("sonnet", messages, state=state)

        self.assertEqual(payload["resume"], "sess-1")
        self.assertNotIn("喜欢 吃 辣", payload["prompt"])
        self.assertIn("最近在减脂", payload["prompt"])
        self.assertEqual(payload["_seen_cards"], ["c1", "c2"])


if __name__ == "__main__":
    unittest.main()
