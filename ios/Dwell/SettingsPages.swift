import SwiftUI
import UniformTypeIdentifiers

// MARK: - 模型供应商

struct Provider: Identifiable, Hashable {
    let id: String
    var name: String
    var baseURL: String
    var type: String
    var enabled: Bool
    let hasKey: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? ""
        baseURL = json["base_url"] as? String ?? ""
        type = json["provider_type"] as? String ?? "generic"
        enabled = (json["enabled"] as? Int ?? 1) != 0 || (json["enabled"] as? Bool ?? false)
        hasKey = json["has_key"] as? Bool ?? false
    }

    static let types: [(id: String, name: String)] = [
        ("generic", "OpenAI 兼容"), ("claude_compatible", "Anthropic Messages"),
        ("openrouter", "OpenRouter"), ("claude_agent_sdk", "Claude Agent SDK 桥接"),
    ]

    var typeName: String { Self.types.first { $0.id == type }?.name ?? type }
}

struct ProvidersPage: View {
    @State private var items: [Provider] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                SheetIntro(title: "模型供应商", subtitle: "每个聊天可自行选择；密钥只会保存到服务器。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section("已保存的供应商") {
                if items.isEmpty && loaded {
                    Text("还没有保存供应商").foregroundStyle(Theme.dim)
                }
                ForEach(items) { provider in
                    NavigationLink {
                        ProviderEditor(provider: provider) { Task { await load() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).foregroundStyle(Theme.text)
                            Text("\(provider.typeName) · \(provider.hasKey ? "密钥已保存" : "还没有密钥")")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        }
                    }
                }
                NavigationLink {
                    ProviderEditor(provider: nil) { Task { await load() } }
                } label: {
                    Label("添加供应商", systemImage: "plus")
                }
            }
            Section {
                NavigationLink("管理模型与常用项") { CatalogPage() }
            } header: {
                Text("模型目录")
            } footer: {
                Text("获取供应商的模型后，挑进常用模型；聊天页只显示常用项。")
            }
            Section {
            } footer: {
                Text("密钥经服务器加密后保存，之后只能看到「已保存」，拿不回来。保存后，到聊天输入框下方选择模型；「获取 / 刷新」模型即可验证供应商连接。")
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("模型供应商")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if let json = try? await API.shared.request("GET", "api/providers") {
            items = (json["items"] as? [[String: Any]] ?? []).map(Provider.init(json:))
        }
        loaded = true
    }
}

private struct CatalogPage: View {
    @StateObject private var catalog = ModelCatalog()

    var body: some View {
        CatalogBrowser(catalog: catalog)
            .task { await catalog.load() }
    }
}

struct ProviderEditor: View {
    let provider: Provider?
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var type = "generic"
    @State private var token = ""
    @State private var message = ""
    @State private var saving = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                TextField("名称，例如：聚梦 AG", text: $name)
                TextField("接口地址，例如 https://api.example.com/v1", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("连接类型", selection: $type) {
                    ForEach(Provider.types, id: \.id) { item in Text(item.name).tag(item.id) }
                }
                .onChange(of: type) { _, value in
                    if value == "openrouter" && baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                        baseURL = "https://openrouter.ai/api/v1"
                    }
                }
                SecureField(provider?.hasKey == true ? "已保存 · 不换就留空" : "粘贴 API 密钥", text: $token)
            } footer: {
                Text("这里只决定怎样连接供应商；缓存时长在每间聊天的模型选择里设置。")
            }
            Section {
                Button(saving ? "正在安全保存…" : "保存供应商") { Task { await save() } }
                    .font(.system(size: 16, weight: .semibold))
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                if provider != nil {
                    Button("删除供应商", role: .destructive) { confirmDelete = true }
                }
            } footer: {
                if !message.isEmpty { Text(message) }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle(provider?.name ?? "添加供应商")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = provider?.name ?? ""
            baseURL = provider?.baseURL ?? ""
            type = provider?.type ?? "generic"
        }
        .confirmationDialog("删掉供应商「\(provider?.name ?? "")」？", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("它保存的密钥也会一起没了。")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = [
            "id": provider?.id ?? "", "name": name.trimmingCharacters(in: .whitespaces),
            "base_url": baseURL.trimmingCharacters(in: .whitespaces), "provider_type": type,
        ]
        let nextToken = token.trimmingCharacters(in: .whitespaces)
        // 不换密钥就别传 token：传了空字符串等于清掉。
        if !nextToken.isEmpty || provider == nil { body["token"] = nextToken }
        do {
            _ = try await API.shared.request("POST", "api/providers", body: body)
            onChange()
            dismiss()
        } catch {
            message = "没存上：" + error.localizedDescription
        }
    }

    private func delete() async {
        guard let provider else { return }
        do {
            _ = try await API.shared.request("DELETE", "api/providers/\(provider.id)")
            onChange()
            dismiss()
        } catch {
            // 后端挡着：还有聊天在用这个供应商时不给删，理由照原样说。
            message = "删不掉：" + error.localizedDescription
        }
    }
}

