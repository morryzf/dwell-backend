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

## 本地跑

pip install -r requirements.txt
uvicorn app.main:app --reload
