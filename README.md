# dwell backend

我们家的后端。聊天、日记、待办、日历、悄悄话，也包括 Cloudy 的书房。

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

## 书房

左侧「书房」可以上传 EPUB。Dwell 会把书拆成章节，保存 Cloudy 的阅读位置；每次只读一小段，
不会一次读完整本。自动阅读默认关闭，可以在书房里逐个设置当天的准确阅读时间：写几个时间，
每天就安排几次；也可以临时让他现在去读一会儿，而临时阅读不会占用当天的定时次数。
一次阅读不会被 EPUB 的章节文件强行截断：遇到扉页、版权页等短内容时，会继续读取后续章节，
直到接近本次设置的原文 token 数或全书读完。

书房要选择一间聊天作为 Cloudy 的身份来源，并使用那间聊天已经正式采用的长期记忆；没有正式记忆时不会开始阅读。
每次阅读的原文默认约 4000 tokens，可在 1000–12000 之间调整。总输入超过约 32000 tokens 时会停止并提示，
而不是暗中删减内容。一次阅读最多输出 700 tokens，一次回信最多输出 500 tokens。

Cloudy 每次阅读都会留下用户可见的读书笔记。「想和小猫分享的」是另一册本子：Cloudy 有真正想分享的
想法或问题时会写一页，用户可以留言。下次定时或手动唤醒时，如果有新留言，会先进行一次独立的回信，
再进行一次独立的阅读；回信不会占用阅读次数。回信只携带当前这本书的全部读书笔记和当前分享页的完整对话，
不会混入其他书或其他分享页。未来的私人内容会另做为私人日记，不放在读书笔记里。

定时任务每分钟检查一次，并允许约两分钟的普通运行延迟；服务停机而错过的时间不会在恢复后补读。
书籍正文、进度、笔记和分享对话都保存在 `DWELL_DB` 中，因此该数据库必须使用持久化存储。

## 本地跑

pip install -r requirements.txt
uvicorn app.main:app --reload
