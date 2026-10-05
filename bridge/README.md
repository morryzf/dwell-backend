# Claude Agent SDK 桥接服务

把 Dwell 的聊天接到本机 Claude Code 上，走 Claude 订阅额度，而不是按量计费的 API。

```
Dwell 后端 (Python/FastAPI) --HTTP/SSE--> 本服务 (Node) --> Agent SDK --> Claude Code CLI
```

## 为什么要有这一层

Agent SDK 只有 Node.js 和 Python 两个包，而 Dwell 后端要用的是 Node 那条路上的
`query()` 子进程模式。桥接服务不认识 Dwell：没有数据库、不存会话、不碰记忆。
历史怎么铺平、system prompt 怎么拼，都在 Python 侧的 `app/agent_sdk_client.py`。

## 部署（VPS）

前提：这台机器上 Claude Code 已装好，并且 `claude setup-token` 生成的
`CLAUDE_CODE_OAUTH_TOKEN` 已经在环境里。验证一下：

```bash
claude -p "说一个字" --model sonnet
```

装依赖并启动：

```bash
cd ~/dwell-backend/bridge
npm install
BRIDGE_TOKEN="$(openssl rand -hex 24)" npm start
```

记下这个 `BRIDGE_TOKEN`，等下要填进 Dwell 的供应商设置。

### 用 systemd 常驻

`/etc/systemd/system/dwell-bridge.service`：

```ini
[Unit]
Description=Dwell Claude Agent SDK bridge
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/dwell-backend/bridge
Environment=CLAUDE_CODE_OAUTH_TOKEN=<你的令牌>
Environment=BRIDGE_TOKEN=<上面生成的门禁 token>
Environment=CLAUDE_AGENT_MODEL=sonnet
ExecStart=/usr/bin/node server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now dwell-bridge
curl -s localhost:8787/health
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8787` | 监听端口 |
| `HOST` | `127.0.0.1` | 监听地址。只给本机的 Dwell 用就别改 |
| `BRIDGE_TOKEN` | 空 | 门禁 token。空＝不校验，只在 `127.0.0.1` 上才可接受 |
| `CLAUDE_AGENT_MODEL` | `sonnet` | 请求没带 model 时的默认值 |
| `MAX_CONCURRENCY` | `1` | 同时在跑的 Claude Code 子进程数。2 核 4G 建议保持 1 |
| `TURN_TIMEOUT_MS` | `900000` | 单轮硬上限（15 分钟）。0＝不限，不建议 |
| `PROMPT_CACHE_TTL` | `1h` | 缓存保留时长，`5m` 或 `1h`；留空＝跟随 Claude Code 默认 |
| `BUILTIN_TOOLS` | 空 | 给模型哪些内置工具。留空＝一件都不给；`preset`＝全套；或逗号分隔的名字 |
| `MCP_SERVERS_JSON` | 空 | MCP 配置（内联 JSON） |
| `MCP_SERVERS_FILE` | 空 | MCP 配置（文件路径），`MCP_SERVERS_JSON` 优先 |

**`CLAUDE_CODE_OAUTH_TOKEN` 要在环境里。** 服务会把 `ANTHROPIC_API_KEY` 和
`ANTHROPIC_AUTH_TOKEN` 从子进程环境里删掉——留着它们就会走 API 计费而不是订阅额度。

## 接口

### `GET /health`

```json
{"ok": true, "model": "sonnet", "mcp_servers": [], "max_concurrency": 1, "running": 0, "queued": 0}
```

### `POST /v1/chat/stream`

请求体：

```json
{
  "model": "sonnet",
  "system": "你是……",
  "prompt": "铺平后的对话",
  "include_thinking": true,
  "images": [{"type": "base64", "media_type": "image/jpeg", "data": "…"}],
  "effort": "high",
  "max_turns": 1,
  "session_id": "dwell-chat:xxx",
  "rewrite_rules": [{"phrases": ["我就在这里"], "reason": "别用现成的安慰句。"}],
  "require_english": true,
  "mcp_servers": {"dwell": {"type": "http", "url": "https://dwell.example.com/mcp/home",
                            "headers": {"Authorization": "Bearer <一次性通行证>"}}}
}
```

`require_english` 用于语音回复：收尾前回复里出现汉字、假名或谚文就打回重说一次（和重写规则共用同一个 Stop 钩子，也只打回一次）。

