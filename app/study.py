"""Cloudy's study: EPUB ingestion, reading progress, private notes and shared threads."""

import io
import json
import posixpath
import re
import time
import zipfile
from datetime import datetime
from html.parser import HTMLParser
from pathlib import PurePosixPath
from xml.etree import ElementTree as ET

from . import db

MAX_EPUB_BYTES = 25 * 1024 * 1024
MAX_UNPACKED_BYTES = 60 * 1024 * 1024
MAX_TEXT_BYTES = 12 * 1024 * 1024
READING_CHUNK_CHARS = 4200


SCHEMA = """
CREATE TABLE IF NOT EXISTS study_books (
    id              TEXT PRIMARY KEY,
    title           TEXT NOT NULL,
    author          TEXT NOT NULL DEFAULT '',
    filename        TEXT NOT NULL DEFAULT '',
    chapter_count   INTEGER NOT NULL DEFAULT 0,
    current_chapter INTEGER NOT NULL DEFAULT 0,
    current_offset  INTEGER NOT NULL DEFAULT 0,
    finished        INTEGER NOT NULL DEFAULT 0,
    made            INTEGER NOT NULL,
    updated         INTEGER NOT NULL,
    last_read       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_study_books_reading
ON study_books(finished, last_read, made);

CREATE TABLE IF NOT EXISTS study_chapters (
    book_id TEXT NOT NULL,
    idx     INTEGER NOT NULL,
    title   TEXT NOT NULL DEFAULT '',
    body    TEXT NOT NULL,
    PRIMARY KEY (book_id, idx),
    FOREIGN KEY (book_id) REFERENCES study_books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS study_notes (
    id          TEXT PRIMARY KEY,
    book_id     TEXT NOT NULL,
    chapter_idx INTEGER NOT NULL DEFAULT 0,
    anchor      TEXT NOT NULL DEFAULT '',
    text        TEXT NOT NULL,
    kind        TEXT NOT NULL DEFAULT 'private',
    who         TEXT NOT NULL DEFAULT 'cloudy',
    made        INTEGER NOT NULL,
    FOREIGN KEY (book_id) REFERENCES study_books(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_study_notes_book
ON study_notes(book_id, kind, made DESC);

CREATE TABLE IF NOT EXISTS study_replies (
    id             TEXT PRIMARY KEY,
    note_id        TEXT NOT NULL,
    who            TEXT NOT NULL,
    text           TEXT NOT NULL,
    made           INTEGER NOT NULL,
    seen_by_cloudy INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (note_id) REFERENCES study_notes(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_study_replies_note
ON study_replies(note_id, made);

CREATE TABLE IF NOT EXISTS study_activity (
    id          TEXT PRIMARY KEY,
    book_id     TEXT NOT NULL,
    chapter_idx INTEGER NOT NULL DEFAULT 0,
    summary     TEXT NOT NULL,
    made        INTEGER NOT NULL,
    FOREIGN KEY (book_id) REFERENCES study_books(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_study_activity_made ON study_activity(made DESC);
"""


class EpubError(ValueError):
    pass


class _Text(HTMLParser):
    BLOCKS = {"p", "div", "br", "li", "h1", "h2", "h3", "h4", "blockquote", "section", "article"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.title_parts: list[str] = []
        self.heading_parts: list[str] = []
        self.hidden = 0
        self.in_title = False
        self.in_heading = False

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag in {"script", "style", "svg"}:
            self.hidden += 1
        if tag == "title":
            self.in_title = True
        if tag in {"h1", "h2"} and not self.heading_parts:
            self.in_heading = True
        if tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in {"script", "style", "svg"} and self.hidden:
            self.hidden -= 1
        if tag == "title":
            self.in_title = False
        if tag in {"h1", "h2"}:
            self.in_heading = False
        if tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_data(self, data):
        if self.hidden:
            return
        text = re.sub(r"\s+", " ", data)
        if not text.strip():
            return
        self.parts.append(text)
        if self.in_title:
            self.title_parts.append(text)
        if self.in_heading:
            self.heading_parts.append(text)

    def result(self) -> tuple[str, str]:
        text = "".join(self.parts)
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r" *\n *", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text).strip()
        title = "".join(self.heading_parts).strip() or "".join(self.title_parts).strip()
        return title[:160], text


def init_db() -> None:
    with db.conn() as cx:
        cx.executescript(SCHEMA)


def _safe_member(path: str) -> str:
    value = posixpath.normpath(path.replace("\\", "/")).lstrip("/")
    if value == ".." or value.startswith("../"):
        raise EpubError("书里有不安全的文件路径")
    return value


