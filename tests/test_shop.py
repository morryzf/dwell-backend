"""小荷包：审批单、当月额度、收银台校验、alipay-bot 只在批准过的单上跑一次。"""

import asyncio
import json
import os
import stat
import tempfile
import time
import unittest
import uuid
from datetime import datetime

from app import db, main, shop

CASHIER = "https://excashier.alipay.com/standard/auth/cashiermain.htm?orderId=abc123"


def order(**overrides):
    body = {
        "goods": "USB-C 编织线", "merchant": "示例数码店", "sku": "黑色 / 1 米",
        "quantity": 1, "subtotal": "45.90", "shipping": "0", "discount": "6",
        "total": "39.90", "address_hint": "家 · 上海浦东 · 尾号1234",
        "item_url": "https://item.taobao.com/item.htm?id=1",
    }
    body.update(overrides)
    return body


class ShopTestBase(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"shop-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("对话")["id"]
        self.now = int(datetime(2026, 10, 12, 12, 0, tzinfo=db.CN_TZ).timestamp())

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)


class AmountTest(unittest.TestCase):
    def test_yuan_to_minor(self):
        self.assertEqual(shop.to_minor("39.9", "x"), 3990)
        self.assertEqual(shop.to_minor("¥1,234.56", "x"), 123456)
        self.assertEqual(shop.to_minor(0, "x"), 0)
        for bad in ("-1", "1.234", "abc", True, "NaN"):
            with self.assertRaises(shop.ShopError):
                shop.to_minor(bad, "x")
        with self.assertRaises(shop.ShopError):
            shop.to_minor("0", "x", allow_zero=False)


class RequestTest(ShopTestBase):
    def test_default_wallet_is_500_a_month(self):
        w = shop.wallet(self.now)
        self.assertEqual(w["limit"], "500.00")
        self.assertEqual(w["available"], "500.00")

    def test_amounts_must_add_up(self):
        with self.assertRaises(shop.ShopError) as ctx:
            shop.create_request(self.chat, order(total="45.90"), self.now)
        self.assertIn("对不上", ctx.exception.message)

    def test_over_budget_never_opens_a_card(self):
        with self.assertRaises(shop.ShopError) as ctx:
            shop.create_request(self.chat, order(subtotal="600", discount="0", total="600"), self.now)
        self.assertEqual(ctx.exception.code, "budget")

    def test_only_taobao_item_urls(self):
        with self.assertRaises(shop.ShopError):
            shop.create_request(self.chat, order(item_url="https://taobao.com.evil.example/x"), self.now)

    def test_approve_holds_budget_and_reject_does_not(self):
        a = shop.create_request(self.chat, order(), self.now)
        b = shop.create_request(self.chat, order(), self.now)
        self.assertEqual(shop.decide(a["id"], True, self.now)["status"], "approved")
        self.assertEqual(shop.decide(b["id"], False, self.now)["status"], "rejected")
        w = shop.wallet(self.now)
        self.assertEqual(w["held"], "39.90")
        self.assertEqual(w["available"], "460.10")
        with self.assertRaises(shop.ShopError) as ctx:
            shop.decide(a["id"], True, self.now)
        self.assertEqual(ctx.exception.code, "conflict")

    def test_two_cards_cannot_overspend(self):
        shop.set_monthly_limit(5000)
        a = shop.create_request(self.chat, order(), self.now)
        b = shop.create_request(self.chat, order(), self.now)
        shop.decide(a["id"], True, self.now)
        self.assertEqual(shop.decide(b["id"], True, self.now)["status"], "budget_blocked")

    def test_unclicked_card_expires(self):
        a = shop.create_request(self.chat, order(), self.now)
        self.assertEqual(shop.get(a["id"], self.now + shop.APPROVAL_TTL)["status"], "expired")
        with self.assertRaises(shop.ShopError):
            shop.decide(a["id"], True, self.now + shop.APPROVAL_TTL)

    def test_unpaid_approval_expires_and_frees_budget(self):
        a = shop.create_request(self.chat, order(), self.now)
        shop.decide(a["id"], True, self.now)
        later = self.now + shop.PAY_TTL
        self.assertEqual(shop.get(a["id"], later)["status"], "expired")
        self.assertEqual(shop.wallet(later)["available"], "500.00")

    def test_new_month_starts_fresh(self):
        a = shop.create_request(self.chat, order(), self.now)
        shop.decide(a["id"], True, self.now)
        next_month = int(datetime(2026, 11, 1, 0, 1, tzinfo=db.CN_TZ).timestamp())
        with db.conn() as cx:   # 让它付掉，不然会过期放回额度
            cx.execute("UPDATE shop_requests SET status='paid' WHERE id=?", (a["id"],))
        self.assertEqual(shop.wallet(self.now)["spent"], "39.90")
        self.assertEqual(shop.wallet(next_month)["available"], "500.00")

    def test_cashier_url_never_exposed(self):
        a = shop.create_request(self.chat, order(), self.now)
        self.assertNotIn("cashier_url", shop.get(a["id"], self.now))


