"""Relevance ranker for Dwell memory cards.

Hybrid retrieval via Reciprocal Rank Fusion (RRF):
- When both vector and keyword scores are available, fuse rankings from both.
- Falls back to keyword-only when no query embedding is provided.
"""

from __future__ import annotations

import math
import re
from datetime import date, datetime
from functools import lru_cache

try:
    # 中文按词切：「坏小子」「闹腾」「起床」各是一个词，不再两三个字硬切出「丁这」「为什」。
    # 装不上（老部署还没跑 pip）就退回硬切，召回照样能用，只是粗一点。
    import jieba
    jieba.setLogLevel(60)
    # 词典第一次用时要读半秒：服务一起来就在后台读好，别让第一条回复等它。
    import threading
    threading.Thread(target=jieba.initialize, daemon=True).start()
except ImportError:  # pragma: no cover - 部署时 requirements 会装上
    jieba = None


def _valid_on(card: dict, today: date) -> bool:
    if str(card.get("status") or "active") != "active":
        return False
    valid_until = str(card.get("valid_until") or "").strip()
    if not valid_until:
        return True
    try:
        return datetime.strptime(valid_until, "%Y-%m-%d").date() >= today
    except ValueError:
        return False


# ---- Vector retrieval ----

def _cosine_similarity(a: list[float], b: list[float]) -> float:
    if len(a) != len(b) or not a:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


def _vector_score(card: dict, query_embedding: list[float]) -> float:
    card_embedding = card.get("embedding")
    if not card_embedding or not query_embedding:
        return 0.0
    similarity = _cosine_similarity(query_embedding, card_embedding)
    if similarity < 0.25:
        return 0.0
    return round(similarity, 6)


# ---- Keyword fallback ----

# 触发词匹配的是「查询」，加分给的是「卡片的 topic」——这一路不要求查询和卡片
# 同语言，所以中英并列能接住「英文提问 / 中文卡片」那种组合（词重叠那一路在
# 跨语言时必然是 0，救不回来）。
#
# 中文词走子串匹配，英文词走分词匹配：_normalized 会删掉所有空格，英文按子串匹
# 配会乱命中（tea 命中 instead、eat 命中 great、like 命中 unlike）。见 _hint_hit。
# 中文触发词至少两个字：单个字（「坏」「疼」「吃」）在日常句子里到处都是——
# 「坏小子」会被当成在聊亲密内容，「不疼了」会被当成在聊健康。
TOPIC_HINTS = {
    "identity": ("名字", "年龄", "生日", "职业", "身份", "背景", "哪里人",
                 "name", "age", "birthday", "born", "job"),
    "personality": ("性格", "习惯", "脾气", "特点", "怪癖", "内向", "外向", "个性",
                    "personality", "habit", "temper", "quirk", "introvert", "extrovert"),
    "about_me": ("我自己", "关于我", "我喜欢", "我的", "我想", "我觉得", "cloudy", "老公", "朵朵",
                 "yourself", "wolfie", "strawberry"),
    "daily_life": ("日常", "最近", "今天", "生活", "家里", "每天",
                   "daily", "lately", "routine"),
    "place": ("哪里", "地点", "住在", "搬家", "城市", "旅行", "天气", "上海", "北京",
              "where", "city", "travel", "weather", "shanghai", "beijing"),
    "food": ("吃什么", "喝什么", "吃饭", "好吃", "想吃", "吃了", "喝了", "做饭", "外卖", "餐厅", "口味", "咖啡", "奶茶", "食物",
             "eat", "drink", "food", "meal", "restaurant", "coffee", "tea", "hungry"),
    "books": ("看书", "读书", "这本书", "阅读", "小说", "作者", "读完", "读到",
              "book", "read", "reading", "novel", "author"),
    "work_creativity": ("工作", "项目", "创作", "设计", "代码", "产品", "写作", "dwell",
                        "work", "project", "design", "code", "coding", "build", "writing"),
    "schedule": ("日程", "几点", "什么时候", "明天", "今天", "下周", "计划", "提醒",
                 "when", "tomorrow", "schedule", "remind", "plan"),
    # 「我们」「聊天」拿掉了：这两个词几乎每句都有，当触发词等于给所有 relationship
    # 卡片无差别加分，把本该空着的召回位填满。
    "relationship": ("关系", "相处", "陪伴", "联系", "在意",
                     "relationship", "dynamic", "together", "distance"),
    "health_safety": ("身体", "健康", "生病", "头疼", "肚子疼", "胃疼", "睡眠", "吃药", "医院", "安全", "情绪",
                      "health", "sick", "pain", "sleep", "tired", "doctor", "safe"),
    "entertainment": ("电影", "电视剧", "视频", "游戏", "音乐", "听歌", "这首歌", "综艺", "动漫",
                      "movie", "film", "show", "game", "music", "song", "anime"),
    "family_friends": ("家人", "朋友", "妈妈", "爸爸", "同事", "同学", "亲人", "宠物",
                       "family", "friend", "mom", "mother", "dad", "father", "pet"),
    "nsfw": ("想要", "操我", "鸡巴", "惩罚", "脱掉", "后入", "咬我", "打屁股", "安全词", "做爱",
             "fuck", "cock", "punish", "spank", "naughty", "safeword"),
}