def _xml_text(root: ET.Element, local_name: str) -> str:
    for item in root.iter():
        if item.tag.rsplit("}", 1)[-1] == local_name and (item.text or "").strip():
            return (item.text or "").strip()
    return ""


def parse_epub(raw: bytes, filename: str) -> tuple[str, str, list[tuple[str, str]]]:
    if not filename.lower().endswith(".epub"):
        raise EpubError("请上传 .epub 格式的书")
    if not raw or len(raw) > MAX_EPUB_BYTES:
        raise EpubError("这本书太大了，目前每本最多 25 MB")
    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile as exc:
        raise EpubError("这个文件不像完整的 EPUB") from exc
    with zf:
        infos = zf.infolist()
        if sum(item.file_size for item in infos) > MAX_UNPACKED_BYTES:
            raise EpubError("这本书展开后太大了")
        names = {_safe_member(item.filename): item for item in infos}
        container_name = "META-INF/container.xml"
        if container_name not in names:
            raise EpubError("EPUB 里缺少目录信息")
        try:
            container = ET.fromstring(zf.read(names[container_name]))
            rootfile = next(
                item.attrib.get("full-path", "") for item in container.iter()
                if item.tag.rsplit("}", 1)[-1] == "rootfile"
            )
            opf_name = _safe_member(rootfile)
            package = ET.fromstring(zf.read(names[opf_name]))
        except Exception as exc:
            raise EpubError("没有读懂这本 EPUB 的目录") from exc

        title = _xml_text(package, "title") or PurePosixPath(filename).stem
        author = _xml_text(package, "creator")
        manifest: dict[str, tuple[str, str]] = {}
        spine: list[str] = []
        for item in package.iter():
            local = item.tag.rsplit("}", 1)[-1]
            if local == "item" and item.attrib.get("id") and item.attrib.get("href"):
                manifest[item.attrib["id"]] = (item.attrib["href"], item.attrib.get("media-type", ""))
            elif local == "itemref" and item.attrib.get("idref"):
                spine.append(item.attrib["idref"])
        if not spine:
            spine = [key for key, value in manifest.items() if "html" in value[1]]

        base = posixpath.dirname(opf_name)
        chapters: list[tuple[str, str]] = []
        total_text = 0
        for item_id in spine[:400]:
            entry = manifest.get(item_id)
            if not entry:
                continue
            href, media_type = entry
            if "html" not in media_type and not href.lower().endswith((".html", ".xhtml", ".htm")):
                continue
            member = _safe_member(posixpath.join(base, href.split("#", 1)[0]))
            if member not in names:
                continue
            try:
                source = zf.read(names[member]).decode("utf-8", "replace")
                parser = _Text()
                parser.feed(source)
                chapter_title, body = parser.result()
            except Exception:
                continue
            if len(body) < 40:
                continue
            body = body[:250_000]
            total_text += len(body.encode("utf-8"))
            if total_text > MAX_TEXT_BYTES:
                raise EpubError("这本书文字太多了，目前还放不下")
            chapters.append((chapter_title or f"第 {len(chapters) + 1} 节", body))
        if not chapters:
            raise EpubError("没有从这本 EPUB 里读到正文")
        return title[:240], author[:160], chapters[:300]


def add_book(raw: bytes, filename: str) -> dict:
    title, author, chapters = parse_epub(raw, filename)
    now = int(time.time())
    book_id = db.new_id()
    row = {
        "id": book_id, "slug": book_id, "title": title, "author": author,
        "filename": filename[:260], "chapter_count": len(chapters),
        "current_chapter": 0, "current_offset": 0, "finished": 0,
        "made": now, "updated": now, "last_read": 0,
    }
    with db.conn() as cx:
        cx.execute(
            """INSERT INTO study_books
               (id,title,author,filename,chapter_count,current_chapter,current_offset,finished,made,updated,last_read)
               VALUES (:id,:title,:author,:filename,:chapter_count,:current_chapter,:current_offset,:finished,:made,:updated,:last_read)""",
            row,
        )
        cx.executemany(
            "INSERT INTO study_chapters (book_id,idx,title,body) VALUES (?,?,?,?)",
            [(book_id, idx, chapter_title, body) for idx, (chapter_title, body) in enumerate(chapters)],
        )
    row["chapters"] = [item[0] for item in chapters]
    return row


