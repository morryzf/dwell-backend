// Dwell 的 Claude Agent SDK 桥接服务。
//
// Dwell 后端是 Python，Agent SDK 是 Node.js 包，这个小服务是中间那一层：
// 收一段 prompt，交给本机的 Claude Code，把文字流原样吐回去。
//
// 它刻意不认识 Dwell：没有数据库、没有会话状态、没有记忆逻辑。
// 历史怎么铺平、system 怎么拼，都由 Python 那边（app/agent_sdk_client.py）决定。

import { createServer } from "node:http";
import { readFileSync } from "node:fs";

import { query } from "@anthropic-ai/claude-agent-sdk";

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || "127.0.0.1";
const BRIDGE_TOKEN = (process.env.BRIDGE_TOKEN || "").trim();
const DEFAULT_MODEL = (process.env.CLAUDE_AGENT_MODEL || "sonnet").trim();
// 2 核 4G 上一个 Claude Code 子进程就够吃了，默认串行。
const MAX_CONCURRENCY = Math.max(1, Number(process.env.MAX_CONCURRENCY || 1));
const MAX_BODY_BYTES = 4 * 1024 * 1024;
// 并发上限是 1，一轮卡住就等于整个聊天卡住——而冷启动可能接近三分钟没有任何
// 事件，所以不能靠「有没有动静」判断，只能给一轮一个硬上限。0＝不限。
const TURN_TIMEOUT_MS = Math.max(0, Number(process.env.TURN_TIMEOUT_MS || 15 * 60 * 1000));

// Claude Code 自带的工具全是给改代码用的，光说明就占一万多 token，而这条
// 通道只是聊天。所以用白名单而不是黑名单：黑名单挡不住 CLI 以后新增的工具，
// 它们会悄悄溜回上下文里，而我们不会发现。
//
// 留空＝一件都不给；"preset"＝原样给 Claude Code 的整套；其余按逗号分隔取名字。
// MCP 工具不受这里影响（它们走 mcpServers），但挂了很多 MCP 工具时要把
// ToolSearch 加回来——CLI 会把一部分 schema 延迟加载，靠它才取得到。
const BUILTIN_TOOLS_RAW = (process.env.BUILTIN_TOOLS ?? "").trim();
const BUILTIN_TOOLS = BUILTIN_TOOLS_RAW === "preset"
  ? { type: "preset", preset: "claude_code" }
  : BUILTIN_TOOLS_RAW.split(/[,\s]+/).map((name) => name.trim()).filter(Boolean);

// 子进程里留着这两个变量就会走按量计费的 API，而不是订阅额度。
const CHILD_ENV = { ...process.env };
delete CHILD_ENV.ANTHROPIC_API_KEY;
delete CHILD_ENV.ANTHROPIC_AUTH_TOKEN;

// harness 自带的记忆索引（MEMORY.md）是给终端窗口用的工程笔记，聊天用不上，
// 实测能占好几千 token。
CHILD_ENV.CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1";

// 订阅在套餐额度内本来就是 1 小时，但一开始吃 usage credits 就会掉到 5 分钟。
// 聊天经常隔几十分钟才继续，掉到 5 分钟等于每次都重新建缓存，所以显式钉住。
const PROMPT_CACHE_TTL = (process.env.PROMPT_CACHE_TTL || "1h").trim();
if (PROMPT_CACHE_TTL) {
  CHILD_ENV.CLAUDE_CODE_PROMPT_CACHE_TTL = PROMPT_CACHE_TTL;
}

function loadMcpServers() {
  const inline = (process.env.MCP_SERVERS_JSON || "").trim();
  const file = (process.env.MCP_SERVERS_FILE || "").trim();
  const raw = inline || (file ? readFileSync(file, "utf8") : "");
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (error) {
    console.error(`[bridge] MCP 配置无法解析，已忽略：${error.message}`);
    return {};
  }
}

const MCP_SERVERS = loadMcpServers();
const HAS_MCP = Object.keys(MCP_SERVERS).length > 0;

