"""外面的天气。

Open-Meteo（免 key）拉固定城市的当前天气，归成几个客户端认识的状态：
clear / cloudy / fog / rain / snow / storm，带强度和昼夜。聊天背景照它下雨下雪，
聊天上下文里也带一行，他就知道外面什么天。

位置存在 settings 的 weather_location 里（"纬度,经度,名字"），默认上海。
最近一次拉到的结果同时留在内存和 settings 里：重启后、拉不到的时候都还有旧的可用。
"""

import asyncio
import json
import time

import httpx

from app import db

LOCATION_KEY = "weather_location"
DEFAULT_LOCATION = "31.2304,121.4737,上海"
CACHE_KEY = "weather_last"
# 多久算新鲜。天气不是股价，20 分钟足够了。
FRESH_SECONDS = 20 * 60
# prompt 里最多用多旧的缓存：太旧的「现在在下雨」就不是事实了。
PROMPT_MAX_AGE = 2 * 60 * 60

_lock = asyncio.Lock()
_cached: dict | None = None

# WMO weather code → (状态, 强度)。
# https://open-meteo.com/en/docs 文档底部那张表。
_CODES = {
    0: ("clear", ""),
    1: ("clear", ""), 2: ("cloudy", "light"), 3: ("cloudy", ""),
    45: ("fog", ""), 48: ("fog", ""),
    51: ("rain", "light"), 53: ("rain", "light"), 55: ("rain", "moderate"),
    56: ("rain", "light"), 57: ("rain", "moderate"),
    61: ("rain", "light"), 63: ("rain", "moderate"), 65: ("rain", "heavy"),
    66: ("rain", "light"), 67: ("rain", "heavy"),
    71: ("snow", "light"), 73: ("snow", "moderate"), 75: ("snow", "heavy"),
    77: ("snow", "light"),
    80: ("rain", "light"), 81: ("rain", "moderate"), 82: ("rain", "heavy"),
    85: ("snow", "light"), 86: ("snow", "heavy"),
    95: ("storm", "moderate"), 96: ("storm", "heavy"), 99: ("storm", "heavy"),
}

_CN = {
    "clear": "晴", "cloudy": "多云", "fog": "雾",
    "rain": "雨", "snow": "雪", "storm": "雷雨",
}
_CN_INTENSITY = {"light": "小", "moderate": "中", "heavy": "大"}


def location() -> tuple[float, float, str]:
    raw = db.setting_get(LOCATION_KEY, DEFAULT_LOCATION)
    try:
        lat, lon, name = raw.split(",", 2)
        return float(lat), float(lon), name.strip() or "上海"
    except ValueError:
        lat, lon, name = DEFAULT_LOCATION.split(",", 2)
        return float(lat), float(lon), name


def classify(code: int) -> tuple[str, str]:
    return _CODES.get(int(code), ("cloudy", ""))


def _from_response(payload: dict, city: str) -> dict:
    current = payload.get("current") or {}
    code = int(current.get("weather_code") or 0)
    condition, intensity = classify(code)
    return {
        "city": city,
        "condition": condition,
        "intensity": intensity,
        "is_day": bool(current.get("is_day", 1)),
        "temperature": current.get("temperature_2m"),
        "wind": current.get("wind_speed_10m"),
        "code": code,
        "at": int(time.time()),
    }


def _remembered() -> dict | None:
    global _cached
    if _cached is None:
        raw = db.setting_get(CACHE_KEY, "")
        if raw:
            try:
                _cached = json.loads(raw)
            except ValueError:
                _cached = None
    return _cached


async def _fetch() -> dict:
    lat, lon, city = location()
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(
            "https://api.open-meteo.com/v1/forecast",
            params={
                "latitude": lat, "longitude": lon,
                "current": "temperature_2m,weather_code,is_day,wind_speed_10m",
                "timezone": "Asia/Shanghai",
            },
        )
        resp.raise_for_status()
        return _from_response(resp.json(), city)


async def current() -> dict:
    """新鲜的直接给；过期了拉一次，拉不到就把旧的标上 stale 给出去。"""
    global _cached
    known = _remembered()
    if known and time.time() - known.get("at", 0) < FRESH_SECONDS:
        return {**known, "stale": False}
    async with _lock:
        known = _remembered()
        if known and time.time() - known.get("at", 0) < FRESH_SECONDS:
            return {**known, "stale": False}
        try:
            fresh = await _fetch()
        except Exception:
            if known:
                return {**known, "stale": True}
            return {"city": location()[2], "condition": "unknown", "intensity": "",
                    "is_day": True, "temperature": None, "wind": None,
                    "code": -1, "at": 0, "stale": True}
        _cached = fresh
        db.setting_set(CACHE_KEY, json.dumps(fresh, ensure_ascii=False))
        return {**fresh, "stale": False}


def describe(data: dict) -> str:
    """一行中文：小雨 12°C。拼进聊天上下文用。"""
    condition = data.get("condition") or ""
    if condition in ("", "unknown"):
        return ""
    name = _CN.get(condition, condition)
    if condition in ("rain", "snow") and data.get("intensity"):
        name = _CN_INTENSITY.get(data["intensity"], "") + name
    temperature = data.get("temperature")
    if temperature is not None:
        name += f" {round(float(temperature))}°C"
    return name


def prompt_line() -> str:
    """给聊天上下文的那行；只用缓存，从不现场拉，不拖慢回复。"""
    known = _remembered()
    if not known or time.time() - known.get("at", 0) > PROMPT_MAX_AGE:
        return ""
    text = describe(known)
    if not text:
        return ""
    return f"[Weather] Outside in {known.get('city', '上海')} right now: {text}."
