from datetime import datetime
import unittest

from app.memory_retrieval import select_memory_cards


NOW = datetime(2026, 8, 31, 12, 0, 0)


def card(card_id, content, *, topics=None, status="active", valid_until=None,
         importance="normal", memory_type="stable_fact", updated=1_787_000_000):
    return {
        "id": card_id,
        "content": content,
        "topics": topics or ["other"],
        "status": status,
        "valid_until": valid_until,
        "importance": importance,
        "memory_type": memory_type,
        "retention": "long_term",
        "updated": updated,
    }


class MemoryRetrievalTest(unittest.TestCase):
    def test_selects_relevant_cards_without_forcing_unrelated_ones(self):
        cards = [
            card("place", "她目前住在上海。", topics=["place"]),
            card("food", "她不吃香菜。", topics=["food"], memory_type="preference"),
            card("book", "她正在读一本推理小说。", topics=["books"]),
        ]
        chosen = select_memory_cards(cards, "上海最近天气怎么样？", now=NOW)
        self.assertEqual([item["id"] for item in chosen], ["place"])

    def test_excludes_hidden_archived_and_expired_cards(self):
        cards = [
            card("active", "她喜欢川菜。", topics=["food"], memory_type="preference"),
            card("hidden", "她喜欢粤菜。", topics=["food"], status="hidden"),
            card("archived", "她喜欢湘菜。", topics=["food"], status="archived"),
            card("expired", "她今天想吃火锅。", topics=["food"], valid_until="2026-08-30"),
        ]
        chosen = select_memory_cards(cards, "我们去吃什么菜？", now=NOW)
        self.assertEqual([item["id"] for item in chosen], ["active"])

    def test_returns_no_more_than_five(self):
        cards = [card(str(index), f"上海地点记录 {index}", topics=["place"]) for index in range(9)]
        chosen = select_memory_cards(cards, "上海有哪些地点？", now=NOW)
        self.assertEqual(len(chosen), 5)

    def test_empty_or_unrelated_context_returns_nothing(self):
        cards = [card("book", "她正在读一本推理小说。", topics=["books"])]
        self.assertEqual(select_memory_cards(cards, "", now=NOW), [])
        self.assertEqual(select_memory_cards(cards, "帮我算 2 加 2", now=NOW), [])


if __name__ == "__main__":
    unittest.main()



class CommonWordsTest(unittest.TestCase):
    """几乎每张卡都有的词（她的名字）对上了不算数，不然问什么都是一堆写着 Morry 的卡。"""

    def test_her_name_does_not_outweigh_the_rare_words(self):
        from app.memory_retrieval import rank_memory_cards
        cards = [{"id": f"c{i}", "content": f"Morry 说过第{i}件小事，和工作有关。", "importance": "normal",
                  "status": "active", "memory_type": "stable_fact", "topics": []} for i in range(12)]
        cards.append({"id": "cat", "content": "布丁是她的猫，早上爱闹腾。", "importance": "normal",
                      "status": "active", "memory_type": "stable_fact", "topics": []})
        ranked = rank_memory_cards(cards, "Morry：布丁在6点闹腾，我睡不好", explain=True)
        self.assertEqual(ranked[0]["id"], "cat")
        self.assertNotIn("morry", ranked[0]["recall_why"]["shared"])
        rest = [c for c in ranked if c["id"] != "cat"]
        self.assertTrue(all("morry" not in c["recall_why"]["shared"] for c in rest))
