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

// Dwell 每轮可以带上自己的 MCP（家里的待办、日记、日历），由 Claude Code 回调
// Dwell。只收远程的 http / sse：stdio 会在这台机器上起进程，不能让一个请求决定。
const REMOTE_MCP_TYPES = new Set(["http", "sse"]);

function requestMcpServers(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const servers = {};
  for (const [name, config] of Object.entries(raw)) {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(name)) continue;
    if (!config || typeof config !== "object") continue;
    const type = String(config.type || "");
    const url = String(config.url || "");
    if (!REMOTE_MCP_TYPES.has(type) || !/^https?:\/\//.test(url)) continue;
    const headers = {};
    if (config.headers && typeof config.headers === "object") {
      for (const [key, value] of Object.entries(config.headers)) {
        headers[String(key)] = String(value);
      }
    }
    servers[name] = { type, url, headers };
  }
  return servers;
}

// —— 订阅用量 ——
//
// 聊天时 Claude Code 会顺手报一下额度用到哪了（rate_limit_event）。记下每个
// 窗口最近一次的数字：官方用量接口没回应时，用量页至少还有这个可看。
const observedLimits = {};

function rememberRateLimit(info) {
  if (!info || typeof info !== "object") return;
  const key = String(info.rateLimitType || "unknown");
  observedLimits[key] = {
    status: info.status || "",
    utilization: typeof info.utilization === "number" ? info.utilization : null,
    resets_at: typeof info.resetsAt === "number" ? info.resetsAt : null,
    observed_at: Math.floor(Date.now() / 1000),
  };
}

// 用量页一打开就要一次，刷新按钮也会连点；结果留一分钟，同一时刻只问一次。
const USAGE_CACHE_MS = 60 * 1000;
const USAGE_TIMEOUT_MS = 45 * 1000;
let usageCache = null;
let usageInflight = null;

// 读 /usage 背后的那份数据：起一个不发消息的 Claude Code 会话，问完就关。
// 不占聊天的并发槽位——它只读一下账号状态，几秒钟的事，不该排在一轮长回复后面。
async function fetchPlanUsage(env) {
  let finish;
  const idle = new Promise((resolve) => { finish = resolve; });
  async function* noPrompt() { await idle; }
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), USAGE_TIMEOUT_MS);
  const q = query({
    prompt: noPrompt(),
    options: {
      model: DEFAULT_MODEL, env, abortController: abort,
      settingSources: [], tools: [], maxTurns: 1,
    },
  });
  // 消息流要有人读着，控制请求的回应才送得回来。
  (async () => { try { for await (const _ of q) { /* 不发消息，也就没有要处理的 */ } } catch { /* 关掉时会抛 */ } })();
  try {
    if (typeof q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET !== "function") {
      throw new Error("桥接里的 Agent SDK 版本太旧，读不了订阅用量；在 bridge 目录里 npm install 一下");
    }
    const [usage, account] = await Promise.all([
      q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true }),
      q.accountInfo().catch(() => null),
    ]);
    return { usage, account };
  } finally {
    clearTimeout(timer);
    finish();
    try { q.close(); } catch { /* 已经结束 */ }
  }
}

function readUsage({ usage, account }) {
  return {
    available: Boolean(usage?.rate_limits_available && usage?.rate_limits),
    subscription_type: usage?.subscription_type || account?.subscriptionType || null,
    rate_limits: usage?.rate_limits || null,
    account: account ? { email: account.email || "", organization: account.organization || "" } : null,
    token_source: account?.tokenSource || "",
  };
}

// setup-token 生成的 CLAUDE_CODE_OAUTH_TOKEN 只能聊天，没有读取账号用量的权限；
// 而只要它在环境里，Claude Code 就优先用它，不看 /login 存下的登录。
// 所以带着它拿不到数字时，去掉它、用 /login 的登录再问一次。聊天照旧用它。
function withoutEnvToken() {
  const env = { ...CHILD_ENV };
  delete env.CLAUDE_CODE_OAUTH_TOKEN;
  return env;
}

