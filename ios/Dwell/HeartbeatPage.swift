import SwiftUI

/// 「心跳」，照网页的 #heartbeatSheet：他按这个节奏醒来，读一读那间聊天，再自己决定要不要说话。
/// 设置存在服务器上，跟网页是同一份；按侧栏当前选中的那位助手各存各的。
struct HeartbeatPage: View {
    @EnvironmentObject private var store: ChatStore

    @State private var on = false
    @State private var dayMinutes = 120
    @State private var nightMinutes = 300
    @State private var dayStart = 9
    @State private var dayEnd = 24
    @State private var dailyLimit = 4
    @State private var count = 0
    @State private var lastStatus = "idle"
    @State private var lastError = ""
    @State private var lastSent = 0
    @State private var bark = false
    @State private var webPush = 0
    @State private var targetID = ""
    @State private var chats: [ChatSummary] = []
    @State private var loaded = false
    @State private var message = ""
    @State private var messageBad = false
    @State private var waking = false
    @State private var saveTask: Task<Void, Never>?
    /// 服务器上现在存着的节奏；跟它一样就不用存（读进来的那次也不会触发保存）。
    @State private var savedRhythm: [Int] = []
    @State private var pickingTarget = false
    @State private var showBark = false

    private var name: String { store.assistant?.name ?? "Cloudy" }

