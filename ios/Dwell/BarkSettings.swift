import SwiftUI

/// 「Bark 通知」：免费签名的 app 收不到苹果推送，就借 Bark 响一声。
/// 他主动找你、去书房读完书……网页能收到的通知，Bark 也会收到；点通知回到 Dwell 那一间。
struct BarkSettings: View {
    @State private var configured = false
    @State private var keyHint = ""
    @State private var server = ""
    @State private var open = "app"
    @State private var level = "active"
    @State private var sound = ""
    @State private var address = ""
    @State private var message = ""
    @State private var busy = false
    @State private var confirmOff = false

    /// Bark 自带的铃声。
    private static let sounds = [
        "", "minuet", "bell", "birdsong", "bloom", "calypso", "chime", "choo", "glass", "healthnotification",
        "ladder", "newmail", "noir", "paymentsuccess", "spell", "telegraph", "tiptoes", "typewriters", "update",
    ]

    var body: some View {
        List {
            Section {
                SheetIntro(title: "Bark 通知", subtitle: "app 没法收苹果的推送，就让 Bark 代为响一声。他主动找你时，手机会叮一下，点开回到那个聊天。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(configured ? "已开 · \(keyHint)" : "还没填").foregroundStyle(Theme.dim)
                }
                if configured, !server.isEmpty, server != "https://api.day.app" {
                    HStack {
                        Text("服务器")
                        Spacer()
                        Text(URL(string: server)?.host ?? server).foregroundStyle(Theme.dim)
                    }
                }
            }

            Section {
                TextField("https://api.day.app/…", text: $address, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14).monospaced())
                Button(configured ? "换成这个" : "保存") {
                    Task { await save(["address": address.trimmingCharacters(in: .whitespacesAndNewlines)]) }
                }
                .disabled(busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("推送地址")
            } footer: {
                Text("打开 Bark app，首页「使用示例」下面点「复制」，整段粘过来就行（只粘地址或 key 也可以）。地址存在你自己的服务器上。")
            }

            if configured {
                Section {
                    Picker("点通知打开", selection: Binding(get: { open }, set: { value in
                        open = value
                        Task { await save(["open": value]) }
                    })) {
                        Text("Dwell app").tag("app")
                        Text("网页").tag("web")
                    }
                    Picker("提醒方式", selection: Binding(get: { level }, set: { value in
                        level = value
                        Task { await save(["level": value]) }
                    })) {
                        Text("普通").tag("active")
                        Text("时效性").tag("timeSensitive")
                        Text("静悄悄").tag("passive")
                    }
                    Picker("铃声", selection: Binding(get: { sound }, set: { value in
                        sound = value
                        Task { await save(["sound": value]) }
                    })) {
                        ForEach(Self.sounds, id: \.self) { name in
                            Text(name.isEmpty ? "Bark 默认" : name).tag(name)
                        }
                    }
                } footer: {
                    Text("「时效性」在专注模式下也会响，要在 Bark 的通知设置里允许；「静悄悄」只放进通知中心，不亮屏不出声。")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        Label("发一条试试", systemImage: "bell")
                    }
                    .disabled(busy)
                    Button("关掉 Bark", role: .destructive) { confirmOff = true }
                        .disabled(busy)
                }
            }

            if !message.isEmpty {
                Section {
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("Bark 通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("关掉 Bark？", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("关掉", role: .destructive) { Task { await save(["address": ""]) } }
        } message: {
            Text("之后手机不会再通过 Bark 收到通知。网页的通知不受影响。")
        }
    }

    private func apply(_ json: [String: Any]) {
        configured = json["configured"] as? Bool ?? false
        keyHint = json["key_hint"] as? String ?? ""
        server = json["server"] as? String ?? ""
        open = json["open"] as? String ?? "app"
        level = json["level"] as? String ?? "active"
        sound = json["sound"] as? String ?? ""
        if !Self.sounds.contains(sound) { sound = "" }
    }

    private func load() async {
        do {
            apply(try await API.shared.request("GET", "api/bark"))
        } catch {
            message = (error as? APIError)?.message ?? "没读到 Bark 设置"
        }
    }

    private func save(_ body: [String: Any]) async {
        busy = true
        defer { busy = false }
        var body = body
        // 通知的小图标和「打开网页」都要用到这台服务器的公网地址，顺手带上。
        if let base = API.shared.baseURL?.absoluteString {
            body["web_base"] = base.hasSuffix("/") ? String(base.dropLast()) : base
        }
        do {
            let wasConfigured = configured
            apply(try await API.shared.request("POST", "api/bark", body: body))
            if body["address"] != nil {
                address = ""
                message = configured ? "存好了。点「发一条试试」看看手机响不响。" : (wasConfigured ? "Bark 关掉了。" : "")
            }
        } catch {
            message = (error as? APIError)?.message ?? "没存上，再试一次"
        }
    }

    private func test() async {
        busy = true
        defer { busy = false }
        message = "发送中…"
        do {
            let json = try await API.shared.request("POST", "api/bark/test")
            message = (json["ok"] as? Bool) == true
                ? "发出去了，手机应该响了。没响的话看看 Bark 的通知权限。"
                : (json["detail"] as? String ?? "Bark 没收下这条")
        } catch {
            message = (error as? APIError)?.message ?? "没发出去"
        }
    }
}
