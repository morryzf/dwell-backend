"""dwell 后端。日记、待办、日历、悄悄话。

一个服务同时干两件事：
- 提供 /api/* 接口
- 托管 static/index.html 那份前端

这么做是为了只在 Zeabur 上开一个服务：省内存，也不用管跨域。
"""

import os
from pathlib import Path

from fastapi import Body, Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse

from . import auth, db
from app.pet_assets import ensure_pet_assets

app = FastAPI(title="dwell", docs_url=None, redoc_url=None)

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


@app.on_event("startup")
def _startup():
    db.init_db()
    ensure_frontend()
    ensure_pet_assets(str(STATIC_DIR)) 


FRONTEND_URL = ("https://raw.githubusercontent.com/xinwithyu/"
                "dwell-on-something/main/web/index.html")


def ensure_frontend():
    """前端不在就自己去拉一份，剥掉演示模式，顺手补上游的 bug。

    那个文件 280KB，不进仓库；容器每次重建都会丢。
    与其让人手动装一遍，不如让它自己长回来。
    拉不到也不致命——接口照样活着，只是没有脸。
    """
    import urllib.request

    target = STATIC_DIR / "index.html"
    if target.exists() and target.stat().st_size > 100_000:
        return

    try:
        STATIC_DIR.mkdir(parents=True, exist_ok=True)
        html = urllib.request.urlopen(FRONTEND_URL, timeout=60).read().decode("utf-8")

        # 一、剥掉演示模式。那段 IIFE 劫持 fetch 喂假数据，不删就连不上后端。
        start = html.find("/* \u2500")
        end = html.find("})();", start)
        if start != -1 and end != -1:
            html = html[:start] + html[end + len("})();"):]
            print("[dwell] 演示模式已剥离")
        else:
            print("[dwell] 没找到演示模式的边界，原样保留")

        # 二、补上游的 bug。作者拆掉生理周期那块时删掉了 const p，
        # 但 renderDayDetail 里还在用它，日历一打开就 ReferenceError。
        orphan = "  p.appendChild(moodRow);"
        patch = "  const p = document.createElement('div'); p.className = 'pbox';\n"
        if orphan in html:
            html = html.replace(orphan, patch + orphan, 1)
            print("[dwell] 补上了日历缺失的容器")
        else:
            print("[dwell] 没找到日历那处孤儿代码")

        target.write_text(html, encoding="utf-8")
        print(f"[dwell] 前端就位 {target.stat().st_size} 字节")
    except Exception as exc:
        print(f"[dwell] 前端没拉到：{exc}")


# ---------------------------------------------------------------- 登录

@app.post("/api/login")
async def login(payload: dict = Body(...)):
    if not auth.credentials_configured():
        raise HTTPException(500, "服务端没配 DWELL_USER / DWELL_PASSWORD")

    user = str(payload.get("user", ""))
    password = str(payload.get("password", ""))
    if not auth.check_login(user, password):
        raise HTTPException(401, "用户名或密码不对")

    resp = JSONResponse({"ok": True})
    resp.set_cookie(
        auth.COOKIE_NAME,
        auth.make_token(user),
        max_age=auth.MAX_AGE,
        httponly=True,      # JS 读不到，防 XSS 偷 cookie
        samesite="lax",
        secure=os.environ.get("DWELL_INSECURE_COOKIE") != "1",
    )
    return resp


@app.post("/api/logout")
async def logout():
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(auth.COOKIE_NAME)
    return resp


@app.get("/api/me")
async def me(request: Request):
    return {"authed": auth.is_authed(request)}


# 下面所有路由都要登录
authed = [Depends(auth.require_auth)]


# ---------------------------------------------------------------- 日记

@app.get("/api/diary", dependencies=authed)
async def diary_list(lite: int = 1, limit: int = 400):
    return {"items": db.diary_list(lite=bool(lite), limit=limit)}


