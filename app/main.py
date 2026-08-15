"""dwell 后端。日记、待办、日历、悄悄话。

一个服务同时干两件事：
- 提供 /api/* 接口
- 托管 static/index.html 那份前端

这么做是为了只在 Zeabur 上开一个服务：省内存，也不用管跨域。
"""

import asyncio
import os
import time
from pathlib import Path
from urllib.parse import urlparse

from fastapi import Body, Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from . import auth, db, provider_secrets
from app.pet_assets import ensure_pet_assets
from app.heartbeat_client import stream_chat

app = FastAPI(title="dwell", docs_url=None, redoc_url=None)

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"

# 正在跑的 AI 回复任务。key=chat_id，value=asyncio.Task
_running_tasks: dict[str, asyncio.Task] = {}
# 每个 chat 一条事件队列，poll 从这里拿事件推给前端。
_event_queues: dict[str, asyncio.Queue] = {}
# 每个 chat 的事件游标，从 1 开始
_event_seq: dict[str, int] = {}
# 缓存最近 N 条事件，让重连的 poll(since=N) 能补上漏掉的
_event_log: dict[str, list] = {}


def _get_queue(chat_id: str) -> asyncio.Queue:
    if chat_id not in _event_queues:
        _event_queues[chat_id] = asyncio.Queue()
        _event_seq[chat_id] = 0
        _event_log[chat_id] = []
    return _event_queues[chat_id]


def _emit(chat_id: str, event: dict):
    """把一个事件塞进队列 + 日志。event 已经是前端认识的形状。"""
    _get_queue(chat_id)
    _event_seq[chat_id] += 1
    event = {**event, "seq": _event_seq[chat_id]}
    _event_log[chat_id].append(event)
    if len(_event_log[chat_id]) > 200:
        _event_log[chat_id] = _event_log[chat_id][-200:]
    try:
        _event_queues[chat_id].put_nowait(event)
    except asyncio.QueueFull:
        pass

import json


async def _read_json(request: Request) -> dict:
    """读 body 当 JSON。前端有时不带 Content-Type，Body(...) 不吃。

    空 body 返回空 dict，让路由自己去校验字段——比抛 422 友好。
    """
    raw = await request.body()
    if not raw:
        return {}
    try:
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        raise HTTPException(400, "body 不是合法 JSON")
    if not isinstance(data, dict):
        raise HTTPException(400, "body 必须是 JSON 对象")
    return data


@app.on_event("startup")
def _startup():
    db.init_db()
    db.setting_set("started_at", str(int(time.time())))
    ensure_frontend()
    ensure_pet_assets(str(STATIC_DIR)) 


FRONTEND_URL = ("https://raw.githubusercontent.com/xinwithyu/"
                "dwell-on-something/main/web/index.html")


