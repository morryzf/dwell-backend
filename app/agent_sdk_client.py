"""Claude Agent SDK 通道：走本机 Claude Code 的订阅额度，而不是按量计费的 API。

Dwell 是 Python，Agent SDK 是 Node.js 包，中间隔一个本机小服务（见 bridge/）：

    Dwell (FastAPI) --HTTP/SSE--> bridge (Node) --> Agent SDK --> Claude Code CLI

这个模块只做两件事：把 Dwell 的中立消息历史整理成桥接服务要的形状，
再把桥接服务回来的 SSE 事件翻译成 stream_chat 的事件。它不认识 Agent SDK
本身，换掉桥接实现时这里不需要动。
"""

import json

import httpx

from .llm_client import _usage_dict, content_texts
from .provider_secrets import SecretConfigurationError, decrypt_api_key

BRIDGE_PATH = "/v1/chat/stream"

# Agent SDK 接收的是「一句 prompt」，不是 OpenAI 那种 role 数组，所以多轮历史
# 要自己铺平。角色名用中文，和 Dwell 里模型看到的其余上下文保持同一种语言。
SPEAKER_USER = "用户"
SPEAKER_ASSISTANT = "助手"
SPEAKER_TOOL = "工具结果"

HISTORY_OPEN = "<对话记录>"
HISTORY_CLOSE = "</对话记录>"
CONTINUE_HINT = "请接着上面的对话继续回应。"


def _plain_text(content) -> str:
    """取出可展示的正文；thinking 片段不会混进历史。"""
    return "\n".join(content_texts(content)).strip()


def split_history(messages: list) -> tuple[str, list[tuple[str, str]]]:
    """把中立历史拆成 system 文本和 (说话人, 正文) 的轮次列表。"""
    system_parts: list[str] = []
    turns: list[tuple[str, str]] = []
    for message in messages or []:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "")
        text = _plain_text(message.get("content"))
        if role == "system":
            if text:
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
    return "\n\n".join(system_parts), turns


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


def build_bridge_payload(model_id: str, messages: list, tools: list | None = None,
                         max_tokens: int | None = None,
                         reasoning_effort: str | None = None,
                         thinking_enabled: bool = True,
                         session_id: str | None = None) -> dict:
    """组装一次桥接请求。

    tools 只用来判断这轮要不要多跑几圈：Dwell 的 function tools 无法直接交给
    Agent SDK，真正的工具在桥接侧由 MCP 提供，所以这里不透传它们的 schema。
    """
    system, turns = split_history(messages)
    hint = _length_hint(max_tokens)
    if hint:
        system = f"{system}\n\n{hint}".strip()

    payload = {
        "model": str(model_id or ""),
        "system": system,
        "prompt": build_prompt(turns),
        "include_thinking": bool(thinking_enabled),
        # 没有工具时一轮就该收尾；留给 MCP 的余量在桥接侧按需要放大。
        "max_turns": 8 if tools else 1,
    }
    effort = str(reasoning_effort or "").strip()
    if effort and thinking_enabled:
        payload["effort"] = effort
    if session_id:
        payload["session_id"] = str(session_id)[:256]
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
        elif kind == "error":
            message = str(event.get("message") or "Claude Agent SDK 调用失败")[:500]
            yield {"type": "text", "text": f"[桥接错误] {message}"}
            return


async def stream_bridge_chat(provider: dict, model_id: str, messages: list,
                             tools: list | None = None,
                             max_tokens: int | None = None,
                             reasoning_effort: str | None = None,
                             thinking_enabled: bool = True,
                             session_id: str | None = None):
    """通过桥接服务跑一轮对话。密钥是可选的：它是桥接服务的门禁，不是模型凭据。"""
    payload = build_bridge_payload(
        model_id, messages, tools, max_tokens=max_tokens,
        reasoning_effort=reasoning_effort, thinking_enabled=thinking_enabled,
        session_id=session_id,
    )
    if not payload["prompt"]:
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
            async with client.stream("POST", url, headers=headers, json=payload) as resp:
                if resp.status_code != 200:
                    body = (await resp.aread()).decode("utf-8", errors="ignore")[:500]
                    yield {"type": "text", "text": f"[桥接错误 {resp.status_code}] {body}"}
                    return
                yield {
                    "type": "cache_status",
                    "protocol": "claude_agent_sdk",
                    "auth_mode": "bridge_token" if box else "none",
                    "fallback_reason": "",
                }
                async for event in bridge_events(resp.aiter_lines()):
                    yield event
    except httpx.RequestError as exc:
        yield {
            "type": "text",
            "text": f"[网络错误] 无法连接 Claude Agent SDK 桥接服务：{exc}",
        }