def books() -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute("SELECT * FROM study_books ORDER BY finished, updated DESC").fetchall()
        out = []
        for row in rows:
            item = dict(row)
            item["slug"] = item["id"]
            item["chapters"] = [r["title"] for r in cx.execute(
                "SELECT title FROM study_chapters WHERE book_id=? ORDER BY idx", (item["id"],)
            ).fetchall()]
            out.append(item)
    return out


def delete_book(book_id: str) -> bool:
    with db.conn() as cx:
        cur = cx.execute("DELETE FROM study_books WHERE id=?", (book_id,))
    return cur.rowcount > 0


def progress() -> dict:
    with db.conn() as cx:
        rows = cx.execute("SELECT id,current_chapter,current_offset,finished FROM study_books").fetchall()
    return {r["id"]: {"ch": r["current_chapter"], "offset": r["current_offset"], "finished": bool(r["finished"])} for r in rows}


def set_progress(book_id: str, chapter: int, offset: int = 0) -> bool:
    with db.conn() as cx:
        row = cx.execute("SELECT chapter_count FROM study_books WHERE id=?", (book_id,)).fetchone()
        if not row:
            return False
        chapter = max(0, min(int(chapter), max(0, row["chapter_count"] - 1)))
        cx.execute(
            "UPDATE study_books SET current_chapter=?,current_offset=?,finished=0,updated=? WHERE id=?",
            (chapter, max(0, int(offset)), int(time.time()), book_id),
        )
    return True


def chapter(book_id: str, idx: int) -> dict | None:
    with db.conn() as cx:
        book = cx.execute("SELECT * FROM study_books WHERE id=?", (book_id,)).fetchone()
        item = cx.execute("SELECT * FROM study_chapters WHERE book_id=? AND idx=?", (book_id, idx)).fetchone()
        if not book or not item:
            return None
        titles = [r["title"] for r in cx.execute(
            "SELECT title FROM study_chapters WHERE book_id=? ORDER BY idx", (book_id,)
        ).fetchall()]
    return {
        "book": book["title"], "title": item["title"], "text": item["body"],
        "index": item["idx"], "total": book["chapter_count"], "chapters": titles,
    }


def _fmt_ts(value: int) -> str:
    return datetime.fromtimestamp(value, db.CN_TZ).strftime("%m月%d日 %H:%M")


def annotations(book_id: str, chapter_idx: int) -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute(
            """SELECT * FROM study_notes
               WHERE book_id=? AND chapter_idx=? AND kind='annotation' ORDER BY made""",
            (book_id, chapter_idx),
        ).fetchall()
        out = []
        for row in rows:
            item = dict(row)
            item["ts"] = _fmt_ts(item["made"])
            item["note"] = item.pop("text")
            replies = cx.execute("SELECT * FROM study_replies WHERE note_id=? ORDER BY made", (item["id"],)).fetchall()
            item["replies"] = [{**dict(r), "ts": _fmt_ts(r["made"])} for r in replies]
            out.append(item)
    return out


def add_annotation(book_id: str, chapter_idx: int, anchor: str, note: str, who: str = "user") -> dict:
    if not chapter(book_id, chapter_idx):
        raise KeyError(book_id)
    row = {
        "id": db.new_id(), "book_id": book_id, "chapter_idx": chapter_idx,
        "anchor": anchor.strip()[:280], "text": note.strip()[:4000],
        "kind": "annotation", "who": "cloudy" if who == "ai" else "user", "made": int(time.time()),
    }
    if not row["anchor"]:
        raise ValueError("没有选中文字")
    with db.conn() as cx:
        cx.execute(
            """INSERT INTO study_notes (id,book_id,chapter_idx,anchor,text,kind,who,made)
               VALUES (:id,:book_id,:chapter_idx,:anchor,:text,:kind,:who,:made)""", row,
        )
    return row


def add_reply(note_id: str, text: str, who: str = "user") -> dict:
    text = text.strip()[:4000]
    if not text:
        raise ValueError("回复是空的")
    with db.conn() as cx:
        if not cx.execute("SELECT 1 FROM study_notes WHERE id=?", (note_id,)).fetchone():
            raise KeyError(note_id)
        row = {
            "id": db.new_id(), "note_id": note_id, "who": "cloudy" if who in {"cloudy", "ai"} else "user",
            "text": text, "made": int(time.time()), "seen_by_cloudy": 1 if who in {"cloudy", "ai"} else 0,
        }
        cx.execute(
            """INSERT INTO study_replies (id,note_id,who,text,made,seen_by_cloudy)
               VALUES (:id,:note_id,:who,:text,:made,:seen_by_cloudy)""", row,
        )
    return row