async function planUsage(force) {
  if (!force && usageCache && Date.now() - usageCache.at < USAGE_CACHE_MS) return usageCache.body;
  if (!usageInflight) {
    usageInflight = (async () => {
      const body = { ok: true, fetched_at: Math.floor(Date.now() / 1000) };
      const tried = [];
      try {
        let result = readUsage(await fetchPlanUsage(CHILD_ENV));
        tried.push(result.token_source || "默认登录");
        if (!result.available && CHILD_ENV.CLAUDE_CODE_OAUTH_TOKEN) {
          try {
            const second = readUsage(await fetchPlanUsage(withoutEnvToken()));
            tried.push(second.token_source || "/login 的登录");
            if (second.available) result = second;
          } catch (error) {
            tried.push(`/login 的登录（${String(error?.message || error).slice(0, 120)}）`);
          }
        }
        Object.assign(body, result);
        if (!body.available) {
          body.error = "官方用量接口没有给出额度：试过的登录方式（" + tried.join("、") + "）都没有读取用量的权限。"
            + (CHILD_ENV.CLAUDE_CODE_OAUTH_TOKEN
              ? "桥接环境里的 CLAUDE_CODE_OAUTH_TOKEN 是 setup-token 生成的，只能聊天；要看额度，得用运行桥接的那个系统用户在 claude 里 /login 一次。"
              : "");
        }
      } catch (error) {
        body.available = false;
        body.error = String(error?.message || error);
      }
      body.observed = { ...observedLimits };
      usageCache = { at: Date.now(), body };
      return body;
    })().finally(() => { usageInflight = null; });
  }
  return usageInflight;
}

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

// —— 重写规则 ——
//
// 撞到这些话就把这一轮打回去，让它重说一遍，并告诉它为什么。规则每轮都由
// Dwell 传过来，改完立刻生效——桥接自己不存，也不认识它们从哪儿来。
//
// 只有这条通道能做：它靠 Claude Code 的 Stop 钩子，模型说完、真要收尾之前
// 还能拦一次。HTTP API 那条路上回复吐完就结束了，没有这个位置。

function normalizeRules(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((rule) => ({
      phrases: (Array.isArray(rule?.phrases) ? rule.phrases : [])
        .map((phrase) => String(phrase || "").trim())
        .filter(Boolean),
      reason: String(rule?.reason || "").trim(),
    }))
    // 没有触发词的规则会拦下每一句话；没有理由的规则它不知道往哪儿改。
    .filter((rule) => rule.phrases.length && rule.reason);
}

function firstBreach(rules, text) {
  const body = String(text || "");
  if (!body.trim()) return null;
  const folded = body.toLowerCase();
  for (const rule of rules) {
    const hit = rule.phrases.filter((phrase) => folded.includes(phrase.toLowerCase()));
    if (hit.length) return { rule, hit };
  }
  return null;
}

function blockReason({ rule, hit }) {
  const quoted = hit.map((phrase) => `「${phrase}」`).join("");
  return `你刚才那一版里出现了${quoted}。${rule.reason}\n`
    + "重新说一遍。不要提这次打回，"
    + "也不要解释，直接给新的那一版。";
}

// 汉字、假名、谚文。英文回复里偶尔出现的符号、emoji 不算。
const CJK_RE = /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff]/;

function hasCjk(text) {
  return CJK_RE.test(String(text || ""));
}

const ENGLISH_ONLY_REASON = "This reply will be read aloud by an English voice, "
  + "but your last version contained Chinese characters. Say it again entirely in English, "
  + "with no Chinese at all. Don't mention the redo or explain; just give the new version.";

