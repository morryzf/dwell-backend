# Dwell iOS

原生聊天页。其他页面（日记、待办、日历、书房……）暂时还在网页里。

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
| `Dwell/Images.swift` | 选图压缩（跟网页同样的尺寸）、记录里的图片显示和放大 |
| `Dwell/MemoryView.swift` | 记忆面板：记忆卡（搜索、筛选、编辑、共享、隐藏、归档）、待确认（采用、先修改、拆开、忽略）、看原文 |
| `Dwell/MemoryPanels.swift` | 记忆面板的「摘要」「设置」两页 |
| `Dwell/MemoryStore.swift`、`MemoryModels.swift` | 记忆面板的状态和数据，接口跟网页的记忆控制台同一套 |
| `Dwell/ChatListView.swift` | 聊天列表 |
| `Dwell/LoginView.swift` | 登录 |

登录用的是网页同一套 cookie，不需要把 `DWELL_API_TOKEN` 放进手机。
