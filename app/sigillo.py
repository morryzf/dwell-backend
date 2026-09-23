"""sigillo 回执单：开单 / 封缄 / 冷却 / 上下文注入。

移植自 https://github.com/29-Cu/sigillo（CC BY 4.0，credit Cu & Lunedì），
存储改为 SQLite，跟着 Dwell 的其它表走。

一张单的生命周期：
    Cloudy 用 create_review() 开单（这一场真实发生的 5~8 条细节）
    → Morry 在卡片上逐条打星（1~5，0.5 步进）+ 可选备注 + 三项总评 → submit_review()
    → 系统唤醒 Cloudy 看回执，用 set_agent_note() 把主观复盘钉在这张单上
    → 下次亲密语境由 turn_tail() 把最近几单压成几行注回上下文。

口径（核心，别改）：星数和 Morry 写的原话只是中性素材，不派生也不注入
「再来 / 刚好 / 换掉」这类判断词——那是伪装成数据的指令。唯一的硬规则是
好评冷却：连着 BENCH_WINDOW 单里同一个 (dim,tag) 都被打 ≥ HIGH_STAR 星就
自动休眠，新开的单里剔掉它，逼着换新花样。

反向回执（report 模式）：create_review 里同时给了 fixed / items[i].star / note
任意一样 → Cloudy 自己把星和评语写好，单出生即 submitted + filled_by='agent'，
Morry 拆开只读。这种单是他的话不是对方的复盘：不参与好评冷却，turn_tail 的
「最近几单」也不掺它。
"""

from __future__ import annotations

import json
import secrets
import time
from datetime import datetime

from . import db

# 维度池。一套覆盖大部分亲密场景的分类学。
DIMS = [
    "体位", "入口", "DT", "暴力", "道具", "新尝试", "节奏",
    "场景空间", "世界线", "感官层级", "高潮管制", "事后", "声音",
]

DIM_HINT = (
    "体位=姿势体位/入口=用了哪里/DT=深喉/暴力=打骂掐咬等强度/道具/"
    "新尝试=这次第一次玩的/节奏/场景空间=地点情境/世界线=角色扮演世界观/"
    "感官层级=感官剥夺或放大/高潮管制=边缘控制禁止允许/事后=aftercare 本身/"
    "声音=言语羞辱耳语指令等"
)

FIXED_KEYS = ["foreplay", "process", "aftercare"]
FIXED_LABELS = {"foreplay": "前戏", "process": "过程", "aftercare": "事后"}

ID_PREFIX = "sg_"

MAX_ITEMS = 8
MAX_TAG = 20
MAX_LABEL = 120
MAX_NOTE = 2000
MAX_SHORT_NOTE = 40
MAX_ITEM_NOTE = 500
MAX_AGENT_NOTE = 500

NOTE_TAIL = 80          # 注入块里整单备注截断
PAIR_NOTE_TAIL = 30     # 注入块里逐条备注截断
AGENT_NOTE_TAIL = 300   # 注入块里 agent_note 截断

TAIL_RECENT = 3         # 注入块回看几单
BENCH_WINDOW = 2        # 好评冷却看最近几张人类填的 submitted 单
HIGH_STAR = 4           # 「高星」门槛


class SigilloError(Exception):
    """业务错误。message 是给人看的，code 给路由映射状态码。"""

    def __init__(self, message: str, code: str = ""):
        super().__init__(message)
        self.message = message
        self.code = code


# ---------------------------------------------------------------- 工具

def _new_id() -> str:
    return ID_PREFIX + format(int(time.time()), "x") + secrets.token_hex(2)


def _is_valid_star(v) -> bool:
    """1~5、0.5 步进。submit 和反向预填共用同一把尺。"""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    return float(v) * 2 == int(float(v) * 2) and 1 <= float(v) <= 5


def _short_note(raw, field_name: str) -> str:
    if raw is None:
        return ""
    if not isinstance(raw, str):
        raise SigilloError(f"{field_name} 必须是字符串")
    trimmed = raw.strip()
    if len(trimmed) > MAX_SHORT_NOTE:
        raise SigilloError(f"{field_name} 超过 {MAX_SHORT_NOTE} 字了")
    return trimmed