`mcp_servers` 是这一轮额外交给 Claude Code 的 MCP，和环境变量里配的合在一起（同名以请求为准）。
Dwell 用它把这间聊天的整套工具（待办、日记、日历、sigillo、网页、外部 MCP）交过来：Claude Code 需要时回调 Dwell 的 `/mcp/home`，
凭 Dwell 每轮签发的通行证进门。只接受 `http` / `sse` 两种远程类型，不会因为请求在本机起进程。
所以**这台机器要能访问到 Dwell 的外部地址**。

响应是 SSE，每行一个事件，最后以 `data: [DONE]` 收尾：

```
data: {"type":"text","text":"你"}
data: {"type":"thinking","thinking":"……"}
data: {"type":"usage","usage":{"input_tokens":120,"output_tokens":48,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
data: {"type":"reset"}
data: {"type":"error","message":"……"}
data: [DONE]
```

`usage` 只在 `result` 消息上取——Agent SDK 每步 assistant 消息上的
`output_tokens` 是占位值，不是真实数字。

### `GET /v1/usage`

订阅额度：5 小时窗口、每周窗口（以及账号有的分模型窗口、额外用量）各用了多少、什么时候重置。
桥接起一个不发消息的 Claude Code 会话，读 `/usage` 背后那份数据，问完就关；结果缓存一分钟，
`?refresh=1` 强制重问。不占聊天的并发槽位。

官方用量接口要能读取账号资料的登录（在这台机器上 `claude` 里 `/login` 过）。拿不到时
`available` 为 false，`observed` 里是最近几次聊天时 Claude Code 报来的额度（`rate_limit_event`），
Dwell 会拿它顶上并注明记录时间。

```json
{"ok": true, "available": true, "subscription_type": "max",
 "rate_limits": {"five_hour": {"utilization": 5, "resets_at": "2026-10-05T13:30:00Z"},
                 "seven_day": {"utilization": 44, "resets_at": "2026-10-06T14:59:00Z"}},
 "observed": {"five_hour": {"utilization": 0.05, "resets_at": 1791207000, "observed_at": 1791190000}}}
```


`session` 事件带回 Claude Code 的会话 id。Dwell 把它存在 settings 表的
`agent_sdk_session:<聊天键>` 下，下一轮作为 `resume` 传回来。桥接自己不存任何状态。

## 一轮卡住怎么办

并发上限是 1，所以一轮卡住就等于整个聊天卡住。而冷启动可能接近三分钟没有
任何事件，靠「有没有动静」判断会误杀，所以用的是一轮一个硬上限
（`TURN_TIMEOUT_MS`，默认 15 分钟）：到点中止，槽位当场释放，Dwell 那边
收到一条说明而不是无限等待。

Dwell 主动断开（用户放弃、后端超时）也会中止这一轮——没人要的回复没必要
继续占着槽位。

## 图片

带图的一轮走流式输入：字符串 prompt 没有地方放图片块。图在前、字在后；
没写字就只发图——空的文字块会被上游拒绝。没有图时仍旧直接传字符串。

`images` 里是 Anthropic 的 image source（`base64` 或 `url`），桥接原样转给 SDK。
原图只进这一轮的请求，不写进聊天历史——Dwell 一直是这么做的，所以只看最后
一条用户消息。

## thinking 和 effort

Dwell 的两个设置直接对上 SDK 的选项：

| Dwell | 传过来 | SDK |
|---|---|---|
| 显示思考 开 | `include_thinking: true` | `thinking: {type:"adaptive", display:"summarized"}` |
| 显示思考 关 | `include_thinking: false` | `thinking: {type:"disabled"}` |
| Effort 档位 | `effort: "high"` | `effort`（low/medium/high/xhigh/max） |

要显式写 `display: "summarized"`：当前模型默认是 `omitted`，thinking 会是空的，
Dwell 那边就什么都看不到。

关掉 thinking 时，`xhigh` / `max` 会被丢弃——部分模型不接受这个组合，会直接 400。
模型不支持的档位由 Claude Code 自己降级，桥接不拦。

## 内置工具

Claude Code 自带的工具（Read / Write / Bash / WebSearch…）全是给改代码用的，
光说明就占一万多 token，而这条通道只是聊天。默认一件都不给。

用白名单而不是黑名单，是因为黑名单挡不住 CLI 以后新增的工具——它们会悄悄
溜回上下文里，而我们不会发现。

- `BUILTIN_TOOLS=`（默认，留空）→ 一件都不给
- `BUILTIN_TOOLS=preset` → 原样给 Claude Code 的整套
- `BUILTIN_TOOLS=WebSearch,ToolSearch` → 只给这几件

MCP 工具不受这里影响（走 `mcpServers`）。但挂了很多 MCP 工具时要把
`ToolSearch` 加回来：CLI 会把一部分 schema 延迟加载，模型靠它才取得到。

