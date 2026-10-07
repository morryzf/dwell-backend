"""Claude Agent SDK 通道：走本机 Claude Code 的订阅额度，而不是按量计费的 API。

Dwell 是 Python，Agent SDK 是 Node.js 包，中间隔一个本机小服务（见 bridge/）：

    Dwell (FastAPI) --HTTP/SSE--> bridge (Node) --> Agent SDK --> Claude Code CLI

这个模块只做两件事：把 Dwell 的中立消息历史整理成桥接服务要的形状，
再把桥接服务回来的 SSE 事件翻译成 stream_chat 的事件。它不认识 Agent SDK
本身，换掉桥接实现时这里不需要动。
"""

import hashlib
import json

import httpx

from . import db
from .llm_client import _usage_dict, content_texts
from .provider_secrets import SecretConfigurationError, decrypt_api_key

BRIDGE_PATH = "/v1/chat/stream"

# Claude Code 自己记着每个会话，续上就只用递新的那一句，不必每轮重抄整段历史。
SESSION_SETTING_PREFIX = "agent_sdk_session:"

# Agent SDK 接收的是「一句 prompt」，不是 OpenAI 那种 role 数组，所以多轮历史
# 要自己铺平。角色名用中文，和 Dwell 里模型看到的其余上下文保持同一种语言。
SPEAKER_USER = "Morry"
SPEAKER_ASSISTANT = "助手"
SPEAKER_TOOL = "工具结果"

HISTORY_OPEN = "<对话记录>"
HISTORY_CLOSE = "</对话记录>"
CONTINUE_HINT = "请接着上面的对话继续回应。"


def _plain_text(content) -> str:
    """取出可展示的正文；thinking 片段不会混进历史。"""
    return "\n".join(content_texts(content)).strip()


def image_blocks(messages: list) -> list[dict]:
    """取出这一轮要发的图片。

    原图只进这一轮的请求，不写进聊天历史（Dwell 一直是这么做的），所以只看
    最后一条用户消息。返回 Anthropic 的 image source 形状，桥接原样转给 SDK。
    """
    for message in reversed(messages or []):
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content")
        if not isinstance(content, list):
            return []
        blocks: list[dict] = []
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "image" and isinstance(part.get("source"), dict):
                blocks.append(dict(part["source"]))
                continue
            if part.get("type") != "image_url":
                continue
            raw = part.get("image_url")
            url = raw.get("url") if isinstance(raw, dict) else raw
            if not isinstance(url, str) or not url:
                continue
            if url.startswith("data:") and ";base64," in url:
                head, data = url.split(",", 1)
                media_type = head[5:].split(";", 1)[0] or "image/jpeg"
                blocks.append({"type": "base64", "media_type": media_type, "data": data})
            elif url.startswith(("https://", "http://")):
                blocks.append({"type": "url", "url": url})
        return blocks
    return []


# 记忆卡在消息里是一块块带 id 的正文（见 main._memory_card_blocks）。
# Claude Code 会把每轮的 prompt 原样记进会话，续会话时递过一次的卡它一直记着；
# 同一段会话里再递一遍，只会让每句话前面都堆着同样的几张卡。
MEMORY_CARD_KEY = "memory_card_id"

# 带这个标记的 system 消息不进临时上下文那一堆，而是接在 prompt 的最末尾，
# 排在她刚说的那句之后（语音回复的「只说英文」）。它不进 system、不进轮次，
# 所以不影响续会话。
PROMPT_TAIL_KEY = "dwell_prompt_tail"


def split_tail(messages: list) -> tuple[list, list[str]]:
    """摘出要接在 prompt 末尾的那几段。"""
    kept, tail = [], []
    for message in messages or []:
        if isinstance(message, dict) and message.get(PROMPT_TAIL_KEY):
            text = _plain_text(message.get("content"))
            if text:
                tail.append(text)
        else:
            kept.append(message)
    return kept, tail


def offered_cards(messages: list) -> set[str]:
    """这一轮挑出来的记忆卡 id。"""
    ids: set[str] = set()
    for message in messages or []:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for part in content:
            if isinstance(part, dict) and part.get(MEMORY_CARD_KEY):
                ids.add(str(part[MEMORY_CARD_KEY]))
    return ids


