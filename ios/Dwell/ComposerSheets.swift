import PhotosUI
import SwiftUI
import UIKit

// MARK: - ＋：Add context

/// 网页的「Add context」：拍照、相册、文件，下面一行回复语言。
struct AddContextSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @Binding var pickedItems: [PhotosPickerItem]
    let maxImages: Int
    let onCamera: () -> Void
    let onFiles: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                        onCamera()
                    } label: {
                        bigTile("camera", "Camera")
                    }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    PhotosPicker(selection: $pickedItems, maxSelectionCount: maxImages, matching: .images) {
                        bigTile("photo", "Photos")
                    }
                    .onChange(of: pickedItems) { _, items in
                        if !items.isEmpty { dismiss() }
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    dismiss()
                    onFiles()
                } label: {
                    row("doc.badge.plus", "Add files")
                }
                HStack(spacing: 12) {
                    Image(systemName: "character.bubble").font(.system(size: 17))
                    Text("回复语言")
                    Spacer()
                    Picker("回复语言", selection: Binding(
                        get: { store.replyLanguage },
                        set: { lang in Task { await store.setReplyLanguage(lang) } }
                    )) {
                        Text("自动").tag("auto")
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ComposerStyle.tile))
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .background(PaperBackground())
            .navigationTitle("Add context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .tint(Theme.text)
        }
    }

    private func bigTile(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24))
            Text(title).font(.system(size: 15))
        }
        .foregroundStyle(Theme.text)
        .frame(width: 108, height: 108)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ComposerStyle.tile))
    }

    private func row(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17))
            Text(title).font(.system(size: 16))
            Spacer()
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ComposerStyle.tile))
    }
}

/// 拍照。PhotosPicker 不管相机，只能包一层 UIImagePickerController。
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - 指令

struct Instruction: Identifiable {
    let id: String
    var name: String
    var content: String
    var selected: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? ""
        content = json["content"] as? String ?? ""
        selected = json["selected"] as? Bool ?? false
    }
}

/// 「这间聊天的指令」：分条回复开关 + 勾选要用哪几条指令。
struct InstructionsSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var items: [Instruction] = []
    @State private var splitReplies = false
    @State private var loaded = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SheetIntro(title: "当前聊天的指令", subtitle: "勾选后，下一条消息开始会一起发给模型。")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section("回复方式") {
                    CheckRow(title: "分条回复", detail: "按自然空行自动拆开", on: splitReplies) {
                        Task { await setSplit(!splitReplies) }
                    }
                }
                Section {
                    if items.isEmpty && loaded {
                        Text("还没有可用指令。先在下面「管理指令」里写一条。")
                            .font(.system(size: 14)).foregroundStyle(Theme.dim)
                    }
                    ForEach($items) { $item in
                        CheckRow(title: item.name, detail: item.content, on: item.selected) {
                            item.selected.toggle()
                            Task { await save() }
                        }
                    }
                } footer: {
                    if !message.isEmpty { Text(message) }
                }
                Section {
                    NavigationLink("管理指令") {
                        InstructionManager { Task { await load() } }
                    }
                    .font(.system(size: 16, weight: .semibold))
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle("这间聊天的指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .tint(Theme.text)
            .task { await load() }
        }
    }

    private func load() async {
        if let json = try? await API.shared.request("GET", "api/instructions/chat") {
            items = (json["items"] as? [[String: Any]] ?? []).map(Instruction.init(json:))
        }
        if let json = try? await API.shared.request("GET", "api/reply-style") {
            splitReplies = json["split_replies"] as? Bool ?? false
        }
        loaded = true
    }

    private func save() async {
        let ids = items.filter(\.selected).map(\.id)
        do {
            _ = try await API.shared.request("POST", "api/instructions/chat", body: ["instruction_ids": ids])
            message = ids.isEmpty ? "这间聊天暂未启用指令" : "已用于当前聊天"
            await store.refreshInstructionCount()
        } catch {
            message = "没保存上：" + error.localizedDescription
        }
    }

    private func setSplit(_ on: Bool) async {
        splitReplies = on
        do {
            _ = try await API.shared.request("POST", "api/reply-style", body: ["split_replies": on])
            message = on ? "已开启分条回复" : "已关闭分条回复"
        } catch {
            splitReplies = !on
            message = "没保存上：" + error.localizedDescription
        }
    }
}