TYPE_HINTS = {
    "preference": ("喜欢", "不喜欢", "偏好", "想要", "讨厌",
                   "like", "love", "hate", "prefer", "favorite"),
    "plan": ("计划", "准备", "打算", "以后", "明天", "下周",
             "plan", "going", "will", "tomorrow"),
    "open_thread": ("继续", "进展", "完成", "做到哪", "后来", "项目",
                    "still", "progress", "finish", "done"),
    "recent_event": ("最近", "刚才", "昨天", "今天", "发生",
                     "recently", "lately", "yesterday", "happened"),
    "quote": ("原话", "说过", "怎么说", "那句话",
              "said", "quote", "words"),
}

COMMON_CJK_GRAMS = {
    "一个", "一些", "这个", "那个", "什么", "怎么", "可以", "需要", "觉得", "还是",
    "已经", "正在", "现在", "今天", "最近", "我们", "你们", "他们", "自己", "事情",
    "喜欢", "知道", "记得", "以后", "时候", "因为", "所以", "但是", "如果", "没有",
    "是我", "我是", "不是", "就是", "还有", "一下", "一直", "为什么", "怎么样",
}


# 三个字的常用词切开以后，那几个两字块（「为什」「么样」）也一样没意义，一起去掉。
COMMON_CJK_GRAMS |= {
    word[index:index + 2] for word in tuple(COMMON_CJK_GRAMS) if len(word) >= 3
    for index in range(len(word) - 1)
}


def _normalized(text: object) -> str:
    return re.sub(r"\s+", "", str(text or "").casefold())


_CJK_WORD = re.compile(r"[㐀-鿿]{2,}")
_known_words: set[str] = set()


def learn_words(names) -> None:
    """把专有名词教给分词：事件名「布丁（Pudding）」里的「布丁」，「追音音」……
    不教的话，生僻的名字会被切碎，对不上。教过的记着，不重复教。"""
    if jieba is None:
        return
    fresh = set()
    for name in names:
        for part in re.split(r"[（）()、/,，·\s]+", str(name or "")):
            if _CJK_WORD.fullmatch(part) and part not in _known_words:
                fresh.add(part)
    if not fresh:
        return
    for word in fresh:
        jieba.add_word(word, freq=20000)
    _known_words.update(fresh)
    # 词典变了，之前切好的要作废。
    _terms.cache_clear()


@lru_cache(maxsize=8192)
def _split(raw: str) -> frozenset[str]:
    terms = set(re.findall(r"[a-z0-9_]{2,}", raw))
    # 「6点」「10月」「3次」：数字连着后面那个字算一块，不然数字会把它切没了。
    terms.update(re.findall(r"[0-9]+[㐀-鿿]", raw))
    if jieba is not None:
        # 搜索模式：长词也给出里面的短词（「坏小子」也给「小子」），找和被找用同一种切法。
        for word in jieba.lcut_for_search(raw):
            if not _CJK_WORD.fullmatch(word):
                continue
            terms.add(word)
            # 三个字以上的词再拆出两字块：「追音音」里的「音音」，她单说「音音」也要对得上。
            # 只在一个词里面拆，不像以前整句硬切，切不出「丁这」这种跨词的碎块。
            if len(word) >= 3:
                terms.update(word[index:index + 2] for index in range(len(word) - 1))
    else:
        for chunk in _CJK_WORD.findall(raw):
            for size in (2, 3):
                terms.update(chunk[index:index + size] for index in range(len(chunk) - size + 1))
    return frozenset(term for term in terms if term not in COMMON_CJK_GRAMS)


def _terms(text: object) -> set[str]:
    return set(_split(str(text or "").casefold()))


_terms.cache_clear = _split.cache_clear


def _hint_hit(hints, normalized_query: str, query_terms: set[str]) -> bool:
    """中文触发词按子串匹配，英文触发词按整词匹配。

    _normalized 删掉了所有空格，英文按子串匹配会乱命中：tea 命中 instead、
    eat 命中 great、like 命中 unlike。英文改走 _terms 切出来的词表就没这问题。
    """
    for hint in hints:
        if hint.isascii():
            if hint in query_terms:
                return True
        elif hint in normalized_query:
            return True
    return False