def forget_seen_cards(messages: list, seen: set[str]) -> list:
    """摘掉这段会话里已经递过的卡；一张新卡都不剩，整条卡片说明也不必再发。"""
    kept = []
    for message in messages or []:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list) or not any(
            isinstance(part, dict) and part.get(MEMORY_CARD_KEY) for part in content
        ):
            kept.append(message)
            continue
        parts = [
            part for part in content
            if not (isinstance(part, dict) and str(part.get(MEMORY_CARD_KEY) or "") in seen)
        ]
        if any(isinstance(part, dict) and part.get(MEMORY_CARD_KEY) for part in parts):
            kept.append({**message, "content": parts})
    return kept


def _seen_cards(state: dict | None) -> set[str]:
    raw = state.get("seen_cards") if isinstance(state, dict) else None
    if not isinstance(raw, list):
        return set()
    return {str(item) for item in raw if item}


def split_history(messages: list) -> tuple[str, list[tuple[str, str]], list[str]]:
    """把中立历史拆成 system 文本、轮次列表、以及本轮的临时上下文。

    历史开始之前的 system 是稳定人设；历史开始之后才出现的 system 是这一轮的
    临时信息（设备时间、专注计时、记忆卡…），每轮都不一样。两者必须分开：
    续会话时 Claude Code 只认第一次记下的 system，把易变的东西混进去，
    指纹每轮都对不上，会话就永远续不起来。
    """
    system_parts: list[str] = []
    turns: list[tuple[str, str]] = []
    context_parts: list[str] = []
    for message in messages or []:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "")
        text = _plain_text(message.get("content"))
        if role == "system":
            if not text:
                continue
            if turns:
                context_parts.append(text)
            else:
                system_parts.append(text)
        elif role == "user":
            if text:
                turns.append((SPEAKER_USER, text))
        elif role == "assistant":
            if text:
                turns.append((SPEAKER_ASSISTANT, text))
        elif role == "tool":
            # 这个通道由桥接侧跑工具，历史里的旧工具结果只当上下文留着。
            if text:
                turns.append((SPEAKER_TOOL, text))
    return "\n\n".join(system_parts), turns, context_parts


def build_prompt(turns: list[tuple[str, str]]) -> str:
    """把轮次铺平成一句 prompt；只有一条用户消息时原样送出。"""
    if not turns:
        return ""
    if len(turns) == 1 and turns[0][0] == SPEAKER_USER:
        return turns[0][1]

    history = turns
    latest = ""
    if turns[-1][0] == SPEAKER_USER:
        history, latest = turns[:-1], turns[-1][1]

    blocks = []
    if history:
        lines = "\n\n".join(f"{speaker}：{text}" for speaker, text in history)
        blocks.append(f"{HISTORY_OPEN}\n{lines}\n{HISTORY_CLOSE}")
    blocks.append(latest or CONTINUE_HINT)
    return "\n\n".join(blocks)


def turns_digest(turns: list[tuple[str, str]]) -> str:
    """给已经递出去的那几轮留个指纹，用来发现历史被改过。"""
    digest = hashlib.sha256()
    for speaker, text in turns:
        digest.update(speaker.encode("utf-8"))
        digest.update(b"\x00")
        digest.update(text.encode("utf-8"))
        digest.update(b"\x00")
    return digest.hexdigest()


# 锚点取末尾几轮：一轮用户 + 一轮回复 + 再一轮用户，足够认出位置，
# 又不至于因为一两句重复的「嗯」认错地方。
ANCHOR_TURNS = 3


def _anchor(turns: list[tuple[str, str]]) -> tuple[str, int]:
    """给「已经递出去到哪儿了」取个指纹。"""
    size = min(ANCHOR_TURNS, len(turns))
    return (turns_digest(turns[len(turns) - size:]) if size else ""), size


def memory_pool_version() -> str:
    """记忆池的版本。读不到就当没变——它只是个优化，不该挡下这次回复。"""
    try:
        return db.memory_pool_version()
    except Exception:
        return ""