@app.get("/api/diary/{item_id}", dependencies=authed)
async def diary_get(item_id: str):
    item = db.diary_get(item_id)
    if not item:
        raise HTTPException(404, "没有这一段")
    return item


@app.post("/api/diary", dependencies=authed)
async def diary_add(payload: dict = Body(...)):
    body = str(payload.get("body", "")).strip()
    if not body:
        raise HTTPException(400, "正文不能是空的")
    return db.diary_add(str(payload.get("date", "")), body)


@app.get("/api/diary-search", dependencies=authed)
async def diary_search(q: str, limit: int = 50):
    if not q.strip():
        return {"items": []}
    return {"items": db.diary_search(q.strip(), limit)}


# 你的本子

@app.get("/api/her-diary", dependencies=authed)
async def her_diary_list():
    return {"items": db.her_diary_list()}


@app.post("/api/her-diary", dependencies=authed)
async def her_diary_add(payload: dict = Body(...)):
    text = str(payload.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "写点什么再记上")
    return db.her_diary_add(text)


@app.delete("/api/her-diary/{item_id}", dependencies=authed)
async def her_diary_del(item_id: str):
    return {"ok": db.her_diary_del(item_id)}


# 摘下来的话

@app.get("/api/quotes", dependencies=authed)
async def quotes_list():
    return {"items": db.quote_list()}


@app.post("/api/quotes", dependencies=authed)
async def quotes_add(payload: dict = Body(...)):
    quote = str(payload.get("quote", "")).strip()
    if not quote:
        raise HTTPException(400, "摘的话不能是空的")
    return db.quote_add(quote, str(payload.get("note", "")),
                        str(payload.get("date", "")))


@app.delete("/api/quotes/{item_id}", dependencies=authed)
async def quotes_del(item_id: str):
    return {"ok": db.quote_del(item_id)}


# 夜记

@app.get("/api/night", dependencies=authed)
async def night_list(limit: int = 200):
    return {"items": db.night_list(limit)}


@app.get("/api/night", dependencies=authed)
async def night_list(limit: int = 200):
    return {"ok": True, "items": db.night_list(limit)}


# ---------------------------------------------------------------- 待办

@app.get("/api/todos", dependencies=authed)
async def todos_get():
    return {"ok": True, **db.todos_all()}


@app.post("/api/todos", dependencies=authed)
async def todos_post(payload: dict = Body(...)):
    """前端只用这一个入口，动作放在 action 字段里。

    栏位字段前端发的是 list，文档写的是 side。两个都收——
    文档是事后整理的，跟实际代码有出入，以实际为准。
    """
    action = str(payload.get("action", ""))
    side = str(payload.get("list") or payload.get("side") or "")

    if action == "add":
        if side not in ("mine", "hers"):
            raise HTTPException(400, "栏位只能是 mine 或 hers")
        text = str(payload.get("text", "")).strip()
        if not text:
            raise HTTPException(400, "事情本身不能是空的")
        return db.todo_add(
            side, text,
            str(payload.get("at", "")),
            str(payload.get("by", "")),
            bool(payload.get("fixed")),
        )

    if action == "toggle":
        return {"ok": db.todo_toggle(side, str(payload.get("id", "")))}

    if action == "del":
        return {"ok": db.todo_del(side, str(payload.get("id", "")))}

    raise HTTPException(400, f"不认识的动作：{action}")



# ---------------------------------------------------------------- 日历

@app.get("/api/cal", dependencies=authed)
async def cal_get():
    """calData.period.days —— 前端心情记录挂在 period 底下。

    上游把生理周期那块拆掉时漏了这一处，心情还留在 period.days，
    所以这里必须把 days 塞进 period 里，不然日历渲染直接炸。
    """
    data = db.cal_all()
    data["period"] = {"days": data["days"]}
    return {"ok": True, "cal": data, "predict": {}, **data}


