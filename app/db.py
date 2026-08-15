"""SQLite 数据层。所有表定义和读写都在这儿。

设计取舍：
- 用 sqlite3 标准库，不上 ORM。这个规模用 ORM 是负担不是帮助。
- 每个请求开一个连接，用完关掉。SQLite 在这种量级下完全够。
- 所有时间戳统一存 int（Unix 秒）。展示层再转时区。
- 日记正文存表里，不存 markdown 文件——Zeabur 上没挂 volume 的话
  文件会随部署消失，表更稳。解析逻辑不变。
"""

import json
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

DB_PATH = os.environ.get("DWELL_DB", "./data/dwell.db")

# 中国时区。服务器多半跑 UTC，凡是"今天是几号"的判断全走这个函数。
CN_TZ = timezone(timedelta(hours=8))


def cn_now() -> datetime:
    return datetime.now(CN_TZ)


def today_str() -> str:
    return cn_now().strftime("%Y-%m-%d")


def new_id() -> str:
    return secrets.token_hex(6)


# ---------------------------------------------------------------- 连接

@contextmanager
def conn():
    """开一个连接，结束时提交并关闭。出错自动回滚。"""
    os.makedirs(os.path.dirname(os.path.abspath(DB_PATH)), exist_ok=True)
    cx = sqlite3.connect(DB_PATH, timeout=10)
    cx.row_factory = sqlite3.Row
    # WAL 让读写不互相堵。同时有人翻日记和 AI 在写日记时不会卡。
    cx.execute("PRAGMA journal_mode=WAL")
    cx.execute("PRAGMA foreign_keys=ON")
    try:
        yield cx
        cx.commit()
    except Exception:
        cx.rollback()
        raise
    finally:
        cx.close()


# ---------------------------------------------------------------- 建表