# 一个词出现在多少张卡里，就有多不稀奇。几乎每张都有的词（她的名字、「我们」）
# 对上了也说明不了什么——不压下去，问什么都会把一堆写着「Morry」的卡顶上来。
TOPIC_BONUS = 0.6
TYPE_BONUS = 0.4
RARE_ENOUGH = 0.35
COMMON_FLOOR = 0.05


def _term_weights(query_terms: set[str], card_terms: list[set[str]]) -> dict[str, float]:
    """每个查询词的分量，0–1：只在一张卡里出现的是 1，张张都有的是 0。"""
    total = len(card_terms)
    if total < 3:
        return {term: 1.0 for term in query_terms}
    weights = {}
    for term in query_terms:
        seen = sum(1 for terms in card_terms if term in terms)
        # 留一点底：要找的词真的张张都有时（「铃兰」），还找得到。
        weights[term] = 1.0 if seen <= 1 else max(COMMON_FLOOR, math.log(total / seen) / math.log(total))
    return weights


def _card_text(card: dict) -> str:
    """关键词比对用的卡片文字：正文加上事件名。事件名常常写着另一个叫法
    （「布丁（Pudding）」），这样两个名字都对得上，不用另外记别名。"""
    return f"{card.get('content') or ''} {card.get('thread') or ''}"


def _keyword_parts(card: dict, query: str, query_terms: set[str],
                   weights: dict[str, float] | None = None) -> dict:
    """关键词这一路的分数，连同是怎么得来的：哪些词对上了、哪些话题对上了。"""
    content = str(card.get("content") or "").strip()
    if not content:
        return {"score": 0.0, "shared": [], "topics": [], "type_hit": False}
    content_terms = _terms(_card_text(card))
    shared = query_terms & content_terms
    weight = (lambda term: weights.get(term, 1.0)) if weights else (lambda term: 1.0)
    score = sum((1.6 if len(term) >= 3 else 1.0) * weight(term) for term in shared)
    # 理由里只写真起了作用的词。
    shared = {term for term in shared if weight(term) >= RARE_ENOUGH}
    normalized_query, normalized_content = _normalized(query), _normalized(content)
    if len(normalized_content) >= 4 and normalized_content in normalized_query:
        score += 5.0
    topics = []
    for topic in card.get("topics") or []:
        if _hint_hit(TOPIC_HINTS.get(str(topic), ()), normalized_query, query_terms):
            topics.append(str(topic))
    # 话题、类型只在分不出先后时帮一把：对上一个话题抵不上对上一个少见的词。
    score += min(2, len(topics)) * TOPIC_BONUS
    memory_type = str(card.get("memory_type") or "")
    type_hit = _hint_hit(TYPE_HINTS.get(memory_type, ()), normalized_query, query_terms)
    if type_hit:
        score += TYPE_BONUS
    return {"score": round(score, 4), "shared": sorted(shared), "topics": topics, "type_hit": type_hit}


def _keyword_score(card: dict, query: str, query_terms: set[str]) -> float:
    return _keyword_parts(card, query, query_terms)["score"]


# ---- Importance / freshness boost (shared by both paths) ----

def _meta_boost(card: dict, now: datetime) -> float:
    boost = {"high": 0.8, "normal": 0.3, "low": 0.0}.get(
        str(card.get("importance")), 0.0
    )
    try:
        age_days = max(0, (now - datetime.fromtimestamp(int(card.get("updated") or 0))).days)
    except (TypeError, ValueError, OSError):
        age_days = 9999
    if age_days <= 30:
        boost += 0.35
    elif age_days <= 180:
        boost += 0.12
    if str(card.get("retention")) == "fading":
        boost -= 0.2
    return boost


# ---- RRF fusion ----

_RRF_K = 60


def _rrf_rank(scored: list[tuple[str, float]]) -> dict[str, int]:
    """Return {card_id: 1-based rank} from a list of (card_id, score), descending."""
    sorted_items = sorted(scored, key=lambda t: -t[1])
    return {card_id: rank for rank, (card_id, _) in enumerate(sorted_items, 1)}


# ---- Public API ----