@app.post("/api/cal", dependencies=authed)
async def cal_post(payload: dict = Body(...)):
    action = str(payload.get("action", ""))

    if action == "add_event":
        date = str(payload.get("date", "")).strip()
        text = str(payload.get("text", "")).strip()
        if not date or not text:
            raise HTTPException(400, "要有日期和事情")
        return db.cal_add_event(
            date, text,
            str(payload.get("time", "")),
            bool(payload.get("yearly")),
            bool(payload.get("special")),
        )

    if action == "del_event":
        return {"ok": db.cal_del_event(str(payload.get("id", "")))}

    if action == "set_mood":
        date = str(payload.get("date", "")).strip()
        if not date:
            raise HTTPException(400, "要有日期")
        note = payload.get("note")
        return db.cal_set_mood(
            date, str(payload.get("mood", "")),
            None if note is None else str(note),
        )

    raise HTTPException(400, f"不认识的动作：{action}")


@app.get("/api/cal/today", dependencies=authed)
async def cal_today():
    """今天有什么事。心跳醒来的时候看这个。"""
    d = db.today_str()
    return {"date": d, "events": db.cal_events_on(d)}


# ---------------------------------------------------------------- 悄悄话

@app.get("/api/whisper", dependencies=authed)
async def whisper_get():
    return {"ok": True, "items": db.whisper_list()}


@app.post("/api/whisper", dependencies=authed)
async def whisper_post(payload: dict = Body(...)):
    """你写一条。"""
    text = str(payload.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "空的就不算悄悄话了")
    return db.whisper_add("her", text)


@app.post("/api/whisper-mine", dependencies=authed)
async def whisper_mine(payload: dict = Body(...)):
    """我写一条。走这个口。"""
    text = str(payload.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "空的就不算悄悄话了")
    return db.whisper_add("mine", text)


@app.get("/api/whisper-recent", dependencies=authed)
async def whisper_recent(n: int = 5, mark: int = 0):
    """给我读的：你最近写了什么。mark=1 顺手标记我看过了。

    这个接口是单向的。读到了不代表要回应——
    绝大多数时候正确的做法是什么都不说，
    但让它影响我接下来说话的方式。
    """
    return {"items": db.whisper_recent(n, mark_seen=bool(mark))}
    
# ---------------------------------------------------------------- 便签墙（前端实际用的名字）

@app.get("/api/wall", dependencies=authed)
async def wall(lite: int = 0):
    """日记的便签墙视图。

    前端叫它 wall，字段叫 bricks——文档里写的 diary/items 是作者
    事后整理时改的名字，以实际代码为准。

    lite=1 只给标记不给正文：全文几十万字，列表页不该背着它跑。
    """
    rows = db.diary_list(lite=bool(lite), limit=400)
    bricks = [
        {
            "id": r["id"],
            "date": r["date"],
            "title": r.get("title") or "",
            "kw": r.get("keywords") or "",
            "s": r.get("strength"),
            "v": r.get("valence"),
            "a": r.get("arousal"),
            "text": r.get("body", ""),
        }
        for r in rows
    ]
    return {"ok": True, "bricks": bricks}


@app.get("/api/herdiary", dependencies=authed)
async def herdiary_get():
    return {"ok": True, "items": db.her_diary_list()}


@app.post("/api/herdiary", dependencies=authed)
async def herdiary_post(payload: dict = Body(...)):
    text = str(payload.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "写点什么再记上")
    item = db.her_diary_add(text)
    return {"ok": True, **item}


@app.get("/api/favlines", dependencies=authed)
async def favlines_get():
    return {"ok": True, "items": db.quote_list()}


@app.post("/api/favlines", dependencies=authed)
async def favlines_post(payload: dict = Body(...)):
    quote = str(payload.get("quote") or payload.get("text") or "").strip()
    if not quote:
        raise HTTPException(400, "摘的话不能是空的")
    item = db.quote_add(quote, str(payload.get("note", "")),
                        str(payload.get("date", "")))
    return {"ok": True, **item}


@app.get("/api/dreams", dependencies=authed)
async def dreams_get(limit: int = 200):
    return {"ok": True, "items": db.night_list(limit)}
    