// MARK: - MCP 工具

struct MCPServer: Identifiable {
    let id: String
    var name: String
    var url: String
    var transport: String
    let hasCredentials: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? ""
        url = json["url"] as? String ?? ""
        transport = json["transport"] as? String ?? "streamable_http"
        hasCredentials = json["has_credentials"] as? Bool ?? false
    }
}

struct MCPServersPage: View {
    @State private var items: [MCPServer] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                SheetIntro(title: "MCP 工具", subtitle: "在这里接上 MCP 服务器；每间聊天再从输入框下方的扳手选择要用哪些。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section("已保存的服务器") {
                if items.isEmpty && loaded {
                    Text("还没有 MCP 服务器").foregroundStyle(Theme.dim)
                }
                ForEach(items) { server in
                    NavigationLink {
                        MCPEditor(server: server) { Task { await load() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).foregroundStyle(Theme.text)
                            Text("\(server.transport == "sse" ? "SSE" : "HTTP") · \(server.url)")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(1)
                        }
                    }
                }
                NavigationLink {
                    MCPEditor(server: nil) { Task { await load() } }
                } label: {
                    Label("添加服务器", systemImage: "plus")
                }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("MCP 工具")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if let json = try? await API.shared.request("GET", "api/mcp/servers") {
            items = (json["items"] as? [[String: Any]] ?? []).map(MCPServer.init(json:))
        }
        loaded = true
    }
}

struct MCPEditor: View {
    let server: MCPServer?
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var savedID = ""
    @State private var name = ""
    @State private var url = ""
    @State private var transport = "streamable_http"
    @State private var headers = ""
    @State private var message = ""
    @State private var busy = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                TextField("名称", text: $name)
                TextField("地址，例如 https://example.com/mcp", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("传输方式", selection: $transport) {
                    Text("Streamable HTTP").tag("streamable_http")
                    Text("SSE").tag("sse")
                }
                TextField(server?.hasCredentials == true ? "请求头已保存 · 不换就留空"
                          : #"请求头（JSON，可选），例如 {"Authorization": "Bearer …"}"#,
                          text: $headers, axis: .vertical)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("请求头会加密保存在服务器上，之后只能看到「已保存」。")
            }
            Section {
                Button("保存") { Task { await save() } }
                    .font(.system(size: 16, weight: .semibold))
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || url.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("测试连接") { Task { await test() } }
                    .disabled(busy || savedID.isEmpty)
                if server != nil {
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
            } footer: {
                if !message.isEmpty { Text(message) }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle(server?.name ?? "添加 MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            savedID = server?.id ?? ""
            name = server?.name ?? ""
            url = server?.url ?? ""
            transport = server?.transport ?? "streamable_http"
        }
        .confirmationDialog("删掉「\(server?.name ?? "")」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delete() } }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var body: [String: Any] = [
            "id": savedID, "name": name.trimmingCharacters(in: .whitespaces),
            "url": url.trimmingCharacters(in: .whitespaces), "transport": transport,
        ]
        let raw = headers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                message = "请求头要是一个 JSON 对象"
                return
            }
            body["headers"] = object
        }
        do {
            let json = try await API.shared.request("POST", "api/mcp/servers", body: body)
            savedID = (json["server"] as? [String: Any])?["id"] as? String ?? savedID
            headers = ""
            message = "保存好了 · 现在可以测试，并在聊天的扳手里勾选"
            onChange()
        } catch {
            message = "没存上：" + error.localizedDescription
        }
    }

    private func test() async {
        busy = true
        defer { busy = false }
        message = "正在连接…"
        do {
            let json = try await API.shared.request("POST", "api/mcp/test", body: ["server_id": savedID])
            if json["ok"] as? Bool == true {
                let tools = json["tools"] as? [String] ?? []
                message = "通了 · 找到 \(json["count"] as? Int ?? tools.count) 个工具：" + tools.joined(separator: "、")
            } else {
                message = "没通：" + (json["detail"] as? String ?? "连接失败")
            }
        } catch {
            message = "没通：" + error.localizedDescription
        }
    }

    private func delete() async {
        do {
            _ = try await API.shared.request("DELETE", "api/mcp/servers/\(savedID)")
            onChange()
            dismiss()
        } catch {
            message = "没删掉：" + error.localizedDescription
        }
    }
}

// MARK: - 重写规则

struct RewriteRule: Identifiable {
    var id: String
    var phrases: [String]
    var reason: String
    var enabled: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        phrases = json["phrases"] as? [String] ?? []
        reason = json["reason"] as? String ?? ""
        enabled = json["enabled"] as? Bool ?? true
    }

    init() {
        id = ""
        phrases = []
        reason = ""
        enabled = true
    }
}

