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
| `PROMPT_CACHE_TTL` | `1h` | 缓存保留时长，`5m` 或 `1h`；留空＝跟随 Claude Code 默认 |
| `DISABLED_TOOLS` | 见下 | 移出上下文的内置工具，逗号分隔；留空＝一个都不禁 |
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
  "max_turns": 1,
  "session_id": "dwell-chat:xxx"
}
```

响应是 SSE，每行一个事件，最后以 `data: [DONE]` 收尾：

```
data: {"type":"text","text":"你"}
data: {"type":"thinking","thinking":"……"}
data: {"type":"usage","usage":{"input_tokens":120,"output_tokens":48,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
data: {"type":"error","message":"……"}
data: [DONE]
```

`usage` 只在 `result` 消息上取——Agent SDK 每步 assistant 消息上的
`output_tokens` 是占位值，不是真实数字。

`session` 事件带回 Claude Code 的会话 id。Dwell 把它存在 settings 表的
`agent_sdk_session:<聊天键>` 下，下一轮作为 `resume` 传回来。桥接自己不存任何状态。

## 内置工具

Claude Code 自带 25 个工具（Read / Write / Bash / WebSearch…），全是给改代码用的，
光工具说明就占一万多 token，而这条通道只是聊天。所以默认把它们用
`disallowedTools` 移出上下文——传裸名字是移除，不只是禁止调用。

想放回来：`DISABLED_TOOLS=` （留空）。想只留几个：把不要的列进去就行。

MCP 工具名字长这样 `mcp__<服务>__<工具>`，不受这个清单影响。

## MCP（Ombre Brain 等）

Dwell 自己的 function tools 没法直接交给 Agent SDK，所以走这条通道时工具由
Claude Code 那边的 MCP 提供。把 Ombre 配进来：

```bash
export MCP_SERVERS_JSON='{"ombre":{"type":"http","url":"https://……/mcp","headers":{"Authorization":"Bearer ……"}}}'
```

配好之后 Dwell 侧这条聊天带上工具时会把 `max_turns` 放宽到 8，让 Claude Code
有余量跑完工具再收尾。

> 注意：这跟 Dwell 原本的工具回路不是同一条。走这个供应商类型时，Dwell 内置的
> 搜索 / 抓取 / 房间工具不会生效，只有这里配进来的 MCP 工具会。

## 已知取舍

- **多轮靠续会话，回退时才铺平。** Agent SDK 收的是一句 prompt，不是 role 数组。
  平时 Python 侧带上 `resume`，Claude Code 自己记着之前说过什么，这轮只递新的
  那一句；只有在会话对不上的时候，才把历史渲染成 `<对话记录>` 块重讲一遍。
  对不上的情况有四种：换了模型、system 变了（记忆卡更新）、历史被改过或删过、
  以及这轮没有新的用户发言（重新生成）。续会话失败会自动重来一次，用户无感。
- **`max_tokens` 不是硬上限。** Agent SDK 没有这个参数，Dwell 只能把它写成
  system 里的一句长度要求。
- **成本数字不上报。** 订阅额度不按量计费，Agent SDK 的 `total_cost_usd` 是本地
  估算，Python 侧已经把它从 usage 里摘掉，不进 Dwell 的成本统计。token 数照常统计。
- **缓存 TTL 钉在 1 小时。** 订阅在套餐额度内本来就是 1 小时，但一旦开始吃
  usage credits 就会掉到 5 分钟。聊天常隔几十分钟才继续，5 分钟基本等于每次
  都重建缓存，所以显式钉住（`PROMPT_CACHE_TTL`）。代价是缓存写入比 5 分钟贵些。
- **没做缓存保活。** 交接文件里说先不做。
