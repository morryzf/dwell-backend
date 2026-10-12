# 小荷包：让 Cloudy 在淘宝替你买东西

```
Cloudy（VPS 上的 Claude Code）
  ├─ 逛淘宝 ──ZeroTier──> 你 Windows 电脑上的 Edge（Playwright MCP :8931）
  └─ 开审批卡 / 付款 ───> Dwell 后端 ──> alipay-bot（支付宝官方 AI 付）──> 你手机按指纹
```

付一笔钱要过两道人手：Dwell 里那张卡上点「确认」，再在手机支付宝上按指纹。
Cloudy 碰不到 alipay-bot（桥接不给他终端），只有你批准过的单，后端才会交给支付宝，每单只交一次。
每月额度默认 ¥500，超出额度的单子开不出卡来。

## 一、组网：ZeroTier（只做一次）

1. 打开 https://my.zerotier.com ，用 GitHub 登录，点 **Create A Network**。Access Control 保持 **Private**，不要开 Auto-Assign。记下 16 位 Network ID。
2. **Windows 电脑**：从 https://www.zerotier.com/download/ 装客户端，右下角托盘图标右键 → **Join New Network** → 填 Network ID。
3. **VPS**（ssh 进去）：

   ```bash
   curl -s https://install.zerotier.com | sudo bash
   sudo zerotier-cli join <Network ID>
   ```

4. 回到 my.zerotier.com → 你的网络 → Members，两台设备都勾上 **Authorized**。记下电脑分到的 `10.x.x.x`，下面叫它 `<电脑IP>`。
5. VPS 上验证：`ping -c 3 <电脑IP>`，能通就行。

> Network ID 不要发给别人。Members 里只应该有你这两台。

## 二、Windows 电脑：让 Cloudy 能用 Edge

前提：装了 Node.js 18 以上（PowerShell 里 `node -v` 能看到版本号）。

在 PowerShell 里运行（`<电脑IP>` 换成上面那个 10 开头的地址）：

```powershell
$env:PLAYWRIGHT_MCP_PING_TIMEOUT_MS="1800000"; npx @playwright/mcp@latest --port 8931 --host <电脑IP> --browser msedge --user-data-dir "$env:USERPROFILE\dwell-edge" --shared-browser-context
```

- Windows 防火墙弹窗问要不要允许，点 **允许**。
- 第一次会打开一个新的 Edge 窗口：在这个窗口里**手动登录一次淘宝**。登录状态存在 `dwell-edge` 文件夹里，下次不用再登。
- Cloudy 逛的时候，这个 PowerShell 窗口和 Edge 窗口都要开着。关掉就逛不了。
- `--shared-browser-context` 让浏览器在两次对话之间一直开着。不加的话，每轮对话结束浏览器就关掉，淘宝的登录也跟着丢，每次都要重新登。
- 电脑上开着代理（Clash 之类）的话，要用**规则模式**，别用全局模式。全局模式会把淘宝也送出国，淘宝会直接断开连接。

> 这个端口谁连上谁就能操作这个浏览器，所以只开在 ZeroTier 的地址上，不要改成 `0.0.0.0`。

## 三、VPS：桥接接上浏览器

编辑 `/etc/systemd/system/dwell-bridge.service`，在 `MCP_SERVERS_JSON` 里加上 `taobao` 这一项（已有的 `ombre` 留着），并确保有 `ToolSearch`（已经有 `BUILTIN_TOOLS` 的话，把 `ToolSearch` 加进那串逗号列表里）：

```ini
Environment=MCP_SERVERS_JSON={"ombre":{...原来的...},"taobao":{"type":"http","url":"http://<电脑IP>:8931/mcp"}}
Environment=BUILTIN_TOOLS=ToolSearch
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart dwell-bridge
curl -s localhost:8787/health
```

`mcp_servers` 里能看到 `taobao` 就对了。

## 四、VPS：开通支付宝 AI 付

要用**跑 Dwell 服务的那个用户**来装（`dwell.service` 里 `User=` 写的是谁就用谁），不然 Dwell 找不到授权。

```bash
npx -y @alipay/agent-payment@latest install-cli
alipay-bot apply-wallet --agent-name "Cloudy"
```

它会给一个二维码链接，用**手机支付宝**扫码授权。然后：

```bash
alipay-bot check-wallet      # 看到「已开启支付宝支付功能」就好了
command -v alipay-bot        # 记下这个路径
```

把路径写进 `/etc/systemd/system/dwell.service`：

```ini
Environment=ALIPAY_BOT_PATH=<上面那个路径>
```

```bash
sudo systemctl daemon-reload
./deploy.sh
```

## 五、手机支付宝：设一个每天的上限

支付宝 → 设置 → 支付设置 → AI 付，设一个单日限额。这是 Dwell 之外的最后一道保险。

## 六、Dwell 里打开

聊天里打开记忆控制台 → **设置** → 打开 **小荷包**。下面能改每月额度，也能看到这个月还剩多少。

## 买一次是什么样

1. Cloudy 在 Edge 里逛淘宝、挑东西、选规格，一直走到订单确认页。到这里停下，不会点付款。
2. 聊天里出现一张卡：总价和寄到哪里一直显示；买的是什么折起来了，点「偷看一下」才会展开。
3. 你点 **确认**：这笔钱从额度里先扣着，Cloudy 被叫醒去付款。点 **不要**，这单就作废了。
4. Cloudy 提交订单后，把支付宝收银台的地址交给 Dwell，Dwell 再转给支付宝，你的手机会弹出确认。
5. 你按指纹。Cloudy 查到支付宝说「成功」，这笔钱才记成花掉。

卡片 30 分钟内没点，或者点了确认但 30 分钟内没付出去，这单都会作废，扣着的钱退回额度。

## 出问题时

| 现象 | 怎么办 |
|---|---|
| Cloudy 说浏览器连不上 | 电脑上那个 PowerShell 窗口是不是关了；ZeroTier 托盘图标是不是在线 |
| 浏览器连接报 `Access is only allowed at …` | 在电脑那条命令后面加上 `--allowed-hosts <电脑IP>:8931` |
| Cloudy 说「服务器上没装 alipay-bot」 | 第四步的 `ALIPAY_BOT_PATH` 没写，或者路径不对 |
| 一直显示「等你在手机支付宝上确认」 | 你还没按指纹，或者支付宝还没回话；让 Cloudy 再查一次 |
| 淘宝弹出验证 | 在那个 Edge 窗口里自己点一下，Cloudy 会接着往下走 |

## 目前还没做的

- iOS App 里还不会画这张卡，消息里只会显示 `[[shop:sp_…]]` 这一行。先在网页版里点。
- alipay-bot 的输出格式是按教程推断的，第一单真实付款时要核对一次（判断「付成功」只认支付宝明确写着成功的字样，不会猜）。
