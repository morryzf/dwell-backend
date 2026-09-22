"""OpenAI-compatible embedding client for memory card vector retrieval."""

from __future__ import annotations

import logging

import httpx

from .provider_secrets import SecretConfigurationError, decrypt_api_key

log = logging.getLogger(__name__)

_last_error: str = ""


def last_error() -> str:
    return _last_error


def _extract_error(resp: httpx.Response) -> str:
    try:
        body = resp.json()
        msg = body.get("error", {})
        if isinstance(msg, dict):
            msg = msg.get("message", "") or msg.get("msg", "")
        return str(msg)[:300] or resp.text[:300]
    except Exception:
        return resp.text[:300]


async def get_embedding(
    provider: dict, model_id: str, text: str, *, timeout: float = 30.0
) -> list[float] | None:
    global _last_error
    if not text or not model_id:
        return None
    if not provider.get("api_key_box"):
        _last_error = "供应商没有设置 API key"
        return None
    try:
        api_key = decrypt_api_key(provider["api_key_box"])
    except SecretConfigurationError as exc:
        _last_error = f"API key 解密失败: {exc}"
        return None

    base_url = str(provider.get("base_url") or "https://api.openai.com/v1").rstrip("/")
    url = base_url + "/embeddings"
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    body = {"model": model_id, "input": text}

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=10.0)) as client:
            resp = await client.post(url, headers=headers, json=body)
            if resp.status_code != 200:
                _last_error = f"HTTP {resp.status_code}: {_extract_error(resp)}"
                log.warning("embedding request HTTP %s: %s", resp.status_code, resp.text[:500])
                return None
            data = resp.json()
            embedding = data["data"][0]["embedding"]
            return [float(v) for v in embedding]
    except Exception as exc:
        _last_error = str(exc)[:300]
        log.warning("embedding request failed: %s", exc)
        return None


async def get_embeddings_batch(
    provider: dict, model_id: str, texts: list[str], *, timeout: float = 60.0
) -> list[list[float] | None]:
    global _last_error
    if not texts or not model_id:
        return [None] * len(texts)
    if not provider.get("api_key_box"):
        return [None] * len(texts)
    try:
        api_key = decrypt_api_key(provider["api_key_box"])
    except SecretConfigurationError:
        return [None] * len(texts)

    base_url = str(provider.get("base_url") or "https://api.openai.com/v1").rstrip("/")
    url = base_url + "/embeddings"
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    body = {"model": model_id, "input": texts}

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=10.0)) as client:
            resp = await client.post(url, headers=headers, json=body)
            if resp.status_code != 200:
                _last_error = f"HTTP {resp.status_code}: {_extract_error(resp)}"
                log.warning("batch embedding HTTP %s: %s", resp.status_code, resp.text[:500])
                return [None] * len(texts)
            data = resp.json()
            items = sorted(data["data"], key=lambda d: d["index"])
            return [[float(v) for v in item["embedding"]] for item in items]
    except Exception as exc:
        _last_error = str(exc)[:300]
        log.warning("batch embedding request failed: %s", exc)
        return [None] * len(texts)
