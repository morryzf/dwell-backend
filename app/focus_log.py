"""专注的正计时记录（YPT 那种）：分科目，点一下开始、再点一下停，
一天的总时长 = 各科相加。日子按北京时间切，跨过零点的那一段拆到两天里算。

记录存在服务器上，网页和 app 看到的是同一份；聊天时助手能看到今天的，
用 DwellFocusLog 工具能查过去的。
"""

from __future__ import annotations

import re
import time
from datetime import datetime, timedelta

from . import db

MAX_SUBJECTS = 30
# 一段最长算 16 小时：忘了停的那一段不会把一天撑到 24 小时以上。
MAX_SESSION_SECONDS = 16 * 3600
COLOR_RE = re.compile(r"#[0-9A-Fa-f]{6}")


class FocusError(ValueError):
    pass


def _now() -> int:
    return int(time.time())


def day_bounds(day: str) -> tuple[int, int]:
    """北京时间某一天的 [开始, 结束) Unix 秒。"""
    try:
        start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=db.CN_TZ)
    except ValueError as exc:
        raise FocusError("日期要写成 YYYY-MM-DD") from exc
    return int(start.timestamp()), int((start + timedelta(days=1)).timestamp())


def _end_of(row, now: int) -> int:
    end = row["ended"] if row["ended"] is not None else now
    return min(end, row["started"] + MAX_SESSION_SECONDS)


# ---------------------------------------------------------------- 科目

def subjects(include_archived: bool = False) -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute(
            "SELECT * FROM focus_subjects" + ("" if include_archived else " WHERE archived=0")
            + " ORDER BY sort ASC, made ASC"
        ).fetchall()
    return [{"id": r["id"], "name": r["name"], "color": r["color"], "archived": bool(r["archived"])} for r in rows]


def _clean_name(name: object) -> str:
    text = re.sub(r"\s+", " ", str(name or "")).strip()[:30]
    if not text:
        raise FocusError("科目名字不能为空")
    return text


def _clean_color(color: object) -> str:
    text = str(color or "").strip()
    return text.upper() if COLOR_RE.fullmatch(text) else "#D9A7B7"


def subject_add(name: object, color: object = "") -> dict:
    name = _clean_name(name)
    with db.conn() as cx:
        count = cx.execute("SELECT COUNT(*) FROM focus_subjects WHERE archived=0").fetchone()[0]
        if count >= MAX_SUBJECTS:
            raise FocusError(f"科目最多 {MAX_SUBJECTS} 个")
        sort = cx.execute("SELECT COALESCE(MAX(sort), 0) + 1 FROM focus_subjects").fetchone()[0]
        row = {"id": db.new_id(), "name": name, "color": _clean_color(color), "sort": sort, "made": _now()}
        cx.execute(
            "INSERT INTO focus_subjects (id,name,color,sort,archived,made) VALUES (:id,:name,:color,:sort,0,:made)",
            row,
        )
    return {"id": row["id"], "name": name, "color": row["color"], "archived": False}


def subject_edit(subject_id: str, name: object = None, color: object = None) -> None:
    sets, args = [], []
    if name is not None:
        sets.append("name=?")
        args.append(_clean_name(name))
    if color is not None:
        sets.append("color=?")
        args.append(_clean_color(color))
    if not sets:
        return
    with db.conn() as cx:
        cur = cx.execute(f"UPDATE focus_subjects SET {', '.join(sets)} WHERE id=?", (*args, subject_id))
    if not cur.rowcount:
        raise FocusError("没有这个科目")


def subject_archive(subject_id: str) -> None:
    """删科目只是收起来：过去的时长还算在那几天里。正在计时的话先停下。"""
    with db.conn() as cx:
        cx.execute("UPDATE focus_sessions SET ended=? WHERE subject_id=? AND ended IS NULL", (_now(), subject_id))
        cur = cx.execute("UPDATE focus_subjects SET archived=1 WHERE id=?", (subject_id,))
    if not cur.rowcount:
        raise FocusError("没有这个科目")