let running = 0;
const waiting = [];

function acquire() {
  if (running < MAX_CONCURRENCY) {
    running += 1;
    return Promise.resolve();
  }
  return new Promise((resolve) => waiting.push(resolve));
}

function release() {
  const next = waiting.shift();
  if (next) {
    next();
    return;
  }
  running = Math.max(0, running - 1);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("请求体过大"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function authorized(req) {
  if (!BRIDGE_TOKEN) return true;
  const header = String(req.headers.authorization || "");
  return header === `Bearer ${BRIDGE_TOKEN}`;
}

function writeEvent(res, event) {
  res.write(`data: ${JSON.stringify(event)}\n\n`);
}

// Agent SDK 的 usage 已经是 Anthropic 的形状，Python 那边按原样解析。
const EFFORT_LEVELS = new Set(["low", "medium", "high", "xhigh", "max"]);
// 关掉 thinking 时，部分模型不接受高档 effort，会直接 400。挡在这儿。
const EFFORT_WITHOUT_THINKING = new Set(["low", "medium", "high"]);

function usagePayload(usage) {
  if (!usage || typeof usage !== "object") return null;
  return {
    input_tokens: usage.input_tokens || 0,
    output_tokens: usage.output_tokens || 0,
    cache_read_input_tokens: usage.cache_read_input_tokens || 0,
    cache_creation_input_tokens: usage.cache_creation_input_tokens || 0,
  };
}

async function runChat(res, request) {
  const prompt = String(request.prompt || "");
  if (!prompt) {
    writeEvent(res, { type: "error", message: "prompt 不能为空" });
    return;
  }

  const abort = new AbortController();
  let timedOut = false;
  const timer = TURN_TIMEOUT_MS
    ? setTimeout(() => { timedOut = true; abort.abort(); }, TURN_TIMEOUT_MS)
    : null;
  // Dwell 那边放弃了就没必要继续烧着这个槽位。
  res.on("close", () => abort.abort());

  const options = {
    model: String(request.model || DEFAULT_MODEL),
    abortController: abort,
    env: CHILD_ENV,
    includePartialMessages: true,
    // 空数组＝不读 VPS 上的 CLAUDE.md、settings 和 output style：
    // 聊天的人格由 Dwell 的 system prompt 定，不该被这台机器的项目配置改写。
    settingSources: [],
    maxTurns: Math.max(1, Number(request.max_turns || 1)),
    canUseTool: async (_name, input) => ({ behavior: "allow", updatedInput: input }),
  };

  const system = String(request.system || "");
  if (system) {
    options.systemPrompt = system;
  }
  // 续上一次的会话：Claude Code 自己记着之前说过什么，这轮只递新的那一句。
  const resume = String(request.resume || "");
  if (resume) {
    options.resume = resume;
  }
  if (HAS_MCP) {
    options.mcpServers = MCP_SERVERS;
  }
  options.tools = BUILTIN_TOOLS;

  const includeThinking = request.include_thinking !== false;
  // Dwell 的「显示思考」开关本来就是改请求，不是只藏起来，所以这里真的关掉它。
  // 开着时要显式要 summarized：当前模型默认是 omitted，thinking 会是空的。
  options.thinking = includeThinking
    ? { type: "adaptive", display: "summarized" }
    : { type: "disabled" };

  const effort = String(request.effort || "").trim();
  if (EFFORT_LEVELS.has(effort)
      && (includeThinking || EFFORT_WITHOUT_THINKING.has(effort))) {
    options.effort = effort;
  }
  try {
    await streamTurn(res, prompt, options, includeThinking);
  } catch (error) {
    if (timedOut) {
      throw new Error(`这一轮超过 ${Math.round(TURN_TIMEOUT_MS / 1000)} 秒没跑完，已中止`);
    }
    throw error;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function streamTurn(res, prompt, options, includeThinking) {
  let sawResultUsage = false;
  let sentSession = "";

  // 会话 id 要在正文之前送出去，这样出错时上层也知道该不该清掉旧状态。
  const reportSession = (id) => {
    const sid = String(id || "");
    if (sid && sid !== sentSession) {
      sentSession = sid;
      writeEvent(res, { type: "session", session_id: sid });
    }
  };

  for await (const message of query({ prompt, options })) {
    if (message.session_id) {
      reportSession(message.session_id);
    }

    if (message.type === "stream_event") {
      const delta = message.event?.delta;
      if (delta?.type === "text_delta" && delta.text) {
        writeEvent(res, { type: "text", text: delta.text });
      } else if (includeThinking && delta?.type === "thinking_delta" && delta.thinking) {
        writeEvent(res, { type: "thinking", thinking: delta.thinking });
      }
      continue;
    }

    // 限流和上游错误：不转发的话，用户只看到长时间没反应，不知道是卡了还是在排队。
    if (message.type === "system" && message.subtype === "api_retry") {
      const seconds = Math.round(Number(message.retry_delay_ms || 0) / 1000);
      writeEvent(res, {
        type: "notice",
        message: `上游暂时不可用（${message.error || message.error_status || "未知原因"}）`
          + `，第 ${message.attempt || 1} 次重试${seconds ? `，等 ${seconds} 秒` : ""}`,
      });
      continue;
    }

    if (message.type === "result") {
      // 每步 assistant 消息上的 output_tokens 是占位值，真实数字只在 result 上。
      const usage = usagePayload(message.usage);
      if (usage) {
        sawResultUsage = true;
        writeEvent(res, { type: "usage", usage });
      }
      if (message.is_error) {
        writeEvent(res, {
          type: "error",
          message: String(message.result || message.subtype || "Claude Code 未能完成这次回复"),
        });
      }
    }
  }

  if (!sawResultUsage) {
    console.warn("[bridge] 这次没有拿到 result usage");
  }
}

const server = createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    sendJson(res, 200, {
      ok: true,
      model: DEFAULT_MODEL,
      mcp_servers: Object.keys(MCP_SERVERS),
      max_concurrency: MAX_CONCURRENCY,
      running,
      queued: waiting.length,
    });
    return;
  }

  if (req.method !== "POST" || req.url !== "/v1/chat/stream") {
    sendJson(res, 404, { ok: false, error: "not found" });
    return;
  }
  if (!authorized(req)) {
    sendJson(res, 401, { ok: false, error: "unauthorized" });
    return;
  }

  let request;
  try {
    request = JSON.parse(await readBody(req));
  } catch (error) {
    sendJson(res, 400, { ok: false, error: `请求解析失败：${error.message}` });
    return;
  }

  await acquire();
  res.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });

  try {
    await runChat(res, request);
  } catch (error) {
    console.error("[bridge] 调用失败", error);
    // 响应头已经发出去了，错误只能作为一个事件送达。
    writeEvent(res, { type: "error", message: String(error?.message || error) });
  } finally {
    release();
    res.write("data: [DONE]\n\n");
    res.end();
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[bridge] 监听 http://${HOST}:${PORT}`);
  console.log(`[bridge] 默认模型 ${DEFAULT_MODEL}，并发上限 ${MAX_CONCURRENCY}`);
  console.log(`[bridge] 门禁 token：${BRIDGE_TOKEN ? "已启用" : "未设置"}`);
  console.log(`[bridge] 缓存 TTL ${PROMPT_CACHE_TTL || "跟随默认"}`);
  console.log(`[bridge] 内置工具 ${
    Array.isArray(BUILTIN_TOOLS)
      ? (BUILTIN_TOOLS.length ? BUILTIN_TOOLS.join(",") : "一件都不给")
      : "Claude Code 全套"
  }`);
  console.log(`[bridge] 单轮上限 ${TURN_TIMEOUT_MS ? Math.round(TURN_TIMEOUT_MS / 1000) + " 秒" : "不限"}`);
  if (HAS_MCP) {
    console.log(`[bridge] MCP：${Object.keys(MCP_SERVERS).join(", ")}`);
  }
});