def select_memory_cards(
    cards: list[dict],
    context: str,
    *,
    limit: int = 5,
    now: datetime | None = None,
    query_embedding: list[float] | None = None,
    cap: int = 5,
    rank_gate: int | None = None,
) -> list[dict]:
    """Return at most ``limit`` relevant, active and unexpired cards.

    ``rank_gate``: only cards ranked within this many places on at least one
    path (meaning or keywords) may come — chat recall uses it so a card that is
    far down on both lists stays out instead of filling the five places.

    ``cap`` bounds ``limit``: chat injection keeps the default 5; the memory MCP
    lets an outside client ask for a few more.

    Uses RRF to fuse vector and keyword rankings when both are available.
    Falls back to keyword-only when no query embedding is provided.
    """
    ranked = rank_memory_cards(cards, context, now=now, query_embedding=query_embedding)
    if rank_gate:
        ranked = [card for card in ranked if passes_rank_gate(card, rank_gate)]
    return ranked[: max(0, min(int(cap), int(limit)))]


def passes_rank_gate(card: dict, gate: int) -> bool:
    """意思、关键词两路里，至少有一路排进前 gate 名。"""
    ranks = card.get("recall_ranks") or {}
    return any(rank is not None and rank <= gate for rank in (ranks.get("vector"), ranks.get("keyword")))


def rank_memory_cards(
    cards: list[dict],
    context: str,
    *,
    now: datetime | None = None,
    query_embedding: list[float] | None = None,
    explain: bool = False,
) -> list[dict]:
    """All matching cards, best first. ``explain`` adds ``recall_why`` to each:
    the vector similarity, the shared terms, the topics that matched — what the
    召回演练 page shows next to every card.
    """
    now = now or datetime.now()
    query = str(context or "").strip()
    if not query:
        return []
    valid_cards: dict[str, dict] = {}
    why: dict[str, dict] = {}
    vec_scores: list[tuple[str, float]] = []
    kw_scores: list[tuple[str, float]] = []

    for card in cards:
        cid = str(card.get("id") or "")
        if cid and _valid_on(card, now.date()):
            valid_cards[cid] = card
    # 事件名是她起的名字，先教给分词，再切查询和卡片。
    learn_words(card.get("thread") for card in valid_cards.values())
    query_terms = _terms(query)
    # 每行开头的「Morry：」「Cloudy：」是说话人的标签，不是说了什么，不拿来比对。
    for speaker in re.findall(r"(?m)^([^：:\n]{1,20})[：:]", query):
        query_terms -= _terms(speaker)
    weights = _term_weights(query_terms, [_terms(_card_text(card)) for card in valid_cards.values()])

    for cid, card in valid_cards.items():
        parts = _keyword_parts(card, query, query_terms, weights)
        kw = parts["score"]
        if kw > 0:
            kw_scores.append((cid, kw))

        vs = _vector_score(card, query_embedding) if query_embedding else 0.0
        if vs > 0:
            vec_scores.append((cid, vs))
        if explain:
            why[cid] = {"vector": vs, "keyword": kw, "shared": parts["shared"],
                        "topics": parts["topics"], "type_hit": parts["type_hit"]}

    # 有卡是靠稀罕的词对上的，就不让只沾了个常见词（名字）的卡进关键词那一路的排名。
    if kw_scores and max(score for _, score in kw_scores) >= 1.0:
        kw_scores = [(cid, score) for cid, score in kw_scores if score >= 0.3]

    if not kw_scores and not vec_scores:
        return []

    kw_rank = _rrf_rank(kw_scores) if kw_scores else {}
    vec_rank = _rrf_rank(vec_scores) if vec_scores else {}
    all_ids = set(kw_rank) | set(vec_rank)

    ranked = []
    for cid in all_ids:
        rrf = 0.0
        if cid in vec_rank:
            rrf += 1.0 / (_RRF_K + vec_rank[cid])
        if cid in kw_rank:
            rrf += 1.0 / (_RRF_K + kw_rank[cid])
        card = valid_cards[cid]
        boost = _meta_boost(card, now)
        # 重要程度、新旧只在名次挨着时分先后：前几名之间 RRF 差 0.0003 左右，
        # 这一项最多 0.00012，翻不过一个名次。
        score = rrf + boost * 0.0001
        item = {**card, "selection_score": round(score, 6),
                "recall_ranks": {"vector": vec_rank.get(cid), "keyword": kw_rank.get(cid)}}
        if explain:
            item["recall_why"] = {**why[cid], "boost": round(boost, 3),
                                  "vector_rank": vec_rank.get(cid), "keyword_rank": kw_rank.get(cid)}
        ranked.append(item)

    ranked.sort(
        key=lambda item: (
            -float(item["selection_score"]),
            {"high": 0, "normal": 1, "low": 2}.get(str(item.get("importance")), 3),
            -int(item.get("updated") or 0),
            str(item.get("id") or ""),
        )
    )
    return ranked