/// 「管理指令」：写新的、改旧的、删掉。指令是全局的，每间聊天再勾选要用哪些。
struct InstructionManager: View {
    let onChange: () -> Void

    @State private var items: [Instruction] = []
    @State private var editingID = ""
    @State private var name = ""
    @State private var content = ""
    @State private var message = ""
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                SheetIntro(title: "聊天指令", subtitle: "在这里写好；每间聊天再从输入框下方选择要用哪些。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section("已保存的指令") {
                if items.isEmpty {
                    Text("还没有指令。写第一条吧。").font(.system(size: 14)).foregroundStyle(Theme.dim)
                }
                ForEach(items) { item in
                    Button {
                        editingID = item.id
                        name = item.name
                        content = item.content
                        message = ""
                    } label: {
                        HStack {
                            Text(item.name).foregroundStyle(Theme.text)
                            Spacer()
                            Text(item.id == editingID ? "正在编辑" : "编辑 ›").foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            Section {
                TextField("名称，例如：OB", text: $name)
                TextField("写给模型看的规则或背景…", text: $content, axis: .vertical)
                    .lineLimit(6...16)
                Button(editingID.isEmpty ? "添加指令" : "保存修改") { Task { await save() } }
                    .font(.system(size: 16, weight: .semibold))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !editingID.isEmpty {
                    Button("删除", role: .destructive) { confirmDelete = true }
                    Button("取消编辑") { reset() }.foregroundStyle(Theme.dim)
                }
            } header: {
                Text(editingID.isEmpty ? "添加指令" : "编辑指令")
            } footer: {
                if !message.isEmpty { Text(message) }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("聊天指令")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("删除「\(name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("已勾选它的聊天会自动取消。")
        }
    }

    private func load() async {
        if let json = try? await API.shared.request("GET", "api/instructions") {
            items = (json["items"] as? [[String: Any]] ?? []).map(Instruction.init(json:))
        }
    }

    private func reset() {
        editingID = ""
        name = ""
        content = ""
    }

    private func save() async {
        do {
            _ = try await API.shared.request("POST", "api/instructions", body: [
                "id": editingID, "name": name.trimmingCharacters(in: .whitespaces),
                "content": content.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            // 新建保存后回到空白的「添加指令」；只有点上面的已有项才进入编辑。
            reset()
            message = "保存好了"
            await load()
            onChange()
        } catch {
            message = "没存上：" + error.localizedDescription
        }
    }

    private func delete() async {
        do {
            _ = try await API.shared.request("DELETE", "api/instructions/\(editingID)")
            reset()
            await load()
            onChange()
        } catch {
            message = "没删掉：" + error.localizedDescription
        }
    }
}

// MARK: - 工具

/// 「这间聊天的工具」：内置网页工具说明、家里的功能开关、MCP 服务器勾选。
struct ToolsSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    struct Server: Identifiable {
        let id: String
        let name: String
        let transport: String
        var selected: Bool
    }

    @State private var servers: [Server] = []
    @State private var homeEnabled = false
    @State private var loaded = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SheetIntro(title: "当前聊天的工具", subtitle: "模型会自己决定是否调用已启用的工具。")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section("内置网页工具") {
                    Text("网页搜索和读取网页链接已启用；它们只会访问公共 http(s) 地址。")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim)
                }
                Section {
                    CheckRow(title: "允许 \(store.assistant?.name ?? "Cloudy") 使用待办、日记和日历", detail: "",
                             on: homeEnabled) {
                        homeEnabled.toggle()
                        Task { await save() }
                    }
                    Text("可以查看和修改这三个页面；这是当前聊天单独的授权，每一次调用都会显示在聊天记录里。")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim)
                } header: {
                    Text("家里的功能")
                }
                Section {
                    if servers.isEmpty && loaded {
                        Text("还没有 MCP 服务器，先去网页设置里的 MCP 工具添加。")
                            .font(.system(size: 14)).foregroundStyle(Theme.dim)
                    }
                    ForEach($servers) { $server in
                        CheckRow(title: server.name, detail: server.transport == "sse" ? "SSE" : "HTTP",
                                 on: server.selected) {
                            server.selected.toggle()
                            Task { await save() }
                        }
                    }
                } header: {
                    Text("MCP 服务器")
                } footer: {
                    if !message.isEmpty { Text(message) }
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle("这间聊天的工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .tint(Theme.text)
            .task { await load() }
        }
    }

    private func load() async {
        guard let json = try? await API.shared.request("GET", "api/mcp/chat") else { return }
        homeEnabled = json["home_todos_enabled"] as? Bool ?? false
        servers = (json["items"] as? [[String: Any]] ?? []).map {
            Server(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
                   transport: $0["transport"] as? String ?? "", selected: $0["selected"] as? Bool ?? false)
        }
        loaded = true
    }

    private func save() async {
        let ids = servers.filter(\.selected).map(\.id)
        do {
            _ = try await API.shared.request("POST", "api/mcp/chat", body: [
                "server_ids": ids, "home_todos_enabled": homeEnabled,
            ])
            let parts = [homeEnabled ? "待办、日记和日历已启用" : "",
                         ids.isEmpty ? "" : "\(ids.count) 个 MCP 工具已用于当前聊天"].filter { !$0.isEmpty }
            message = parts.isEmpty ? "这间聊天只使用内置网页工具" : parts.joined(separator: "；")
            await store.refreshTools()
        } catch {
            message = "没保存上：" + error.localizedDescription
        }
    }
}

// MARK: - 模型

struct CatalogModel: Identifiable, Hashable {
    let providerID: String
    let modelID: String
    let providerName: String
    var favorite: Bool
    let manual: Bool
    var id: String { providerID + "|" + modelID }

    init(json: [String: Any]) {
        providerID = json["provider_id"] as? String ?? ""
        modelID = json["model_id"] as? String ?? ""
        providerName = json["provider_name"] as? String ?? ""
        favorite = (json["favorite"] as? Int ?? 0) != 0 || (json["favorite"] as? Bool ?? false)
        manual = (json["manual"] as? Int ?? 0) != 0 || (json["manual"] as? Bool ?? false)
    }

    init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
        providerName = ""
        favorite = false
        manual = false
    }
}

struct CatalogProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let baseURL: String

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? ""
        type = json["provider_type"] as? String ?? ""
        baseURL = json["base_url"] as? String ?? ""
    }
}

