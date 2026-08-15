"""Ombre Brain 的最小 Streamable HTTP MCP 客户端。

这里只读取得 ``I`` 和 ``breath`` 的结果，供对话模型参考。记忆写入必须由
将来的显式功能触发，不能因为一次普通聊天就自动保存。
"""

import json
import os
import uuid
from typing import Any

import httpx


MCP_URL = os.environ.get("OMBRE_MCP_URL", "").rstrip("/")
MCP_TOKEN = os.environ.get("OMBRE_MCP_TOKEN", "")
MCP_TIMEOUT = float(os.environ.get("OMBRE_MCP_TIMEOUT", "12"))
PROTOCOL_VERSION = "2025-03-26"


def configured() -> bool:
    """只有 URL 和令牌都存在时才接入，避免意外访问未鉴权的记忆服务。"""
    return bool(MCP_URL and MCP_TOKEN)


def _headers(session_id: str = "") -> dict[str, str]:
    headers = {
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
        "MCP-Protocol-Version": PROTOCOL_VERSION,
        "Authorization": f"Bearer {MCP_TOKEN}",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    return headers


def _response_json(response: httpx.Response) -> dict[str, Any]:
    """兼容 JSON 响应和少数旧 MCP 服务的 SSE 响应。"""
    body = response.text.strip()
    if body.startswith("data:"):
        for line in body.splitlines():
            if line.startswith("data:"):
                body = line[5:].strip()
                break
    value = json.loads(body)
    if not isinstance(value, dict):
        raise ValueError("MCP 返回不是 JSON 对象")
    if value.get("error"):
        raise RuntimeError(str(value["error"]))
    return value


async def _request(
    client: httpx.AsyncClient,
    method: str,
    params: dict[str, Any],
    session_id: str = "",
) -> tuple[dict[str, Any], str]:
    payload = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": method,
        "params": params,
    }
    response = await client.post(MCP_URL, headers=_headers(session_id), json=payload)
    response.raise_for_status()
    return _response_json(response), response.headers.get("Mcp-Session-Id", session_id)


def _tool_text(response: dict[str, Any]) -> str:
    result = response.get("result") or {}
    blocks = result.get("content") or []
    texts = [str(block.get("text", "")) for block in blocks if block.get("type") == "text"]
    return "\n".join(text for text in texts if text).strip()


async def conversation_context() -> str:
    """取回身份与当前浮现记忆；未配置或临时故障时静默降级为空。"""
    if not configured():
        return ""

    try:
        async with httpx.AsyncClient(timeout=MCP_TIMEOUT) as client:
            _, session_id = await _request(
                client,
                "initialize",
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "dwell-backend", "version": "0.1.0"},
                },
            )
            # 旧版 MCP 服务会要求这条通知；Ombre Brain 的无状态 HTTP 版本忽略它。
            await client.post(
                MCP_URL,
                headers=_headers(session_id),
                json={"jsonrpc": "2.0", "method": "notifications/initialized"},
            )
            identity, session_id = await _request(
                client, "tools/call", {"name": "I", "arguments": {}}, session_id
            )
            memories, _ = await _request(
                client, "tools/call", {"name": "breath", "arguments": {}}, session_id
            )
    except (httpx.HTTPError, ValueError, RuntimeError):
        # 记忆服务不能让正常聊天失效。
        return ""

    parts = [text for text in (_tool_text(identity), _tool_text(memories)) if text]
    return "\n\n".join(parts)
