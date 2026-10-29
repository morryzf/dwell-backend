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


class EverydayWordsTest(unittest.TestCase):
    """「坏小子」不是在聊亲密内容，「不疼了」不是在聊健康；事件名里的另一个叫法也算数。"""

    QUERY = "Morry：不疼了 但是我才起，知道为什么吗……\n因为布丁这个坏小子在6点闹腾，我一直睡不好"

    def test_her_pudding_card_comes_first(self):
        from app.memory_retrieval import rank_memory_cards
        cards = [
            {"id": "pudding", "content": "2026-05-20：Pudding是Morry养的蓝金渐层英短。常在早上6点把她床头的水碰翻，非要叫她起床。",
             "thread": "布丁（Pudding）", "topics": ["family_friends"], "importance": "normal", "status": "active"},
            {"id": "ruin", "content": "Morry原话：I need you to ruin me。于是我们定了个安全词，是我可以和她自由的前提。",
             "topics": ["health_safety", "nsfw"], "importance": "high", "status": "active"},
            {"id": "bra", "content": "Morry 在家从来不穿内衣。", "topics": ["nsfw"], "importance": "normal", "status": "active"},
        ] + [{"id": f"x{i}", "content": f"Morry 说过第{i}件小事。", "topics": [], "status": "active"} for i in range(8)]
        ranked = rank_memory_cards(cards, self.QUERY, explain=True)
        self.assertEqual(ranked[0]["id"], "pudding")
        self.assertIn("6点", ranked[0]["recall_why"]["shared"])
        self.assertIn("布丁", ranked[0]["recall_why"]["shared"])
        for card in ranked:
            self.assertNotIn("nsfw", card["recall_why"]["topics"])
            self.assertNotIn("health_safety", card["recall_why"]["topics"])


class CommonWordPiecesTest(unittest.TestCase):
    def test_pieces_of_common_words_do_not_count(self):
        from app.memory_retrieval import _terms
        terms = _terms("知道为什么吗，怎么样")
        for piece in ("为什", "什么", "么样", "怎么"):
            self.assertNotIn(piece, terms)


@unittest.skipIf(__import__("app.memory_retrieval", fromlist=["jieba"]).jieba is None, "jieba 没装")
class WordSplitTest(unittest.TestCase):
    """按词切：整词对得上，跨词的碎块不再出现；名字藏在事件名里也找得到。"""

    def test_words_not_fragments(self):
        from app.memory_retrieval import _terms
        terms = _terms("因为布丁这个坏小子在6点闹腾，我一直睡不好")
        for word in ("布丁", "坏小子", "闹腾", "6点"):
            self.assertIn(word, terms)
        for fragment in ("丁这", "子在", "直睡"):
            self.assertNotIn(fragment, terms)

    def test_a_name_inside_an_event_name(self):
        from app.memory_retrieval import learn_words, rank_memory_cards
        learn_words(["追音音"])
        cards = [{"id": "yin", "content": "Morry 在追音音，还没放手。", "thread": "追音音", "status": "active"},
                 {"id": "swim", "content": "她在学游泳，周末上课。", "status": "active"},
                 {"id": "cat", "content": "布丁是她的猫。", "status": "active"}]
        ranked = rank_memory_cards(cards, "音音今天回我了")
        self.assertEqual(ranked[0]["id"], "yin")


class RankGateTest(unittest.TestCase):
    """聊天带卡：意思、关键词两路都在前 10 名以外的卡不带，宁缺毋滥。"""

    def test_cards_far_down_both_lists_stay_out(self):
        from app.memory_retrieval import select_memory_cards
        cards = [{"id": f"swim{i}", "content": f"她周末去游泳，第{i}次课。", "status": "active"} for i in range(14)]
        chosen = select_memory_cards(cards, "周末游泳", limit=20, cap=20, rank_gate=10)
        self.assertEqual(len(chosen), 10)
        self.assertEqual(len(select_memory_cards(cards, "周末游泳", limit=20, cap=20)), 14)
