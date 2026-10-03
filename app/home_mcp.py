"""把 Dwell 聊天里的工具作为一个 MCP 服务递给 Claude Code。

走 Claude Agent SDK 时，模型跑在桥接那台机器上的 Claude Code 里，Dwell 的
function tools 交不过去。于是反过来：Dwell 自己开一个 MCP 端点，每轮把地址和
一张临时通行证交给桥接，Claude Code 需要时回头来调。

    Claude Code --MCP(HTTP)--> Dwell /mcp/home --> 和普通聊天同一个工具执行器

给哪些工具和普通聊天一致：家里的待办、日记、日历，sigillo，网页搜索和读取，
以及这间聊天挂的外部 MCP（由 Dwell 转一手）。端点路径沿用最早只有家里工具时的名字。

只实现 Streamable HTTP 里用得到的那一小块：POST 一条 JSON-RPC，回一条 JSON。
不开 SSE 流、不存会话——工具调用都是一问一答，用不上。

通行证是用 DWELL_SECRET 签的一小段数据：属于哪间聊天、记到哪条回复下、
是不是只读。它只在这一轮里有用，过期就作废，不需要另配令牌。
"""

import json

from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from . import auth

SERVER_NAME = "dwell"
ENDPOINT_PATH = "/mcp/home"
# 单轮在桥接侧最多跑 15 分钟，留足余量；过期了顶多这一轮调不到工具。
GRANT_MAX_AGE = 60 * 60

SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")

_signer = URLSafeTimedSerializer(auth.SECRET, salt="dwell-home-mcp")


def make_grant(chat_id: str, message_id: str = "", read_only: bool = False) -> str:
    return _signer.dumps({"c": chat_id, "m": message_id, "ro": bool(read_only)})


def read_grant(token: str) -> dict | None:
    """认得出就返回 {chat_id, message_id, read_only}，否则 None。"""
    if not token:
        return None
    try:
        data = _signer.loads(token, max_age=GRANT_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return None
    if not isinstance(data, dict) or not data.get("c"):
        return None
    return {
        "chat_id": str(data["c"]),
        "message_id": str(data.get("m") or ""),
        "read_only": bool(data.get("ro")),
    }


def bearer(header: str) -> str:
    header = str(header or "")
    return header[7:].strip() if header[:7].lower() == "bearer " else ""


def server_config(base_url: str, grant: str) -> dict:
    """交给桥接的 MCP 配置，形状照 Claude Code 的 mcpServers。"""
    return {SERVER_NAME: {
        "type": "http",
        "url": base_url.rstrip("/") + ENDPOINT_PATH,
        "headers": {"Authorization": f"Bearer {grant}"},
    }}


def mcp_tools(function_tools: list[dict]) -> list[dict]:
    """OpenAI function 形状 → MCP tool 形状。"""
    out = []
    for tool in function_tools:
        function = tool.get("function") or {}
        out.append({
            "name": function.get("name") or "",
            "description": function.get("description") or "",
            "inputSchema": function.get("parameters") or {"type": "object", "properties": {}},
        })
    return out


def _result(rid, result: dict) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _error(rid, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


async def handle_message(message, tools: list[dict], call) -> dict | None:
    """处理一条 JSON-RPC 消息。通知没有回复，返回 None。

    tools 是这张通行证能看到的工具（MCP 形状）；call(name, arguments) 真正去执行，
    返回 (文本结果, 是否出错)。
    """
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return _error(None, -32600, "Invalid Request")
    method = str(message.get("method") or "")
    rid = message.get("id")
    if rid is None:
        # notifications/initialized、notifications/cancelled 之类，照单全收。
        return None
    params = message.get("params") if isinstance(message.get("params"), dict) else {}

    if method == "initialize":
        asked = str(params.get("protocolVersion") or "")
        return _result(rid, {
            "protocolVersion": asked if asked in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": "1.0.0"},
        })
    if method == "ping":
        return _result(rid, {})
    if method == "tools/list":
        return _result(rid, {"tools": tools})
    if method == "tools/call":
        name = str(params.get("name") or "")
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if name not in {tool["name"] for tool in tools}:
            return _result(rid, {
                "content": [{"type": "text", "text": f"这间聊天没有开放工具 {name}"}],
                "isError": True,
            })
        if not isinstance(arguments, dict):
            return _result(rid, {
                "content": [{"type": "text", "text": "参数必须是对象"}],
                "isError": True,
            })
        text, is_error = await call(name, arguments)
        return _result(rid, {"content": [{"type": "text", "text": text}], "isError": bool(is_error)})
    return _error(rid, -32601, f"Method not found: {method}")


def parse_body(raw: bytes):
    try:
        return json.loads(raw.decode("utf-8") or "null")
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
