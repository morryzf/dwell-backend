"""外面的天气：WMO 代码归类、缓存与降级、给聊天上下文的那一行。"""

import asyncio
import os
import time
import unittest
import uuid

from app import db
from app import weather


class WeatherTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"weather-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        weather._cached = None

    def tearDown(self):
        weather._cached = None
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    # ---------------------------------------------------------------- 归类

    def test_codes_map_to_conditions(self):
        self.assertEqual(weather.classify(0), ("clear", ""))
        self.assertEqual(weather.classify(3), ("cloudy", ""))
        self.assertEqual(weather.classify(61), ("rain", "light"))
        self.assertEqual(weather.classify(65), ("rain", "heavy"))
        self.assertEqual(weather.classify(75), ("snow", "heavy"))
        self.assertEqual(weather.classify(95), ("storm", "moderate"))
        self.assertEqual(weather.classify(12345), ("cloudy", ""), "不认识的代码当多云，别炸")

    def test_location_default_and_custom(self):
        self.assertEqual(weather.location(), (31.2304, 121.4737, "上海"))
        db.setting_set(weather.LOCATION_KEY, "39.9042,116.4074,北京")
        self.assertEqual(weather.location(), (39.9042, 116.4074, "北京"))
        db.setting_set(weather.LOCATION_KEY, "坏掉的")
        self.assertEqual(weather.location()[2], "上海", "存坏了退回默认")

    # ---------------------------------------------------------------- 拉取与缓存

    def _fake_fetch(self, calls, code=61, temperature=12.3):
        async def fetch():
            calls.append(1)
            return weather._from_response({"current": {
                "weather_code": code, "temperature_2m": temperature,
                "is_day": 1, "wind_speed_10m": 8.0,
            }}, "上海")
        return fetch

    def test_fresh_cache_skips_fetch(self):
        calls = []
        original = weather._fetch
        weather._fetch = self._fake_fetch(calls)
        try:
            first = asyncio.run(weather.current())
            second = asyncio.run(weather.current())
        finally:
            weather._fetch = original
        self.assertEqual(first["condition"], "rain")
        self.assertFalse(first["stale"])
        self.assertEqual(len(calls), 1, "20 分钟内第二次该用缓存")
        self.assertEqual(second["condition"], "rain")

    def test_failure_serves_stale(self):
        stale = weather._from_response({"current": {"weather_code": 71, "is_day": 0,
                                                    "temperature_2m": -1.0}}, "上海")
        stale["at"] = int(time.time()) - weather.FRESH_SECONDS - 5
        weather._cached = stale

        async def boom():
            raise RuntimeError("网断了")
        original = weather._fetch
        weather._fetch = boom
        try:
            got = asyncio.run(weather.current())
        finally:
            weather._fetch = original
        self.assertEqual(got["condition"], "snow")
        self.assertTrue(got["stale"], "拉不到要把旧的标成 stale 给出去")

    def test_failure_without_cache_degrades(self):
        async def boom():
            raise RuntimeError("网断了")
        original = weather._fetch
        weather._fetch = boom
        try:
            got = asyncio.run(weather.current())
        finally:
            weather._fetch = original
        self.assertEqual(got["condition"], "unknown")
        self.assertTrue(got["stale"])

    def test_survives_restart_via_settings(self):
        calls = []
        original = weather._fetch
        weather._fetch = self._fake_fetch(calls)
        try:
            asyncio.run(weather.current())
            weather._cached = None   # 装作重启
            again = asyncio.run(weather.current())
        finally:
            weather._fetch = original
        self.assertEqual(len(calls), 1, "settings 里的那份该接着用")
        self.assertEqual(again["condition"], "rain")

    # ---------------------------------------------------------------- 那一行

    def test_describe(self):
        self.assertEqual(weather.describe({"condition": "rain", "intensity": "light",
                                           "temperature": 12.3}), "小雨 12°C")
        self.assertEqual(weather.describe({"condition": "snow", "intensity": "heavy",
                                           "temperature": -1.0}), "大雪 -1°C")
        self.assertEqual(weather.describe({"condition": "clear", "intensity": "",
                                           "temperature": 28.6}), "晴 29°C")
        self.assertEqual(weather.describe({"condition": "unknown"}), "")

    def test_prompt_line_only_fresh(self):
        self.assertEqual(weather.prompt_line(), "", "没有缓存就一行都不带")
        data = weather._from_response({"current": {"weather_code": 63,
                                                   "temperature_2m": 9.8, "is_day": 1}}, "上海")
        weather._cached = data
        line = weather.prompt_line()
        self.assertIn("上海", line)
        self.assertIn("中雨", line)
        data["at"] = int(time.time()) - weather.PROMPT_MAX_AGE - 5
        self.assertEqual(weather.prompt_line(), "", "太旧的天气不该再当成「现在」")


if __name__ == "__main__":
    unittest.main()
