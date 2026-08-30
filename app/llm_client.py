"""通用 OpenAI 兼容聊天客户端。

这是普通聊天的模型通道；heartbeat 只应负责定时唤醒，不应成为每次对话的必经网关。
"""

import json

import httpx

from .provider_secrets import SecretConfigurationError, decrypt_api_key


async def stream_chat(provider: dict, model_id: str, messages: list, tools: list | None = None,
                      max_tokens: int | None = None):
    """以 OpenAI 兼容 SSE 请求聊天，yield 文本或完整的工具调用组。"""
    if not model_id:
        yield {"type": "text", "text": "[配置错误] 这个聊天还没有选择模型"}
        return
    if not provider.get("api_key_box"):
        yield {"type": "text", "text": "[配置错误] 这个供应商还没有保存 API 密钥"}
        return

    try:
        api_key = decrypt_api_key(provider["api_key_box"])
    except SecretConfigurationError as exc:
        yield {"type": "text", "text": f"[配置错误] {exc}"}
        return

    url = provider["base_url"].rstrip("/") + "/chat/completions"
    payload = {"model": model_id, "messages": messages, "stream": True}
    if tools:
        payload["tools"] = tools
    if max_tokens is not None:
        payload["max_tokens"] = max(1, int(max_tokens))
    headers = {"Authorization": f"Bearer {api_key}", "Accept": "text/event-stream"}

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(90.0, connect=20.0)) as client:
            async with client.stream("POST", url, headers=headers, json=payload) as resp:
                if resp.status_code != 200:
                    body = (await resp.aread()).decode("utf-8", errors="ignore")[:500]
                    yield {"type": "text", "text": f"[供应商错误 {resp.status_code}] {body}"}
                    return
                calls: dict[int, dict] = {}
                async for line in resp.aiter_lines():
                    if not line or not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    text = delta.get("content")
                    if isinstance(text, str) and text:
                        yield {"type": "text", "text": text}
                    for part in delta.get("tool_calls") or []:
                        index = int(part.get("index", 0))
                        call = calls.setdefault(index, {"id": "", "name": "", "arguments": ""})
                        call["id"] += str(part.get("id") or "")
                        fn = part.get("function") or {}
                        call["name"] += str(fn.get("name") or "")
                        call["arguments"] += str(fn.get("arguments") or "")
                if calls:
                    yield {"type": "tool_calls", "calls": [calls[index] for index in sorted(calls)]}
    except httpx.RequestError as exc:
        yield {"type": "text", "text": f"[网络错误] 无法连接供应商：{exc}"}