@MainActor
final class ModelCatalog: ObservableObject {
    @Published var providers: [CatalogProvider] = []
    @Published var items: [CatalogModel] = []
    @Published var favorites: [CatalogModel] = []

    func load() async {
        guard let json = try? await API.shared.request("GET", "api/model-catalog") else { return }
        providers = (json["providers"] as? [[String: Any]] ?? []).map(CatalogProvider.init(json:))
        items = (json["items"] as? [[String: Any]] ?? []).map(CatalogModel.init(json:))
        favorites = (json["favorites"] as? [[String: Any]] ?? []).map(CatalogModel.init(json:))
    }

    func setFavorite(_ item: CatalogModel, _ on: Bool, manual: Bool = false) async throws {
        _ = try await API.shared.request("POST", "api/model-catalog", body: [
            "provider_id": item.providerID, "model_id": item.modelID, "favorite": on, "manual": manual,
        ])
        await load()
    }

    func remove(_ item: CatalogModel) async throws {
        _ = try await API.shared.request("DELETE", "api/model-catalog", body: [
            "provider_id": item.providerID, "model_id": item.modelID,
        ])
        await load()
    }

    func refresh(providerID: String) async throws -> Int {
        let json = try await API.shared.request("POST", "api/model-catalog/refresh", body: ["provider_id": providerID])
        await load()
        return json["count"] as? Int ?? 0
    }

    // 常用模型按「在这台手机上选过几次」排，前四个放外面；正在用的不在前四就顶掉第四个。
    private static let useKey = "dwell.modelUse"

    static func bumpUse(_ item: CatalogModel) {
        var counts = UserDefaults.standard.dictionary(forKey: useKey) as? [String: Int] ?? [:]
        counts[item.id, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: useKey)
    }

