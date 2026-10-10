import asyncio
import json
import unittest
from unittest.mock import patch

import httpx

from app import push_service


class BarkTest(unittest.TestCase):
    def setUp(self):
        self.store = {}
        self.patches = [
            patch.object(push_service.db, "setting_get", side_effect=lambda k, d="": self.store.get(k, d)),
            patch.object(push_service.db, "setting_set", side_effect=lambda k, v: self.store.__setitem__(k, v)),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()

    def test_parse_copied_address_and_bare_key(self):
        self.assertEqual(push_service.parse_bark_address("https://api.day.app/AbCdEf123/推送内容"),
                         ("https://api.day.app", "AbCdEf123"))
        self.assertEqual(push_service.parse_bark_address("https://bark.example.com:8443/k1/"),
                         ("https://bark.example.com:8443", "k1"))
        self.assertEqual(push_service.parse_bark_address("  AbCdEf123 "), ("", "AbCdEf123"))
        self.assertEqual(push_service.parse_bark_address(
            "curl -X GET https://api.day.app/AbCdEf123/title/body?group=example&ttl=600"),
            ("https://api.day.app", "AbCdEf123"))
        with self.assertRaises(ValueError):
            push_service.parse_bark_address("https://api.day.app/")

    def test_public_view_hides_key(self):
        push_service.save_bark({"address": "https://api.day.app/AbCdEf1234567/x"})
        view = push_service.bark_public()
        self.assertTrue(view["configured"])
        self.assertNotIn("key", view)
        self.assertNotIn("AbCdEf1234567", json.dumps(view))

    def test_click_opens_the_app_on_that_chat(self):
        settings = push_service.save_bark({"address": "k1", "web_base": "https://dwell.example.com"})
        self.assertEqual(push_service._bark_click_url("/?chat=c_42&from=push", settings), "dwell://open?chat=c_42")
        self.assertEqual(push_service._bark_click_url("/?study=1&from=push", settings), "dwell://open?study=1")
        self.assertEqual(push_service._bark_click_url("/?from=push", settings), "dwell://open")
        settings = push_service.save_bark({"open": "web"})
        self.assertEqual(push_service._bark_click_url("/?study=1", settings), "https://dwell.example.com/?study=1")

    def test_send_push_reaches_bark_without_web_subscriptions(self):
        push_service.save_bark({"address": "https://api.day.app/k1", "web_base": "https://dwell.example.com"})
        sent = {}

        def handler(request: httpx.Request) -> httpx.Response:
            sent["url"] = str(request.url)
            sent["body"] = json.loads(request.content)
            return httpx.Response(200, json={"code": 200, "message": "success"})

        transport = httpx.MockTransport(handler)
        real_client = httpx.AsyncClient
        with (
            patch.object(push_service, "_subscriptions", return_value=[]),
            patch.object(push_service.db, "system_log_start", return_value=""),
            patch.object(push_service.httpx, "AsyncClient",
                         side_effect=lambda **kw: real_client(transport=transport, **kw)),
        ):
            result = asyncio.run(push_service.send_push("Cloudy 发来一条消息", "在吗", "/?chat=c1&from=push"))

        self.assertEqual(result["sent"], 1)
        self.assertTrue(result["bark"])
        self.assertEqual(sent["url"], "https://api.day.app/push")
        self.assertEqual(sent["body"]["device_key"], "k1")
        self.assertEqual(sent["body"]["url"], "dwell://open?chat=c1")
        self.assertEqual(sent["body"]["icon"], "https://dwell.example.com/icons/dwell-bunny-180.png")

    def test_bark_failure_hides_the_key(self):
        push_service.save_bark({"address": "https://api.day.app/SecretKeyValue1234567"})
        transport = httpx.MockTransport(
            lambda r: httpx.Response(400, json={"code": 400, "message": "failed to get device token: SecretKeyValue1234567"}))
        real_client = httpx.AsyncClient
        with patch.object(push_service.httpx, "AsyncClient",
                          side_effect=lambda **kw: real_client(transport=transport, **kw)):
            result = asyncio.run(push_service.send_bark("t", "b", "/"))
        self.assertEqual(result["sent"], 0)
        self.assertIn("HTTP 400", result["diagnostic"])
        self.assertNotIn("SecretKeyValue1234567", result["diagnostic"])


if __name__ == "__main__":
    unittest.main()
