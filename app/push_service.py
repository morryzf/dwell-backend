"""Dwell 的手机通知：原生 Web Push，加上可选的 Bark。

VAPID 密钥首次使用时生成并保存在 Dwell 的 settings 表，因此服务重启、重新部署后
订阅仍然有效。浏览器订阅同样保存在数据库；主动消息只需要调用 send_push。

Bark 是给 iOS app 用的：免费签名的 app 收不到苹果推送，就借 Bark 响一声，
点通知再用 dwell:// 打开 app。两条线路互不影响，send_push 一次都发。
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import re
import time
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from pywebpush import WebPushException, webpush

from . import db

DEFAULT_BARK_SERVER = "https://api.day.app"

# 搬去腾讯云之前的地址。VAPID subject 只是给推送服务看的联系方式，不必能打开；
# 没设 VAPID_SUBJECT 和 DWELL_PUBLIC_URL 时才会用到它。
DEFAULT_VAPID_SUBJECT = "https://dwell-morry.zeabur.app"


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def ensure_vapid_keys() -> tuple[str, str]:
    """Return ``(public_b64url, private_der_b64url)`` and create a stable pair."""
    public_key = db.setting_get("vapid_public_key", "").strip()
    private_key = db.setting_get("vapid_private_key", "").strip()
    if public_key and private_key:
        return public_key, private_key

    private = ec.generate_private_key(ec.SECP256R1())
    private_key = _b64url(private.private_bytes(
        serialization.Encoding.DER,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ))
    public_raw = private.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )
    public_key = _b64url(public_raw)
    db.setting_set("vapid_private_key", private_key)
    db.setting_set("vapid_public_key", public_key)
    return public_key, private_key


def public_key() -> str:
    return ensure_vapid_keys()[0]


def _vapid_subject() -> str:
    """Return a public contact URI accepted by Apple Push."""
    configured = os.environ.get("VAPID_SUBJECT", "").strip()
    if configured:
        parsed = urlsplit(configured)
        if parsed.scheme == "https" and parsed.hostname not in {None, "localhost"}:
            return configured
        if parsed.scheme == "mailto" and "@" in parsed.path:
            domain = parsed.path.rsplit("@", 1)[-1].lower()
            if domain and domain != "localhost" and "." in domain:
                return configured
    public = os.environ.get("DWELL_PUBLIC_URL", "").strip().rstrip("/")
    parsed = urlsplit(public)
    if parsed.scheme == "https" and parsed.hostname and parsed.hostname != "localhost" \
            and "." in parsed.hostname:
        return public
    return DEFAULT_VAPID_SUBJECT


def _subscriptions() -> list[dict[str, Any]]:
    raw = db.setting_get("push_subscriptions", "")
    if raw:
        try:
            value = json.loads(raw)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict) and item.get("endpoint")]
        except (TypeError, ValueError, json.JSONDecodeError):
            pass

    # 兼容此前只保存一个设备的版本。
    legacy = db.setting_get("push_subscription", "")
    if legacy:
        try:
            value = json.loads(legacy)
            if isinstance(value, dict) and value.get("endpoint"):
                return [value]
        except (TypeError, ValueError, json.JSONDecodeError):
            pass
    return []


def save_subscription(subscription: dict[str, Any]) -> int:
    endpoint = str(subscription.get("endpoint") or "").strip()
    keys = subscription.get("keys") or {}
    if not endpoint.startswith("https://") or not keys.get("p256dh") or not keys.get("auth"):
        raise ValueError("推送订阅内容不完整")

    clean = {
        "endpoint": endpoint,
        "expirationTime": subscription.get("expirationTime"),
        "keys": {"p256dh": str(keys["p256dh"]), "auth": str(keys["auth"])},
    }
    items = [item for item in _subscriptions() if item.get("endpoint") != endpoint]
    items.append(clean)
    items = items[-8:]
    db.setting_set("push_subscriptions", json.dumps(items, ensure_ascii=False))
    # 新版写入后清空旧单设备值，避免同一个 endpoint 被发送两次。
    db.setting_set("push_subscription", "")
    return len(items)


def subscription_count() -> int:
    return len(_subscriptions())


def remove_subscription(endpoint: str) -> int:
    """Forget one browser without disturbing notifications on other devices."""
    endpoint = endpoint.strip()
    items = [item for item in _subscriptions() if item.get("endpoint") != endpoint]
    db.setting_set("push_subscriptions", json.dumps(items, ensure_ascii=False))
    return len(items)


def _push_host(subscription: dict[str, Any]) -> str:
    try:
        return (urlsplit(str(subscription.get("endpoint") or "")).hostname or "未知主机")[:160]
    except ValueError:
        return "无效主机"


def _safe_push_failure(subscription: dict[str, Any], exc: Exception) -> dict[str, Any]:
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", None)
    response_text = str(getattr(response, "text", "") or str(exc) or "").strip()
    response_text = re.sub(r"https?://\S+", "[地址已隐藏]", response_text)
    response_text = re.sub(r"[A-Za-z0-9_-]{24,}", "[令牌已隐藏]", response_text)
    response_text = re.sub(r"\s+", " ", response_text)[:180]
    return {
        "host": _push_host(subscription),
        "status": int(status) if isinstance(status, int) else None,
        "kind": type(exc).__name__,
        "reason": response_text,
    }


def _failure_summary(failures: list[dict[str, Any]]) -> str:
    parts = []
    for failure in failures[:3]:
        item = f"主机 {failure['host']}"
        if failure.get("status"):
            item += f" · HTTP {failure['status']}"
        item += f" · {failure['kind']}"
        if failure.get("reason"):
            item += f" · {failure['reason']}"
        parts.append(item)
    return "；".join(parts)


def _send_sync(title: str, body: str, url: str) -> dict[str, Any]:
    _public, private_key = ensure_vapid_keys()
    subject = _vapid_subject()
    payload = json.dumps({
        "title": title[:80] or "Cloudy",
        "body": body[:240],
        "url": url or "/",
    }, ensure_ascii=False)
    subscriptions = _subscriptions()
    alive: list[dict[str, Any]] = []
    sent = 0
    failed = 0
    failures: list[dict[str, Any]] = []
    for subscription in subscriptions:
        try:
            webpush(
                subscription_info=subscription,
                data=payload,
                vapid_private_key=private_key,
                vapid_claims={"sub": subject},
                ttl=60 * 60,
            )
            alive.append(subscription)
            sent += 1
        except WebPushException as exc:
            status = getattr(getattr(exc, "response", None), "status_code", None)
            failures.append(_safe_push_failure(subscription, exc))
            if status not in {404, 410}:
                alive.append(subscription)
            failed += 1
        except Exception as exc:
            failures.append(_safe_push_failure(subscription, exc))
            alive.append(subscription)
            failed += 1
    if alive != subscriptions:
        db.setting_set("push_subscriptions", json.dumps(alive, ensure_ascii=False))
    return {
        "sent": sent, "failed": failed, "subscriptions": len(alive),
        "diagnostic": _failure_summary(failures),
        "status_code": next(
            (item["status"] for item in failures if item.get("status")), None
        ),
    }


# —— Bark ——

def bark_settings() -> dict[str, Any]:
    raw = db.setting_get("bark", "")
    try:
        value = json.loads(raw) if raw else {}
    except (TypeError, ValueError, json.JSONDecodeError):
        value = {}
    if not isinstance(value, dict):
        value = {}
    return {
        "key": str(value.get("key") or ""),
        "server": str(value.get("server") or DEFAULT_BARK_SERVER),
        "open": "web" if value.get("open") == "web" else "app",
        "web_base": str(value.get("web_base") or ""),
        "sound": str(value.get("sound") or ""),
        "level": value.get("level") if value.get("level") in {"active", "timeSensitive", "passive"} else "active",
    }


def bark_enabled() -> bool:
    return bool(bark_settings()["key"])


def bark_public(settings: dict[str, Any] | None = None) -> dict[str, Any]:
    """给设置页看的版本：key 只露头尾。"""
    settings = settings or bark_settings()
    key = settings["key"]
    masked = (key[:4] + "…" + key[-3:]) if len(key) > 10 else ("已填写" if key else "")
    return {**{k: v for k, v in settings.items() if k != "key"}, "configured": bool(key), "key_hint": masked}


def parse_bark_address(text: str) -> tuple[str, str]:
    """Bark app 里复制出来的是 https://api.day.app/KEY/推送内容，
    也可能只粘了 KEY。返回 (server, key)；server 为空表示沿用原来的。"""
    text = text.strip()
    if not text:
        return "", ""
    # Bark 里「复制」默认复制的是一整条 curl 命令，从里面把地址抠出来。
    found = re.search(r"https?://\S+", text)
    if found:
        text = found.group(0)
    elif "://" not in text:
        return "", text.strip("/")
    parts = urlsplit(text)
    if parts.scheme not in {"http", "https"} or not parts.hostname:
        raise ValueError("Bark 地址看不懂")
    segments = [seg for seg in parts.path.split("/") if seg]
    if not segments:
        raise ValueError("Bark 地址里没有找到 key")
    port = f":{parts.port}" if parts.port else ""
    return f"{parts.scheme}://{parts.hostname}{port}", segments[0]


def save_bark(payload: dict[str, Any]) -> dict[str, Any]:
    current = bark_settings()
    if "address" in payload:
        server, key = parse_bark_address(str(payload.get("address") or ""))
        current["key"] = key
        if server:
            current["server"] = server
    if payload.get("server") is not None:
        server = str(payload["server"]).strip().rstrip("/") or DEFAULT_BARK_SERVER
        if not server.startswith(("https://", "http://")):
            raise ValueError("Bark 服务器要以 https:// 开头")
        current["server"] = server
    if payload.get("open") in {"app", "web"}:
        current["open"] = payload["open"]
    if payload.get("web_base") is not None:
        base = str(payload["web_base"]).strip().rstrip("/")
        if base and not base.startswith(("https://", "http://")):
            raise ValueError("网页地址要以 https:// 开头")
        current["web_base"] = base
    if payload.get("sound") is not None:
        current["sound"] = re.sub(r"[^A-Za-z0-9_.-]", "", str(payload["sound"]))[:40]
    if payload.get("level") in {"active", "timeSensitive", "passive"}:
        current["level"] = payload["level"]
    db.setting_set("bark", json.dumps(current, ensure_ascii=False))
    return current


def _bark_click_url(url: str, settings: dict[str, Any]) -> str:
    """网页通知里的 /?chat=xxx 换成点 Bark 通知后要打开的地址。"""
    if settings["open"] == "web":
        return settings["web_base"] + (url or "/") if settings["web_base"] else ""
    query = parse_qs(urlsplit(url or "/").query)
    if query.get("study"):
        return "dwell://open?study=1"
    chat = (query.get("chat") or [""])[0]
    return "dwell://open" + (f"?chat={chat}" if re.fullmatch(r"[A-Za-z0-9_-]{1,80}", chat) else "")


async def send_bark(title: str, body: str, url: str) -> dict[str, Any]:
    settings = bark_settings()
    if not settings["key"]:
        return {"sent": 0, "failed": 0, "subscriptions": 0, "diagnostic": "", "status_code": None}
    payload: dict[str, Any] = {
        "device_key": settings["key"],
        "title": title[:80] or "Cloudy",
        "body": body[:240],
        "group": "Dwell",
        "level": settings["level"],
    }
    click = _bark_click_url(url, settings)
    if click:
        payload["url"] = click
    if settings["web_base"]:
        payload["icon"] = settings["web_base"] + "/icons/dwell-bunny-180.png"
    if settings["sound"]:
        payload["sound"] = settings["sound"]
    host = urlsplit(settings["server"]).hostname or "Bark"
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(10.0, connect=6.0)) as client:
            response = await client.post(settings["server"].rstrip("/") + "/push", json=payload)
        data = response.json() if response.headers.get("content-type", "").startswith("application/json") else {}
        if response.status_code == 200 and data.get("code", 200) == 200:
            return {"sent": 1, "failed": 0, "subscriptions": 1, "diagnostic": "", "status_code": None}
        reason = str(data.get("message") or response.text or "")
        reason = re.sub(r"[A-Za-z0-9_-]{16,}", "[令牌已隐藏]", reason)[:120]
        return {"sent": 0, "failed": 1, "subscriptions": 1,
                "diagnostic": f"Bark {host} · HTTP {response.status_code} · {reason}".strip(" ·"),
                "status_code": response.status_code}
    except (httpx.HTTPError, ValueError) as exc:
        return {"sent": 0, "failed": 1, "subscriptions": 1,
                "diagnostic": f"Bark {host} · {type(exc).__name__}", "status_code": None}


async def send_push(title: str, body: str, url: str = "/") -> dict[str, Any]:
    """Web Push 和 Bark 一起发；不阻塞 FastAPI 的事件循环。"""
    started = time.perf_counter()
    try:
        log_id = db.system_log_start("push_delivery", "push_delivery")
    except Exception:
        log_id = ""
    if not _subscriptions() and not bark_enabled():
        result = {
            "sent": 0, "failed": 0, "subscriptions": 0,
            "diagnostic": "服务端没有已保存的手机订阅", "status_code": None,
        }
    else:
        async def web() -> dict[str, Any]:
            if not _subscriptions():
                return {"sent": 0, "failed": 0, "subscriptions": 0, "diagnostic": "", "status_code": None}
            return await asyncio.to_thread(_send_sync, title, body, url)

        web_result, bark_result = await asyncio.gather(web(), send_bark(title, body, url))
        result = {
            "sent": web_result["sent"] + bark_result["sent"],
            "failed": web_result["failed"] + bark_result["failed"],
            "subscriptions": web_result["subscriptions"] + bark_result["subscriptions"],
            "diagnostic": "；".join(d for d in (web_result["diagnostic"], bark_result["diagnostic"]) if d),
            "status_code": web_result["status_code"] or bark_result["status_code"],
            "bark": bool(bark_result["sent"]),
        }
    if log_id:
        try:
            db.system_log_finish(
                log_id, "success" if result["sent"] else "error",
                round((time.perf_counter() - started) * 1000),
                status_code=result.get("status_code"),
                detail=result.get("diagnostic") or (
                    f"成功发送 {result['sent']} 条；失败 {result['failed']} 条"
                ),
            )
        except Exception:
            pass
    return result