def subject_reorder(ids: list) -> None:
    with db.conn() as cx:
        for index, subject_id in enumerate(ids):
            cx.execute("UPDATE focus_subjects SET sort=? WHERE id=?", (index, str(subject_id)))


# ---------------------------------------------------------------- 计时

def running() -> dict | None:
    with db.conn() as cx:
        row = cx.execute(
            "SELECT * FROM focus_sessions WHERE ended IS NULL ORDER BY started DESC LIMIT 1"
        ).fetchone()
    if not row:
        return None
    return {"id": row["id"], "subject_id": row["subject_id"], "started": row["started"]}


def start(subject_id: str) -> dict:
    """开始给一个科目计时；别的科目正在计时就先停下（同一时间只有一段）。"""
    now = _now()
    with db.conn() as cx:
        subject = cx.execute(
            "SELECT id FROM focus_subjects WHERE id=? AND archived=0", (subject_id,)
        ).fetchone()
        if not subject:
            raise FocusError("没有这个科目")
        current = cx.execute("SELECT * FROM focus_sessions WHERE ended IS NULL").fetchall()
        for row in current:
            if row["subject_id"] == subject_id:
                return {"id": row["id"], "subject_id": subject_id, "started": row["started"]}
            cx.execute("UPDATE focus_sessions SET ended=? WHERE id=?", (_end_of(row, now), row["id"]))
        session = {"id": db.new_id(), "subject_id": subject_id, "started": now}
        cx.execute(
            "INSERT INTO focus_sessions (id,subject_id,started,ended,source) VALUES (:id,:subject_id,:started,NULL,'stopwatch')",
            session,
        )
    return session


def stop() -> dict | None:
    now = _now()
    stopped = None
    with db.conn() as cx:
        for row in cx.execute("SELECT * FROM focus_sessions WHERE ended IS NULL").fetchall():
            end = _end_of(row, now)
            cx.execute("UPDATE focus_sessions SET ended=? WHERE id=?", (end, row["id"]))
            stopped = {"id": row["id"], "subject_id": row["subject_id"], "started": row["started"], "ended": end}
    return stopped


def log(subject_id: str, started: int, ended: int, source: str = "pomodoro") -> dict:
    """补一段已经结束的计时（番茄钟做完一轮时用）。"""
    now = _now()
    started, ended = int(started), int(ended)
    if not 0 < started < ended <= now + 60:
        raise FocusError("这段时间不对")
    if ended - started > MAX_SESSION_SECONDS:
        raise FocusError("一段最长 16 小时")
    with db.conn() as cx:
        if not cx.execute("SELECT id FROM focus_subjects WHERE id=?", (subject_id,)).fetchone():
            raise FocusError("没有这个科目")
        row = {"id": db.new_id(), "subject_id": subject_id, "started": started,
               "ended": min(ended, now), "source": source[:20]}
        cx.execute(
            "INSERT INTO focus_sessions (id,subject_id,started,ended,source) VALUES (:id,:subject_id,:started,:ended,:source)",
            row,
        )
    return row


def session_delete(session_id: str) -> None:
    with db.conn() as cx:
        cur = cx.execute("DELETE FROM focus_sessions WHERE id=?", (session_id,))
    if not cur.rowcount:
        raise FocusError("没有这段记录")


# ---------------------------------------------------------------- 统计

def _sessions_between(start: int, end: int) -> list:
    with db.conn() as cx:
        return cx.execute(
            "SELECT s.*, f.name AS subject_name, f.color AS subject_color FROM focus_sessions s "
            "JOIN focus_subjects f ON f.id = s.subject_id "
            "WHERE s.started < ? AND s.started > ? AND (s.ended IS NULL OR s.ended > ?) "
            "ORDER BY s.started ASC",
            (end, start - MAX_SESSION_SECONDS, start),
        ).fetchall()