    func split(current: ChatModelState) -> (top: [CatalogModel], rest: [CatalogModel]) {
        let counts = UserDefaults.standard.dictionary(forKey: Self.useKey) as? [String: Int] ?? [:]
        let sorted = favorites.enumerated().sorted {
            let a = counts[$0.element.id] ?? 0, b = counts[$1.element.id] ?? 0
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        var top = Array(sorted.prefix(4))
        let isCurrent = { (item: CatalogModel) in
            item.providerID == current.providerID && item.modelID == current.modelID
        }
        if !current.modelID.isEmpty && !top.contains(where: isCurrent) {
            let currentItem = sorted.first(where: isCurrent) ?? items.first(where: isCurrent)
                ?? CatalogModel(providerID: current.providerID, modelID: current.modelID)
            top = Array(top.prefix(3)) + [currentItem]
        }
        let topIDs = Set(top.map(\.id))
        return (top, sorted.filter { !topIDs.contains($0.id) })
    }

    /// 缓存时长只对 Claude 模型、走支持缓存的供应商时有用（跟网页的 promptCacheAvailable 一样）。
    func cacheAvailable(for current: ChatModelState) -> Bool {
        guard let provider = providers.first(where: { $0.id == current.providerID }) else { return false }
        let model = current.modelID.lowercased()
        guard model.contains("claude") else { return false }
        if ["claude_compatible", "generic"].contains(provider.type) { return true }
        let host = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        return provider.type == "openrouter" && host == "openrouter.ai" && model.hasPrefix("anthropic/")
    }
}

/// 模型胶囊点开的「切换模型」。
struct ModelSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = ModelCatalog()