class CashierUrlTest(unittest.TestCase):
    def test_accepts_final_cashier(self):
        self.assertEqual(shop.validate_cashier_url(CASHIER), CASHIER)

    def test_rejects_everything_else(self):
        for url in (
            "http://excashier.alipay.com/standard/auth/cashiermain.htm?orderId=1",
            "https://alipay.com.evil.example/cashiermain.htm?orderId=1",
            "https://excashier.alipay.com/trust_login.do?x=1",
            "https://excashier.alipay.com/standard/auth/cashiermain.htm",
            "https://excashier.alipay.com/standard/auth/cashiermain.htm?orderId=",
        ):
            with self.assertRaises(shop.ShopError, msg=url):
                shop.validate_cashier_url(url)


class FakeCliTest(ShopTestBase):
    """用一个假的 alipay-bot 脚本：把收到的参数记下来，按环境变量回话。"""

    def setUp(self):
        super().setUp()
        self.dir = tempfile.mkdtemp()
        self.calls = os.path.join(self.dir, "calls.txt")
        self.reply = os.path.join(self.dir, "reply.txt")
        script = os.path.join(self.dir, "alipay-bot")
        with open(script, "w") as handle:
            handle.write(f'#!/bin/sh\necho "$@" >> {self.calls}\ncat {self.reply}\n')
        os.chmod(script, os.stat(script).st_mode | stat.S_IEXEC)
        self.previous_cli = os.environ.get("ALIPAY_BOT_PATH")
        os.environ["ALIPAY_BOT_PATH"] = script
        self.say('{"code":200,"data":{"outShakeNo":"OS123456","shortUrl":"https://u.alipay.cn/x"}}')

    def tearDown(self):
        if self.previous_cli is None:
            os.environ.pop("ALIPAY_BOT_PATH", None)
        else:
            os.environ["ALIPAY_BOT_PATH"] = self.previous_cli
        super().tearDown()

    def say(self, text):
        with open(self.reply, "w") as handle:
            handle.write(text)

    def calls_made(self):
        if not os.path.exists(self.calls):
            return []
        with open(self.calls) as handle:
            return [line.strip() for line in handle if line.strip()]

    def approved(self):
        a = shop.create_request(self.chat, order(), int(time.time()))
        return shop.decide(a["id"], True)

    def test_cannot_pay_before_approval(self):
        a = shop.create_request(self.chat, order(), int(time.time()))
        with self.assertRaises(shop.ShopError) as ctx:
            asyncio.run(shop.submit_payment(a["id"], CASHIER))
        self.assertEqual(ctx.exception.code, "not_approved")
        self.assertEqual(self.calls_made(), [])

    def test_pay_once_then_only_query(self):
        a = self.approved()
        result = asyncio.run(shop.submit_payment(a["id"], CASHIER))
        self.assertEqual(result["request"]["status"], "pending_alipay")
        self.assertEqual(result["request"]["provider_ref"], "OS123456")
        self.assertEqual(self.calls_made(), [f"submit-payment --payment-link {CASHIER}"])
        with self.assertRaises(shop.ShopError) as ctx:
            asyncio.run(shop.submit_payment(a["id"], CASHIER))
        self.assertEqual(ctx.exception.code, "already_submitted")

        self.say('{"code":200,"data":{"status":"WAIT_BUYER_PAY"}}')
        self.assertEqual(asyncio.run(shop.query_payment(a["id"]))["request"]["status"], "pending_alipay")
        self.say('{"code":200,"message":"查询成功","data":{"status":"TRADE_SUCCESS"}}')
        self.assertEqual(asyncio.run(shop.query_payment(a["id"]))["request"]["status"], "paid")
        self.assertEqual(self.calls_made()[-1], "query-payment-status --out-shake-no OS123456")
        self.assertEqual(shop.wallet()["spent"], "39.90")

    def test_query_success_word_alone_is_not_paid(self):
        self.assertEqual(shop.read_outcome('{"message":"查询成功","status":"WAIT_BUYER_PAY"}'), "pending")

    def test_bad_cashier_url_never_reaches_cli(self):
        a = self.approved()
        with self.assertRaises(shop.ShopError):
            asyncio.run(shop.submit_payment(a["id"], "https://excashier.alipay.com/trust_login.do"))
        self.assertEqual(self.calls_made(), [])
        self.assertEqual(shop.get(a["id"])["status"], "approved")

    def test_missing_cli_puts_order_back(self):
        a = self.approved()
        os.environ["ALIPAY_BOT_PATH"] = os.path.join(self.dir, "nope")
        with self.assertRaises(shop.ShopError) as ctx:
            asyncio.run(shop.submit_payment(a["id"], CASHIER))
        self.assertEqual(ctx.exception.code, "cli_unavailable")
        self.assertEqual(shop.get(a["id"])["status"], "approved")