// 这间聊天选了回复语言时的兜底。口径和 app/llm_client.py 的 reply_language_ok 一致：
// 代码和链接不算；en 最多容得下三个汉字，zh 要以汉字为主。
const HAN_G = /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff]/g;
const LATIN_G = /[A-Za-z]/g;
const CODE_OR_LINK_G = /```[\s\S]*?```|`[^`]*`|https?:\/\/\S+/g;

function replyLanguageOk(text, language) {
  if (language !== "en" && language !== "zh") return true;
  const body = String(text || "").replace(CODE_OR_LINK_G, " ");
  const han = (body.match(HAN_G) || []).length;
  const latin = (body.match(LATIN_G) || []).length;
  if (!han && !latin) return true;
  if (language === "en") return han <= 3 && latin >= han * 5 && latin > 0;
  return han > 0 && han * 4 >= latin;
}

const LANGUAGE_REASONS = {
  zh: "你刚才那一版不是中文。用中文重新说一遍。不要提这次打回，也不要解释，直接给新的那一版。",
  en: "Your last version wasn't in English. Say it again in English. "
    + "Don't mention the redo or explain; just give the new version.",
};
const LANGUAGE_NOTICES = { zh: "打回重说：回复不是中文", en: "打回重说：回复不是英文" };

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
  const images = Array.isArray(request.images) ? request.images : [];
  // 只发一张图、一个字都不写，也是一条消息。
  if (!prompt && !images.length) {
    writeEvent(res, { type: "error", message: "这一轮没有任何内容" });
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
  // 同名时以这一轮带来的为准：通行证每轮都换。
  const mcpServers = { ...MCP_SERVERS, ...requestMcpServers(request.mcp_servers) };
  if (Object.keys(mcpServers).length) {
    options.mcpServers = mcpServers;
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

  const rules = normalizeRules(request.rewrite_rules);
  // 语音回复只能说英文：中文会被英文音色念得一塌糊涂。提示里已经要求过，
  // 这里是兜底——模型偶尔还是会被前面满屏的中文带回去。
  const requireEnglish = request.require_english === true;
  // 语音优先：要念出来的那一轮只认英文，不再看这间聊天选的语言。
  const requireLanguage = requireEnglish ? "" : String(request.require_language || "");
  const checkLanguage = requireLanguage === "zh" || requireLanguage === "en";
  if (rules.length || requireEnglish || checkLanguage) {
    // 打回之后它还要再说一遍，那是多出来的一轮——不放宽就会撞上 maxTurns。
    options.maxTurns += 1;
    options.hooks = {
      Stop: [{
        hooks: [async (input) => {
          // 已经打回过一次了。再拦下去就没完没了——它可能根本绕不开那句话，
          // 而一句都说不出来比说了句现成话更糟。
          if (input.stop_hook_active) return {};
          const text = input.last_assistant_message || "";
          let notice = "";
          let reason = "";
          if (requireEnglish && hasCjk(text)) {
            notice = "打回重说：语音回复里出现了中文";
            reason = ENGLISH_ONLY_REASON;
          } else if (checkLanguage && !replyLanguageOk(text, requireLanguage)) {
            notice = LANGUAGE_NOTICES[requireLanguage];
            reason = LANGUAGE_REASONS[requireLanguage];
          } else {
            const breach = firstBreach(rules, text);
            if (!breach) return {};
            notice = `打回重说：撞到了${breach.hit.map((phrase) => `「${phrase}」`).join("")}`;
            reason = blockReason(breach);
          }
          // 记一笔，让她知道这一版是重说的；这不是回复的一部分，走思考面板。
          writeEvent(res, { type: "notice", message: notice });
          // 已经吐出去的那一版要当场抹掉，否则两版首尾相接，像它精神分裂。
          writeEvent(res, { type: "reset" });
          return { decision: "block", reason };
        }],
      }],
    };
  }

  try {
    await streamTurn(res, turnInput(prompt, images), options, includeThinking);
  } catch (error) {
    if (timedOut) {
      throw new Error(`这一轮超过 ${Math.round(TURN_TIMEOUT_MS / 1000)} 秒没跑完，已中止`);
    }
    throw error;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

// 带图的一轮只能走流式输入：字符串 prompt 没有地方放图片块。
// 图在前、字在后；空的文字块会被上游拒绝，所以没写字就只发图。
function turnInput(prompt, images) {
  const blocks = (Array.isArray(images) ? images : [])
    .filter((source) => source && typeof source === "object")
    .map((source) => ({ type: "image", source }));
  if (!blocks.length) return prompt;
  if (prompt) blocks.push({ type: "text", text: prompt });
  return (async function* () {
    yield {
      type: "user",
      message: { role: "user", content: blocks },
      parent_tool_use_id: null,
      session_id: "",
    };
  })();
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

    if (message.type === "rate_limit_event") {
      rememberRateLimit(message.rate_limit_info);
      continue;
    }

    // 会话被压缩过：早先递进去的记忆卡可能已经被总结掉了，上层据此重新记账。
    if (message.type === "system" && message.subtype === "compact_boundary") {
      writeEvent(res, { type: "compacted" });
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

  if (req.method === "GET" && req.url.split("?")[0] === "/v1/usage") {
    if (!authorized(req)) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }
    const force = /[?&]refresh=1\b/.test(req.url);
    sendJson(res, 200, await planUsage(force));
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
  if (Object.keys(MCP_SERVERS).length) {
    console.log(`[bridge] MCP：${Object.keys(MCP_SERVERS).join(", ")}`);
  }
});