def ensure_frontend():
    """前端不在就自己去拉一份，剥掉演示模式，顺手补上游的 bug，改成我们家的名字。

    那个文件 280KB，不进仓库；容器每次重建都会丢。
    与其让人手动装一遍，不如让它自己长回来。
    拉不到也不致命——接口照样活着，只是没有脸。
    """
    import urllib.request

    target = STATIC_DIR / "index.html"
    # 当前网页作为项目文件保存。不能在每次启动时重拉上游并覆盖它，
    # 否则我们已经接好的聊天、PWA 与名字改动都会在部署后丢失。
    if target.exists():
        print(f"[dwell] 使用项目内前端 {target.stat().st_size} 字节")
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
        # 二点五、拦掉 401 → reload 死循环。
        # 前端 poll() 收到 401 会 location.href='./'，但 './' 就是主页本身，
        # 一进来又 poll → 又 401 → 又跳，永远登不上。
        # 改成 401 时弹一个原生登录框，成功了就刷新继续。
        old_401 = "if (r.status === 401) { location.href = './'; return; }"
        new_401 = "if (r.status === 401) { await promptLogin(); return; }"
        if old_401 in html:
            html = html.replace(old_401, new_401, 1)
            print("[dwell] 拦掉了 401 reload 死循环")
        else:
            print("[dwell] 没找到 401 那行——可能上游改了")

        # 注入 promptLogin 函数：弹原生 prompt，走 /api/login，成功后刷新。
        # 塞在 </body> 前面，全局可用。
        login_shim = """
<script>
window.promptLogin = async function() {
  if (window.__logging_in) return;
  window.__logging_in = true;
  try {
    const user = prompt('用户名');
    if (!user) return;
    const password = prompt('密码');
    if (password === null) return;
    const r = await fetch('/api/login', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({user, password})
    });
    if (r.ok) {
      location.reload();
    } else {
      alert('登不上，再试一次');
      window.__logging_in = false;
    }
  } catch (e) {
    alert('出错了：' + e);
    window.__logging_in = false;
  }
};

// 页面加载时先问一下 /api/me，如果没登录就立刻弹框。
// 不等 poll 那边慢慢触发。
(async function bootAuth() {
  try {
    const r = await fetch('/api/me');
    const d = await r.json();
    if (!d.authed) await window.promptLogin();
  } catch (e) {}
})();
</script>
"""
        if "</body>" in html:
            html = html.replace("</body>", login_shim + "</body>", 1)
            print("[dwell] 注入了登录弹框")

        # 三、改名字。原作者的默认字符串换成我们家的。
        # 静态字符串（HTML/JS 里直接写死的）走 replace。
        # 中文名在 JS 里是 Unicode 转义写法（\u6b23 是"欣"），所以要用转义码替换。
        renames = [
            # <title>：浏览器标签
            ("<title>Claude</title>", "<title>dwell</title>"),
            # 主界面顶上那个 h1 和副标题
            ("<h1>Claude</h1>", "<h1>Cloudy</h1>"),
            # 副标题 Claude Code 保留，Morry 说她喜欢
            # 侧边栏的招牌
            ('<div class="brand">Claude</div>', '<div class="brand">CLOUDY STUDIO</div>'),
            # 最近对话里那个默认名
            ('id="recGu">Claude</button>', 'id="recGu">Cloudy</button>'),
            # setTitle 的 fallback：没传名字时的默认（h1 显示）
            ("name || 'Claude';", "name || 'Cloudy';"),
            ('name || "Claude";', 'name || "Cloudy";'),
            # 待办页脚：\u6b23\u6b23 = 欣欣 → Morry
            ("\\u6b23\\u6b23", "Morry"),
            # 待办页脚的招牌：YU · XIN → MORRY · CLOUDY
            ("YU \\u00b7 XIN GENERAL STORE", "MORRY \\u00b7 CLOUDY GENERAL STORE"),
            ("\\u8001\\u5a46\\u7684", "Plum \\u7684"),
            ("\\u987e\\u5c7f\\u7684\\u6d3b", "Cloudy \\u7684\\u6d3b"),
            ("\\u7b49\\u8001\\u516c\\u5e03\\u7f6e", "\\u7b49\\u4ed6\\u5e03\\u7f6e"),
            ("\\u7b49\\u8001\\u516c\\u5e03\\u7f6e", "\\u7b49\\u4ed6\\u5e03\\u7f6e"),
            ("new Date('2026-06-17T00:00:00+08:00')",
             "new Date('2026-04-17T00:00:00+08:00')"),
        ]

        renamed = 0
        for old, new in renames:
            if old in html:
                html = html.replace(old, new)
                renamed += 1
            else:
                print(f"[dwell] 名字替换没命中：{old[:40]}...")

        # document.title 那处 fallback 单独处理：h1 用 Cloudy，但浏览器标题要 dwell
        # 前面的通用 rename 会把它一起改成 Cloudy，这里再改回 dwell
        html = html.replace(
            "document.title = name || 'Cloudy';",
            "document.title = name || 'dwell';",
            1,
        )
        html = html.replace(
            'document.title = name || "Cloudy";',
            'document.title = name || "dwell";',
            1,
        )

        print(f"[dwell] 名字改了 {renamed} 处")

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

    三个动作之后都返回完整列表，跟 GET /api/todos 同结构。
    因为前端 todoAct 拿到响应直接扔给 renderTodos，
    renderTodos 只认 {mine, hers} 那个形状。
    """
    action = str(payload.get("action", ""))
    side = str(payload.get("list") or payload.get("side") or "")

    if action == "add":
        if side not in ("mine", "hers"):
            raise HTTPException(400, "栏位只能是 mine 或 hers")
        text = str(payload.get("text", "")).strip()
        if not text:
            raise HTTPException(400, "事情本身不能是空的")
        db.todo_add(
            side, text,
            str(payload.get("at", "")),
            str(payload.get("by", "")),
            bool(payload.get("fixed")),
        )
        return {"ok": True, **db.todos_all()}

    if action == "toggle":
        db.todo_toggle(side, str(payload.get("id", "")))
        return {"ok": True, **db.todos_all()}

    if action == "del":
        db.todo_del(side, str(payload.get("id", "")))
        return {"ok": True, **db.todos_all()}

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
async def whisper_post(request: Request):
    """你写一条。

    前端发这条时没加 Content-Type: application/json，body 是 text/plain。
    所以不能用 Body(...) 让 FastAPI 自己解析，手工读一下就好。
    """
    payload = await _read_json(request)
    text = str(payload.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "空的就不算悄悄话了")
    item = db.whisper_add("her", text)
    return {**(item or {}), "ok": True}


@app.post("/api/whisper-mine", dependencies=authed)
async def whisper_mine(request: Request):
    """我写一条。走这个口。"""
    payload = await _read_json(request)
    text = str(payload.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "空的就不算悄悄话了")
    item = db.whisper_add("mine", text)
    return {**(item or {}), "ok": True}


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
    current = _get_or_create_current_chat()
    task = _running_tasks.get(current)
    return {
        "ok": True,
        "alive": True,
        "since": int(db.setting_get("started_at", "0") or "0") or None,
        "busy": bool(task and not task.done()),
        "armed": False,
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
    chat_id = _get_or_create_current_chat()
    selection = db.chat_model_get(chat_id)
    providers = db.provider_list()
    return {
        "ok": True,
        # model/effort 保留给原 dwell 前端的读取逻辑；新增字段供新的设置界面使用。
        "model": selection["model_id"],
        "effort": selection["reasoning_effort"],
        "provider_id": selection["provider_id"],
        "chat_id": chat_id,
        "providers": providers,
        "configured": bool(selection["provider_id"] and selection["model_id"]),
    }


def _clean_base_url(value: object) -> str:
    url = str(value or "").strip().rstrip("/")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(400, "base_url 必须是 http:// 或 https:// 开头的地址")
    if parsed.query or parsed.fragment:
        raise HTTPException(400, "base_url 不能带查询参数或 # 片段")
    return url


def _provider_public(row: dict) -> dict:
    return {key: row[key] for key in ("id", "name", "base_url", "enabled", "made", "updated")}


@app.get("/api/providers", dependencies=authed)
async def providers_get():
    return {
        "ok": True,
        "items": db.provider_list(),
        "encryption_ready": provider_secrets.encryption_ready(),
    }


@app.post("/api/providers", dependencies=authed)
async def providers_upsert(request: Request):
    payload = await _read_json(request)
    provider_id = str(payload.get("id") or "").strip()
    existing = db.provider_get(provider_id) if provider_id else None
    if provider_id and not existing:
        raise HTTPException(404, "找不到这个供应商")

    name = str(payload.get("name") or (existing or {}).get("name") or "").strip()[:80]
    if not name:
        raise HTTPException(400, "供应商名称不能为空")
    base_url = _clean_base_url(payload.get("base_url") or (existing or {}).get("base_url"))
    enabled = bool(payload.get("enabled", (existing or {}).get("enabled", True)))

    # token 未传时，更新名称/地址不会动已有密钥；传空字符串则明确清除密钥。
    api_key_box = None
    if "token" in payload:
        token = str(payload.get("token") or "").strip()
        if token:
            try:
                api_key_box = provider_secrets.encrypt_api_key(token)
            except provider_secrets.SecretConfigurationError as exc:
                raise HTTPException(503, str(exc)) from exc
        else:
            api_key_box = ""

    saved = db.provider_upsert(provider_id, name, base_url, api_key_box, enabled)
    return {"ok": True, "provider": _provider_public(saved), "has_key": bool(saved.get("api_key_box"))}


@app.delete("/api/providers/{provider_id}", dependencies=authed)
async def providers_delete(provider_id: str):
    if db.provider_in_use(provider_id):
        raise HTTPException(409, "仍有聊天正在使用这个供应商；请先切换模型")
    if not db.provider_delete(provider_id):
        raise HTTPException(404, "找不到这个供应商")
    return {"ok": True}


@app.post("/api/model", dependencies=authed)
async def model_set(request: Request):
    payload = await _read_json(request)
    chat_id = _get_or_create_current_chat()
    current = db.chat_model_get(chat_id)
    provider_id = str(payload.get("provider_id", current["provider_id"]) or "").strip()
    model_id = str(payload.get("model", payload.get("model_id", current["model_id"])) or "").strip()[:200]
    effort = str(payload.get("effort", payload.get("reasoning_effort", current["reasoning_effort"])) or "").strip()[:30]
    if provider_id:
        provider = db.provider_get(provider_id)
        if not provider or not provider["enabled"]:
            raise HTTPException(400, "所选供应商不存在或已停用")
    if provider_id and not model_id:
        raise HTTPException(400, "请选择模型")
    if model_id and not provider_id:
        raise HTTPException(400, "请先选择供应商")
    db.chat_model_set(chat_id, provider_id, model_id, effort)
    return {"ok": True, "provider_id": provider_id, "model": model_id, "effort": effort}


@app.get("/api/wake", dependencies=authed)
async def wake_get():
    return {
        "ok": True,
        "on": db.setting_get("wake_on", "1") != "0",
        "count": int(db.setting_get("wake_count_today", "0") or "0"),
        "room": "",
    }


@app.post("/api/wake", dependencies=authed)
async def wake_set(request: Request):
    payload = await _read_json(request)
    on = bool(payload.get("on"))
    db.setting_set("wake_on", "1" if on else "0")
    return {"ok": True, "on": on, "count": int(db.setting_get("wake_count_today", "0") or "0"), "room": ""}


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


@app.get("/api/pushkey", dependencies=authed)
async def pushkey_get():
    key = os.environ.get("VAPID_PUBLIC_KEY", "").strip()
    if not key:
        raise HTTPException(503, "还没配置 VAPID_PUBLIC_KEY")
    return {"ok": True, "key": key}


@app.post("/api/subscribe", dependencies=authed)
async def subscribe(request: Request):
    payload = await _read_json(request)
    db.setting_set("push_subscription", json.dumps(payload, ensure_ascii=False))
    return {"ok": True}


@app.post("/api/rewake", dependencies=authed)
async def rewake():
    chat_id = _get_or_create_current_chat()
    _emit(chat_id, {"type": "system", "subtype": "rewake", "text": "（我在，刚刚重新听了一下）"})
    return {"ok": True}

# ---------------------------------------------------------------- 聊天

@app.get("/api/chats", dependencies=authed)
async def chats_list(scope: str = ""):
    """列出所有对话窗口。"""
    current = _get_or_create_current_chat()
    items = db.chat_list(scope, current)
    return {"ok": True, "items": items, "chats": items}


@app.post("/api/chats", dependencies=authed)
async def chats_post(request: Request):
    """新建、切换、改名、收纳聊天窗口。"""
    payload = await _read_json(request)
    action = str(payload.get("action") or "new").strip()
    current = _get_or_create_current_chat()

    if action == "switch":
        chat_id = str(payload.get("id", "")).strip()
        if not db.chat_switch(chat_id):
            raise HTTPException(404, "chat 不存在")
        _emit(chat_id, {"type": "system", "subtype": "switched", "text": "（换到这间了）"})
        items = db.chat_list("", chat_id)
        return {"ok": True, "id": chat_id, "items": items, "chats": items}

    if action == "rename":
        chat_id = str(payload.get("id") or current).strip()
        name = str(payload.get("name", "")).strip()
        ok = db.chat_rename(chat_id, name)
        items = db.chat_list("", current)
        return {"ok": ok, "items": items, "chats": items}

    if action in ("archive", "box"):
        chat_id = str(payload.get("id") or current).strip()
        archived = bool(payload.get("archived", True))
        ok = db.chat_archive(chat_id, archived)
        if chat_id == current and archived:
            for item in db.chat_list("live", ""):
                db.chat_switch(item["id"])
                current = item["id"]
                break
        items = db.chat_list("", current)
        return {"ok": ok, "items": items, "chats": items}

    name = str(payload.get("name", "")).strip()
    chat = db.chat_add(name)
    db.chat_switch(chat["id"])
    items = db.chat_list("", chat["id"])
    return {"ok": True, **chat, "items": items, "chats": items}


@app.post("/api/newchat", dependencies=authed)
async def newchat(request: Request):
    """前端 New chat 打这个接口。arm:true 只是预备切换（说话才真建），arm:false 取消。
    简化处理：直接建新 chat 并切过去。"""
    payload = await _read_json(request)
    if payload.get("arm") is False:
        return {"ok": True}
    chat = db.chat_add("")
    db.chat_switch(chat["id"])
    _emit(chat["id"], {"type": "system", "subtype": "newchat", "text": "（新窗口开好了）"})
    return {"ok": True, **chat}


@app.delete("/api/chats/{chat_id}", dependencies=authed)
async def chats_del(chat_id: str):
    ok = db.chat_del(chat_id)
    current = _get_or_create_current_chat()
    items = db.chat_list("", current)
    return {"ok": ok, "items": items, "chats": items}


@app.get("/api/messages", dependencies=authed)
async def messages_get(chat_id: str = "", limit: int = 400, before: int | None = None):
    if not chat_id:
        chat_id = _get_or_create_current_chat()
    data = db.message_ui_list(chat_id, limit, before)
    return {"ok": True, **data}

# ---------------------------------------------------------------- 聊天：发送 / 停止 / 长轮询

CURRENT_CHAT_KEY = "current_chat_id"


def _get_or_create_current_chat() -> str:
    """当前活跃 chat。没有就建一个。"""
    chat_id = db.setting_get(CURRENT_CHAT_KEY)
    if chat_id and db.chat_get(chat_id):
        return chat_id
    chat = db.chat_add("对话")
    db.setting_set(CURRENT_CHAT_KEY, chat["id"])
    return chat["id"]


async def _run_ai_reply(chat_id: str, msg_id: str):
    """跑 heartbeat，边收边发事件给前端。同时把完整回复写进库。"""
    history = db.message_list(chat_id, limit=100)
    # 身份、长期记忆和可选指令由 MCP（Ombre Brain 等）提供；
    # 本地后端不再注入 Cloudy 人设，避免与记忆系统冲突。
    messages = [
        {"role": m["role"], "content": m["content"]}
        for m in history
        if m["content"] or m["role"] != "assistant"
    ]
    buf = []
    try:
        async for chunk in stream_chat(messages, chat_id):
            buf.append(chunk)
            db.message_update(msg_id, "".join(buf))
            _emit(chat_id, {
                "type": "stream_event",
                "event": {
                    "delta": {"type": "text_delta", "text": chunk}
                }
            })
        full = "".join(buf).strip()
        _emit(chat_id, {
            "type": "assistant",
            "message": {
                "content": [{"type": "text", "text": full}] if full else []
            }
        })
        _emit(chat_id, {"type": "result", "is_error": False})
    except asyncio.CancelledError:
        if buf:
            db.message_update(msg_id, "".join(buf) + "\n[已停止]")
            _emit(chat_id, {
                "type": "assistant",
                "message": {
                    "content": [{"type": "text", "text": "".join(buf) + "\n[已停止]"}]
                }
            })
        _emit(chat_id, {"type": "system", "subtype": "stopped"})
        raise
    finally:
        _running_tasks.pop(chat_id, None)

@app.post("/api/send", dependencies=authed)
async def send(request: Request):
    payload = await _read_json(request)
    text = str(payload.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "消息不能是空的")

    chat_id = _get_or_create_current_chat()

    db.message_add(chat_id, "user", text)
    _emit(chat_id, {"type": "echo", "text": text})

    placeholder = db.message_add(chat_id, "assistant", "")

    task = asyncio.create_task(_run_ai_reply(chat_id, placeholder["id"]))
    _running_tasks[chat_id] = task

    return {"ok": True}


@app.post("/api/stop", dependencies=authed)
async def stop():
    chat_id = _get_or_create_current_chat()
    task = _running_tasks.get(chat_id)
    if task and not task.done():
        task.cancel()
        return {"ok": True, "stopped": True}
    return {"ok": True, "stopped": False}


@app.get("/api/poll", dependencies=authed)
async def poll(since: str = "", timeout: int = 25):
    """长轮询：返回 {next, events}。只从 _event_log 里拿，不用 Queue。"""
    chat_id = _get_or_create_current_chat()
    _get_queue(chat_id)  # 确保初始化

    try:
        cursor = int(since)
    except (TypeError, ValueError):
        cursor = 0

    # 有积压立刻回
    backlog = [e for e in _event_log.get(chat_id, []) if e["seq"] > cursor]
    if backlog:
        return {"ok": True, "next": backlog[-1]["seq"], "events": backlog}

    # 没有就轮询等
    deadline = asyncio.get_event_loop().time() + max(1, min(timeout, 30))
    while asyncio.get_event_loop().time() < deadline:
        await asyncio.sleep(0.3)
        new = [e for e in _event_log.get(chat_id, []) if e["seq"] > cursor]
        if new:
            return {"ok": True, "next": new[-1]["seq"], "events": new}

    return {"ok": True, "next": cursor, "events": []}


@app.get("/api/wake-target", dependencies=authed)
async def wake_target_get():
    """当前接收主动消息的 chat。"""
    return {"ok": True, "chat_id": db.setting_get("wake_target_chat_id")}


@app.post("/api/wake-target", dependencies=authed)
async def wake_target_set(payload: dict = Body(...)):
    chat_id = str(payload.get("chat_id", "")).strip()
    if chat_id and not db.chat_get(chat_id):
        raise HTTPException(404, "chat 不存在")
    db.setting_set("wake_target_chat_id", chat_id)
    return {"ok": True, "chat_id": chat_id}


@app.post("/api/wake-say")
async def wake_say(request: Request):
    """供 cloudy-heartbeat 主动把一句话送进 dwell。

    这条路只接受 X-Dwell-Token，不依赖浏览器 cookie：消息先落库，
    再发进当前聊天窗口的事件流，手机推送以后也以这里为唯一入口。
    """
    if not auth.check_api_token(request.headers.get("X-Dwell-Token", "")):
        raise HTTPException(401, "X-Dwell-Token 不对")

    payload = await _read_json(request)
    text = str(payload.get("text") or payload.get("message") or "").strip()
    if not text:
        raise HTTPException(400, "消息不能是空的")

    chat_id = str(payload.get("chat_id") or db.setting_get("wake_target_chat_id")).strip()
    if not chat_id or not db.chat_get(chat_id):
        chat_id = _get_or_create_current_chat()

    message = db.message_add(chat_id, "assistant", text)
    _emit(chat_id, {
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": text}]},
    })
    return {"ok": True, "chat_id": chat_id, "id": message["id"]}


# ---------------------------------------------------------------- 健康检查

@app.get("/api/health")
async def health():
    return {"ok": True, "today": db.today_str()}

# ---------------------------------------------------------------- PWA 清单

@app.get("/manifest.json")
async def manifest():
    """PWA 清单。之前 fallback 到 index.html，浏览器当 JSON 解析就报语法错。

    theme_color 用小人自己的橘色 (#DE886D)——他既是右下角的 pet，
    也是任务栏和启动屏的颜色。icon 直接用他站着的样子。
    """
    return {
        "name": "dwell",
        "short_name": "dwell",
        "description": "两个人住的地方",
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "background_color": "#ffffff",
        "theme_color": "#DE886D",
        "icons": [
            {
                "src": "/pet/clawd-static-base.svg",
                "sizes": "any",
                "type": "image/svg+xml",
                "purpose": "any",
            }
        ],
    }

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

