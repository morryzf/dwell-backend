"""Relevance ranker for Dwell memory cards.

Hybrid retrieval via Reciprocal Rank Fusion (RRF):
- When both vector and keyword scores are available, fuse rankings from both.
- Falls back to keyword-only when no query embedding is provided.
"""

from __future__ import annotations

import math
import re
from datetime import date, datetime


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

TOPIC_HINTS = {
    "identity": ("名字", "年龄", "生日", "职业", "身份", "背景", "哪里人"),
    "personality": ("性格", "习惯", "脾气", "特点", "怪癖", "内向", "外向", "个性"),
    "about_me": ("你自己", "关于你", "你喜欢", "你的", "你想", "你觉得", "cloudy", "老公", "朵朵"),
    "daily_life": ("日常", "最近", "今天", "生活", "家里", "每天"),
    "place": ("哪里", "地点", "住", "搬家", "城市", "旅行", "天气", "上海", "北京"),
    "food": ("吃", "喝", "菜", "饭", "餐厅", "口味", "咖啡", "奶茶", "食物"),
    "books": ("书", "阅读", "小说", "作者", "读完", "读到"),
    "work_creativity": ("工作", "项目", "创作", "设计", "代码", "产品", "写作", "dwell"),
    "schedule": ("日程", "几点", "什么时候", "明天", "今天", "下周", "计划", "提醒"),
    "relationship": ("关系", "相处", "我们", "陪伴", "聊天", "联系", "在意"),
    "health_safety": ("身体", "健康", "生病", "疼", "睡眠", "药", "医院", "安全", "情绪"),
    "entertainment": ("电影", "电视剧", "视频", "游戏", "音乐", "歌", "综艺", "动漫"),
    "family_friends": ("家人", "朋友", "妈妈", "爸爸", "同事", "同学", "亲人"),
    "nsfw": ("想要", "亲亲", "抱抱", "惩罚", "乖", "坏", "脱", "摸", "咬", "打屁股", "安全词"),
}

TYPE_HINTS = {
    "preference": ("喜欢", "不喜欢", "偏好", "想要", "讨厌"),
    "plan": ("计划", "准备", "打算", "以后", "明天", "下周"),
    "open_thread": ("继续", "进展", "完成", "做到哪", "后来", "项目"),
    "recent_event": ("最近", "刚才", "昨天", "今天", "发生"),
    "quote": ("原话", "说过", "怎么说", "那句话"),
}

COMMON_CJK_GRAMS = {
    "一个", "一些", "这个", "那个", "什么", "怎么", "可以", "需要", "觉得", "还是",
    "已经", "正在", "现在", "今天", "最近", "我们", "你们", "他们", "自己", "事情",
    "喜欢", "知道", "记得", "以后", "时候", "因为", "所以", "但是", "如果", "没有",
}


def _normalized(text: object) -> str:
    return re.sub(r"\s+", "", str(text or "").casefold())


def _terms(text: object) -> set[str]:
    raw = str(text or "").casefold()
    terms = {word for word in re.findall(r"[a-z0-9_]{2,}", raw)}
    for chunk in re.findall(r"[㐀-鿿]{2,}", raw):
        for size in (2, 3):
            terms.update(chunk[index:index + size] for index in range(len(chunk) - size + 1))
    return {term for term in terms if term not in COMMON_CJK_GRAMS}


def _keyword_score(card: dict, query: str, query_terms: set[str]) -> float:
    content = str(card.get("content") or "").strip()
    if not content:
        return 0.0
    content_terms = _terms(content)
    shared = query_terms & content_terms
    score = sum(1.6 if len(term) >= 3 else 1.0 for term in shared)
    normalized_query, normalized_content = _normalized(query), _normalized(content)
    if len(normalized_content) >= 4 and normalized_content in normalized_query:
        score += 5.0
    topic_hits = 0
    for topic in card.get("topics") or []:
        hints = TOPIC_HINTS.get(str(topic), ())
        if any(hint in normalized_query for hint in hints):
            topic_hits += 1
    score += min(2, topic_hits) * 2.4
    memory_type = str(card.get("memory_type") or "")
    if any(hint in normalized_query for hint in TYPE_HINTS.get(memory_type, ())):
        score += 1.4
    return round(score, 4)


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
) -> list[dict]:
    """Return at most ``limit`` relevant, active and unexpired cards.

    Uses RRF to fuse vector and keyword rankings when both are available.
    Falls back to keyword-only when no query embedding is provided.
    """
    now = now or datetime.now()
    query = str(context or "").strip()
    if not query:
        return []
    query_terms = _terms(query)

    valid_cards: dict[str, dict] = {}
    vec_scores: list[tuple[str, float]] = []
    kw_scores: list[tuple[str, float]] = []

    for card in cards:
        if not _valid_on(card, now.date()):
            continue
        cid = str(card.get("id") or "")
        if not cid:
            continue
        valid_cards[cid] = card

        kw = _keyword_score(card, query, query_terms)
        if kw > 0:
            kw_scores.append((cid, kw))

        if query_embedding:
            vs = _vector_score(card, query_embedding)
            if vs > 0:
                vec_scores.append((cid, vs))

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
        score = rrf + _meta_boost(card, now) * 0.001
        ranked.append({**card, "selection_score": round(score, 6)})

    ranked.sort(
        key=lambda item: (
            -float(item["selection_score"]),
            {"high": 0, "normal": 1, "low": 2}.get(str(item.get("importance")), 3),
            -int(item.get("updated") or 0),
            str(item.get("id") or ""),
        )
    )
    return ranked[: max(0, min(5, int(limit)))]
