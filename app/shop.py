"""小荷包：Cloudy 在淘宝替 Morry 挑东西、下单，付款要过两道人手。

一笔钱的路：

    Cloudy 用浏览器（她电脑上的 Edge，经 Playwright MCP）逛、选规格、进订单确认页
    → ShopRequestApproval 开一张审批单，聊天里渲染成卡片（细节默认折着，想看再展开）
    → Morry 在卡上点「确认」：当月额度里原子地预占这笔钱 → 系统唤醒 Cloudy 去付
    → Cloudy 点「立即支付」，拿到支付宝最终收银台地址 → ShopPay
    → 后端校验地址、调官方 alipay-bot submit-payment → Morry 手机按指纹
    → ShopPaymentStatus 查到支付宝说成功才算花掉。

模型碰不到 alipay-bot：桥接默认不给 Claude Code 任何内置工具（没有 Bash），
付款命令只在这里由后端用 argv 跑，且只在 Morry 批准过的单上跑。
卡片上的商品和金额是 Cloudy 从页面抄下来的摘要，不是支付宝签过名的报价——
真正的最后一道是她手机上的指纹，那一下看到的是支付宝自己的金额。
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import shutil
import time
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qs, urlparse

from . import db

ID_PREFIX = "sp_"

DEFAULT_MONTHLY_LIMIT_MINOR = 50_000   # ¥500
LIMIT_SETTING = "shop_monthly_limit_minor"

APPROVAL_TTL = 30 * 60   # 卡片开出来多久内要点
PAY_TTL = 30 * 60        # 批准之后多久内要付出去，过了就放回额度

# 预占额度的状态：批准了、等手机确认、已付。
HOLD_STATUSES = ("approved", "pending_alipay", "paid")
FINAL_STATUSES = ("paid", "rejected", "cancelled", "expired", "failed", "budget_blocked")

MAX_TEXT = 200
MAX_NOTE = 300
MAX_URL = 2000
MAX_QUANTITY = 99

CLI_TIMEOUT = 45
CLI_OUTPUT_LIMIT = 64 * 1024
CLI_REPLY_LIMIT = 2000

# 查询结果里只认这些字样，宁可一直「待确认」也不猜成功。
PAID_MARKERS = ("TRADE_SUCCESS", "TRADE_FINISHED", "PAY_SUCCESS", "支付成功")
FAILED_MARKERS = ("TRADE_CLOSED", "PAY_FAILED", "支付失败", "交易关闭", "已关闭")


class ShopError(Exception):
    def __init__(self, message: str, code: str = "invalid"):
        super().__init__(message)
        self.message = message
        self.code = code


# ---------------------------------------------------------------- 金额

def to_minor(value, field: str, allow_zero: bool = True) -> int:
    """「39.9」/ 39.9 / "39.90" → 3990 分。最多两位小数，不收负数和浮点误差。"""
    if value is None or value == "":
        if allow_zero:
            return 0
        raise ShopError(f"{field} 必须填")
    if isinstance(value, bool):
        raise ShopError(f"{field} 必须是金额")
    text = str(value).strip().lstrip("¥￥").replace(",", "")
    try:
        amount = Decimal(text)
    except InvalidOperation as exc:
        raise ShopError(f"{field} 不是金额：{value!r}") from exc
    if not amount.is_finite() or amount < 0 or (amount == 0 and not allow_zero):
        raise ShopError(f"{field} 必须是{'不小于' if allow_zero else '大于'} 0 的金额")
    if amount.as_tuple().exponent < -2:
        raise ShopError(f"{field} 最多两位小数")
    minor = int(amount * 100)
    if minor > 10_000_000:
        raise ShopError(f"{field} 太大了")
    return minor


def yuan(minor: int) -> str:
    return f"{int(minor) // 100}.{int(minor) % 100:02d}"


# ---------------------------------------------------------------- 额度

def month_key(ts: int | None = None) -> str:
    moment = db.cn_now() if ts is None else db.datetime.fromtimestamp(ts, db.CN_TZ)
    return moment.strftime("%Y-%m")


def monthly_limit() -> int:
    try:
        value = int(db.setting_get(LIMIT_SETTING, str(DEFAULT_MONTHLY_LIMIT_MINOR)))
    except ValueError:
        return DEFAULT_MONTHLY_LIMIT_MINOR
    return max(0, value)


def set_monthly_limit(minor: int) -> int:
    if not isinstance(minor, int) or isinstance(minor, bool) or minor < 0 or minor > 10_000_000:
        raise ShopError("额度必须是 0 ~ 100000 元之间的整数分")
    db.setting_set(LIMIT_SETTING, str(minor))
    return minor


def _used(cx, month: str) -> tuple[int, int]:
    """当月 (已花, 预占中)。"""
    rows = cx.execute(
        "SELECT status, COALESCE(SUM(total_minor),0) AS s FROM shop_requests "
        f"WHERE budget_month=? AND status IN ({','.join('?' * len(HOLD_STATUSES))}) GROUP BY status",
        (month, *HOLD_STATUSES),
    ).fetchall()
    spent = sum(r["s"] for r in rows if r["status"] == "paid")
    held = sum(r["s"] for r in rows if r["status"] != "paid")
    return spent, held


def wallet(now: int | None = None) -> dict:
    now = int(now or time.time())
    month = month_key(now)
    with db.conn() as cx:
        _expire(cx, now)
        spent, held = _used(cx, month)
    limit = monthly_limit()
    available = max(0, limit - spent - held)
    return {
        "month": month,
        "limit_minor": limit, "spent_minor": spent, "held_minor": held,
        "available_minor": available,
        "limit": yuan(limit), "spent": yuan(spent), "held": yuan(held), "available": yuan(available),
    }


# ---------------------------------------------------------------- 单子

def _expire(cx, now: int) -> None:
    """过期的单落到终态：没点的卡、批准了却迟迟没付出去的（放回额度）。"""
    cx.execute(
        "UPDATE shop_requests SET status='expired' "
        "WHERE status='pending_approval' AND expires_at<=?",
        (now,),
    )
    cx.execute(
        "UPDATE shop_requests SET status='expired' "
        "WHERE status='approved' AND decided_at IS NOT NULL AND decided_at<=?",
        (now - PAY_TTL,),
    )


def _row(row) -> dict:
    data = dict(row)
    for key in ("subtotal", "shipping", "discount", "total"):
        data[key] = yuan(data[f"{key}_minor"])
    data.pop("cashier_url", None)
    return data


def get(request_id: str, now: int | None = None) -> dict | None:
    with db.conn() as cx:
        _expire(cx, int(now or time.time()))
        row = cx.execute("SELECT * FROM shop_requests WHERE id=?", (str(request_id or ""),)).fetchone()
    return _row(row) if row else None


def recent(limit: int = 5) -> list[dict]:
    with db.conn() as cx:
        _expire(cx, int(time.time()))
        rows = cx.execute(
            "SELECT * FROM shop_requests ORDER BY created_at DESC LIMIT ?", (limit,)
        ).fetchall()
    return [_row(r) for r in rows]


def _text(value, field: str, limit: int = MAX_TEXT, required: bool = False) -> str:
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise ShopError(f"{field} 必须是字符串")
    value = " ".join(value.split())
    if required and not value:
        raise ShopError(f"{field} 必须填")
    if len(value) > limit:
        raise ShopError(f"{field} 超过 {limit} 字了")
    return value


def allowed_shop_url(value: str) -> bool:
    parsed = urlparse(value or "")
    host = (parsed.hostname or "").lower().rstrip(".")
    return parsed.scheme == "https" and any(
        host == root or host.endswith("." + root) for root in ("taobao.com", "tmall.com")
    )


def create_request(chat_id: str, payload: dict, now: int | None = None) -> dict:
    """开一张审批单。超出当月剩余额度的直接拒绝，不开卡。"""
    now = int(now or time.time())
    body = payload or {}
    goods = _text(body.get("goods"), "goods", required=True)
    merchant = _text(body.get("merchant"), "merchant")
    sku = _text(body.get("sku"), "sku")
    address_hint = _text(body.get("address_hint"), "address_hint", required=True)
    note = _text(body.get("note"), "note", MAX_NOTE)
    item_url = _text(body.get("item_url"), "item_url", MAX_URL)
    if item_url and not allowed_shop_url(item_url):
        raise ShopError("item_url 只能是 https 的淘宝或天猫地址")
    quantity = body.get("quantity", 1)
    if not isinstance(quantity, int) or isinstance(quantity, bool) or not 1 <= quantity <= MAX_QUANTITY:
        raise ShopError(f"quantity 必须是 1~{MAX_QUANTITY} 的整数")

    total = to_minor(body.get("total"), "total", allow_zero=False)
    shipping = to_minor(body.get("shipping"), "shipping")
    discount = to_minor(body.get("discount"), "discount")
    subtotal = to_minor(body.get("subtotal"), "subtotal", allow_zero=False)
    if subtotal + shipping - discount != total:
        raise ShopError(
            f"金额对不上：商品 {yuan(subtotal)} + 运费 {yuan(shipping)} - 优惠 {yuan(discount)}"
            f" ≠ 合计 {yuan(total)}。回订单确认页再核一遍"
        )

    request_id = ID_PREFIX + secrets.token_hex(6)
    with db.conn() as cx:
        cx.execute("BEGIN IMMEDIATE")
        _expire(cx, now)
        spent, held = _used(cx, month_key(now))
        available = monthly_limit() - spent - held
        if total > available:
            raise ShopError(
                f"超出这个月小荷包的剩余额度：要 {yuan(total)}，只剩 {yuan(max(0, available))}",
                "budget",
            )
        cx.execute(
            "INSERT INTO shop_requests (id, chat_id, status, merchant, goods, sku, quantity, "
            "subtotal_minor, shipping_minor, discount_minor, total_minor, address_hint, item_url, "
            "note, created_at, expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (request_id, chat_id, "pending_approval", merchant, goods, sku, quantity,
             subtotal, shipping, discount, total, address_hint, item_url, note,
             now, now + APPROVAL_TTL),
        )
    return get(request_id, now)


def decide(request_id: str, approve: bool, now: int | None = None) -> dict:
    """Morry 在卡上点了确认或拒绝。批准和预占额度在同一个事务里，两张卡同时点也不会超额。"""
    now = int(now or time.time())
    with db.conn() as cx:
        cx.execute("BEGIN IMMEDIATE")
        _expire(cx, now)
        row = cx.execute("SELECT * FROM shop_requests WHERE id=?", (str(request_id or ""),)).fetchone()
        if not row:
            raise ShopError("没有这张单", "not_found")
        if row["status"] != "pending_approval":
            raise ShopError("这张单已经处理过了", "conflict")
        if not approve:
            cx.execute(
                "UPDATE shop_requests SET status='rejected', decided_at=? WHERE id=?",
                (now, row["id"]),
            )
        else:
            month = month_key(now)
            spent, held = _used(cx, month)
            if row["total_minor"] > monthly_limit() - spent - held:
                cx.execute(
                    "UPDATE shop_requests SET status='budget_blocked', decided_at=? WHERE id=?",
                    (now, row["id"]),
                )
            else:
                cx.execute(
                    "UPDATE shop_requests SET status='approved', decided_at=?, budget_month=? "
                    "WHERE id=? AND status='pending_approval'",
                    (now, month, row["id"]),
                )
    return get(request_id, now)


def cancel(request_id: str, now: int | None = None) -> dict:
    """Cloudy 自己撤单（还没发去支付宝之前）。"""
    now = int(now or time.time())
    with db.conn() as cx:
        _expire(cx, now)
        cur = cx.execute(
            "UPDATE shop_requests SET status='cancelled', decided_at=COALESCE(decided_at, ?) "
            "WHERE id=? AND status IN ('pending_approval','approved')",
            (now, str(request_id or "")),
        )
    if not cur.rowcount:
        found = get(request_id, now)
        if not found:
            raise ShopError("没有这张单", "not_found")
        raise ShopError(f"这张单现在是 {found['status']}，撤不了", "conflict")
    return get(request_id, now)


# ---------------------------------------------------------------- 支付宝

def validate_cashier_url(value: str) -> str:
    """只收支付宝官方的最终收银台：https、alipay 域名、cashiermain.htm、带 orderId。

    点「立即支付」后会先经过 trust_login.do 这类中间页，那种地址交给 CLI 会报错。
    """
    value = str(value or "").strip()
    if len(value) > MAX_URL:
        raise ShopError("收银台地址太长了")
    parsed = urlparse(value)
    if parsed.scheme != "https":
        raise ShopError("收银台地址必须是 https")
    host = (parsed.hostname or "").lower().rstrip(".")
    if not any(host == root or host.endswith("." + root) for root in ("alipay.com", "alipay.cn")):
        raise ShopError("这不是支付宝官方的地址")
    if not parsed.path.rstrip("/").lower().endswith("/cashiermain.htm"):
        raise ShopError("这还不是最终收银台（要等它跳到 cashiermain.htm?orderId=…）")
    if not any(v.strip() for v in parse_qs(parsed.query).get("orderId", [])):
        raise ShopError("收银台地址里没有 orderId，再等两三秒让页面跳完")
    return value


def cli_path() -> str:
    configured = os.environ.get("ALIPAY_BOT_PATH", "").strip()
    return configured or shutil.which("alipay-bot") or ""


async def run_cli(args: list[str]) -> tuple[int, str]:
    """跑一次 alipay-bot。argv 数组、不过 shell、有超时、有输出上限。"""
    binary = cli_path()
    if not binary or not os.access(binary, os.X_OK):
        raise ShopError("服务器上没装 alipay-bot（或 ALIPAY_BOT_PATH 不对）", "cli_unavailable")
    process = await asyncio.create_subprocess_exec(
        binary, *args,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=CLI_TIMEOUT)
    except asyncio.TimeoutError as exc:
        process.kill()
        await process.wait()
        raise ShopError("alipay-bot 超时没回话", "cli_timeout") from exc
    output = (stdout + b"\n" + stderr)[:CLI_OUTPUT_LIMIT]
    return process.returncode or 0, output.decode("utf-8", errors="replace").strip()


def _find_ref(output: str) -> str:
    """从 CLI 输出里找支付宝的查询号（out-shake-no）。找不到就空着，查询时改用收银台地址。"""
    try:
        data = json.loads(output)
    except (json.JSONDecodeError, ValueError):
        match = re.search(r"out[-_]?shake[-_]?no\W+([A-Za-z0-9_-]{6,})", output, re.I)
        return match.group(1) if match else ""
    stack = [data]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            for key, value in item.items():
                if isinstance(value, str) and re.sub(r"[-_]", "", key).lower() == "outshakeno":
                    return value[:200]
                stack.append(value)
        elif isinstance(item, list):
            stack.extend(item)
    return ""


def _short(output: str) -> str:
    return output if len(output) <= CLI_REPLY_LIMIT else output[:CLI_REPLY_LIMIT] + "…"


async def submit_payment(request_id: str, cashier_url: str, now: int | None = None) -> dict:
    """把批准过的单交给支付宝。每张单只交一次；交出去之后只查不再交。"""
    now = int(now or time.time())
    url = validate_cashier_url(cashier_url)
    with db.conn() as cx:
        cx.execute("BEGIN IMMEDIATE")
        _expire(cx, now)
        row = cx.execute("SELECT * FROM shop_requests WHERE id=?", (str(request_id or ""),)).fetchone()
        if not row:
            raise ShopError("没有这张单", "not_found")
        if row["status"] == "pending_approval":
            raise ShopError("Morry 还没在卡上点确认，不能付", "not_approved")
        if row["status"] == "pending_alipay":
            raise ShopError("这张单已经发去支付宝了，用 ShopPaymentStatus 查，别再交", "already_submitted")
        if row["status"] != "approved":
            raise ShopError(f"这张单现在是 {row['status']}，不能付", "conflict")
        # 先占住再跑 CLI：两次并发调用只有一次走得到这里。
        cx.execute(
            "UPDATE shop_requests SET status='pending_alipay', submitted_at=?, cashier_url=? WHERE id=?",
            (now, url, row["id"]),
        )
    try:
        code, output = await run_cli(["submit-payment", "--payment-link", url])
    except ShopError as exc:
        _set_error(request_id, exc.message, back_to_approved=True)
        raise
    if code != 0:
        _set_error(request_id, _short(output) or f"退出码 {code}", back_to_approved=True)
        raise ShopError(f"alipay-bot 没接这单：{_short(output) or code}", "cli_failed")
    ref = _find_ref(output)
    with db.conn() as cx:
        cx.execute(
            "UPDATE shop_requests SET provider_ref=?, last_error='' WHERE id=?",
            (ref, str(request_id)),
        )
    return {"request": get(request_id), "output": _short(output)}


def _set_error(request_id: str, message: str, back_to_approved: bool = False) -> None:
    """CLI 根本没接这单（没装、超时、报错）时退回 approved，还能在额度时限内再试。"""
    with db.conn() as cx:
        if back_to_approved:
            cx.execute(
                "UPDATE shop_requests SET status='approved', submitted_at=NULL, last_error=? "
                "WHERE id=? AND status='pending_alipay' AND provider_ref=''",
                (message[:500], str(request_id)),
            )
        else:
            cx.execute("UPDATE shop_requests SET last_error=? WHERE id=?", (message[:500], str(request_id)))


def read_outcome(output: str) -> str:
    upper = output.upper()
    if any(marker.upper() in upper for marker in PAID_MARKERS):
        return "paid"
    if any(marker.upper() in upper for marker in FAILED_MARKERS):
        return "failed"
    return "pending"


async def query_payment(request_id: str, now: int | None = None) -> dict:
    """问支付宝这单付没付。只有支付宝明说成功才记成已付。"""
    now = int(now or time.time())
    with db.conn() as cx:
        row = cx.execute("SELECT * FROM shop_requests WHERE id=?", (str(request_id or ""),)).fetchone()
    if not row:
        raise ShopError("没有这张单", "not_found")
    if row["status"] == "paid":
        return {"request": _row(row), "output": "已经记过账了"}
    if row["status"] != "pending_alipay":
        raise ShopError(f"这张单现在是 {row['status']}，没有在等支付宝", "conflict")
    if row["provider_ref"]:
        args = ["query-payment-status", "--out-shake-no", row["provider_ref"]]
    else:
        args = ["query-payment-status", "--payment-link", row["cashier_url"]]
    code, output = await run_cli(args)
    outcome = read_outcome(output) if code == 0 else "pending"
    with db.conn() as cx:
        if outcome == "paid":
            cx.execute(
                "UPDATE shop_requests SET status='paid', paid_at=?, last_error='' "
                "WHERE id=? AND status='pending_alipay'",
                (now, row["id"]),
            )
        elif outcome == "failed":
            cx.execute(
                "UPDATE shop_requests SET status='failed', last_error=? "
                "WHERE id=? AND status='pending_alipay'",
                (_short(output)[:500], row["id"]),
            )
    return {"request": get(request_id, now), "output": _short(output)}


# ---------------------------------------------------------------- 唤醒

def build_decision_note(request: dict, partner: str = "Morry") -> str:
    r = request or {}
    status = r.get("status")
    head = f"[系统消息 · 小荷包] {partner}"
    what = f"「{r.get('goods', '')}」¥{r.get('total', '')}（单号 {r.get('id', '?')}）"
    if status == "approved":
        return (
            f"{head}在卡上确认了{what}，额度已经预占。现在去付：\n"
            "① 回到那张订单确认页，点「提交订单」/「立即支付」；\n"
            "② 等两三秒，页面会先经过 trust_login.do 这类中间页，"
            "要等它跳到 cashiermain.htm?orderId=… 才是最终收银台；\n"
            f"③ 把那个完整地址交给 ShopPay（id={r.get('id')}）。不要在收银台页面上点任何东西。\n"
            f"交出去以后告诉{partner}去手机上按指纹，她按完你再用 ShopPaymentStatus 查。"
            f"批准 {PAY_TTL // 60} 分钟内没付出去，这单会作废、额度放回去。"
        )
    if status == "budget_blocked":
        return f"{head}点了确认，但{what}超出了这个月小荷包的剩余额度，没有批准。跟她说一声。"
    return f"{head}没要{what}，这单作废了。别再开同一单，想说什么就说。"