def plan_turn(state: dict | None, model_id: str, system: str,
              turns: list[tuple[str, str]], cards: str = "") -> tuple[str, list[tuple[str, str]]]:
    """决定这轮是续上旧会话还是从头讲一遍。

    按内容在末尾对齐，不按位置。原文窗口是滑动的——聊满之后每轮都会挤掉最旧
    的几条，开头一直在变。早先的版本把指纹锚在开头，于是窗口一满就再也对不上，
    每轮都在重讲整段。

    返回 (要续的会话 id, 这次要递过去的轮次)。会话 id 为空就是从头开始。
    任何一处对不上都退回从头：宁可多花一次，也不能让 Claude Code 的上下文
    和 Dwell 的记录悄悄分叉。
    """
    if not isinstance(state, dict):
        return "", turns
    sid = str(state.get("sid") or "")
    if not sid or state.get("model") != model_id:
        return "", turns
    if state.get("sys") != turns_digest([("system", system)]):
        return "", turns
    # 记忆卡是每轮随 prompt 递过去的，Claude Code 把每一轮都记着——她把一张卡
    # 收起来、改掉、删掉，已经递出去的那几份都追不回来。池子一动就重开一段
    # 会话，是让它真的忘掉的唯一办法。
    if state.get("cards", "") != cards:
        return "", turns

    anchor = str(state.get("anchor") or "")
    size = int(state.get("anchor_len") or 0)
    if not anchor or not 0 < size <= len(turns):
        return "", turns

    # 从后往前找锚点：越靠后越可能是它，重复的短句也就不容易认错。
    for end in range(len(turns), size - 1, -1):
        if turns_digest(turns[end - size:end]) != anchor:
            continue
        fresh = turns[end:]
        # 它自己那条回复它本来就记着，别再抄回去。
        while fresh and fresh[0][0] == SPEAKER_ASSISTANT:
            fresh = fresh[1:]
        if not fresh:
            return "", turns
        return sid, fresh
    return "", turns


def load_state(chat_key: str) -> dict | None:
    if not chat_key:
        return None
    try:
        raw = db.setting_get(SESSION_SETTING_PREFIX + chat_key, "")
    except Exception:
        return None
    if not raw:
        return None
    try:
        state = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return state if isinstance(state, dict) else None


def save_state(chat_key: str, sid: str, model_id: str, system: str,
               turns: list[tuple[str, str]], cards: str = "",
               seen_cards: list[str] | None = None) -> None:
    """记下 Claude Code 这次的会话 id，以及它已经听过哪些轮次。

    存的是「递出去时」最后几轮的指纹。下一轮按内容找回这个位置，它后面的
    才是新的——它自己刚生成的那条回复会被当成已知的开头跳过。
    """
    if not chat_key or not sid:
        return
    # 状态只是下一轮的优化。写不进去顶多下次重讲一遍，不该连累已经说完的这条回复。
    try:
        anchor, size = _anchor(turns)
        db.setting_set(SESSION_SETTING_PREFIX + chat_key, json.dumps({
            "sid": sid,
            "model": model_id,
            "sys": turns_digest([("system", system)]),
            "anchor": anchor,
            "anchor_len": size,
            "cards": cards,
            "seen_cards": sorted(seen_cards or []),
        }, ensure_ascii=False))
    except Exception:
        pass


def clear_state(chat_key: str) -> None:
    if not chat_key:
        return
    try:
        db.setting_set(SESSION_SETTING_PREFIX + chat_key, "")
    except Exception:
        pass


def _length_hint(max_tokens: int | None) -> str:
    """Agent SDK 不接受 max_tokens，只能把长度要求写进 system 里。"""
    if max_tokens is None:
        return ""
    try:
        budget = int(max_tokens)
    except (TypeError, ValueError):
        return ""
    if budget <= 0:
        return ""
    return f"请把回复控制在大约 {budget} 个 token 以内。"


def enabled_rewrite_rules() -> list[dict]:
    """撞到就打回重说的那几条规则。全局共用——这是 Cloudy 怎么说话的事。

    读不到就当没有：规则是给回复挑刺的，不该反过来挡下这次回复。
    """
    try:
        return db.rewrite_rule_list(enabled_only=True)
    except Exception:
        return []