    var body: some View {
        NavigationStack {
            List {
                if catalog.cacheAvailable(for: store.model) {
                    Section {
                        Picker("缓存", selection: Binding(
                            get: { store.model.promptCacheTTL },
                            set: { ttl in Task { await store.saveModel(["prompt_cache_ttl": ttl]) } }
                        )) {
                            Text("缓存关闭").tag("off")
                            Text("缓存 5 分钟").tag("5m")
                            Text("缓存 1 小时").tag("1h")
                        }
                    }
                }
                let split = catalog.split(current: store.model)
                Section {
                    if split.top.isEmpty {
                        Text("还没有常用模型。在「More models → 浏览模型库」里把模型加入常用。")
                            .font(.system(size: 14)).foregroundStyle(Theme.dim)
                    }
                    ForEach(split.top) { item in
                        modelRow(item)
                            .swipeActions {
                                if item.favorite {
                                    Button("移出常用") { Task { try? await catalog.setFavorite(item, false) } }
                                        .tint(Theme.send)
                                }
                            }
                    }
                }
                Section {
                    NavigationLink {
                        EffortList()
                    } label: {
                        HStack {
                            Text("Effort")
                            Spacer()
                            Text(store.model.effortName).foregroundStyle(Theme.dim)
                        }
                    }
                }
                Section {
                    NavigationLink("More models") {
                        MoreModels(catalog: catalog)
                    }
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle("切换模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    // thinking 开关在右上角，跟网页一样。
                    Toggle(isOn: Binding(
                        get: { store.model.showThinking },
                        set: { on in
                            Task {
                                if await store.saveModel(["show_thinking": on]) {
                                    try? await store.reloadMessages()
                                }
                            }
                        }
                    )) {
                        Image(systemName: "lightbulb")
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.send)
                }
            }
            .tint(Theme.text)
            .task { await catalog.load() }
        }
    }

    private func modelRow(_ item: CatalogModel) -> some View {
        Button {
            Task {
                if await store.saveModel(["provider_id": item.providerID, "model": item.modelID]) {
                    ModelCatalog.bumpUse(item)
                    store.flash("这间聊天换成 \(item.modelID) 了")
                    dismiss()
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.modelID).foregroundStyle(Theme.text)
                    let provider = catalog.providers.first { $0.id == item.providerID }?.name ?? item.providerName
                    if !provider.isEmpty {
                        Text(provider).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                Spacer()
                if item.providerID == store.model.providerID && item.modelID == store.model.modelID {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

private struct EffortList: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(ChatModelState.efforts) { effort in
                    Button {
                        Task {
                            if await store.saveModel(["effort": effort.id]) { dismiss() }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(effort.name).foregroundStyle(Theme.text)
                                    if effort.id == "high" {
                                        Text("Default").font(.system(size: 11)).foregroundStyle(Theme.dim)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Capsule().fill(ComposerStyle.tile))
                                    }
                                }
                                Text(effort.desc).font(.system(size: 13)).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            if store.model.effort == effort.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } footer: {
                Text("Higher effort means more thorough responses, but takes longer and uses your limits faster.")
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("Effort")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MoreModels: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject var catalog: ModelCatalog

    var body: some View {
        List {
            let rest = catalog.split(current: store.model).rest
            if !rest.isEmpty {
                Section {
                    ForEach(rest) { item in
                        Button {
                            Task {
                                if await store.saveModel(["provider_id": item.providerID, "model": item.modelID]) {
                                    ModelCatalog.bumpUse(item)
                                    store.flash("这间聊天换成 \(item.modelID) 了")
                                }
                            }
                        } label: {
                            HStack {
                                Text(item.modelID).foregroundStyle(Theme.text)
                                Spacer()
                                if item.providerID == store.model.providerID && item.modelID == store.model.modelID {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .swipeActions {
                            Button("移出常用") { Task { try? await catalog.setFavorite(item, false) } }
                                .tint(Theme.send)
                        }
                    }
                } header: {
                    HStack {
                        Text("其他常用")
                        Spacer()
                        Text("左滑可移出")
                    }
                }
            }
            Section {
                NavigationLink("浏览模型库") { CatalogBrowser(catalog: catalog) }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("More models")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 模型目录：选供应商、获取 / 刷新、筛选、加入常用、删掉、手动添加。
struct CatalogBrowser: View {
    @ObservedObject var catalog: ModelCatalog

    @State private var providerID = ""
    @State private var search = ""
    @State private var manualName = ""
    @State private var refreshing = false
    @State private var message = ""

    var body: some View {
        List {
            Section {
                Picker("供应商", selection: $providerID) {
                    ForEach(catalog.providers) { provider in Text(provider.name).tag(provider.id) }
                }
                Button {
                    Task { await refresh() }
                } label: {
                    HStack {
                        Text(refreshing ? "正在获取…" : "获取 / 刷新")
                        if refreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(refreshing || providerID.isEmpty)
                TextField("输入模型名筛选", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                if !message.isEmpty { Text(message) }
            }
            Section {
                let shown = catalog.items.filter {
                    $0.providerID == providerID
                        && (search.isEmpty || $0.modelID.localizedCaseInsensitiveContains(search))
                }.prefix(300)
                if shown.isEmpty {
                    Text("还没有模型。先点「获取 / 刷新」，或在下面手动添加。")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim)
                }
                ForEach(Array(shown)) { item in
                    HStack {
                        Text(item.modelID).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Spacer()
                        Button(item.favorite ? "已常用" : "＋ 常用") {
                            Task { try? await catalog.setFavorite(item, !item.favorite) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.favorite ? Theme.dim : Theme.send)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            Task {
                                do { try await catalog.remove(item) } catch { message = "没删掉：" + error.localizedDescription }
                            }
                        }
                    }
                }
            }
            Section("手动添加") {
                TextField("模型原始名称，例如：[AG]gemini-3.5-flash-low", text: $manualName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加到常用") {
                    Task {
                        let name = manualName.trimmingCharacters(in: .whitespaces)
                        do {
                            try await catalog.setFavorite(CatalogModel(providerID: providerID, modelID: name), true, manual: true)
                            manualName = ""
                        } catch { message = "手动添加失败：" + error.localizedDescription }
                    }
                }
                .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty || providerID.isEmpty)
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("模型目录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if providerID.isEmpty { providerID = catalog.providers.first?.id ?? "" }
        }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let count = try await catalog.refresh(providerID: providerID)
            message = "找到了 \(count) 个模型"
        } catch {
            message = "模型目录没取到：" + error.localizedDescription
        }
    }
}

// MARK: - 共用的小零件

/// 网页 sheet 顶上那种大标题 + 一行说明。
struct SheetIntro: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 25, weight: .regular, design: .serif))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
        }
        // 列表的行会把超出行边的笔画切掉（衬线 M 的左脚、「要」的撇），两边留一点。
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// 勾选行：左边名字，中间一行淡淡的说明，右边一个 ✓。
struct CheckRow: View {
    let title: String
    let detail: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer()
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(on ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 这几个面板的 List 都铺在方格纸上，分组是白色圆角卡片——跟网页的 .group 一个样子。
struct SheetListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
    }
}

enum ComposerStyle {
    static let tile = Color(light: Color.white.opacity(0.7), dark: Color(hex: 0x433D41))
}
