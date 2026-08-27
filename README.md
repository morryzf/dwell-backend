# dwell backend

我们家的后端。日记、待办、日历、悄悄话。

- 前端：`static/index.html`（来自 dwell-on-something，PolyForm Noncommercial）
- 数据：SQLite，落在 `DWELL_DB` 指定的路径
- 部署：Zeabur

## 环境变量

| 变量 | 用途 |
|---|---|
| `DWELL_USER` | 登录用户名 |
| `DWELL_PASSWORD` | 登录密码 |
| `DWELL_SECRET` | 会话签名密钥，随便一长串随机字符 |
| `DWELL_DB` | 数据库文件路径，默认 `./data/dwell.db` |
| `DWELL_API_TOKEN` | 给 AI 侧调用的令牌，绕过网页登录 |
| `OMBRE_MCP_URL` | 可选：Ombre Brain 的完整 MCP 地址，例如 `https://ombre.example.com/mcp` |
| `OMBRE_MCP_TOKEN` | 可选：Ombre Brain 的静态 MCP Token；只设置在 Zeabur 环境变量中 |
| `OMBRE_MCP_TIMEOUT` | 可选：读取记忆的超时秒数，默认 `12` |
| `VAPID_SUBJECT` | 可选：Web Push 联系地址，默认 `mailto:dwell@localhost` |

当 `OMBRE_MCP_URL` 与 `OMBRE_MCP_TOKEN` 都设置后，dwell 会在每次回复前通过
Ombre Brain 的 MCP 调用 `I` 和 `breath`，并将结果作为对话参考。记忆服务临时不可用时，
聊天会照常继续；dwell 不会自动把普通聊天写入 Ombre Brain。

## 心跳与手机通知

左侧的「心跳」可以选择主动消息送达的聊天，并分别设置白天、夜间检查间隔和每日上限。
每次检查时，所选聊天的模型会读取对话与已启用 MCP 的只读上下文，自行决定发消息或保持安静。

Web Push 的 VAPID 密钥会自动生成并保存在同一个 SQLite 数据库中，不需要手动配置。
iPhone 需要 iOS 16.4 或更新版本，并先把 Dwell 添加到主屏幕，再从主屏幕图标进入「心跳」开启通知。
Zeabur 必须为 `DWELL_DB` 所在目录挂载持久化存储；如果数据库被重建，手机需要重新开启一次通知。

## 本地跑

pip install -r requirements.txt
uvicorn app.main:app --reload