def build_bridge_payload(model_id: str, messages: list, tools: list | None = None,
                         max_tokens: int | None = None,
                         reasoning_effort: str | None = None,
                         thinking_enabled: bool = True,
                         state: dict | None = None,
                         rewrite_rules: list[dict] | None = None,
                         mcp_servers: dict | None = None,
                         require_english: bool = False,
                         require_language: str = "") -> dict:
    """组装一次桥接请求。

    tools 只用来判断这轮要不要多跑几圈：Dwell 的 function tools 无法直接交给
    Agent SDK，真正的工具由 MCP 提供（见 mcp_servers），所以这里不透传它们的 schema。

    mcp_servers 是这一轮 Claude Code 可以回调的 MCP（Dwell 这间聊天的整套工具），
    桥接把它和自己环境里配的合在一起。里面带着一次性的通行证，每轮都换，
    但它不进 prompt，也不进会话指纹，所以不影响续会话和缓存。

    rewrite_rules 每轮都重新带过去，所以改完规则下一句就生效。它不进 system，
    也不算进会话指纹——它是收尾时的一道关卡，不是上下文，改了不必重建缓存。

    payload 里额外带上 `_turns` / `_system` / `_seen_cards`，给调用方存会话状态用；发请求前摘掉。
    """
    messages, tail = split_tail(messages)
    system, turns, context = split_history(messages)
    hint = _length_hint(max_tokens)
    if hint:
        system = f"{system}\n\n{hint}".strip()

    cards_version = memory_pool_version()
    resume, outgoing = plan_turn(state, str(model_id or ""), system, turns, cards_version)
    # 从头讲的会话里还没有任何卡，续上的会话里递过的那些它都记着。
    seen = _seen_cards(state) if resume else set()
    if seen:
        _, _, context = split_history(forget_seen_cards(messages, seen))
    # 临时上下文跟着本轮走，不进 system，也不算进轮次指纹。
    prompt = "\n\n".join(context + [build_prompt(outgoing)] + tail)
    images = image_blocks(messages)

    payload = {
        "model": str(model_id or ""),
        "system": system,
        "prompt": prompt,
        "include_thinking": bool(thinking_enabled),
        # 没有工具时一轮就该收尾；留给 MCP 的余量在桥接侧按需要放大。
        "max_turns": 8 if tools or mcp_servers else 1,
        "_turns": turns,
        "_system": system,
        "_cards": cards_version,
        "_seen_cards": sorted(seen | offered_cards(messages)),
    }
    if images:
        payload["images"] = images
    if resume:
        payload["resume"] = resume
    rules = [
        {"phrases": list(rule["phrases"]), "reason": str(rule["reason"]).strip()}
        for rule in (rewrite_rules or [])
        if isinstance(rule, dict) and rule.get("phrases") and str(rule.get("reason") or "").strip()
    ]
    if rules:
        payload["rewrite_rules"] = rules
    if mcp_servers:
        payload["mcp_servers"] = mcp_servers
    if require_english:
        payload["require_english"] = True
    if require_language in {"zh", "en"}:
        payload["require_language"] = require_language
    # effort 关掉 thinking 时依然有意义（它还管花多少 token），能不能用由桥接判断。
    effort = str(reasoning_effort or "").strip()
    if effort:
        payload["effort"] = effort
    return payload


async def bridge_events(lines):
    """把桥接服务的 SSE 行翻成 stream_chat 的事件。"""
    async for line in lines:
        if not line or not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data or data == "[DONE]":
            continue
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue

        kind = str(event.get("type") or "")
        if kind == "text":
            text = str(event.get("text") or "")
            if text:
                yield {"type": "text", "text": text}
        elif kind == "thinking":
            thinking = str(event.get("thinking") or "")
            if thinking:
                yield {"type": "thinking", "thinking": thinking}
        elif kind == "usage":
            usage = _usage_dict(event.get("usage"))
            # 订阅额度不按量计费，桥接报的金额是本地估算，不进 Dwell 的成本统计。
            usage.pop("cost", None)
            usage.pop("upstream_cost", None)
            if usage:
                yield {"type": "usage", "usage": usage}
        elif kind == "notice":
            # 限流这类说明走思考面板：它不是回复的一部分，不该混进正文。
            text = str(event.get("message") or "")
            if text:
                yield {"type": "thinking", "thinking": f"（{text}）\n"}
        elif kind == "reset":
            # 桥接把上一版打回了。已经吐出去的字要抹掉，不然两版首尾相接。
            yield {"type": "reset"}
        elif kind == "session":
            sid = str(event.get("session_id") or "")
            if sid:
                yield {"type": "agent_session", "session_id": sid}
        elif kind == "compacted":
            yield {"type": "agent_compacted"}
        elif kind == "error":
            message = str(event.get("message") or "Claude Agent SDK 调用失败")[:500]
            yield {"type": "bridge_error", "message": message}
            return