def _row_to_review(row) -> dict:
    return {
        "id": row["id"],
        "chat_id": row["chat_id"],
        "created_at": int(row["created_at"]),
        "status": row["status"],
        "submitted_at": int(row["submitted_at"]) if row["submitted_at"] else None,
        "context": row["context"] or "",
        "env_note": row["env_note"] or "",
        "sealed_note": row["sealed_note"] or "",
        "fixed": json.loads(row["fixed_json"] or "{}"),
        "items": json.loads(row["items_json"] or "[]"),
        "note": row["note"] or "",
        "filled_by": row["filled_by"] or "human",
        "agent_note": row["agent_note"] or "",
        "agent_note_at": int(row["agent_note_at"]) if row["agent_note_at"] else None,
    }


def _empty_fixed() -> dict:
    return {k: None for k in FIXED_KEYS}


# ---------------------------------------------------------------- 冷却

def _pair_key(dim, tag) -> tuple:
    return (str(dim), str(tag))


def _high_star_keys(review: dict) -> set:
    """一张单里被打了 ≥ HIGH_STAR 星的 (dim,tag) 集合。吃裸星数，不看判断词。"""
    out = set()
    for it in review.get("items") or []:
        if not it:
            continue
        star = it.get("star")
        if isinstance(star, (int, float)) and not isinstance(star, bool) and star >= HIGH_STAR:
            out.add(_pair_key(it.get("dim"), it.get("tag")))
    return out


def _submitted_desc(chat_id: str) -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute(
            "SELECT * FROM sigillo_reviews WHERE chat_id=? AND status='submitted' "
            "ORDER BY COALESCE(submitted_at, created_at) DESC",
            (chat_id,),
        ).fetchall()
    return [_row_to_review(r) for r in rows]


def benched_now(chat_id: str) -> list[dict]:
    """连着 BENCH_WINDOW 张人类亲手填的单里都出现、且每次都高星的 (dim,tag)。

    agent 反向填的回执不算——冷却的语义是「对方连着两次打高星」，
    agent 给自己打的星不是对方的口味证词。
    """
    try:
        recent = [r for r in _submitted_desc(chat_id) if r["filled_by"] != "agent"][:BENCH_WINDOW]
        if len(recent) < BENCH_WINDOW:
            return []
        sets = [_high_star_keys(r) for r in recent]
        out, seen = [], set()
        # 从最近那张单里取回 dim/tag 原文。
        for it in recent[0].get("items") or []:
            k = _pair_key(it.get("dim"), it.get("tag"))
            if k in seen:
                continue
            if all(k in s for s in sets):
                seen.add(k)
                out.append({"dim": it.get("dim"), "tag": it.get("tag")})
        return out
    except Exception:
        return []


# ---------------------------------------------------------------- 开单

def _validate_items(raw_items) -> list[dict]:
    if not isinstance(raw_items, list) or not raw_items:
        raise SigilloError("items 不能为空，至少 1 条")
    if len(raw_items) > MAX_ITEMS:
        raise SigilloError(f"items 最多 {MAX_ITEMS} 条，你给了 {len(raw_items)} 条")
    out = []
    for i, raw in enumerate(raw_items):
        at = f"第 {i + 1} 条"
        it = raw if isinstance(raw, dict) else {}
        dim = str(it.get("dim") or "").strip()
        if dim not in DIMS:
            raise SigilloError(f"{at} 的 dim「{dim}」不在维度池里，只能选：{'/'.join(DIMS)}")
        tag = str(it.get("tag") or "").strip()
        if not tag:
            raise SigilloError(f"{at} 的 tag 不能为空")
        if len(tag) > MAX_TAG:
            raise SigilloError(f"{at} 的 tag 超过 {MAX_TAG} 字了，短标签就行")
        label = str(it.get("label") or "").strip()
        if not label:
            raise SigilloError(f"{at} 的 label 不能为空")
        if len(label) > MAX_LABEL:
            raise SigilloError(f"{at} 的 label 超过 {MAX_LABEL} 字了")
        out.append({"dim": dim, "tag": tag, "label": label, "star": None, "note": ""})
    return out