/// 它说完、还没交出来之前拦一道：撞到这些话就打回，附上「为什么」让它重说。所有窗口共用。
struct RewriteRulesPage: View {
    @State private var rules: [RewriteRule] = []
    @State private var loaded = false
    @State private var editing: RewriteRule?
    @State private var maxRules = 0

    var body: some View {
        List {
            Section {
                SheetIntro(title: "重写规则", subtitle: "它说完、还没交出来之前拦一道：撞到这些话就打回，让它重说。所有窗口共用。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section {
                Text("只有走 Claude Code 通道的聊天生效——别的供应商没有「说完再拦一次」的位置。")
                Text("一轮最多打回一次。重说那一版还撞上也照样放过去：一句话都说不出来，比说了句现成话更糟。")
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.dim)
            Section {
                if rules.isEmpty && loaded {
                    Text("还没有规则。加第一条吧。").foregroundStyle(Theme.dim)
                }
                ForEach(rules) { rule in
                    Button {
                        editing = rule
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.phrases.joined(separator: " / "))
                                .foregroundStyle(rule.enabled ? Theme.text : Theme.dim)
                            Text(rule.reason).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(2)
                        }
                    }
                }
                Button {
                    editing = RewriteRule()
                } label: {
                    Label("加一条规则", systemImage: "plus")
                }
                .disabled(maxRules > 0 && rules.count >= maxRules)
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("重写规则")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editing) { rule in
            RewriteRuleEditor(rule: rule) { Task { await load() } }
        }
    }

    private func load() async {
        if let json = try? await API.shared.request("GET", "api/rewrite-rules") {
            rules = (json["items"] as? [[String: Any]] ?? []).map(RewriteRule.init(json:))
            maxRules = json["max_rules"] as? Int ?? 0
        }
        loaded = true
    }
}

private struct RewriteRuleEditor: View {
    let rule: RewriteRule
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phrases = ""
    @State private var reason = ""
    @State private var enabled = true
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("触发词，一行一个", text: $phrases, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("撞到这些话")
                } footer: {
                    Text("回复里出现其中任何一句，就把这一版打回去。")
                }
                Section("为什么打回") {
                    TextField("写清楚为什么，模型才知道往哪儿改", text: $reason, axis: .vertical)
                        .lineLimit(3...10)
                }
                Section {
                    Toggle("启用", isOn: $enabled).tint(Theme.send)
                    if !rule.id.isEmpty {
                        Button("删除这条规则", role: .destructive) { Task { await delete() } }
                    }
                } footer: {
                    if !message.isEmpty { Text(message) }
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle(rule.id.isEmpty ? "新规则" : "规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } } }
            }
            .tint(Theme.text)
            .onAppear {
                phrases = rule.phrases.joined(separator: "\n")
                reason = rule.reason
                enabled = rule.enabled
            }
        }
    }

    private func save() async {
        let list = phrases.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            _ = try await API.shared.request("POST", "api/rewrite-rules", body: [
                "id": rule.id, "phrases": list, "reason": reason, "enabled": enabled,
            ])
            onChange()
            dismiss()
        } catch {
            message = "没存上：" + error.localizedDescription
        }
    }

    private func delete() async {
        do {
            _ = try await API.shared.request("DELETE", "api/rewrite-rules/\(rule.id)")
            onChange()
            dismiss()
        } catch {
            message = "没删掉：" + error.localizedDescription
        }
    }
}

// MARK: - 系统日志

struct SystemLogPage: View {
    struct Entry: Identifiable {
        let id: String
        let category: String
        let action: String
        let status: String
        let model: String
        let duration: Int
        let statusCode: Int?
        let detail: String
        let made: Date

        init(json: [String: Any]) {
            id = json["id"] as? String ?? UUID().uuidString
            category = json["category"] as? String ?? ""
            action = json["action"] as? String ?? ""
            status = json["status"] as? String ?? ""
            model = json["model_id"] as? String ?? ""
            duration = json["duration_ms"] as? Int ?? 0
            statusCode = json["status_code"] as? Int
            detail = json["detail"] as? String ?? ""
            made = Date(timeIntervalSince1970: TimeInterval(json["made"] as? Int ?? 0))
        }
    }

    @State private var items: [Entry] = []
    @State private var category = ""
    @State private var status = ""
    @State private var confirmClear = false
    @State private var loaded = false

    private static let categories = [("", "全部"), ("api_request", "接口"), ("model_request", "模型"), ("memory_task", "记忆")]
    private static let statuses = [("", "全部"), ("success", "成功"), ("error", "出错"), ("running", "进行中"), ("cancelled", "取消")]