    var body: some View {
        PageScaffold(title: "心跳", subtitle: "让他偶尔想起你") {
            Text("\(name) 会按这个节奏醒来，读一读所选聊天的上下文，再自己决定要不要发消息。")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.dim)
                .lineSpacing(3)
                .padding(.top, 6)

            PageSection(text: "连接")
            VStack(spacing: 9) {
                PageRow {
                    Image(systemName: "alarm").foregroundStyle(Theme.dim)
                    Toggle("允许主动消息", isOn: Binding(get: { on }, set: { value in
                        on = value
                        Task { await save(["on": value], note: value ? "心跳开了——他会按这个节奏醒来看看" : "心跳关了，他不会主动发消息") }
                    }))
                    .tint(Theme.send)
                    .disabled(!loaded)
                }
                Button { showBark = true } label: {
                    PageRow {
                        Image(systemName: "bell").foregroundStyle(Theme.dim)
                        Text("手机通知").foregroundStyle(Theme.text)
                        Spacer()
                        Text(notifyText).foregroundStyle(Theme.dim)
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .buttonStyle(.plain)
                Button { pickingTarget = true } label: {
                    PageRow {
                        Image(systemName: "bubble.left").foregroundStyle(Theme.dim)
                        Text("消息送到").foregroundStyle(Theme.text)
                        Spacer()
                        Text(targetName).foregroundStyle(Theme.dim).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 15))

            PageSection(text: "醒来的节奏")
            VStack(spacing: 9) {
                stepper("白天每隔", value: $dayMinutes, range: 15...1440, step: 15, unit: "分钟")
                stepper("夜间每隔", value: $nightMinutes, range: 15...1440, step: 15, unit: "分钟")
                stepper("白天开始", value: $dayStart, range: 0...23, step: 1, unit: "点")
                stepper("白天结束", value: $dayEnd, range: 1...24, step: 1, unit: "点")
                stepper("一天最多主动发", value: $dailyLimit, range: 1...24, step: 1, unit: "条")
            }
            .disabled(!loaded)

            PageSection(text: "现在")
            Button {
                Task { await wake() }
            } label: {
                PageRow {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Theme.dim)
                    Text("现在让他醒一次").foregroundStyle(Theme.text)
                    Spacer()
                    Text(waking ? "正在醒来…" : "让他自己判断要不要说话")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim)
                }
                .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(waking || !loaded)

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(messageBad ? MemoryStyle.danger : Theme.dim)
                    .padding(.top, 12)
                    .padding(.horizontal, 4)
            }

            Text(statusText)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.dim.opacity(0.08)))
                .padding(.top, 18)
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: rhythm) { _, _ in scheduleSave() }
        .sheet(isPresented: $pickingTarget) { targetPicker }
        .sheet(isPresented: $showBark, onDismiss: { Task { await load() } }) {
            NavigationStack {
                BarkSettings()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("好") { showBark = false }
                        }
                    }
            }
        }
    }

    // MARK: - 小零件

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                         step: Int, unit: String) -> some View {
        PageRow {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.text)
            Spacer()
            Text("\(value.wrappedValue) \(unit)")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.accent)
            Stepper(title, value: value, in: range, step: step).labelsHidden()
        }
    }

    private var notifyText: String {
        switch (bark, webPush > 0) {
        case (true, true): return "Bark · 网页"
        case (true, false): return "Bark"
        case (false, true): return "只有网页"
        default: return "还没开"
        }
    }

    private var targetName: String {
        guard !targetID.isEmpty else { return "还没选" }
        guard let chat = chats.first(where: { $0.id == targetID }) else { return loaded ? "不在列表里" : "…" }
        return chat.name.isEmpty ? "新对话" : chat.name
    }

    private var statusText: String {
        guard loaded else { return "正在听心跳…" }
        let labels = [
            "idle": "还没有进行过心跳", "waiting": "正在等下一次合适的时间", "queued": "已经叫他了，马上会醒",
            "thinking": "\(name) 正在读上下文", "quiet": "上次醒来后，他觉得此刻不该打扰",
            "duplicate": "这次想说的话和刚才重复了，他决定不再发一遍",
            "sent": "上次醒来后，他主动发了一条消息", "error": "上次心跳没有成功",
            "daily_limit": "今天已经达到主动消息上限", "chat_busy": "所选聊天正在回复，心跳稍后再来",
            "no_target": "还没有选择接收主动消息的聊天", "no_user_message": "这间聊天还没有你的消息",
            "awaiting_reply": "上一条消息还在等 \(name) 正常回复，心跳不会抢答", "off": "心跳目前关着",
        ]
        var text = labels[lastStatus] ?? labels["idle"]!
        if lastStatus == "error" && !lastError.isEmpty { text += "：" + lastError }
        if lastSent > 0 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M/d HH:mm"
            text += " · " + f.string(from: Date(timeIntervalSince1970: TimeInterval(lastSent)))
        }
        return text + "\n今天已经主动发送 \(count) / \(dailyLimit) 条"
    }

    private var targetPicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chats) { chat in
                        Button {
                            Task { await setTarget(chat.id) }
                        } label: {
                            HStack {
                                Text(chat.name.isEmpty ? "新对话" : chat.name).foregroundStyle(Theme.text)
                                Spacer()
                                if chat.id == targetID {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                } else if chat.current {
                                    Text("当前聊天").font(.system(size: 13)).foregroundStyle(Theme.dim)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("主动说话时，永远只会送到这里。新建的其他聊天不会改变这里；删除当前目标时，会切到最近创建的聊天。")
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle("接收主动消息的窗口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pickingTarget = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 读写

    /// 五个节奏数字合成一个，任何一个变了就存。
    private var rhythm: [Int] { [dayMinutes, nightMinutes, dayStart, dayEnd, dailyLimit] }

    private func apply(_ json: [String: Any]) {
        on = json["on"] as? Bool ?? false
        let config = json["config"] as? [String: Any] ?? [:]
        dayMinutes = config["day_minutes"] as? Int ?? dayMinutes
        nightMinutes = config["night_minutes"] as? Int ?? nightMinutes
        dayStart = config["day_start"] as? Int ?? dayStart
        dayEnd = config["day_end"] as? Int ?? dayEnd
        dailyLimit = config["daily_limit"] as? Int ?? dailyLimit
        count = json["count"] as? Int ?? 0
        lastStatus = json["last_status"] as? String ?? "idle"
        lastError = json["last_error"] as? String ?? ""
        lastSent = json["last_sent"] as? Int ?? 0
        bark = json["bark"] as? Bool ?? false
        webPush = json["push_subscriptions"] as? Int ?? 0
        targetID = (json["target"] as? [String: Any])?["chat_id"] as? String ?? ""
        savedRhythm = rhythm
    }

    private func load() async {
        do {
            let json = try await API.shared.request("GET", "api/heartbeat")
            chats = try await API.shared.chats(scope: "live")
            saveTask?.cancel()
            apply(json)
            loaded = true
        } catch {
            message = (error as? APIError)?.message ?? "心跳状态没有拿到"
            messageBad = true
        }
    }

    private func scheduleSave() {
        guard loaded, rhythm != savedRhythm else { return }
        saveTask?.cancel()
        let body: [String: Any] = ["day_minutes": dayMinutes, "night_minutes": nightMinutes,
                                   "day_start": dayStart, "day_end": dayEnd, "daily_limit": dailyLimit]
        // 连按加减号时等手停下来再存。
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await save(body, note: "节奏保存好了")
        }
    }

    private func save(_ body: [String: Any], note: String) async {
        var body = body
        body["assistant"] = store.assistant?.id ?? ""
        do {
            let json = try await API.shared.request("POST", "api/heartbeat", body: body)
            apply(json)
            message = note
            messageBad = false
        } catch {
            message = "没保存：" + ((error as? APIError)?.message ?? "网络不太好")
            messageBad = true
            await load()
        }
    }

    private func setTarget(_ id: String) async {
        do {
            _ = try await API.shared.request("POST", "api/wake-target", body: ["chat_id": id])
            targetID = id
            pickingTarget = false
            message = "以后他主动找你，就到这间"
            messageBad = false
        } catch {
            message = "没换上，再试一次"
            messageBad = true
        }
    }

    private func wake() async {
        waking = true
        defer { waking = false }
        do {
            _ = try await API.shared.request("POST", "api/heartbeat/run", body: ["assistant": store.assistant?.id ?? ""])
            message = "\(name) 正在读这间聊天；如果此刻不适合说话，他会保持安静。"
            messageBad = false
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await load()
        } catch {
            message = (error as? APIError)?.message ?? "没叫动，再试一次"
            messageBad = true
        }
    }
}