def shares(limit: int = 80) -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute(
            """SELECT n.*,b.title AS book_title,c.title AS chapter_title
               FROM study_notes n JOIN study_books b ON b.id=n.book_id
               LEFT JOIN study_chapters c ON c.book_id=n.book_id AND c.idx=n.chapter_idx
               WHERE n.kind='share' ORDER BY n.made DESC LIMIT ?""", (max(1, min(limit, 200)),)
        ).fetchall()
        out = []
        for row in rows:
            item = dict(row)
            item["ts"] = _fmt_ts(item["made"])
            replies = cx.execute("SELECT * FROM study_replies WHERE note_id=? ORDER BY made", (item["id"],)).fetchall()
            item["replies"] = [{**dict(r), "ts": _fmt_ts(r["made"])} for r in replies]
            out.append(item)
    return out


def pending_replies(limit: int = 20) -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute(
            """SELECT r.id AS reply_id,r.note_id,r.text,r.made,n.text AS cloudy_text,
                      b.title AS book_title,c.title AS chapter_title
               FROM study_replies r JOIN study_notes n ON n.id=r.note_id
               JOIN study_books b ON b.id=n.book_id
               LEFT JOIN study_chapters c ON c.book_id=n.book_id AND c.idx=n.chapter_idx
               WHERE r.who='user' AND r.seen_by_cloudy=0
               ORDER BY r.made LIMIT ?""", (max(1, min(limit, 50)),)
        ).fetchall()
    return [dict(r) for r in rows]


