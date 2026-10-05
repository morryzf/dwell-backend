"""订阅额度：Claude 账号的 5 小时窗口和每周窗口各用了多少、什么时候重置。

数据来自桥接服务（bridge/ 的 GET /v1/usage）：它起一个不发消息的 Claude Code
会话，读 /usage 背后那份数据。官方接口没回应时，桥接还记着最近几次聊天里
Claude Code 顺手报来的额度，那就拿那个顶上，并标明是什么时候记下的。

这个模块只把两种来源整理成同一种形状交给前端：一组「窗口」，每个窗口有名字、
用了百分之几、几点重置。
"""

from datetime import datetime

import httpx

from .provider_secrets import SecretConfigurationError, decrypt_api_key

BRIDGE_USAGE_PATH = "/v1/usage"

# 官方接口里的键 → 页面上的名字与分组。顺序就是页面上的顺序。
PLAN_WINDOWS = [
    ("five_hour", "Current session", "session"),
    ("seven_day", "All models", "weekly"),
    ("seven_day_opus", "Opus", "weekly"),
    ("seven_day_sonnet", "Sonnet", "weekly"),
    ("seven_day_oauth_apps", "OAuth apps", "weekly"),
]

# 聊天时报来的 rate_limit_event 用的是另一套名字。
OBSERVED_WINDOWS = {
    "five_hour": ("Current session", "session"),
    "seven_day": ("All models", "weekly"),
    "seven_day_opus": ("Opus", "weekly"),
    "seven_day_sonnet": ("Sonnet", "weekly"),
    "seven_day_overage_included": ("All models", "weekly"),
}


def _epoch(value) -> int | None:
    """ISO 时间或秒数 → 秒数。毫秒数也认（大于 1e12 的当毫秒）。"""
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        return int(number / 1000) if number > 1e12 else int(number)
    try:
        return int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def _percent(value, fraction: bool = False) -> float | None:
    """官方接口给的是 0–100；聊天时报来的（fraction=True）是 0–1 的比例。"""
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if fraction and number <= 1:
        number *= 100
    return max(0.0, min(100.0, round(number, 1)))


def plan_windows(rate_limits: dict | None) -> list[dict]:
    """官方接口给的额度 → 页面上的窗口列表。没有数字的窗口不列。"""
    if not isinstance(rate_limits, dict):
        return []
    windows = []
    for key, label, group in PLAN_WINDOWS:
        raw = rate_limits.get(key)
        if not isinstance(raw, dict):
            continue
        used = _percent(raw.get("utilization"))
        if used is None:
            continue
        windows.append({"key": key, "label": label, "group": group,
                        "used": used, "resets_at": _epoch(raw.get("resets_at"))})
    for index, raw in enumerate(rate_limits.get("model_scoped") or []):
        if not isinstance(raw, dict):
            continue
        used = _percent(raw.get("utilization"))
        if used is None:
            continue
        label = str(raw.get("display_name") or "").strip() or "Model"
        # 分模型的窗口和上面某个同名时，以分模型的为准，不列两遍。
        windows = [w for w in windows if not (w["group"] == "weekly" and w["label"] == label)]
        windows.append({"key": f"model_{index}", "label": label, "group": "weekly",
                        "used": used, "resets_at": _epoch(raw.get("resets_at"))})
    extra = rate_limits.get("extra_usage")
    if isinstance(extra, dict) and extra.get("is_enabled"):
        windows.append({
            "key": "extra_usage", "label": "Extra usage", "group": "extra",
            "used": _percent(extra.get("utilization")), "resets_at": None,
            "used_credits": extra.get("used_credits"), "monthly_limit": extra.get("monthly_limit"),
            "currency": extra.get("currency") or "",
        })
    return windows


def observed_windows(observed: dict | None) -> list[dict]:
    """聊天时记下的额度 → 窗口列表，每个窗口带上是什么时候记下的。"""
    if not isinstance(observed, dict):
        return []
    windows = []
    for key, raw in observed.items():
        if key not in OBSERVED_WINDOWS or not isinstance(raw, dict):
            continue
        used = _percent(raw.get("utilization"), fraction=True)
        if used is None:
            continue
        label, group = OBSERVED_WINDOWS[key]
        if any(w["label"] == label and w["group"] == group for w in windows):
            continue
        windows.append({"key": key, "label": label, "group": group, "used": used,
                        "resets_at": _epoch(raw.get("resets_at")),
                        "observed_at": _epoch(raw.get("observed_at"))})
    order = {name: index for index, (name, _label, _group) in enumerate(PLAN_WINDOWS)}
    windows.sort(key=lambda w: order.get(w["key"], len(order)))
    return windows


def summarize(body: dict) -> dict:
    """桥接的回答 → 交给前端的样子。"""
    windows = plan_windows(body.get("rate_limits")) if body.get("available") else []
    source = "plan" if windows else ""
    if not windows:
        windows = observed_windows(body.get("observed"))
        source = "observed" if windows else ""
    plan = str(body.get("subscription_type") or "").strip()
    account = body.get("account") if isinstance(body.get("account"), dict) else {}
    return {
        "source": source,
        "plan": plan,
        "email": str(account.get("email") or ""),
        "windows": windows,
        "error": "" if source == "plan" else str(body.get("error") or ""),
        "fetched_at": _epoch(body.get("fetched_at")),
    }


async def fetch(provider: dict, refresh: bool = False) -> dict:
    """问桥接要一次用量。网络和门禁的错误直接抛给调用方。"""
    headers = {"Accept": "application/json"}
    box = provider.get("api_key_box") or ""
    if box:
        try:
            headers["Authorization"] = f"Bearer {decrypt_api_key(box)}"
        except SecretConfigurationError as exc:
            raise RuntimeError(str(exc)) from exc
    url = str(provider.get("base_url") or "").rstrip("/") + BRIDGE_USAGE_PATH
    params = {"refresh": "1"} if refresh else None
    # 桥接那边要起一个 Claude Code 进程再问，冷启动给宽一点。
    async with httpx.AsyncClient(timeout=httpx.Timeout(60.0, connect=10.0)) as client:
        response = await client.get(url, headers=headers, params=params)
    if response.status_code == 404:
        raise RuntimeError("桥接服务还是旧版本，没有用量接口；在 VPS 上跑一次 deploy.sh")
    if response.status_code != 200:
        raise RuntimeError(f"桥接服务返回 {response.status_code}")
    body = response.json()
    if not isinstance(body, dict):
        raise RuntimeError("桥接服务的回答看不懂")
    return summarize(body)