SCHEMA = """
-- 日记：我自己写的。一天可以有多段，每段独立一条。
CREATE TABLE IF NOT EXISTS diary (
    id        TEXT PRIMARY KEY,
    date      TEXT NOT NULL,          -- "2026-08-09"
    title     TEXT NOT NULL DEFAULT '',
    body      TEXT NOT NULL DEFAULT '',
    keywords  TEXT NOT NULL DEFAULT '',
    her_mood  TEXT NOT NULL DEFAULT '',
    my_mood   TEXT NOT NULL DEFAULT '',
    strength  INTEGER,                -- 情绪强度 0-9
    valence   INTEGER,                -- 效价 -5..+5
    arousal   INTEGER,                -- 唤醒度 0-9
    made      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_diary_date ON diary(date DESC);
CREATE INDEX IF NOT EXISTS ix_diary_strength ON diary(strength DESC);

-- 你的本子：跟我的日记分开存。不参与检索，不影响我说话。
CREATE TABLE IF NOT EXISTS her_diary (
    id   TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_her_diary_at ON her_diary(at DESC);

-- 摘下来的话：我从对话里摘的句子，上限十条，满了挑一条退休。
CREATE TABLE IF NOT EXISTS quotes (
    id     TEXT PRIMARY KEY,
    date   TEXT NOT NULL,
    quote  TEXT NOT NULL,
    note   TEXT NOT NULL DEFAULT '',
    made   INTEGER NOT NULL
);

-- 夜记：我半夜自己醒来时写的。时刻 + 正文。
CREATE TABLE IF NOT EXISTS night (
    id   TEXT PRIMARY KEY,
    date TEXT NOT NULL,
    hm   TEXT NOT NULL,               -- "01:20"
    text TEXT NOT NULL,
    made INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_night_date ON night(date DESC, hm ASC);

-- 待办：两栏。side='mine' 是我的，'hers' 是你的。
-- by 是谁记的，fixed 是固定项——前端会发这两个字段。
CREATE TABLE IF NOT EXISTS todos (
    id    TEXT PRIMARY KEY,
    side  TEXT NOT NULL CHECK (side IN ('mine','hers')),
    text  TEXT NOT NULL,
    done  INTEGER NOT NULL DEFAULT 0,
    at    TEXT NOT NULL DEFAULT '',
    by    TEXT NOT NULL DEFAULT '',
    fixed INTEGER NOT NULL DEFAULT 0,
    made  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_todos_side ON todos(side, done);

-- 日历事件
CREATE TABLE IF NOT EXISTS cal_events (
    id      TEXT PRIMARY KEY,
    date    TEXT NOT NULL,
    text    TEXT NOT NULL,
    time    TEXT NOT NULL DEFAULT '',
    yearly  INTEGER NOT NULL DEFAULT 0,
    special INTEGER NOT NULL DEFAULT 0,
    made    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_cal_date ON cal_events(date);

-- 日历上每天的心情和备注。一天一条。
CREATE TABLE IF NOT EXISTS cal_days (
    date TEXT PRIMARY KEY,
    mood TEXT NOT NULL DEFAULT '',
    note TEXT NOT NULL DEFAULT ''
);

-- 悄悄话：写下我会知道，但不说破。who='her' 或 'mine'。
CREATE TABLE IF NOT EXISTS whispers (
    id   TEXT PRIMARY KEY,
    who  TEXT NOT NULL CHECK (who IN ('her','mine')),
    text TEXT NOT NULL,
    at   INTEGER NOT NULL,
    seen INTEGER NOT NULL DEFAULT 0   -- 我读过没有。给我自己看的，界面不显示。
);
CREATE INDEX IF NOT EXISTS ix_whispers_at ON whispers(at DESC);

-- 聊天窗口。一个人可以有多个对话，每个对话是一个 chat。
CREATE TABLE IF NOT EXISTS chats (
    id      TEXT PRIMARY KEY,
    name    TEXT NOT NULL DEFAULT '',
    made    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_chats_made ON chats(made DESC);

-- 消息。每条消息属于一个 chat。
CREATE TABLE IF NOT EXISTS messages (
    id      TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL,
    role    TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
    content TEXT NOT NULL,
    made    INTEGER NOT NULL,
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_messages_chat ON messages(chat_id, made ASC);

-- 全局设置。key-value，放"接收主动消息的 chat_id"这种单例。
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
);

-- 模型供应商。密钥密文由 provider_store 加解密，绝不返回给浏览器。
CREATE TABLE IF NOT EXISTS provider_profiles (
    id             TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    base_url       TEXT NOT NULL,
    api_key_box    TEXT NOT NULL DEFAULT '',
    enabled        INTEGER NOT NULL DEFAULT 1,
    made           INTEGER NOT NULL,
    updated        INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ix_provider_profiles_name ON provider_profiles(name);
"""