async def _attempt(client, url: str, headers: dict, payload: dict, box: str):
    """跑一次桥接请求。会话 id 和错误都作为内部事件交给上层判断。"""
    request = {key: value for key, value in payload.items() if not key.startswith("_")}
    async with client.stream("POST", url, headers=headers, json=request) as resp:
        if resp.status_code != 200:
            body = (await resp.aread()).decode("utf-8", errors="ignore")[:500]
            yield {"type": "bridge_error", "message": f"{resp.status_code} {body}"}
            return
        yield {
            "type": "cache_status",
            "protocol": "claude_agent_sdk",
            "auth_mode": "bridge_token" if box else "none",
            "fallback_reason": "resumed" if payload.get("resume") else "",
        }
        async for event in bridge_events(resp.aiter_lines()):
            yield event


async def stream_bridge_chat(provider: dict, model_id: str, messages: list,
                             tools: list | None = None,
                             max_tokens: int | None = None,
                             reasoning_effort: str | None = None,
                             thinking_enabled: bool = True,
                             session_key: str = "", rewrite_guard: bool = False,
                             mcp_servers: dict | None = None,
                             require_english: bool = False,
                             require_language: str = ""):
    """通过桥接服务跑一轮对话。密钥是可选的：它是桥接服务的门禁，不是模型凭据。

    session_key 为空就每轮从头讲：心跳这类不属于这段对话的入口不该续会话，
    更不该把聊天存下的会话状态冲掉。
    """
    chat_key = str(session_key or "")
    rules = enabled_rewrite_rules() if rewrite_guard else []
    payload = build_bridge_payload(
        model_id, messages, tools, max_tokens=max_tokens,
        reasoning_effort=reasoning_effort, thinking_enabled=thinking_enabled,
        state=load_state(chat_key), rewrite_rules=rules, mcp_servers=mcp_servers,
        require_english=require_english, require_language=require_language,
    )
    if not payload["prompt"] and not payload.get("images"):
        yield {"type": "text", "text": "[配置错误] 这次没有可以发给 Claude Code 的内容"}
        return

    headers = {"Accept": "text/event-stream"}
    box = provider.get("api_key_box") or ""
    if box:
        try:
            headers["Authorization"] = f"Bearer {decrypt_api_key(box)}"
        except SecretConfigurationError as exc:
            yield {"type": "text", "text": f"[配置错误] {exc}"}
            return

    url = str(provider.get("base_url") or "").rstrip("/") + BRIDGE_PATH
    # Claude Code 是子进程，冷启动和长回答都比 HTTP API 慢，读超时给得宽一些。
    timeout = httpx.Timeout(600.0, connect=10.0)
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            for attempt in range(2):
                spoke = False
                failed = ""
                sid = ""
                compacted = False
                async for event in _attempt(client, url, headers, payload, box):
                    if event["type"] == "agent_session":
                        sid = event["session_id"]
                        continue
                    if event["type"] == "agent_compacted":
                        compacted = True
                        continue
                    if event["type"] == "bridge_error":
                        failed = event["message"]
                        continue
                    if event["type"] in {"text", "thinking"}:
                        spoke = True
                    yield event

                if failed and payload.get("resume") and not spoke and attempt == 0:
                    # 续会话失败（多半是那个会话已经不在了），当场从头讲一遍。
                    clear_state(chat_key)
                    payload = build_bridge_payload(
                        model_id, messages, tools, max_tokens=max_tokens,
                        reasoning_effort=reasoning_effort,
                        thinking_enabled=thinking_enabled, rewrite_rules=rules,
                        mcp_servers=mcp_servers, require_english=require_english,
                        require_language=require_language,
                    )
                    continue

                if failed:
                    clear_state(chat_key)
                    yield {"type": "text", "text": f"[桥接错误] {failed}"}
                elif sid:
                    # 压缩会把早先的卡总结掉，下一轮起重新递。
                    save_state(
                        chat_key, sid, str(model_id or ""),
                        payload["_system"], payload["_turns"], payload.get("_cards", ""),
                        seen_cards=[] if compacted else payload.get("_seen_cards", []),
                    )
                return
    except httpx.RequestError as exc:
        yield {
            "type": "text",
            "text": f"[网络错误] 无法连接 Claude Agent SDK 桥接服务：{exc}",
        }