    var body: some View {
        List {
            Section {
                Picker("类别", selection: $category) {
                    ForEach(Self.categories, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("状态", selection: $status) {
                    ForEach(Self.statuses, id: \.0) { Text($0.1).tag($0.0) }
                }
            } footer: {
                Text("只记时间、耗时和结果，不存聊天内容；保留 7 天。")
            }
            Section {
                if items.isEmpty && loaded {
                    Text("没有日志").foregroundStyle(Theme.dim)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Circle()
                                .fill(item.status == "error" ? MemoryStyle.danger
                                      : item.status == "success" ? MemoryStyle.sage : Theme.dim)
                                .frame(width: 7, height: 7)
                            Text(item.action.isEmpty ? item.category : item.action)
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text(item.made.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.dim)
                        }
                        let meta = [item.model, item.duration > 0 ? "\(item.duration)ms" : "",
                                    item.statusCode.map { "HTTP \($0)" } ?? ""].filter { !$0.isEmpty }
                        if !meta.isEmpty {
                            Text(meta.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.dim)
                        }
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.system(size: 12.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                        }
                    }
                    .foregroundStyle(Theme.text)
                }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("系统日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("清空日志")
            }
        }
        .refreshable { await load() }
        .task(id: category + "|" + status) { await load() }
        .confirmationDialog("清空所有日志？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    _ = try? await API.shared.request("DELETE", "api/system-logs")
                    await load()
                }
            }
        }
    }

    private func load() async {
        if let json = try? await API.shared.request("GET", "api/system-logs", query: [
            "category": category, "status": status, "limit": "300",
        ]) {
            items = (json["items"] as? [[String: Any]] ?? []).map(Entry.init(json:))
        }
        loaded = true
    }
}

// MARK: - 导入 Kelivo

/// 只读取选中的 kelivo.db；不会上传或导入 settings.json、API 密钥与供应商设置。
struct KelivoImportPage: View {
    struct Conversation: Identifiable {
        let id: String
        let title: String
        let messages: Int
        let attachments: Int
    }

    @State private var picking = false
    @State private var token = ""
    @State private var conversations: [Conversation] = []
    @State private var selected = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        List {
            Section {
                SheetIntro(title: "导入 Kelivo 聊天记录",
                           subtitle: "只读取你选择的 kelivo.db；不会上传或导入 settings.json、API 密钥与供应商设置。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section {
                Button(busy && conversations.isEmpty ? "正在读取…" : "选择 kelivo.db") { picking = true }
                    .disabled(busy)
            } header: {
                Text("1. 选择数据库文件")
            } footer: {
                Text("在「文件」里找到备份中的 database/kelivo.db。")
            }
            if !conversations.isEmpty {
                Section {
                    Picker("对话", selection: $selected) {
                        ForEach(conversations) { item in
                            Text("\(item.title) · \(item.messages) 条" + (item.attachments > 0 ? " · \(item.attachments) 个附件" : ""))
                                .tag(item.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button(busy ? "正在导入…" : "导入这个对话") { Task { await confirm() } }
                        .font(.system(size: 16, weight: .semibold))
                        .disabled(busy || selected.isEmpty)
                } header: {
                    Text("2. 选择一个窗口")
                } footer: {
                    Text("本次先导入文字与工具调用记录；图片、文件附件会在后续单独处理。导入会新建一份 Dwell 对话。")
                }
            }
            if !message.isEmpty {
                Section { Text(message).foregroundStyle(Theme.text) }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("导入 Kelivo")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { Task { await preview(url) } }
        }
    }

    private func preview(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "读不了这个文件"
            return
        }
        busy = true
        defer { busy = false }
        message = "正在读取对话清单…"
        do {
            let json = try await API.shared.multipart("api/import/kelivo/preview", field: "file",
                                                      filename: url.lastPathComponent, data: data)
            token = json["token"] as? String ?? ""
            conversations = (json["conversations"] as? [[String: Any]] ?? []).map {
                Conversation(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "未命名",
                             messages: $0["message_count"] as? Int ?? 0,
                             attachments: $0["attachment_count"] as? Int ?? 0)
            }
            selected = conversations.first?.id ?? ""
            message = "找到了 \(conversations.count) 个对话，请只选一个导入。"
        } catch {
            message = "没读到：" + error.localizedDescription
        }
    }

    private func confirm() async {
        busy = true
        defer { busy = false }
        do {
            let json = try await API.shared.request("POST", "api/import/kelivo/confirm", body: [
                "token": token, "conversation_id": selected,
            ])
            let name = (json["chat"] as? [String: Any])?["name"] as? String ?? ""
            message = "导入好了：\(json["message_count"] as? Int ?? 0) 条消息，\(json["tool_count"] as? Int ?? 0) 条工具记录。到侧边栏打开「\(name)」。"
            conversations = []
        } catch {
            message = "没导进来：" + error.localizedDescription
        }
    }
}