class ToolSurfaceTest(ShopTestBase):
    def tool_names(self):
        tools, tool_map = asyncio.run(main._chat_tools(self.chat, list_tools=lambda server: []))
        return {t["function"]["name"]: tool_map[t["function"]["name"]] for t in tools}

    def test_off_by_default(self):
        self.assertNotIn("ShopRequestApproval", self.tool_names())

    def test_on_gives_shop_tools_but_not_to_heartbeat(self):
        db.shop_set(self.chat, True)
        names = self.tool_names()
        for name in ("ShopWallet", "ShopRequestApproval", "ShopPay", "ShopPaymentStatus", "ShopCancel"):
            self.assertEqual(names[name], "builtin:shop")
        tool = next(t for t in main.SHOP_TOOLS if t["function"]["name"] == "ShopWallet")
        self.assertFalse(main._heartbeat_tool_allowed(tool, "builtin:shop"))

    def test_tool_returns_marker_and_human_errors(self):
        text, is_error = asyncio.run(
            main._run_chat_tool(self.chat, "ShopRequestApproval", "builtin:shop", order())
        )
        data = json.loads(text)
        self.assertFalse(is_error)
        self.assertEqual(data["marker"], f"[[shop:{data['id']}]]")
        text, _ = asyncio.run(
            main._run_chat_tool(self.chat, "ShopPay", "builtin:shop", {"id": data["id"], "cashier_url": CASHIER})
        )
        self.assertIn("还没在卡上点确认", json.loads(text)["error"])

    def test_decision_note_tells_next_step(self):
        a = shop.create_request(self.chat, order(), self.now)
        approved = shop.decide(a["id"], True, self.now)
        self.assertIn("ShopPay", shop.build_decision_note(approved))
        b = shop.create_request(self.chat, order(), self.now)
        self.assertIn("没要", shop.build_decision_note(shop.decide(b["id"], False, self.now)))


if __name__ == "__main__":
    unittest.main()