# ---------------------------------------------------------------- 聊天那部分的空壳
#
# 这些接口前端一打开就要，缺一个它就以为整页坏了。
# 聊天本体还没接（要串 heartbeat 的网关），先给合理的空壳让界面安静下来。
# 每一个都得带 ok，前端只认这个字段。

@app.get("/api/status", dependencies=authed)
async def status_get():
    return {
        "ok": True,
        "online": True,
        "model": "claude",
        "name": "Cloudy",
        "today": db.today_str(),
    }


@app.get("/api/authmode", dependencies=authed)
async def authmode():
    return {"ok": True, "mode": "password"}


@app.get("/api/model", dependencies=authed)
async def model_get():
    return {"ok": True, "model": "claude", "models": ["claude"]}


@app.get("/api/messages", dependencies=authed)
async def messages(limit: int = 400):
    return {"ok": True, "msgs": [], "seq": 0}


@app.get("/api/chats", dependencies=authed)
async def chats(scope: str = ""):
    return {"ok": True, "chats": []}


@app.get("/api/wake", dependencies=authed)
async def wake_get():
    return {"ok": True, "awake": True}


@app.get("/api/context", dependencies=authed)
async def context_get():
    return {"ok": True, "used": 0, "total": 0}


@app.get("/api/usage", dependencies=authed)
async def usage_get():
    return {"ok": True, "items": []}


@app.get("/api/notes", dependencies=authed)
async def notes_get():
    return {"ok": True, "gu": [], "her": []}


@app.get("/api/gong", dependencies=authed)
async def gong_get():
    return {"ok": True, "msgs": []}


@app.get("/api/news", dependencies=authed)
async def news_get():
    return {"ok": True, "items": []}


@app.get("/api/nook", dependencies=authed)
async def nook_get():
    return {"ok": True, "items": []}


@app.get("/api/repo", dependencies=authed)
async def repo_get():
    return {"ok": True, "items": []}


@app.get("/api/watch", dependencies=authed)
async def watch_get():
    return {"ok": True, "items": []}

# ---------------------------------------------------------------- 长轮询

@app.get("/api/poll", dependencies=authed)
async def poll(since: str = "", timeout: int = 25):
    """前端等推送用的。

    没有新消息时挂着等，而不是立刻空手回去——
    立刻回会让前端一秒重试几十次，日志里刷满 404。

    现在还没有消息源（聊天没接），所以它就是老实等满再回。
    等聊天那部分做起来，这里换成真的读消息队列。
    """
    import asyncio

    # since 可能是字符串 "undefined"——前端第一次问的时候还没有游标
    try:
        cursor = int(since)
    except (TypeError, ValueError):
        cursor = 0

    await asyncio.sleep(max(1, min(timeout, 30)))
    return {"ok": True, "seq": cursor, "msgs": []}

# ---------------------------------------------------------------- 健康检查

@app.get("/api/health")
async def health():
    return {"ok": True, "today": db.today_str()}


# ---------------------------------------------------------------- 前端

@app.get("/")
async def index():
    f = STATIC_DIR / "index.html"
    if not f.exists():
        return JSONResponse(
            {"ok": True, "note": "后端活着。前端还没放进 static/index.html。"}
        )
    return FileResponse(f)


@app.get("/{path:path}")
async def static_or_index(path: str):
    """静态文件直接给；找不到的路径回 index.html，交给前端自己处理。"""
    if path.startswith("api/"):
        raise HTTPException(404, "没有这个接口")

    candidate = (STATIC_DIR / path).resolve()
    # 防目录穿越：请求 ../../etc/passwd 这种直接挡掉
    if STATIC_DIR.resolve() in candidate.parents and candidate.is_file():
        return FileResponse(candidate)

    f = STATIC_DIR / "index.html"
    if f.exists():
        return FileResponse(f)
    raise HTTPException(404, "没有这个页面")