def day(day_str: str | None = None) -> dict:
    """某一天：各科时长、总时长、那天的每一段（只算落在这一天里的部分）。"""
    day_str = day_str or db.today_str()
    start, end = day_bounds(day_str)
    now = _now()
    by_subject: dict[str, int] = {}
    sessions = []
    for row in _sessions_between(start, end):
        a = max(row["started"], start)
        b = min(_end_of(row, now), end)
        if b <= a:
            continue
        by_subject[row["subject_id"]] = by_subject.get(row["subject_id"], 0) + (b - a)
        sessions.append({
            "id": row["id"], "subject_id": row["subject_id"], "subject": row["subject_name"],
            "color": row["subject_color"], "started": row["started"], "ended": row["ended"],
            "seconds": b - a, "source": row["source"],
        })
    return {"date": day_str, "total": sum(by_subject.values()), "by_subject": by_subject, "sessions": sessions}


def days(start_day: str, end_day: str) -> list[dict]:
    """[start_day, end_day] 每天各科时长，给统计图和工具用。最多 400 天。"""
    first, _ = day_bounds(start_day)
    _, last = day_bounds(end_day)
    if last <= first:
        raise FocusError("结束日期要在开始日期之后")
    if last - first > 400 * 86400:
        raise FocusError("一次最多查 400 天")
    now = _now()
    totals: dict[str, dict[str, int]] = {}
    for row in _sessions_between(first, last):
        a, b = max(row["started"], first), min(_end_of(row, now), last)
        while a < b:
            day_str = datetime.fromtimestamp(a, db.CN_TZ).strftime("%Y-%m-%d")
            _, day_end = day_bounds(day_str)
            piece = min(b, day_end) - a
            bucket = totals.setdefault(day_str, {})
            bucket[row["subject_id"]] = bucket.get(row["subject_id"], 0) + piece
            a += piece
    out = []
    cursor = datetime.strptime(start_day, "%Y-%m-%d")
    stop_at = datetime.strptime(end_day, "%Y-%m-%d")
    while cursor <= stop_at:
        key = cursor.strftime("%Y-%m-%d")
        bucket = totals.get(key, {})
        out.append({"date": key, "total": sum(bucket.values()), "by_subject": bucket})
        cursor += timedelta(days=1)
    return out


# ---------------------------------------------------------------- 设置

def settings() -> dict:
    try:
        goal = max(0, min(int(db.setting_get("focus_goal_minutes", "0") or 0), 24 * 60))
    except ValueError:
        goal = 0
    return {"goal_minutes": goal, "share": db.setting_get("focus_share", "1") != "0"}


def set_settings(goal_minutes: object = None, share: object = None) -> dict:
    if goal_minutes is not None:
        try:
            goal = int(goal_minutes)
        except (TypeError, ValueError) as exc:
            raise FocusError("目标要是整数分钟") from exc
        db.setting_set("focus_goal_minutes", str(max(0, min(goal, 24 * 60))))
    if share is not None:
        db.setting_set("focus_share", "1" if share else "0")
    return settings()


def snapshot(day_str: str | None = None) -> dict:
    """专注页一次要的全部东西。"""
    return {
        "ok": True,
        "subjects": subjects(),
        "running": running(),
        "today": day(day_str),
        "settings": settings(),
        "now": _now(),
    }


def _hm(seconds: int) -> str:
    hours, minutes = divmod(max(0, seconds) // 60, 60)
    return f"{hours}h{minutes:02d}m" if hours else f"{minutes}m"


def context_text() -> str:
    """聊天时给助手看的今天这一份。今天没开过计时就不打扰。"""
    if not settings()["share"]:
        return ""
    today = day()
    current = running()
    if not today["total"] and not current:
        return ""
    names = {s["id"]: s["name"] for s in subjects(include_archived=True)}
    lines = [f"Today so far: {_hm(today['total'])}"]
    goal = settings()["goal_minutes"]
    if goal:
        lines.append(f"Daily goal: {_hm(goal * 60)}")
    for subject_id, seconds in sorted(today["by_subject"].items(), key=lambda item: -item[1]):
        lines.append(f"- {names.get(subject_id, '?')}: {_hm(seconds)}")
    if current:
        elapsed = _now() - current["started"]
        lines.append(f"Timing right now: {names.get(current['subject_id'], '?')}, for {_hm(elapsed)}")
    else:
        lines.append("No timer running right now.")
    return "\n".join(lines)