def next_passage() -> dict | None:
    with db.conn() as cx:
        book = cx.execute(
            "SELECT * FROM study_books WHERE finished=0 ORDER BY last_read ASC,made ASC LIMIT 1"
        ).fetchone()
        if not book:
            return None
        chapter_idx = int(book["current_chapter"])
        offset = int(book["current_offset"])
        chapter_row = cx.execute(
            "SELECT * FROM study_chapters WHERE book_id=? AND idx=?", (book["id"], chapter_idx)
        ).fetchone()
        if not chapter_row:
            return None
        body = chapter_row["body"]
    if offset >= len(body):
        offset = 0
    end = min(len(body), offset + READING_CHUNK_CHARS)
    if end < len(body):
        cut = body.rfind("\n", offset + READING_CHUNK_CHARS // 2, end)
        if cut > offset:
            end = cut
    return {
        "book_id": book["id"], "book_title": book["title"], "author": book["author"],
        "chapter_idx": chapter_idx, "chapter_title": chapter_row["title"],
        "start_offset": offset, "end_offset": end, "chapter_length": len(body),
        "chapter_count": book["chapter_count"], "text": body[offset:end].strip(),
    }


def private_context(book_id: str, limit: int = 12) -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute(
            """SELECT n.text,n.anchor,n.chapter_idx,c.title AS chapter_title,n.made
               FROM study_notes n LEFT JOIN study_chapters c
               ON c.book_id=n.book_id AND c.idx=n.chapter_idx
               WHERE n.book_id=? AND n.kind='private' ORDER BY n.made DESC LIMIT ?""",
            (book_id, max(1, min(limit, 30))),
        ).fetchall()
    return [dict(r) for r in reversed(rows)]


def record_session(passage: dict, private_note: str, share_text: str = "", share_anchor: str = "",
                   thread_replies: list[dict] | None = None) -> dict:
    now = int(time.time())
    book_id = passage["book_id"]
    next_chapter = passage["chapter_idx"]
    next_offset = passage["end_offset"]
    finished = 0
    if next_offset >= passage["chapter_length"]:
        next_chapter += 1
        next_offset = 0
        if next_chapter >= passage["chapter_count"]:
            next_chapter = max(0, passage["chapter_count"] - 1)
            finished = 1
    share_id = ""
    with db.conn() as cx:
        private_row = (
            db.new_id(), book_id, passage["chapter_idx"], passage["text"][:220],
            private_note.strip()[:5000], "private", "cloudy", now,
        )
        cx.execute(
            """INSERT INTO study_notes (id,book_id,chapter_idx,anchor,text,kind,who,made)
               VALUES (?,?,?,?,?,?,?,?)""", private_row,
        )
        if share_text.strip():
            share_id = db.new_id()
            cx.execute(
                """INSERT INTO study_notes (id,book_id,chapter_idx,anchor,text,kind,who,made)
                   VALUES (?,?,?,?,?,'share','cloudy',?)""",
                (share_id, book_id, passage["chapter_idx"], share_anchor.strip()[:280], share_text.strip()[:5000], now),
            )
        valid_notes = {r["id"] for r in cx.execute("SELECT id FROM study_notes WHERE kind='share'").fetchall()}
        for item in thread_replies or []:
            note_id = str(item.get("thread_id") or "")
            text = str(item.get("text") or "").strip()[:4000]
            if note_id in valid_notes and text:
                cx.execute(
                    """INSERT INTO study_replies (id,note_id,who,text,made,seen_by_cloudy)
                       VALUES (?,?,'cloudy',?,?,1)""", (db.new_id(), note_id, text, now),
                )
        cx.execute("UPDATE study_replies SET seen_by_cloudy=1 WHERE who='user' AND seen_by_cloudy=0")
        cx.execute(
            """UPDATE study_books SET current_chapter=?,current_offset=?,finished=?,last_read=?,updated=?
               WHERE id=?""", (next_chapter, next_offset, finished, now, now, book_id),
        )
        summary = f"读了《{passage['book_title']}》的「{passage['chapter_title']}」"
        if share_id:
            summary += "，在分享本里留了一页"
        elif thread_replies:
            summary += "，也看了小猫的回话"
        else:
            summary += "，给自己记了一页"
        cx.execute(
            "INSERT INTO study_activity (id,book_id,chapter_idx,summary,made) VALUES (?,?,?,?,?)",
            (db.new_id(), book_id, passage["chapter_idx"], summary, now),
        )
    return {"summary": summary, "share_id": share_id, "finished": bool(finished)}


def activities(limit: int = 12) -> list[dict]:
    with db.conn() as cx:
        rows = cx.execute(
            """SELECT a.*,b.title AS book_title FROM study_activity a
               JOIN study_books b ON b.id=a.book_id ORDER BY a.made DESC LIMIT ?""",
            (max(1, min(limit, 50)),),
        ).fetchall()
    return [{**dict(r), "ts": _fmt_ts(r["made"])} for r in rows]


def config() -> dict:
    def integer(key: str, default: int, low: int, high: int) -> int:
        try:
            return max(low, min(int(db.setting_get(key, str(default))), high))
        except (TypeError, ValueError):
            return default
    today = db.today_str()
    if db.setting_get("study_count_date", "") != today:
        db.setting_set("study_count_date", today)
        db.setting_set("study_count_today", "0")
    return {
        "on": db.setting_get("study_on", "0") == "1",
        "day_start": integer("study_day_start", 10, 0, 23),
        "day_end": integer("study_day_end", 23, 1, 24),
        "daily_sessions": integer("study_daily_sessions", 3, 1, 8),
        "count": integer("study_count_today", 0, 0, 99),
        "last_read": integer("study_last_read", 0, 0, 4_000_000_000),
        "last_status": db.setting_get("study_last_status", "idle"),
        "last_error": db.setting_get("study_last_error", ""),
    }


def set_config(payload: dict) -> dict:
    if "on" in payload:
        db.setting_set("study_on", "1" if bool(payload["on"]) else "0")
    for field, low, high in (("day_start", 0, 23), ("day_end", 1, 24), ("daily_sessions", 1, 8)):
        if field not in payload:
            continue
        try:
            value = max(low, min(int(payload[field]), high))
        except (TypeError, ValueError):
            raise ValueError(f"{field} 不是有效数字")
        db.setting_set("study_" + field, str(value))
    result = config()
    if result["day_start"] == result["day_end"]:
        raise ValueError("开始和结束时间不能相同")
    return result


def due(now: datetime, force: bool = False) -> tuple[bool, str]:
    cfg = config()
    if not force and not cfg["on"]:
        return False, "off"
    if not books():
        return False, "no_books"
    if cfg["count"] >= cfg["daily_sessions"] and not force:
        return False, "daily_limit"
    start, end, hour = cfg["day_start"], cfg["day_end"], now.hour
    in_window = start <= hour < end if start < end else (hour >= start or hour < end)
    if not force and not in_window:
        return False, "outside_window"
    window_hours = (end - start) % 24 or 24
    interval = max(30 * 60, int(window_hours * 3600 / cfg["daily_sessions"]))
    if not force and cfg["last_read"] and int(now.timestamp()) - cfg["last_read"] < interval:
        return False, "waiting"
    return True, "ready"


def mark_result(status: str, error: str = "", counted: bool = False) -> None:
    db.setting_set("study_last_status", status)
    db.setting_set("study_last_error", error[:500])
    if counted:
        cfg = config()
        db.setting_set("study_count_today", str(cfg["count"] + 1))
        db.setting_set("study_last_read", str(int(time.time())))