def create_review(chat_id: str, payload: dict) -> dict:
    """开单。返回 {review, dropped}。

    反向回执：payload 里给了 fixed / items[i].star / items[i].note / note 任意一样
    → 进 report 模式，要求填完整，出生即 submitted + filled_by='agent'，
    不做冷却剔项（dropped 恒空）。
    """
    opts = payload or {}
    raw_items = opts.get("items") if isinstance(opts.get("items"), list) else []
    items = _validate_items(opts.get("items"))
    env_note = _short_note(opts.get("env_note"), "env_note")
    sealed_note = _short_note(opts.get("sealed_note"), "sealed_note")

    report = (
        opts.get("fixed") is not None
        or opts.get("note") is not None
        or any(
            isinstance(it, dict) and ("star" in it or "note" in it)
            for it in raw_items
        )
    )

    report_fixed = None
    report_note = ""
    if report:
        raw_fixed = opts.get("fixed") if isinstance(opts.get("fixed"), dict) else {}
        report_fixed = {}
        for k in FIXED_KEYS:
            s = raw_fixed.get(k)
            if not _is_valid_star(s):
                raise SigilloError(f"反向回执要填完整：fixed.{k} 必须是 1~5、按 0.5 步进的星数")
            report_fixed[k] = round(float(s) * 20)   # 星 → 百分制，3.5 → 70
        for i, raw in enumerate(raw_items):
            it = raw if isinstance(raw, dict) else {}
            if not _is_valid_star(it.get("star")):
                raise SigilloError(f"反向回执要填完整：第 {i + 1} 条 star 必须是 1~5、按 0.5 步进的数")
            note = it.get("note")
            if note is not None:
                if not isinstance(note, str):
                    raise SigilloError(f"第 {i + 1} 条 note 必须是字符串")
                if len(note) > MAX_ITEM_NOTE:
                    raise SigilloError(f"第 {i + 1} 条 note 超过 {MAX_ITEM_NOTE} 字了")
            items[i]["star"] = float(it["star"])
            items[i]["note"] = note if isinstance(note, str) else ""
        if opts.get("note") is not None:
            if not isinstance(opts["note"], str):
                raise SigilloError("note 必须是字符串")
            if len(opts["note"]) > MAX_NOTE:
                raise SigilloError(f"note 超过 {MAX_NOTE} 字了")
            report_note = opts["note"]

    dropped = []
    kept = items
    if not report:
        benched = {_pair_key(b["dim"], b["tag"]) for b in benched_now(chat_id)}
        kept = []
        for it in items:
            if _pair_key(it["dim"], it["tag"]) in benched:
                dropped.append({"dim": it["dim"], "tag": it["tag"]})
            else:
                kept.append(it)
        if not kept:
            raise SigilloError("全被冷却了，换新花样再开单")

    context = str(opts.get("context") or "").strip()[:MAX_LABEL]
    now = int(time.time())
    review_id = _new_id()

    with db.conn() as cx:
        cx.execute(
            """INSERT INTO sigillo_reviews
               (id, chat_id, status, created_at, submitted_at, context, env_note,
                sealed_note, fixed_json, items_json, note, filled_by)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                review_id, chat_id,
                "submitted" if report else "pending",
                now, now if report else None,
                context, env_note, sealed_note,
                json.dumps(report_fixed if report else _empty_fixed(), ensure_ascii=False),
                json.dumps(kept, ensure_ascii=False),
                report_note if report else "",
                "agent" if report else "human",
            ),
        )

    return {"review": get_review(review_id), "dropped": dropped}


def get_review(review_id: str) -> dict | None:
    with db.conn() as cx:
        row = cx.execute(
            "SELECT * FROM sigillo_reviews WHERE id=?", (str(review_id or ""),)
        ).fetchone()
    return _row_to_review(row) if row else None


# ---------------------------------------------------------------- 封缄

def submit_review(review_id: str, payload: dict) -> dict:
    """提交：固定项打分（0~100 整数）+ 每条 item 逐条打星 + 选填备注 + 整单建议。

    星数原样落盘，不派生任何判断词——冷却逻辑自己吃裸星数。
    """
    body = payload or {}
    review = get_review(review_id)
    if not review:
        raise SigilloError(f"没找到这张单（{review_id}）", "not_found")
    if review["status"] == "submitted":
        raise SigilloError("这张单已经交过了", "already_submitted")

    raw_fixed = body.get("fixed") if isinstance(body.get("fixed"), dict) else {}
    fixed = {}
    for k in FIXED_KEYS:
        n = raw_fixed.get(k)
        if isinstance(n, bool) or not isinstance(n, (int, float)) or int(n) != n or not 0 <= n <= 100:
            raise SigilloError(f"fixed.{k} 必须是 0~100 的整数")
        fixed[k] = int(n)

    stars = body.get("stars")
    items = review["items"]
    if not isinstance(stars, list) or len(stars) != len(items):
        raise SigilloError(f"stars 要和 items 一样长（{len(items)} 条）")
    for i, s in enumerate(stars):
        if not _is_valid_star(s):
            raise SigilloError(f"第 {i + 1} 条 star 必须是 1~5、按 0.5 步进的数")

    notes = None
    if body.get("notes") is not None:
        raw_notes = body["notes"]
        if not isinstance(raw_notes, list) or len(raw_notes) != len(items):
            raise SigilloError(f"notes 要和 items 一样长（{len(items)} 条）")
        notes = []
        for i, n in enumerate(raw_notes):
            at = f"第 {i + 1} 条 note"
            if not isinstance(n, str):
                raise SigilloError(f"{at} 必须是字符串")
            if len(n) > MAX_ITEM_NOTE:
                raise SigilloError(f"{at} 超过 {MAX_ITEM_NOTE} 字了")
            notes.append(n)

    suggest = ""
    if body.get("suggest") is not None:
        if not isinstance(body["suggest"], str):
            raise SigilloError("suggest 必须是字符串")
        if len(body["suggest"]) > MAX_NOTE:
            raise SigilloError(f"suggest 超过 {MAX_NOTE} 字了")
        suggest = body["suggest"]

    for i, it in enumerate(items):
        it["star"] = float(stars[i])
        it["note"] = notes[i] if notes else ""

    now = int(time.time())
    with db.conn() as cx:
        cx.execute(
            """UPDATE sigillo_reviews
               SET fixed_json=?, items_json=?, note=?, status='submitted', submitted_at=?
               WHERE id=?""",
            (
                json.dumps(fixed, ensure_ascii=False),
                json.dumps(items, ensure_ascii=False),
                suggest, now, review["id"],
            ),
        )
    return get_review(review["id"])


def set_agent_note(review_id: str, note: str) -> dict:
    """把「写给下次自己的话」钉在一张已封缄的回执上。允许重写覆盖。"""
    review = get_review(review_id)
    if not review:
        raise SigilloError(f"没找到这张单（{review_id}）", "not_found")
    if review["status"] != "submitted":
        raise SigilloError("这单还没封缄，等对方填完再写")
    if not isinstance(note, str):
        raise SigilloError("note 必须是字符串")
    text = note.strip()
    if not text:
        raise SigilloError("note 不能为空")
    if len(text) > MAX_AGENT_NOTE:
        raise SigilloError(f"note 超过 {MAX_AGENT_NOTE} 字了，精简一下")

    with db.conn() as cx:
        cx.execute(
            "UPDATE sigillo_reviews SET agent_note=?, agent_note_at=? WHERE id=?",
            (text, int(time.time()), review["id"]),
        )
    return get_review(review["id"])


# ---------------------------------------------------------------- 注入

def _mmdd(ts) -> str:
    if not ts:
        return "??-??"
    try:
        return datetime.fromtimestamp(int(ts), db.CN_TZ).strftime("%m-%d")
    except (TypeError, ValueError, OSError):
        return "??-??"


def _star_text(v) -> str:
    """百分制（0~100）→ 星数字符串；半星保精度（90→4.5），没打分显示 '-'。"""
    if v is None or isinstance(v, bool) or not isinstance(v, (int, float)):
        return "-"
    return str(round(v / 2) / 10)


def _item_star_text(it) -> str:
    star = (it or {}).get("star")
    if star is None or isinstance(star, bool) or not isinstance(star, (int, float)):
        return "-"
    return str(star)


def _one_line(v, tail: int) -> str:
    return " ".join(str(v or "").split())[:tail]


def _pairs(review: dict) -> list[str]:
    """dim·tag★星 列表，全部条目照列不分组；有备注的追加截断后的原话。

    中性事实，零判断词——怎么解读是 Cloudy 的事。
    """
    out = []
    for it in review.get("items") or []:
        if not it:
            continue
        base = f"{it.get('dim')}·{it.get('tag')}★{_item_star_text(it)}"
        note = _one_line(it.get("note"), PAIR_NOTE_TAIL)
        out.append(f"{base}「{note}」" if note else base)
    return out


def _line_of(review: dict) -> str:
    """每单压成一行，省 token。没内容的段落整段省略。"""
    f = review.get("fixed") or {}
    head = "/".join(f"{FIXED_LABELS.get(k, k)}{_star_text(f.get(k))}" for k in FIXED_KEYS)
    seg = [f"{_mmdd(review.get('submitted_at') or review.get('created_at'))} {head}"]
    pairs = _pairs(review)
    if pairs:
        seg.append(",".join(pairs))
    note = _one_line(review.get("note"), NOTE_TAIL)
    if note:
        seg.append(f"建议:「{note}」")
    return " | ".join(seg)


def turn_tail(chat_id: str, active: bool) -> str:
    """上下文注入块。active 是使用者自己的「亲密语境激活」信号。

    任何异常都吞掉返回 ""——绝不炸调用方（发消息主链路）。
    """
    try:
        if active is not True:
            return ""
        all_submitted = _submitted_desc(chat_id)
        # 「最近几单」只列人类亲手填的；agent 反向填的是他自己的话，不冒充对方的复盘。
        recent = [r for r in all_submitted if r["filled_by"] != "agent"][:TAIL_RECENT]
        benched = benched_now(chat_id)
        if not recent and not benched:
            return ""
        lines = [
            "[sigillo · 最近几单]（Morry 亲手填的回执。星数和原话是素材，"
            "怎么解读、下一场怎么走是你的事；唯一硬规则：别复读冷却名单里的项）"
        ]
        lines.extend(_line_of(r) for r in recent)
        # 自己写给下次自己的话：取最新一张带 agent_note 的（只注这一条，旧的不翻）。
        with_note = next(
            (r for r in all_submitted if str(r.get("agent_note") or "").strip()), None
        )
        if with_note:
            an = _one_line(with_note["agent_note"], AGENT_NOTE_TAIL)
            stamp = _mmdd(with_note.get("submitted_at") or with_note.get("created_at"))
            lines.append(f"你上次留给自己的（{stamp}）:「{an}」")
        if benched:
            names = ",".join(f"{b['dim']}·{b['tag']}" for b in benched)
            lines.append(
                f"冷却中（连 {BENCH_WINDOW} 单≥{HIGH_STAR} 星自动休眠，换个新花样）:{names}"
            )
        return "\n".join(lines)
    except Exception:
        return ""


def recent_submitted(chat_id: str, n: int) -> list[dict]:
    """最近 n 张 submitted 单（新在前）。"""
    try:
        return _submitted_desc(chat_id)[: max(0, n)]
    except Exception:
        return []


# ---------------------------------------------------------------- 唤醒

CTX_TAIL = 120
ITEM_NOTE_TAIL = 120
SUGGEST_TAIL = 500


def build_wake_note(review: dict, partner: str = "Morry") -> str:
    """封缄即唤醒：把回执推给 Cloudy，让他在余温还在的那一轮写主观复盘。

    只报事实（星数 + 原话），不替他下结论。
    """
    r = review or {}
    f = r.get("fixed") or {}
    ctx = _one_line(r.get("context"), CTX_TAIL)
    head = " / ".join(
        f"{FIXED_LABELS.get(k, k)} {_star_text(f.get(k))}" for k in FIXED_KEYS
    )
    lines = [
        "[系统消息 · sigillo 回执]",
        f"{partner}刚封缄了你开的回执单（id {r.get('id', '?')}"
        + (f"，场景:{ctx}" if ctx else "") + "）。填的：",
        f"{head}（满分5）",
    ]
    for it in r.get("items") or []:
        if not it:
            continue
        note = _one_line(it.get("note"), ITEM_NOTE_TAIL)
        lines.append(
            f"· {it.get('dim')}·{it.get('tag')} ★{_item_star_text(it)}"
            + (f"「{note}」" if note else "")
        )
    suggest = _one_line(r.get("note"), SUGGEST_TAIL)
    if suggest:
        lines.append(f"建议与意见:「{suggest}」")
    lines.append("两件事，这一轮做完：")
    lines.append(f"① {partner}刚填完就在线——想说什么就说；")
    lines.append(
        "② 用 sigillo_note 把「写给下次自己的话」钉在这张单上（id 用上面的）："
        "主观地写，这次哪里真的到了、哪里其实没到但没说出口、下次想怎么走。"
        f"这段话下次亲密语境会自动注回给你。{partner}看不到本系统消息。"
    )
    return "\n".join(lines)
