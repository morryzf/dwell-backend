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

-- 聊天图片只保存前端压缩后的缩略图。原图仍只用于当次模型请求，避免数据库膨胀。
CREATE TABLE IF NOT EXISTS message_attachments (
    id         TEXT PRIMARY KEY,
    message_id TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'image',
    data_url   TEXT NOT NULL,
    made       INTEGER NOT NULL,
    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_message_attachments_message
ON message_attachments(message_id, made ASC);

-- 聊天的长期上下文。原始 messages 永远是唯一原始记录；这里仅存可重新生成的
-- 派生摘要，以及它已覆盖到的消息位置。
CREATE TABLE IF NOT EXISTS chat_memory_state (
    chat_id          TEXT PRIMARY KEY,
    enabled          INTEGER NOT NULL DEFAULT 0,
    overview         TEXT NOT NULL DEFAULT '',
    through_rowid    INTEGER NOT NULL DEFAULT 0,
    status           TEXT NOT NULL DEFAULT 'idle',
    error            TEXT NOT NULL DEFAULT '',
    generated_at     INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chat_memory_segments (
    id           TEXT PRIMARY KEY,
    chat_id      TEXT NOT NULL,
    start_rowid  INTEGER NOT NULL,
    end_rowid    INTEGER NOT NULL,
    content      TEXT NOT NULL,
    made         INTEGER NOT NULL,
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_chat_memory_segments_chat
ON chat_memory_segments(chat_id, start_rowid, end_rowid);

-- AI 回复的旧版本。重新生成或手动编辑时先存一份，当前 messages 表始终只保留
-- 后续上下文真正会读到的那一版。
CREATE TABLE IF NOT EXISTS message_versions (
    id         TEXT PRIMARY KEY,
    message_id TEXT NOT NULL,
    content    TEXT NOT NULL,
    reason     TEXT NOT NULL DEFAULT '',
    made       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_message_versions_message ON message_versions(message_id, made ASC);

-- 工具调用独立于 AI 正文保存。正文编辑、版本切换都不会吞掉工具参数或返回结果。
CREATE TABLE IF NOT EXISTS tool_calls (
    id                   TEXT PRIMARY KEY,
    chat_id              TEXT NOT NULL,
    assistant_message_id TEXT NOT NULL,
    name                 TEXT NOT NULL,
    arguments            TEXT NOT NULL DEFAULT '{}',
    result               TEXT NOT NULL DEFAULT '',
    is_error             INTEGER NOT NULL DEFAULT 0,
    made                 INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_tool_calls_message ON tool_calls(assistant_message_id, made ASC);

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

-- MCP 工具服务器。headers_box 是加密后的 JSON，可能含 Bearer token 等凭据。
CREATE TABLE IF NOT EXISTS mcp_servers (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    url         TEXT NOT NULL,
    transport   TEXT NOT NULL DEFAULT 'streamable_http',
    headers_box TEXT NOT NULL DEFAULT '',
    enabled     INTEGER NOT NULL DEFAULT 1,
    made        INTEGER NOT NULL,
    updated     INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ix_mcp_servers_name ON mcp_servers(name);

-- 哪些 MCP 服务器可以被某个聊天使用。工具不是全局强塞给每个聊天的。
CREATE TABLE IF NOT EXISTS chat_mcp_servers (
    chat_id   TEXT NOT NULL,
    server_id TEXT NOT NULL,
    PRIMARY KEY (chat_id, server_id),
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE,
    FOREIGN KEY (server_id) REFERENCES mcp_servers(id) ON DELETE CASCADE
);

-- Dwell 自己的“家里工具”也按聊天单独授权；目前先放待办，后续可平滑扩展。
CREATE TABLE IF NOT EXISTS chat_home_tools (
    chat_id            TEXT PRIMARY KEY,
    todos_enabled      INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

-- 可复用的聊天指令，以及每间聊天各自启用的集合。
CREATE TABLE IF NOT EXISTS instruction_presets (
    id      TEXT PRIMARY KEY,
    name    TEXT NOT NULL,
    content TEXT NOT NULL,
    made    INTEGER NOT NULL,
    updated INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ix_instruction_presets_name ON instruction_presets(name);

CREATE TABLE IF NOT EXISTS chat_instruction_presets (
    chat_id        TEXT NOT NULL,
    instruction_id TEXT NOT NULL,
    PRIMARY KEY (chat_id, instruction_id),
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE,
    FOREIGN KEY (instruction_id) REFERENCES instruction_presets(id) ON DELETE CASCADE
);

-- 每家供应商拉取到的模型目录。收藏是用户的常用清单，不会改变供应商原始模型 ID。
CREATE TABLE IF NOT EXISTS provider_models (
    provider_id TEXT NOT NULL,
    model_id    TEXT NOT NULL,
    favorite    INTEGER NOT NULL DEFAULT 0,
    manual      INTEGER NOT NULL DEFAULT 0,
    made        INTEGER NOT NULL,
    updated     INTEGER NOT NULL,
    PRIMARY KEY (provider_id, model_id),
    FOREIGN KEY (provider_id) REFERENCES provider_profiles(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_provider_models_favorite ON provider_models(favorite, updated DESC);
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
        if "split_replies" not in cols:
            cx.execute("ALTER TABLE chats ADD COLUMN split_replies INTEGER NOT NULL DEFAULT 0")


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


def diary_add(date: str, body: str, keywords: str = "") -> dict:
    """写一段日记。标记从正文里解析，不用单独传。"""
    fields = parse_segment(body)
    # diary.keywords is NOT NULL. A tool caller can name keywords explicitly;
    # otherwise store parsed keywords or an empty string, never NULL.
    fields["keywords"] = str(keywords or fields.get("keywords") or "").strip()[:300]
    row = {
        "id": new_id(),
        "date": date or today_str(),
        "body": body.strip()[:8000],
        "made": int(time.time()),
        **fields,
    }
    for key in ("title", "keywords", "her_mood", "my_mood"):
        row[key] = str(row.get(key) or "")
    with conn() as cx:
        cx.execute(
            """INSERT INTO diary
               (id,date,title,body,keywords,her_mood,my_mood,
                strength,valence,arousal,made)
               VALUES (:id,:date,:title,:body,:keywords,:her_mood,:my_mood,
                       :strength,:valence,:arousal,:made)""",
            row,
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


def whisper_unseen(n: int = 5, mark_seen: bool = False) -> list:
    """按写下的顺序取尚未带进聊天上下文的用户悄悄话。"""
    with conn() as cx:
        rows = cx.execute(
            "SELECT * FROM whispers WHERE who='her' AND seen=0 ORDER BY at ASC LIMIT ?",
            (n,),
        ).fetchall()
        if mark_seen and rows:
            cx.executemany(
                "UPDATE whispers SET seen=1 WHERE id=?",
                [(row["id"],) for row in rows],
            )
    return [dict(row) for row in rows]


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


def chat_branch_from_message(source_chat_id: str, message_id: str) -> dict | None:
    """复制从开头到指定消息的一条时间线，原聊天不受影响。"""
    with conn() as cx:
        source = cx.execute("SELECT * FROM chats WHERE id=?", (source_chat_id,)).fetchone()
        pivot = cx.execute("SELECT rowid,* FROM messages WHERE id=? AND chat_id=?", (message_id, source_chat_id)).fetchone()
        if not source or not pivot:
            return None
        suffix = " · 分支"
        base_name = (source["name"] or "对话").strip() or "对话"
        branch = {"id": new_id(), "name": base_name[:max(1, 60 - len(suffix))] + suffix,
                  "made": int(time.time()), "provider_id": source["provider_id"],
                  "model_id": source["model_id"], "reasoning_effort": source["reasoning_effort"]}
        cx.execute("""INSERT INTO chats (id,name,made,archived,provider_id,model_id,reasoning_effort)
                      VALUES (:id,:name,:made,0,:provider_id,:model_id,:reasoning_effort)""", branch)
        rows = cx.execute("SELECT rowid,* FROM messages WHERE chat_id=? AND rowid<=? ORDER BY rowid ASC",
                          (source_chat_id, pivot["rowid"])).fetchall()
        id_map: dict[str, str] = {}
        for row in rows:
            fresh = new_id(); id_map[row["id"]] = fresh
            cx.execute("INSERT INTO messages (id,chat_id,role,content,made) VALUES (?,?,?,?,?)",
                       (fresh, branch["id"], row["role"], row["content"], row["made"]))
        for old_id, fresh in id_map.items():
            versions = cx.execute("SELECT content,reason,made FROM message_versions WHERE message_id=? ORDER BY rowid ASC", (old_id,)).fetchall()
            cx.executemany("INSERT INTO message_versions (id,message_id,content,reason,made) VALUES (?,?,?,?,?)",
                           [(new_id(), fresh, item["content"], item["reason"], item["made"]) for item in versions])
            calls = cx.execute("""SELECT name,arguments,result,is_error,made FROM tool_calls
                                  WHERE assistant_message_id=? ORDER BY rowid ASC""", (old_id,)).fetchall()
            cx.executemany("""INSERT INTO tool_calls (id,chat_id,assistant_message_id,name,arguments,result,is_error,made)
                              VALUES (?,?,?,?,?,?,?,?)""",
                           [(new_id(), branch["id"], fresh, item["name"], item["arguments"], item["result"], item["is_error"], item["made"]) for item in calls])
            images = cx.execute(
                "SELECT kind,data_url,made FROM message_attachments WHERE message_id=? ORDER BY rowid ASC",
                (old_id,),
            ).fetchall()
            cx.executemany(
                """INSERT INTO message_attachments (id,message_id,kind,data_url,made)
                   VALUES (?,?,?,?,?)""",
                [(new_id(), fresh, item["kind"], item["data_url"], item["made"]) for item in images],
            )
        cx.execute("INSERT INTO chat_mcp_servers (chat_id,server_id) SELECT ?,server_id FROM chat_mcp_servers WHERE chat_id=?",
                   (branch["id"], source_chat_id))
        cx.execute("INSERT INTO chat_instruction_presets (chat_id,instruction_id) SELECT ?,instruction_id FROM chat_instruction_presets WHERE chat_id=?",
                   (branch["id"], source_chat_id))
    return {"id": branch["id"], "name": branch["name"], "made": branch["made"]}


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


def chat_split_replies_get(chat_id: str) -> bool:
    with conn() as cx:
        row = cx.execute("SELECT COALESCE(split_replies,0) AS split_replies FROM chats WHERE id=?", (chat_id,)).fetchone()
    return bool(row and row["split_replies"])


def chat_split_replies_set(chat_id: str, enabled: bool) -> bool:
    with conn() as cx:
        cur = cx.execute("UPDATE chats SET split_replies=? WHERE id=?", (1 if enabled else 0, chat_id))
    return cur.rowcount > 0


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

def message_add(chat_id: str, role: str, content: str, made: int | None = None) -> dict:
    row = {
        "id": new_id(),
        "chat_id": chat_id,
        "role": role,
        "content": content,
        "made": int(made if made is not None else time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO messages (id,chat_id,role,content,made)
               VALUES (:id,:chat_id,:role,:content,:made)""",
            row,
        )
    return row


def message_attachment_add(message_id: str, data_url: str) -> dict:
    """给消息保存一张经过前端压缩的图片缩略图。"""
    if not data_url.startswith("data:image/") or len(data_url) > 700_000:
        raise ValueError("图片缩略图无效或过大")
    row = {
        "id": new_id(),
        "message_id": message_id,
        "kind": "image",
        "data_url": data_url,
        "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO message_attachments (id,message_id,kind,data_url,made)
               VALUES (:id,:message_id,:kind,:data_url,:made)""",
            row,
        )
    return row


def message_attachments(message_ids: list[str]) -> dict[str, list[str]]:
    ids = list(dict.fromkeys(message_ids))
    if not ids:
        return {}
    marks = ",".join("?" for _ in ids)
    with conn() as cx:
        rows = cx.execute(
            f"""SELECT message_id,data_url FROM message_attachments
                WHERE message_id IN ({marks}) ORDER BY made ASC, rowid ASC""",
            ids,
        ).fetchall()
    result: dict[str, list[str]] = {}
    for row in rows:
        result.setdefault(row["message_id"], []).append(row["data_url"])
    return result


def message_get(message_id: str) -> dict | None:
    with conn() as cx:
        row = cx.execute("SELECT rowid,* FROM messages WHERE id=?", (message_id,)).fetchone()
    return dict(row) if row else None


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


def message_last_made(chat_id: str, role: str = "") -> int:
    """Return the last persisted message timestamp for heartbeat scheduling."""
    with conn() as cx:
        if role:
            row = cx.execute(
                "SELECT COALESCE(MAX(made),0) AS made FROM messages WHERE chat_id=? AND role=?",
                (chat_id, role),
            ).fetchone()
        else:
            row = cx.execute(
                "SELECT COALESCE(MAX(made),0) AS made FROM messages WHERE chat_id=?",
                (chat_id,),
            ).fetchone()
    return int(row["made"] if row else 0)


def find_everywhere(query: str, limit: int = 80) -> list[dict]:
    """按最近更新时间翻聊天与 Dwell 里可见的文字。数据库很小，LIKE 足够稳。"""
    query = query.strip()[:60]
    if not query:
        return []
    like = f"%{query}%"

    def stamp(value: int, fallback: str = "") -> str:
        if fallback:
            return fallback
        return datetime.fromtimestamp(value, CN_TZ).strftime("%m月%d日")

    def snippet(value: str) -> str:
        text = " ".join((value or "").split())
        at = text.lower().find(query.lower())
        if at < 0:
            return text[:180]
        start = max(0, at - 42)
        end = min(len(text), at + len(query) + 110)
        return ("…" if start else "") + text[start:end] + ("…" if end < len(text) else "")

    hits: list[dict] = []
    with conn() as cx:
        messages = cx.execute(
            """SELECT m.id AS message_id,m.chat_id,m.content,m.made,c.name FROM messages m JOIN chats c ON c.id=m.chat_id
               WHERE m.content LIKE ? ORDER BY m.made DESC LIMIT ?""", (like, limit)
        ).fetchall()
        diary = cx.execute(
            """SELECT date,title,body,keywords,made FROM diary
               WHERE title LIKE ? OR body LIKE ? OR keywords LIKE ?
               ORDER BY date DESC,made DESC LIMIT ?""", (like, like, like, limit)
        ).fetchall()
        personal = cx.execute("SELECT text,at FROM her_diary WHERE text LIKE ? ORDER BY at DESC LIMIT ?", (like, limit)).fetchall()
        quotes = cx.execute("SELECT date,quote,note,made FROM quotes WHERE quote LIKE ? OR note LIKE ? ORDER BY made DESC LIMIT ?", (like, like, limit)).fetchall()
        whispers = cx.execute("SELECT who,text,at FROM whispers WHERE text LIKE ? ORDER BY at DESC LIMIT ?", (like, limit)).fetchall()
        nights = cx.execute("SELECT date,hm,text,made FROM night WHERE text LIKE ? ORDER BY date DESC,hm DESC LIMIT ?", (like, limit)).fetchall()
        events = cx.execute("SELECT date,time,text,made FROM cal_events WHERE text LIKE ? ORDER BY date DESC,time DESC LIMIT ?", (like, limit)).fetchall()

    for row in messages:
        hits.append({"kind": "聊天 · " + (row["name"] or "新对话"), "date": stamp(row["made"]), "snippet": snippet(row["content"]), "at": row["made"], "chat_id": row["chat_id"], "chat_name": row["name"] or "新对话", "message_id": row["message_id"]})
    for row in diary:
        hits.append({"kind": "日记", "date": row["date"], "snippet": snippet(" ".join(filter(None, [row["title"], row["keywords"], row["body"]]))), "at": row["made"]})
    for row in personal:
        hits.append({"kind": "我的日记", "date": stamp(row["at"]), "snippet": snippet(row["text"]), "at": row["at"]})
    for row in quotes:
        hits.append({"kind": "收藏的话", "date": row["date"], "snippet": snippet(row["quote"] + " " + row["note"]), "at": row["made"]})
    for row in whispers:
        hits.append({"kind": "悄悄话 · " + ("你" if row["who"] == "her" else "Cloudy"), "date": stamp(row["at"]), "snippet": snippet(row["text"]), "at": row["at"]})
    for row in nights:
        hits.append({"kind": "夜记", "date": row["date"] + (" · " + row["hm"] if row["hm"] else ""), "snippet": snippet(row["text"]), "at": row["made"]})
    for row in events:
        hits.append({"kind": "日历", "date": row["date"] + (" · " + row["time"] if row["time"] else ""), "snippet": snippet(row["text"]), "at": row["made"]})
    return sorted(hits, key=lambda item: item["at"], reverse=True)[:max(1, min(limit, 80))]


# ---------------------------------------------------------------- 聊天长期上下文

def chat_memory_get(chat_id: str) -> dict:
    """返回派生摘要状态；不存在时给一个未启用的空状态。"""
    with conn() as cx:
        row = cx.execute(
            "SELECT * FROM chat_memory_state WHERE chat_id=?", (chat_id,)
        ).fetchone()
        total = cx.execute(
            "SELECT COUNT(*) FROM messages WHERE chat_id=? AND content<>''", (chat_id,)
        ).fetchone()[0]
        last = cx.execute(
            "SELECT COALESCE(MAX(rowid),0) FROM messages WHERE chat_id=?", (chat_id,)
        ).fetchone()[0]
        segments = cx.execute(
            "SELECT COUNT(*) FROM chat_memory_segments WHERE chat_id=?", (chat_id,)
        ).fetchone()[0]
    out = dict(row) if row else {
        "chat_id": chat_id, "enabled": 0, "overview": "", "through_rowid": 0,
        "status": "idle", "error": "", "generated_at": 0,
    }
    out["enabled"] = bool(out["enabled"])
    out["message_count"] = int(total)
    out["last_rowid"] = int(last)
    out["segment_count"] = int(segments)
    return out


def chat_memory_set_status(chat_id: str, status: str, error: str = "", enabled: bool | None = None) -> None:
    current = chat_memory_get(chat_id)
    values = {
        "chat_id": chat_id,
        "enabled": int(current["enabled"] if enabled is None else enabled),
        "overview": current["overview"],
        "through_rowid": current["through_rowid"],
        "status": status,
        "error": error[:1000],
        "generated_at": current["generated_at"],
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO chat_memory_state
               (chat_id,enabled,overview,through_rowid,status,error,generated_at)
               VALUES (:chat_id,:enabled,:overview,:through_rowid,:status,:error,:generated_at)
               ON CONFLICT(chat_id) DO UPDATE SET enabled=excluded.enabled,
               status=excluded.status,error=excluded.error""",
            values,
        )


def chat_memory_reset(chat_id: str) -> None:
    """只清除派生摘要，绝不动聊天原文。用于重新从头生成。"""
    with conn() as cx:
        cx.execute("DELETE FROM chat_memory_segments WHERE chat_id=?", (chat_id,))
        cx.execute(
            """INSERT INTO chat_memory_state
               (chat_id,enabled,overview,through_rowid,status,error,generated_at)
               VALUES (?,1,'',0,'queued','',0)
               ON CONFLICT(chat_id) DO UPDATE SET enabled=1,overview='',through_rowid=0,
               status='queued',error='',generated_at=0""",
            (chat_id,),
        )


def chat_memory_add_segment(chat_id: str, start_rowid: int, end_rowid: int, content: str) -> dict:
    row = {
        "id": new_id(), "chat_id": chat_id, "start_rowid": start_rowid,
        "end_rowid": end_rowid, "content": content.strip()[:12000], "made": int(time.time()),
    }
    with conn() as cx:
        cx.execute(
            """INSERT INTO chat_memory_segments (id,chat_id,start_rowid,end_rowid,content,made)
               VALUES (:id,:chat_id,:start_rowid,:end_rowid,:content,:made)""", row
        )
    return row


def chat_memory_segments(chat_id: str) -> list[dict]:
    with conn() as cx:
        rows = cx.execute(
            "SELECT * FROM chat_memory_segments WHERE chat_id=? ORDER BY start_rowid ASC",
            (chat_id,),
        ).fetchall()
    return [dict(row) for row in rows]


def chat_memory_finish(chat_id: str, overview: str, through_rowid: int) -> None:
    now = int(time.time())
    with conn() as cx:
        cx.execute(
            """INSERT INTO chat_memory_state
               (chat_id,enabled,overview,through_rowid,status,error,generated_at)
               VALUES (?,1,?,?,'ready','',?)
               ON CONFLICT(chat_id) DO UPDATE SET enabled=1,overview=excluded.overview,
               through_rowid=excluded.through_rowid,status='ready',error='',generated_at=excluded.generated_at""",
            (chat_id, overview.strip()[:12000], int(through_rowid), now),
        )


def chat_memory_save_overview(chat_id: str, overview: str) -> None:
    """保存用户校订过的长期记忆；后续自动更新会以它作为已有记忆。"""
    current = chat_memory_get(chat_id)
    now = int(time.time())
    with conn() as cx:
        cx.execute(
            """INSERT INTO chat_memory_state
               (chat_id,enabled,overview,through_rowid,status,error,generated_at)
               VALUES (?,1,?,?,'ready','',?)
               ON CONFLICT(chat_id) DO UPDATE SET enabled=1,overview=excluded.overview,
               status='ready',error='',generated_at=excluded.generated_at""",
            (chat_id, overview.strip()[:12000], int(current["through_rowid"]), now),
        )


def chat_memory_source_messages(chat_id: str, after_rowid: int, before_rowid: int, limit: int) -> list[dict]:
    """取尚未进入摘要的原始消息，按时间顺序，含 rowid 供水位线追踪。"""
    with conn() as cx:
        rows = cx.execute(
            """SELECT rowid,id,role,content,made FROM messages
               WHERE chat_id=? AND rowid>? AND rowid<=? AND content<>''
               ORDER BY rowid ASC LIMIT ?""",
            (chat_id, int(after_rowid), int(before_rowid), int(limit)),
        ).fetchall()
    return [dict(row) for row in rows]


def message_ui_list(chat_id: str, limit: int = 400, before: int | None = None) -> dict:
    rows = message_list(chat_id, limit, before)
    assistant_ids = [row["id"] for row in rows if row["role"] == "assistant"]
    images_by_message = message_attachments([row["id"] for row in rows])
    tools_by_message: dict[str, list[dict]] = {}
    if assistant_ids:
        placeholders = ",".join("?" for _ in assistant_ids)
        with conn() as cx:
            tool_rows = cx.execute(
                f"SELECT * FROM tool_calls WHERE assistant_message_id IN ({placeholders}) ORDER BY made ASC, rowid ASC",
                assistant_ids,
            ).fetchall()
        for tool in tool_rows:
            item = dict(tool)
            tools_by_message.setdefault(item["assistant_message_id"], []).append(item)
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
            "tools": tools_by_message.get(r["id"], []) if role == "assistant" else [],
            "images": images_by_message.get(r["id"], []),
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


def provider_model_list(provider_id: str = "") -> list[dict]:
    with conn() as cx:
        if provider_id:
            rows = cx.execute(
                "SELECT * FROM provider_models WHERE provider_id=? ORDER BY favorite DESC, model_id COLLATE NOCASE",
                (provider_id,),
            ).fetchall()
        else:
            rows = cx.execute(
                "SELECT * FROM provider_models ORDER BY favorite DESC, updated DESC, model_id COLLATE NOCASE"
            ).fetchall()
    return [{**dict(row), "favorite": bool(row["favorite"]), "manual": bool(row["manual"])} for row in rows]


def provider_model_upsert(provider_id: str, model_id: str, favorite: bool | None = None,
                          manual: bool | None = None) -> dict:
    now = int(time.time())
    old = next((item for item in provider_model_list(provider_id) if item["model_id"] == model_id), None)
    fav = int(favorite if favorite is not None else (old or {}).get("favorite", False))
    is_manual = int(manual if manual is not None else (old or {}).get("manual", False))
    with conn() as cx:
        cx.execute(
            "INSERT INTO provider_models (provider_id,model_id,favorite,manual,made,updated) VALUES (?,?,?,?,?,?) "
            "ON CONFLICT(provider_id,model_id) DO UPDATE SET favorite=excluded.favorite,manual=excluded.manual,updated=excluded.updated",
            (provider_id, model_id, fav, is_manual, now, now),
        )
        row = cx.execute("SELECT * FROM provider_models WHERE provider_id=? AND model_id=?", (provider_id, model_id)).fetchone()
    return {**dict(row), "favorite": bool(row["favorite"]), "manual": bool(row["manual"])}


def provider_models_refresh(provider_id: str, model_ids: list[str]) -> int:
    for model_id in dict.fromkeys(model_ids):
        provider_model_upsert(provider_id, model_id, manual=False)
    return len(list(dict.fromkeys(model_ids)))


# ---------------------------------------------------------------- MCP 工具服务器

def mcp_server_list() -> list:
    with conn() as cx:
        rows = cx.execute(
            "SELECT id,name,url,transport,enabled,made,updated,headers_box FROM mcp_servers "
            "ORDER BY made ASC"
        ).fetchall()
    return [{**{k: row[k] for k in ("id", "name", "url", "transport", "enabled", "made", "updated")},
             "has_credentials": bool(row["headers_box"])} for row in rows]


def mcp_server_get(server_id: str) -> dict | None:
    with conn() as cx:
        row = cx.execute("SELECT * FROM mcp_servers WHERE id=?", (server_id,)).fetchone()
    return dict(row) if row else None


def mcp_server_upsert(server_id: str, name: str, url: str, transport: str,
                      headers_box: str | None, enabled: bool = True) -> dict:
    now = int(time.time())
    old = mcp_server_get(server_id) if server_id else None
    server_id = server_id or new_id()
    box = old["headers_box"] if old and headers_box is None else (headers_box or "")
    with conn() as cx:
        cx.execute(
            "INSERT INTO mcp_servers (id,name,url,transport,headers_box,enabled,made,updated) "
            "VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
            "name=excluded.name,url=excluded.url,transport=excluded.transport,"
            "headers_box=excluded.headers_box,enabled=excluded.enabled,updated=excluded.updated",
            (server_id, name, url, transport, box, 1 if enabled else 0, now, now),
        )
    return mcp_server_get(server_id) or {}


def mcp_server_delete(server_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute("DELETE FROM mcp_servers WHERE id=?", (server_id,))
    return cur.rowcount > 0


def chat_mcp_server_ids(chat_id: str) -> list[str]:
    with conn() as cx:
        rows = cx.execute(
            "SELECT server_id FROM chat_mcp_servers WHERE chat_id=? ORDER BY server_id", (chat_id,)
        ).fetchall()
    return [row["server_id"] for row in rows]


def chat_mcp_servers(chat_id: str) -> list[dict]:
    with conn() as cx:
        rows = cx.execute(
            "SELECT s.* FROM mcp_servers s JOIN chat_mcp_servers c ON c.server_id=s.id "
            "WHERE c.chat_id=? AND s.enabled=1 ORDER BY s.made ASC", (chat_id,)
        ).fetchall()
    return [dict(row) for row in rows]


def chat_mcp_servers_set(chat_id: str, server_ids: list[str]) -> bool:
    if not chat_get(chat_id):
        return False
    clean = list(dict.fromkeys(server_id for server_id in server_ids if mcp_server_get(server_id)))
    with conn() as cx:
        cx.execute("DELETE FROM chat_mcp_servers WHERE chat_id=?", (chat_id,))
        cx.executemany(
            "INSERT INTO chat_mcp_servers (chat_id,server_id) VALUES (?,?)",
            [(chat_id, server_id) for server_id in clean],
        )
    return True


def chat_home_todos_enabled(chat_id: str) -> bool:
    with conn() as cx:
        row = cx.execute(
            "SELECT todos_enabled FROM chat_home_tools WHERE chat_id=?", (chat_id,)
        ).fetchone()
    return bool(row and row["todos_enabled"])


def chat_home_todos_set(chat_id: str, enabled: bool) -> bool:
    if not chat_get(chat_id):
        return False
    with conn() as cx:
        cx.execute(
            "INSERT INTO chat_home_tools (chat_id,todos_enabled) VALUES (?,?) "
            "ON CONFLICT(chat_id) DO UPDATE SET todos_enabled=excluded.todos_enabled",
            (chat_id, 1 if enabled else 0),
        )
    return True


# ---------------------------------------------------------------- 聊天指令

def instruction_list() -> list[dict]:
    with conn() as cx:
        rows = cx.execute(
            "SELECT id,name,content,made,updated FROM instruction_presets ORDER BY made ASC"
        ).fetchall()
    return [dict(row) for row in rows]


def instruction_get(instruction_id: str) -> dict | None:
    with conn() as cx:
        row = cx.execute("SELECT * FROM instruction_presets WHERE id=?", (instruction_id,)).fetchone()
    return dict(row) if row else None


def instruction_upsert(instruction_id: str, name: str, content: str) -> dict:
    now = int(time.time())
    instruction_id = instruction_id or new_id()
    with conn() as cx:
        cx.execute(
            "INSERT INTO instruction_presets (id,name,content,made,updated) VALUES (?,?,?,?,?) "
            "ON CONFLICT(id) DO UPDATE SET name=excluded.name,content=excluded.content,updated=excluded.updated",
            (instruction_id, name, content, now, now),
        )
    return instruction_get(instruction_id) or {}


def instruction_delete(instruction_id: str) -> bool:
    with conn() as cx:
        cur = cx.execute("DELETE FROM instruction_presets WHERE id=?", (instruction_id,))
    return cur.rowcount > 0


def chat_instruction_ids(chat_id: str) -> list[str]:
    with conn() as cx:
        rows = cx.execute(
            "SELECT instruction_id FROM chat_instruction_presets WHERE chat_id=? ORDER BY instruction_id",
            (chat_id,),
        ).fetchall()
    return [row["instruction_id"] for row in rows]


def chat_instructions(chat_id: str) -> list[dict]:
    with conn() as cx:
        rows = cx.execute(
            "SELECT i.* FROM instruction_presets i JOIN chat_instruction_presets c "
            "ON c.instruction_id=i.id WHERE c.chat_id=? ORDER BY i.made ASC", (chat_id,)
        ).fetchall()
    return [dict(row) for row in rows]


def chat_instructions_set(chat_id: str, instruction_ids: list[str]) -> bool:
    if not chat_get(chat_id):
        return False
    clean = list(dict.fromkeys(item_id for item_id in instruction_ids if instruction_get(item_id)))
    with conn() as cx:
        cx.execute("DELETE FROM chat_instruction_presets WHERE chat_id=?", (chat_id,))
        cx.executemany(
            "INSERT INTO chat_instruction_presets (chat_id,instruction_id) VALUES (?,?)",
            [(chat_id, item_id) for item_id in clean],
        )
    return True
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


def message_update(msg_id: str, content: str) -> bool:
    with conn() as cx:
        cur = cx.execute("UPDATE messages SET content=? WHERE id=?", (content, msg_id))
    return cur.rowcount > 0


def message_version_add(message_id: str, content: str, reason: str = "") -> dict:
    row = {"id": new_id(), "message_id": message_id, "content": content,
           "reason": reason, "made": int(time.time())}
    with conn() as cx:
        cx.execute(
            "INSERT INTO message_versions (id,message_id,content,reason,made) "
            "VALUES (:id,:message_id,:content,:reason,:made)", row,
        )
    return row


def message_versions(message_id: str) -> list[dict]:
    with conn() as cx:
        rows = cx.execute(
            "SELECT * FROM message_versions WHERE message_id=? ORDER BY made DESC, rowid DESC",
            (message_id,),
        ).fetchall()
    return [dict(row) for row in rows]


def tool_call_add(chat_id: str, assistant_message_id: str, name: str, arguments: str) -> dict:
    row = {"id": new_id(), "chat_id": chat_id, "assistant_message_id": assistant_message_id,
           "name": name, "arguments": arguments, "result": "", "is_error": 0,
           "made": int(time.time())}
    with conn() as cx:
        cx.execute(
            "INSERT INTO tool_calls (id,chat_id,assistant_message_id,name,arguments,result,is_error,made) "
            "VALUES (:id,:chat_id,:assistant_message_id,:name,:arguments,:result,:is_error,:made)", row,
        )
    return row


def tool_call_finish(tool_call_id: str, result: str, is_error: bool) -> bool:
    with conn() as cx:
        cur = cx.execute("UPDATE tool_calls SET result=?, is_error=? WHERE id=?", (result, int(is_error), tool_call_id))
    return cur.rowcount > 0


def message_delete(msg_id: str) -> bool:
    with conn() as cx:
        cx.execute("DELETE FROM message_versions WHERE message_id=?", (msg_id,))
        cx.execute("DELETE FROM tool_calls WHERE assistant_message_id=?", (msg_id,))
        cur = cx.execute("DELETE FROM messages WHERE id=?", (msg_id,))
    return cur.rowcount > 0


def message_delete_many(msg_ids: list[str]) -> int:
    """一次删多条消息，也一起清掉各自的版本和工具记录。"""
    ids = list(dict.fromkeys(msg_ids))
    if not ids:
        return 0
    marks = ",".join("?" for _ in ids)
    with conn() as cx:
        cx.execute(f"DELETE FROM message_versions WHERE message_id IN ({marks})", ids)
        cx.execute(f"DELETE FROM tool_calls WHERE assistant_message_id IN ({marks})", ids)
        cur = cx.execute(f"DELETE FROM messages WHERE id IN ({marks})", ids)
    return cur.rowcount

