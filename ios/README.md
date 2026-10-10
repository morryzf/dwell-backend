# Dwell iOS

原生的聊天页、记忆、设置，加上侧边栏里的清单、日子、专注、书房、心跳、用量。其他页面（日记、收纳……）暂时还在网页里，侧边栏点了会用网页打开。

不需要 Mac，也不需要付费开发者账号：

- **编译**：GitHub Actions 在云端的 Mac 上编，产出一个没签名的 `Dwell.ipa`
- **签名 + 安装**：Windows 上的 [Sideloadly](https://sideloadly.io/)，用你自己的免费 Apple ID 签

## 第一次安装

1. **Windows 上装两样东西**
   - Sideloadly：官网下载安装
   - iTunes：**用苹果官网的安装包，别用 Microsoft Store 版本**（Sideloadly 靠它认手机）
2. **下载 ipa**
   - 打开仓库的 Actions → `iOS build` → 最近一次绿色的运行 → 页面底部 Artifacts 里的 `Dwell-ipa`
   - 下载下来是个 zip，解压得到 `Dwell.ipa`
3. **装到手机**
   - 数据线连上 iPhone，手机上点「信任这台电脑」
   - 打开 Sideloadly：把 `Dwell.ipa` 拖进去，填你的 Apple ID，点 Start
   - 中途会让你输入 Apple ID 密码，开了双重认证的话还会要验证码
4. **手机上的两步**（只有第一次需要）
   - 设置 → 通用 → VPN 与设备管理 → 点你的 Apple ID → 信任
   - 设置 → 隐私与安全性 → 开发者模式 → 打开，手机会重启
5. 打开 Dwell，填服务器地址（就是浏览器里打开 Dwell 的那个）、用户名、密码

## 每 7 天一次

免费签名 7 天后过期，过期了点开会直接闪退（数据都在服务器上，不会丢）。
连上电脑用 Sideloadly 把同一个 ipa 再装一遍就续上了。

## 通知（Bark）

免费签名的 app 收不到苹果的推送，所以通知借 [Bark](https://apps.apple.com/app/id1403753865) 来响：

1. App Store 装 Bark，打开后允许通知
2. Bark 首页「使用示例」下面点「复制」
3. Dwell app → 设置 → Bark 通知，粘进去保存，点「发一条试试」

之后他主动找你时手机会响，点通知回到 Dwell 里那个聊天（`dwell://open?chat=…`）。网页的通知照常，两边互不影响。

## 改了代码之后

推送到 GitHub 后，`ios/` 下有改动就会自动编译，几分钟后去 Actions 下载新的 ipa，
用 Sideloadly 覆盖安装即可，登录状态会保留。

编译失败时，那次运行的 Artifacts 里会有 `build-log`。

## 目录

| 文件 | 做什么 |
|---|---|
| `project.yml` | XcodeGen 工程描述；`.xcodeproj` 不进仓库，CI 上现生成 |
| `Dwell/API.swift` | 和后端说话：登录、聊天列表、消息、发送、长轮询 |
| `Dwell/ChatStore.swift` | 聊天页状态；处理 `/api/poll` 的流式事件 |
| `Dwell/ChatView.swift` | 聊天页：气泡、日期分隔、思考过程、长按菜单、编辑 |
| `Dwell/Theme.swift` | 网页那套皮：配色、方格纸底、圆按钮（数值量自网页的计算样式） |
| `Dwell/ChatControls.swift` | 输入框那一排的状态：语音、回复语言、指令、工具、模型；语音播放器 |
| `Dwell/ComposerSheets.swift` | ＋（拍照 / 相册 / 文件 / 回复语言）、指令、工具、切换模型这几个面板 |
| `Dwell/VoiceBar.swift` | 语音回复的语音条 |
| `Dwell/Images.swift` | 选图压缩（跟网页同样的尺寸）、记录里的图片显示和放大 |
| `Dwell/MemoryView.swift` | 记忆面板：记忆卡（搜索、筛选、编辑、共享、隐藏、归档）、待确认（采用、先修改、拆开、忽略）、看原文 |
| `Dwell/MemoryPanels.swift` | 记忆面板的「摘要」「设置」两页 |
| `Dwell/MemoryStore.swift`、`MemoryModels.swift` | 记忆面板的状态和数据，接口跟网页的记忆控制台同一套 |
| `Dwell/Sidebar.swift` | 侧边栏：助手切换、月相时间线、Recents（重命名 / 收纳 / 删除）、设置和日夜按钮 |
| `Dwell/Pages.swift` | 清单 / 日子 / 用量共用的页面架子；按北京时间算的「今天」 |
| `Dwell/TasksPage.swift` | 清单：Plum 的（勾、删、新增、定时、每天）和助手的活 |
| `Dwell/CalendarPage.swift` | 日子：月历、那天的事（每年、重要日子）、心情 |
| `Dwell/FocusPage.swift` | 专注 · 正计时（YPT 那种）：分科目计时、今天总时长和目标、每一段、最近 7 天；记录存服务器 |
| `Dwell/PomodoroPane.swift` | 专注 · 番茄钟：只在手机上计时，到点本地通知；做完一轮可记进某个科目 |
| `Dwell/LibraryPage.swift`、`LibraryReading.swift`、`LibraryModels.swift` | 书房：暗红屋子里的两层书架、上传 EPUB、收藏、怀表里的阅读安排；他的读书笔记、分享本（回他一句）、翻书（长按选字「划线」「写一句」，点划线看页边笔记） |
| `Dwell/HeartbeatPage.swift` | 心跳：开关、通知状态、消息送到哪间、醒来的节奏、现在叫醒一次（跟网页同一份设置） |
| `Dwell/UsagePage.swift` | 用量：Claude 订阅额度；OpenRouter 余额、今日 / 本周 / 本月、命中率、柱状图 |
| `Dwell/SettingsView.swift` | 设置首页 |
| `Dwell/BarkSettings.swift` | Bark 通知：填推送地址、点通知打开 app 还是网页、提醒方式、铃声、试发 |
| `Dwell/SettingsPages.swift` | 模型供应商、MCP 工具、重写规则、系统日志、导入 Kelivo |
| `Dwell/TTSSettings.swift` | 语音服务：两位各自的音色和朗读方式，共用的音色库和 ElevenLabs 连接 |
| `Dwell/Appearance.swift`、`AppearanceSettings.swift` | 日夜模式、聊天背景、消息玻璃效果（只存在手机上） |
| `Dwell/Fonts/` | 侧边栏用的 Ephesis 字体（SIL OFL 1.1，许可证在同目录） |
| `Dwell/LoginView.swift` | 登录 |

登录用的是网页同一套 cookie，不需要把 `DWELL_API_TOKEN` 放进手机。