## 重写规则

撞到指定的话就把这一轮打回去，让它换个说法重说，并告诉它为什么。

```json
"rewrite_rules": [
  {"phrases": ["我就在这里", "哪也不去"], "reason": "别用现成的安慰句。说点只对她成立的、具体的话。"}
]
```

规则每轮都由 Dwell 传过来（在 Dwell 的设置 → 重写规则里配），改完下一句就生效；
桥接自己不存。它不进 system，也不算进会话指纹——它是收尾时的一道关卡，
不是上下文，所以改规则不必重建缓存。

只有这条通道做得到：它挂在 Claude Code 的 **Stop 钩子**上，模型说完、真要收尾
之前还能拦一次。HTTP API 那条路上回复吐完就结束了，没有这个位置。

打回时会先后发两个事件：

```
data: {"type":"notice","message":"打回重说：撞到了「我就在这里」"}
data: {"type":"reset"}
```

`reset` 是给 Dwell 的指令：把这一轮**已经流出去的字整个抹掉**。不抹的话两版
首尾相接，像它精神分裂。`notice` 照旧进思考面板，那儿留着打回的记录。

一轮最多打回一次（靠 `stop_hook_active` 判断）。重说那一版还撞上也照样放过去——
它可能根本绕不开那句话，而一句话都说不出来比说了句现成话更糟。打回之后它还要
再说一遍，那是多出来的一轮，所以带规则时 `maxTurns` 会自动加一。

## 限流和上游错误

Claude Code 遇到限流会发 `api_retry`，说明原因、第几次重试、还要等多久。
桥接把它转成 `notice` 事件，Dwell 那边显示在**思考面板**里——它不是回复的
一部分，不该混进正文。关掉「显示思考」时就看不到了。

## MCP（Ombre Brain 等）

Dwell 自己的 function tools 没法直接交给 Agent SDK，所以走这条通道时工具由
Claude Code 那边的 MCP 提供。把 Ombre 配进来：

```bash
export MCP_SERVERS_JSON='{"ombre":{"type":"http","url":"https://……/mcp","headers":{"Authorization":"Bearer ……"}}}'
```

配好之后 Dwell 侧这条聊天带上工具时会把 `max_turns` 放宽到 8，让 Claude Code
有余量跑完工具再收尾。

> Dwell 自己的工具（待办、日记、日历、sigillo、网页、聊天挂的外部 MCP）不用在这里配：
> Dwell 每轮会通过请求里的 `mcp_servers` 把它们交过来，见上面 `/v1/chat/stream` 的说明。

## 已知取舍

- **多轮靠续会话，回退时才铺平。** Agent SDK 收的是一句 prompt，不是 role 数组。
  平时 Python 侧带上 `resume`，Claude Code 自己记着之前说过什么，这轮只递新的
  那一句；只有在会话对不上的时候，才把历史渲染成 `<对话记录>` 块重讲一遍。
  对不上的情况有五种：换了模型、system 变了（摘要或指令更新）、**记忆池动过**、
  历史被改过或删过、以及这轮没有新的用户发言（重新生成）。续会话失败会自动
  重来一次，用户无感。
- **记忆池一动就重开会话。** 记忆卡是每轮随 prompt 递过去的，而 Claude Code
  把整段会话都记着——采用、编辑、归档、删卡都追不回已经递出去的那几份。
  所以指纹里带上池子的版本号（`memory_pool_version`），改过卡下一轮就从头
  讲一遍，旧卡当场蒸发。代价是那一轮重建一次缓存。
  对齐按**内容在末尾**找，不按位置：原文窗口是滑动的，聊满之后每轮都会挤掉
  最旧的几条，开头一直在变——锚在开头的话窗口一满就再也续不上。
- **`max_tokens` 不是硬上限。** Agent SDK 没有这个参数，Dwell 只能把它写成
  system 里的一句长度要求。
- **成本数字不上报。** 订阅额度不按量计费，Agent SDK 的 `total_cost_usd` 是本地
  估算，Python 侧已经把它从 usage 里摘掉，不进 Dwell 的成本统计。token 数照常统计。
- **缓存 TTL 钉在 1 小时。** 订阅在套餐额度内本来就是 1 小时，但一旦开始吃
  usage credits 就会掉到 5 分钟。聊天常隔几十分钟才继续，5 分钟基本等于每次
  都重建缓存，所以显式钉住（`PROMPT_CACHE_TTL`）。代价是缓存写入比 5 分钟贵些。
- **没做缓存保活。** 交接文件里说先不做。