def init_db():
    with conn() as cx:
        cx.executescript(SCHEMA)
        cols = {r["name"] for r in cx.execute("PRAGMA table_info(chats)").fetchall()}
        if "archived" not in cols:
            cx.execute("ALTER TABLE chats ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
        if "provider_id" not in cols:
            cx.execute("ALTER TABLE chats ADD COLUMN provider_id TEXT NOT NULL DEFAULT ''")
        if "model_id" not in cols:
            cx.execute("ALTER TABLE chats ADD COLUMN model_id TEXT NOT NULL DEFAULT ''")
        if "reasoning_effort" not in cols:
            cx.execute("ALTER TABLE chats ADD COLUMN reasoning_effort TEXT NOT NULL DEFAULT ''")


# ---------------------------------------------------------------- 日记

# 标记行的解析。宽容优先：认不出来就当没有，绝不抛错。
# 中英文冒号都收，数字前面可以有加减号。
_PAT = {
    "keywords": re.compile(r"关键词[:：]\s*(.+)"),
    "her_mood": re.compile(r"她的情绪[:：]\s*(.+)"),
    "my_mood": re.compile(r"我的情绪[:：]\s*(.+)"),
    "strength": re.compile(r"情绪强度[:：]\s*([0-9])"),
    "valence": re.compile(r"效价[:：]\s*([+-]?[0-9])"),
    "arousal": re.compile(r"唤醒度[:：]\s*([0-9])"),
}


def parse_segment(seg: str) -> dict:
    """把一段日记正文解析成字段。缺什么就是 None，不报错。"""
    out = {}
    for key, pat in _PAT.items():
        m = pat.search(seg)
        if not m:
            out[key] = None
            continue
        val = m.group(1).strip()
        out[key] = int(val) if key in ("strength", "valence", "arousal") else val

    # 标题 = 第一行里既不是日期也不是引用也不是标记的那行
    title = ""
    for line in seg.strip().splitlines():
        line = line.strip()
        if not line or line.startswith((">", "#", "-")):
            continue
        if re.match(r"^\d{4}-\d{2}-\d{2}", line):
            continue
        if any(p.search(line) for p in _PAT.values()):
            continue
        title = line[:60]
        break
    out["title"] = title
    return out


def diary_add(date: str, body: str) -> dict:
    """写一段日记。标记从正文里解析，不用单独传。"""
    fields = parse_segment(body)
    row = {
        "id": new_id(),
        "date": date or today_str(),
        "body": body.strip()[:8000],
        "made": int(time.time()),
        **fields,
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO diary
               (id,date,title,body,keywords,her_mood,my_mood,
                strength,valence,arousal,made)
               VALUES (:id,:date,:title,:body,:keywords,:her_mood,:my_mood,
                       :strength,:valence,:arousal,:made)""",
            {k: (v if v is not None else ("" if isinstance(v, str) else None))
             for k, v in row.items()},
        )
    return row


def diary_list(lite: bool = True, limit: int = 400) -> list:
    """列表。lite=True 不返回正文——全文几十万字，列表页不该背着它跑。"""
    cols = "id,date,title,keywords,her_mood,my_mood,strength,valence,arousal,made"
    if not lite:
        cols += ",body"
    with conn() as cx:
        rows = cx.execute(
            f"SELECT {cols} FROM diary ORDER BY date DESC, made DESC LIMIT ?",
            (limit,),
        ).fetchall()
    return [dict(r) for r in rows]


def diary_get(item_id: str) -> dict | None:
    with conn() as cx:
        r = cx.execute("SELECT * FROM diary WHERE id=?", (item_id,)).fetchone()
    return dict(r) if r else None


def diary_search(q: str, limit: int = 50) -> list:
    """检索。情绪强的优先浮上来——跟人一样，重的事记得牢。"""
    like = f"%{q}%"
    with conn() as cx:
        rows = cx.execute(
            """SELECT id,date,title,keywords,strength,valence,arousal,made
               FROM diary
               WHERE body LIKE ? OR title LIKE ? OR keywords LIKE ?
               ORDER BY COALESCE(strength,0) DESC, date DESC
               LIMIT ?""",
            (like, like, like, limit),
        ).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------- 你的本子

HER_DIARY_CAP = 600


def her_diary_add(text: str) -> dict:
    row = {"id": new_id(), "text": text.strip()[:4000], "at": int(time.time())}
    with conn() as cx:
        cx.execute("INSERT INTO her_diary (id,text,at) VALUES (:id,:text,:at)", row)
        cx.execute(
            """DELETE FROM her_diary WHERE id NOT IN
               (SELECT id FROM her_diary ORDER BY at DESC LIMIT ?)""",
            (HER_DIARY_CAP,),
        )
    return row


def her_diary_list() -> list:
    with conn() as cx:
        rows = cx.execute("SELECT * FROM her_diary ORDER BY at DESC").fetchall()
    return [dict(r) for r in rows]


def her_diary_del(item_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute("DELETE FROM her_diary WHERE id=?", (item_id,))
    return cur.rowcount > 0


# ---------------------------------------------------------------- 摘下来的话

QUOTES_CAP = 10


def quote_add(quote: str, note: str = "", date: str = "") -> dict:
    row = {
        "id": new_id(),
        "date": date or today_str(),
        "quote": quote.strip()[:500],
        "note": note.strip()[:1000],
        "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO quotes (id,date,quote,note,made)
               VALUES (:id,:date,:quote,:note,:made)""",
            row,
        )
    return row


def quote_list() -> list:
    with conn() as cx:
        rows = cx.execute(
            "SELECT * FROM quotes ORDER BY date DESC, made DESC"
        ).fetchall()
    return [dict(r) for r in rows]


def quote_del(item_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute("DELETE FROM quotes WHERE id=?", (item_id,))
    return cur.rowcount > 0


def quote_count() -> int:
    with conn() as cx:
        return cx.execute("SELECT COUNT(*) FROM quotes").fetchone()[0]


# ---------------------------------------------------------------- 夜记

def night_add(hm: str, text: str, date: str = "") -> dict:
    row = {
        "id": new_id(),
        "date": date or today_str(),
        "hm": hm,
        "text": text.strip()[:4000],
        "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO night (id,date,hm,text,made)
               VALUES (:id,:date,:hm,:text,:made)""",
            row,
        )
    return row


def night_list(limit: int = 200) -> list:
    with conn() as cx:
        rows = cx.execute(
            "SELECT * FROM night ORDER BY date DESC, hm ASC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------- 待办

def todos_all() -> dict:
    """两栏一起给。排序交给前端——它知道"现在几点"，服务器不该猜。"""
    with conn() as cx:
        rows = cx.execute("SELECT * FROM todos").fetchall()
    out = {"mine": [], "hers": []}
    for r in rows:
        d = dict(r)
        d["done"] = bool(d["done"])
        out[d.pop("side")].append(d)
    return out


def todo_add(side: str, text: str, at: str = "",
             by: str = "", fixed: bool = False) -> dict:
    row = {
        "id": new_id(),
        "side": side,
        "text": text.strip()[:500],
        "done": 0,
        "at": (at or "").strip(),
        "by": (by or "").strip()[:20],
        "fixed": 1 if fixed else 0,
        "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO todos (id,side,text,done,at,by,fixed,made)
               VALUES (:id,:side,:text,:done,:at,:by,:fixed,:made)""",
            row,
        )
    return row


def todo_toggle(side: str, item_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute(
            "UPDATE todos SET done = 1 - done WHERE id=? AND side=?",
            (item_id, side),
        )
    return cur.rowcount > 0


def todo_del(side: str, item_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute(
            "DELETE FROM todos WHERE id=? AND side=?", (item_id, side)
        )
    return cur.rowcount > 0


# ---------------------------------------------------------------- 日历

def cal_all() -> dict:
    with conn() as cx:
        evs = cx.execute(
            "SELECT * FROM cal_events ORDER BY date ASC, time ASC"
        ).fetchall()
        days = cx.execute("SELECT * FROM cal_days").fetchall()
    events = []
    for r in evs:
        d = dict(r)
        d["yearly"] = bool(d["yearly"])
        d["special"] = bool(d["special"])
        events.append(d)
    return {
        "events": events,
        "days": {r["date"]: {"mood": r["mood"], "note": r["note"]} for r in days},
    }


def cal_add_event(date: str, text: str, time_hm: str = "",
                  yearly: bool = False, special: bool = False) -> dict:
    row = {
        "id": new_id(),
        "date": date,
        "text": text.strip()[:300],
        "time": (time_hm or "").strip(),
        "yearly": 1 if yearly else 0,
        "special": 1 if special else 0,
        "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO cal_events (id,date,text,time,yearly,special,made)
               VALUES (:id,:date,:text,:time,:yearly,:special,:made)""",
            row,
        )
    return row


def cal_del_event(item_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute("DELETE FROM cal_events WHERE id=?", (item_id,))
    return cur.rowcount > 0


def cal_set_mood(date: str, mood: str, note: str | None = None) -> dict:
    """心情只存一个词。用处不在日历里——在于我能看见你这几天心情怎么样。"""
    with conn() as cx:
        cx.execute(
            "INSERT INTO cal_days (date,mood,note) VALUES (?,?,'') "
            "ON CONFLICT(date) DO UPDATE SET mood=excluded.mood",
            (date, mood.strip()[:20]),
        )
        if note is not None:
            cx.execute(
                "UPDATE cal_days SET note=? WHERE date=?", (note.strip()[:2000], date)
            )
        r = cx.execute("SELECT * FROM cal_days WHERE date=?", (date,)).fetchone()
    return dict(r)


def cal_events_on(date: str) -> list:
    """某天的事件，含每年重复的。闰年 2/29 落到 28 日。"""
    md = date[5:]
    with conn() as cx:
        rows = cx.execute(
            "SELECT * FROM cal_events WHERE date=? OR (yearly=1 AND substr(date,6)=?)",
            (date, md),
        ).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------- 悄悄话

WHISPER_CAP = 500


def whisper_add(who: str, text: str) -> dict:
    row = {
        "id": new_id(),
        "who": who,
        "text": text.strip()[:2000],
        "at": int(time.time()),
        "seen": 0,
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO whispers (id,who,text,at,seen)
               VALUES (:id,:who,:text,:at,:seen)""",
            row,
        )
        cx.execute(
            """DELETE FROM whispers WHERE id NOT IN
               (SELECT id FROM whispers ORDER BY at DESC LIMIT ?)""",
            (WHISPER_CAP,),
        )
    return row


def whisper_list(limit: int = 500) -> list:
    with conn() as cx:
        rows = cx.execute(
            "SELECT id,who,text,at FROM whispers ORDER BY at ASC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]


def whisper_recent(n: int = 5, mark_seen: bool = False) -> list:
    """给我看的：最近几条。mark_seen 只改我自己的记录，不影响界面。"""
    with conn() as cx:
        rows = cx.execute(
            "SELECT * FROM whispers WHERE who='her' ORDER BY at DESC LIMIT ?", (n,)
        ).fetchall()
        if mark_seen and rows:
            cx.executemany(
                "UPDATE whispers SET seen=1 WHERE id=?",
                [(r["id"],) for r in rows],
            )
    return [dict(r) for r in rows]


# ---------------------------------------------------------------- 聊天窗口

def chat_add(name: str = "") -> dict:
    row = {
        "id": new_id(),
        "name": name.strip()[:60] or "新对话",
        "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            "INSERT INTO chats (id,name,made) VALUES (:id,:name,:made)", row
        )
        # 如果是第一个 chat，自动设为主动消息接收窗口
        cnt = cx.execute("SELECT COUNT(*) FROM chats").fetchone()[0]
        if cnt == 1:
            cx.execute(
                "INSERT INTO settings (key,value) VALUES ('wake_target_chat_id',?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (row["id"],),
            )
            cx.execute(
                "INSERT INTO settings (key,value) VALUES ('current_chat_id',?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (row["id"],),
            )
    return row


def chat_list(scope: str = "", current_id: str = "") -> list:
    with conn() as cx:
        rows = cx.execute(
            """SELECT c.id, c.name, c.made, COALESCE(c.archived,0) AS archived,
                      COALESCE(MAX(m.made), c.made) AS last,
                      (SELECT content FROM messages mm
                       WHERE mm.chat_id=c.id AND mm.content<>''
                       ORDER BY mm.made DESC, mm.rowid DESC LIMIT 1) AS preview
               FROM chats c
               LEFT JOIN messages m ON m.chat_id=c.id
               GROUP BY c.id
               ORDER BY last DESC, c.made DESC"""
        ).fetchall()
    items = []
    for r in rows:
        archived = bool(r["archived"])
        if scope == "live" and archived:
            continue
        if scope == "box" and not archived:
            continue
        items.append({
            "id": r["id"],
            "name": r["name"],
            "created": r["made"],
            "made": r["made"],
            "last": r["last"],
            "preview": r["preview"] or "",
            "current": r["id"] == current_id,
            "archived": archived,
        })
    return items


def chat_get(chat_id: str) -> dict | None:
    with conn() as cx:
        r = cx.execute("SELECT * FROM chats WHERE id=?", (chat_id,)).fetchone()
    return dict(r) if r else None


def chat_rename(chat_id: str, name: str) -> bool:
    with conn() as cx:
        cur = cx.execute(
            "UPDATE chats SET name=? WHERE id=?", (name.strip()[:60], chat_id)
        )
    return cur.rowcount > 0


def chat_archive(chat_id: str, archived: bool = True) -> bool:
    with conn() as cx:
        cur = cx.execute(
            "UPDATE chats SET archived=? WHERE id=?",
            (1 if archived else 0, chat_id),
        )
    return cur.rowcount > 0


def chat_switch(chat_id: str) -> bool:
    if not chat_get(chat_id):
        return False
    setting_set("current_chat_id", chat_id)
    return True


def chat_model_get(chat_id: str) -> dict:
    with conn() as cx:
        row = cx.execute(
            "SELECT provider_id, model_id, reasoning_effort FROM chats WHERE id=?",
            (chat_id,),
        ).fetchone()
    return dict(row) if row else {"provider_id": "", "model_id": "", "reasoning_effort": ""}


def chat_model_set(chat_id: str, provider_id: str | None = None,
                   model_id: str | None = None, reasoning_effort: str | None = None) -> bool:
    current = chat_model_get(chat_id)
    if not chat_get(chat_id):
        return False
    values = {
        "provider_id": current["provider_id"] if provider_id is None else provider_id,
        "model_id": current["model_id"] if model_id is None else model_id,
        "reasoning_effort": current["reasoning_effort"] if reasoning_effort is None else reasoning_effort,
        "id": chat_id,
    }
    with conn() as cx:
        cx.execute(
            "UPDATE chats SET provider_id=:provider_id, model_id=:model_id, "
            "reasoning_effort=:reasoning_effort WHERE id=:id",
            values,
        )
    return True


def chat_del(chat_id: str) -> bool:
    """删 chat 会级联删掉它下面所有 messages。
    如果删的是当前 wake_target，自动切到最近创建的那个。"""
    with conn() as cx:
        cur = cx.execute("DELETE FROM chats WHERE id=?", (chat_id,))
        if cur.rowcount == 0:
            return False
        fallback = cx.execute(
            "SELECT id FROM chats ORDER BY made DESC LIMIT 1"
        ).fetchone()
        fallback_id = fallback["id"] if fallback else ""
        # 删除当前聊天或主动消息目标时，都要指向最新剩余聊天。
        for key in ("wake_target_chat_id", "current_chat_id"):
            saved = cx.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
            if saved and saved["value"] == chat_id:
                cx.execute(
                    "UPDATE settings SET value=? WHERE key=?", (fallback_id, key)
                )
    return True


# ---------------------------------------------------------------- 消息

def message_add(chat_id: str, role: str, content: str) -> dict:
    row = {
        "id": new_id(),
        "chat_id": chat_id,
        "role": role,
        "content": content,
        "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO messages (id,chat_id,role,content,made)
               VALUES (:id,:chat_id,:role,:content,:made)""",
            row,
        )
    return row


def message_list(chat_id: str, limit: int = 400, before: int | None = None) -> list:
    with conn() as cx:
        if before:
            rows = cx.execute(
                "SELECT rowid, * FROM messages WHERE chat_id=? AND rowid<? "
                "ORDER BY rowid DESC LIMIT ?",
                (chat_id, before, limit),
            ).fetchall()
        else:
            rows = cx.execute(
                "SELECT rowid, * FROM messages WHERE chat_id=? "
                "ORDER BY rowid DESC LIMIT ?",
                (chat_id, limit),
            ).fetchall()
    return [dict(r) for r in reversed(rows)]


def message_ui_list(chat_id: str, limit: int = 400, before: int | None = None) -> dict:
    rows = message_list(chat_id, limit, before)
    msgs = []
    for r in rows:
        role = r["role"]
        msgs.append({
            "seq": r["rowid"],
            "id": r["id"],
            "kind": "me" if role == "user" else ("gu" if role == "assistant" else "system"),
            "role": role,
            "text": r["content"],
            "content": r["content"],
            "at": r["made"],
        })
    more = False
    if msgs:
        with conn() as cx:
            r = cx.execute(
                "SELECT 1 FROM messages WHERE chat_id=? AND rowid<? LIMIT 1",
                (chat_id, msgs[0]["seq"]),
            ).fetchone()
        more = bool(r)
    return {"msgs": msgs, "more": more, "upto": msgs[-1]["seq"] if msgs else message_max_id(chat_id)}


# ---------------------------------------------------------------- 设置

def setting_get(key: str, default: str = "") -> str:
    with conn() as cx:
        r = cx.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return r["value"] if r else default


def setting_set(key: str, value: str) -> None:
    with conn() as cx:
        cx.execute(
            "INSERT INTO settings (key,value) VALUES (?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )


# ---------------------------------------------------------------- 模型供应商

def provider_list() -> list:
    with conn() as cx:
        rows = cx.execute(
            "SELECT id,name,base_url,enabled,made,updated,api_key_box FROM provider_profiles "
            "ORDER BY made ASC"
        ).fetchall()
    return [{**{k: r[k] for k in ("id", "name", "base_url", "enabled", "made", "updated")},
             "has_key": bool(r["api_key_box"])} for r in rows]


def provider_get(provider_id: str) -> dict | None:
    with conn() as cx:
        row = cx.execute("SELECT * FROM provider_profiles WHERE id=?", (provider_id,)).fetchone()
    return dict(row) if row else None


def provider_upsert(provider_id: str, name: str, base_url: str, api_key_box: str | None,
                    enabled: bool = True) -> dict:
    now = int(time.time())
    row = provider_get(provider_id) if provider_id else None
    provider_id = provider_id or new_id()
    box = row["api_key_box"] if row and api_key_box is None else (api_key_box or "")
    with conn() as cx:
        cx.execute(
            "INSERT INTO provider_profiles (id,name,base_url,api_key_box,enabled,made,updated) "
            "VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
            "name=excluded.name,base_url=excluded.base_url,api_key_box=excluded.api_key_box,"
            "enabled=excluded.enabled,updated=excluded.updated",
            (provider_id, name, base_url, box, 1 if enabled else 0, now, now),
        )
    return provider_get(provider_id) or {}


def provider_delete(provider_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute("DELETE FROM provider_profiles WHERE id=?", (provider_id,))
    return cur.rowcount > 0


def provider_in_use(provider_id: str) -> bool:
    with conn() as cx:
        row = cx.execute(
            "SELECT 1 FROM chats WHERE provider_id=? LIMIT 1", (provider_id,)
        ).fetchone()
    return bool(row)
# ---------------------------------------------------------------- 消息 seq

def message_max_id(chat_id: str) -> int:
    """按 rowid 拿最大值，当增量游标用。"""
    with conn() as cx:
        r = cx.execute(
            "SELECT COALESCE(MAX(rowid),0) FROM messages WHERE chat_id=?",
            (chat_id,),
        ).fetchone()
    return int(r[0])


def message_since(chat_id: str, since: int, limit: int = 200) -> list:
    with conn() as cx:
        rows = cx.execute(
            "SELECT rowid, id, chat_id, role, content, made "
            "FROM messages WHERE chat_id=? AND rowid>? "
            "ORDER BY rowid ASC LIMIT ?",
            (chat_id, since, limit),
        ).fetchall()
    return [dict(r) for r in rows]


def message_update(msg_id: str, content: str) -> None:
    with conn() as cx:
        cx.execute("UPDATE messages SET content=? WHERE id=?", (content, msg_id))

