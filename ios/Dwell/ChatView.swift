import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore

    @State private var draft = ""
    @State private var drawerOpen = false
    /// 手指拖着侧边栏时的位移。用 GestureState：手势被打断（比如拖到一半切去别的 app）时会自己归零，
    /// 不会让侧边栏卡在半路、左边一截被切掉。
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.2)))
    private var drawerDrag: CGFloat = 0
    @State private var showSettings = false
    @State private var page: NativePage?
    @State private var showMemory = false
    @State private var sentCount = 0
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pendingImages: [PendingImage] = []
    @State private var preparingImages = false
    @State private var pendingFiles: [PendingFile] = []
    @State private var showAdd = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showInstructions = false
    @State private var showTools = false
    @State private var showModel = false
    @State private var editing: Message?
    @State private var deleting: Message?
    @FocusState private var inputFocused: Bool

    private let bottomID = "bottom"
    /// 后端一次最多收两张图。
    private let maxImages = 2

    var body: some View {
        GeometryReader { geo in
            chatScroll
                // 网页上气泡最宽占这一行的 85%。
                .environment(\.bubbleMaxWidth, (geo.size.width - 36) * 0.85)
        }
        .background(ChatBackground(assistant: store.assistant?.id ?? "cloudy"))
        .environment(\.assistantID, store.assistant?.id ?? "cloudy")
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .overlay { drawer }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .onChange(of: store.openPage) { _, name in
            guard let name, let target = NativePage(rawValue: name) else { return }
            store.openPage = nil
            page = target
        }
        // 跟网页一样：从侧边栏点进去的页面，返回时侧边栏还开着。
        .fullScreenCover(item: $page, onDismiss: {
            withAnimation(.easeOut(duration: 0.24)) { drawerOpen = true }
        }) { page in
            Group {
                switch page {
                case .tasks: TasksPage()
                case .calendar: CalendarPage()
                case .usage: UsagePage()
                case .heartbeat: HeartbeatPage()
                case .focus: FocusPage()
                case .library: LibraryPage()
                }
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showMemory, onDismiss: {
            Task { await store.refreshMemoryBadge() }
        }) {
            MemoryView(chatID: store.chatID, chatTitle: headerTitle)
        }
        .sheet(item: $editing) { message in
            EditMessageSheet(message: message) { text in
                Task { await store.edit(message, to: text) }
            }
        }
        .confirmationDialog("删掉这条消息？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let message = deleting {
                    Task { await store.delete(message) }
                }
                deleting = nil
            }
        } message: {
            Text("删了就找不回来了。")
        }
        .onChange(of: pickedItems) { _, items in
            Task { await takePicked(items) }
        }
        .sheet(isPresented: $showAdd) {
            AddContextSheet(pickedItems: $pickedItems,
                            maxImages: max(1, maxImages - pendingImages.count),
                            onCamera: { showCamera = true },
                            onFiles: { showFiles = true })
                .environmentObject(store)
                .presentationDetents([.height(380)])
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                Task { await takeCamera(image) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await takeFiles(urls) }
            }
        }
        .sheet(isPresented: $showInstructions) {
            InstructionsSheet().environmentObject(store)
        }
        .sheet(isPresented: $showTools) {
            ToolsSheet().environmentObject(store)
        }
        .sheet(isPresented: $showModel) {
            ModelSheet().environmentObject(store)
        }
        // 一轮说完：新的语音回复自动念一遍（跟网页一样）。
        .onChange(of: store.isReplying) { _, replying in
            guard !replying, let id = store.autoplayVoiceID else { return }
            store.autoplayVoiceID = nil
            if store.messages.contains(where: { $0.id == id && $0.voice && !$0.text.isEmpty }) {
                Task { await VoicePlayer.shared.play(id) }
            }
        }
    }

    private var chatScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.hasMore {
                        olderButton(proxy)
                    }
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(message.at, inSameDayAs: store.messages[index - 1].at) {
                            DaySeparator(date: message.at)
                        }
                        MessageRow(message: message,
                                   onEdit: { editing = $0 },
                                   onDelete: { deleting = $0 })
                    }
                    if !store.streamingThinking.isEmpty {
                        ThinkingView(text: store.streamingThinking, live: store.streamingText.isEmpty)
                    }
                    if !store.streamingText.isEmpty && store.voiceMode {
                        // 语音回复还在说：先给一条「正在说」的语音条，说完再念。
                        VoiceBar(messageID: "streaming", text: store.streamingText, pending: true)
                    } else if !store.streamingText.isEmpty {
                        Bubble(text: store.streamingText)
                    } else if store.isReplying && store.streamingThinking.isEmpty {
                        TypingDots()
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom)
            // 原生 app 最舒服的一点：往下一拖，键盘跟着手指收回去。
            .scrollDismissesKeyboard(.interactively)
            // 点一下聊天记录的空白处，键盘也收起来（跟系统信息 app 一样）。
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            // 只在最底下多了新消息时才滚到底；往上翻出更早的消息时不能把人拽回去。
            .onChange(of: store.messages.last?.id) { _, _ in scrollToBottom(proxy) }
            .onChange(of: store.streamingText) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: inputFocused) { _, focused in
                if focused { scrollToBottom(proxy) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        }
    }

    private func olderButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            let anchor = store.messages.first?.id
            Task {
                await store.loadOlder()
                // 新的一页插在上面，把原来最上面那条留在原位，免得画面跳。
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
        } label: {
            HStack(spacing: 6) {
                if store.loadingOlder { ProgressView().controlSize(.small) }
                Text("更早的消息")
            }
            .font(.footnote)
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .disabled(store.loadingOlder)
    }

    // MARK: - 输入框

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty || !pendingFiles.isEmpty
    }

    /// 网页的 composer：一张浮在方格纸上的圆角卡，上面是输入框，下面一排圆按钮和粉色发送键。
    private var inputBar: some View {
        VStack(spacing: 6) {
            if !store.status.isEmpty {
                Text(store.status)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.chipText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.chip))
                    .overlay(Capsule().stroke(Theme.chipBorder, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 4) {
                if !pendingImages.isEmpty || !pendingFiles.isEmpty || preparingImages {
                    attachmentStrip
                }
                TextField("", text: $draft,
                          prompt: Text("说点什么…").foregroundStyle(Theme.dim),
                          axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                controlRow
            }
            .padding(.top, 10)
            .padding(.horizontal, 14)
            .padding(.bottom, 7)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.composer))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.composerBorder, lineWidth: 1))
            .shadow(color: Theme.composerShadow, radius: 11, y: 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    /// 网页那一排：＋、指令、工具、语音、模型胶囊，右边发送键。
    private var controlRow: some View {
        HStack(spacing: 6) {
            Button { showAdd = true } label: { RoundIcon(systemName: "plus") }
                .accessibilityLabel("添加照片和文件")
            Button { showInstructions = true } label: {
                RoundIcon(systemName: "square.3.layers.3d", on: store.instructionCount > 0)
            }
            .accessibilityLabel(store.instructionCount > 0 ? "这间聊天已启用 \(store.instructionCount) 条指令" : "这间聊天的指令")
            Button { showTools = true } label: {
                RoundIcon(systemName: "wrench", on: store.toolsEnabled)
            }
            .accessibilityLabel("这间聊天的工具")
            Button {
                Task { await store.setVoiceMode(!store.voiceMode) }
            } label: {
                RoundIcon(systemName: "waveform", on: store.voiceMode)
            }
            .accessibilityLabel("语音回复")
            Button { showModel = true } label: {
                // 网页的 #modelPill：贴着字的胶囊，13 号字、左右 9、高 34，跟圆按钮同一种玻璃。
                Text(store.model.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 130)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.roundButton))
                    .glassRim(Capsule())
                    .shadow(color: Theme.composerShadow, radius: 9, y: 6)
            }
            .accessibilityLabel("切换模型")
            Spacer(minLength: 4)
            sendButton
        }
        .buttonStyle(.plain)
    }

    private var attachmentStrip: some View {
        HStack(spacing: 8) {
            ForEach(pendingFiles) { file in
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(file.name).lineLimit(1).frame(maxWidth: 110)
                    Button {
                        pendingFiles.removeAll { $0.id == file.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim)
                    }
                    .accessibilityLabel("去掉这个文件")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chip))
            }
            ForEach(pendingImages) { item in
                Image(uiImage: item.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            pendingImages.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("去掉这张")
                    }
            }
            if preparingImages {
                ProgressView().frame(width: 56, height: 56)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var sendButton: some View {
        if store.isReplying && !canSend {
            Button {
                Task { await store.stop() }
            } label: {
                sendCircle(systemName: "stop.fill", size: 13)
            }
            .accessibilityLabel("停下")
        } else {
            Button {
                let text = draft
                let images = pendingImages
                let files = pendingFiles
                draft = ""
                pendingImages = []
                pendingFiles = []
                sentCount += 1
                Task { await store.send(text, images: images, files: files) }
            } label: {
                sendCircle(systemName: "arrow.up", size: 17)
                    .opacity(canSend ? 1 : 0.55)
            }
            .disabled(!canSend || preparingImages)
            .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
            .accessibilityLabel("发送")
        }
    }

    private func sendCircle(systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Theme.send))
            .shadow(color: Theme.sendShadow, radius: 6, y: 5)
    }

    private func takePicked(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        preparingImages = true
        defer {
            preparingImages = false
            pickedItems = []
        }
        for item in items {
            guard pendingImages.count < maxImages else { break }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // 缩图和编码挺吃 CPU，别卡住主线程。
            let prepared = await Task.detached(priority: .userInitiated) {
                PendingImage(imageData: data)
            }.value
            if let prepared {
                pendingImages.append(prepared)
            } else {
                store.status = "有一张图读不出来"
            }
        }
    }

    private func takeCamera(_ image: UIImage) async {
        guard pendingImages.count < maxImages else { return }
        preparingImages = true
        defer { preparingImages = false }
        let prepared = await Task.detached(priority: .userInitiated) {
            image.jpegData(compressionQuality: 0.9).flatMap { PendingImage(imageData: $0) }
        }.value
        if let prepared { pendingImages.append(prepared) }
    }

    /// 跟网页的 takeFiles 一样：图片走图片那条路；小的纯文本直接读成文字；
    /// 其余的（PDF、大文件）分块传上去，服务器读成文字暂存，随下一条消息一起发。
    private func takeFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                store.flash("读不了 \(name)")
                continue
            }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                if pendingImages.count < maxImages, let image = PendingImage(imageData: data) {
                    pendingImages.append(image)
                }
                continue
            }
            if let text = PendingFile.inlineText(name: name, data: data) {
                pendingFiles.append(text)
                continue
            }
            guard data.count <= 30 * 1024 * 1024 else {
                store.flash("\(name) 太大了，最多 30MB")
                continue
            }
            preparingImages = true
            do {
                let result = try await API.shared.upload(fileData: data, name: name) { fraction in
                    Task { @MainActor in store.status = "在传 \(name)…\(Int(fraction * 100))%" }
                }
                pendingFiles.append(PendingFile(name: name, content: .upload(id: result.id)))
                store.flash("\(name) 读好了，" + (result.truncated ? "太长只带开头一部分，" : "") + "跟下一条消息一起发")
            } catch {
                store.flash("\(name) 没传上：" + error.localizedDescription)
            }
            preparingImages = false
        }
    }

    // MARK: - 侧边栏

    /// 网页的 #drawer：从左边滑出来，宽 min(76%, 292)，后面一层半透明的遮罩，点遮罩或往左划收起。
    /// 没开的时候左边缘留一条窄缝，从屏幕边往右划也能拉出来。
    private var drawer: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.76, 292)
            ZStack(alignment: .leading) {
                if drawerOpen {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .transition(.opacity)
                    Sidebar(isOpen: $drawerOpen, onSettings: {
                        closeDrawer()
                        showSettings = true
                    }, onPage: { next in
                        closeDrawer()
                        page = next
                    })
                    .environmentObject(store)
                    .frame(width: width)
                    .offset(x: min(0, drawerDrag))
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .updating($drawerDrag) { value, state, _ in state = value.translation.width }
                            .onEnded { value in
                                if value.translation.width < -width * 0.3 { closeDrawer() }
                            }
                    )
                    .transition(.move(edge: .leading))
                } else {
                    Color.clear
                        .frame(width: 12)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 16)
                                .onEnded { value in
                                    if value.translation.width > 50 {
                                        withAnimation(.easeOut(duration: 0.24)) { drawerOpen = true }
                                    }
                                }
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func closeDrawer() {
        withAnimation(.easeOut(duration: 0.24)) { drawerOpen = false }
    }

    // MARK: - 顶栏

    /// 网页的 header：左边开侧栏的箭头，中间「✦ 名字 ୨୧」加一行小字，右边三个点。
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.24)) { drawerOpen = true }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("打开侧边栏")

            VStack(spacing: 1) {
                (Text("✦  ").font(.system(size: 12.24, weight: .semibold)).foregroundColor(Theme.accent)
                 + Text(headerTitle).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.text)
                 + Text("  ୨୧").font(.system(size: 14.96, weight: .semibold)).foregroundColor(Theme.accent))
                    .kerning(0.765)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity)

            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(
            Theme.header
                .opacity(0.92)
                .background(.ultraThinMaterial)
                .shadow(color: Theme.headerShadow, radius: 10, y: 7)
                .ignoresSafeArea(edges: .top)
        )
    }

    /// 跟网页的 setTitle 一样：聊天起了名字就用名字，没起就用助手的名字。
    private var headerTitle: String {
        store.chatName.isEmpty ? (store.assistant?.name ?? "Dwell") : store.chatName
    }

    private var headerSubtitle: String {
        store.assistant?.id == "chatgpt" ? "ChatGPT" : "Claude Code"
    }

    private var moreMenu: some View {
        Menu {
            Button {
                showMemory = true
            } label: {
                Label(store.memoryUnseen > 0 ? "记忆 · \(store.memoryUnseen) 条新的" : "记忆", systemImage: "book")
            }
            Toggle(isOn: Binding(get: { store.memoryInjection },
                                 set: { on in Task { await store.setMemoryInjection(on) } })) {
                Label("按需记忆", systemImage: "sparkles")
            }
            Button {
                Task { await store.newChat() }
            } label: {
                Label("新窗口", systemImage: "square.and.pencil")
            }
            if let assistant = store.assistant, assistant.all.count > 1 {
                Section("换一位") {
                    ForEach(assistant.all) { item in
                        Button {
                            Task { await store.switchAssistant(item.id) }
                        } label: {
                            if item.id == assistant.id {
                                Label(item.name, systemImage: "checkmark")
                            } else {
                                Text(item.name)
                            }
                        }
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    Task { await store.logout() }
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                // 跟网页一样：有新的待确认记忆时，三个点右上角一颗粉点。
                .overlay(alignment: .topTrailing) {
                    if store.memoryUnseen > 0 {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: -6, y: 9)
                    }
                }
        }
        .accessibilityLabel("更多")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

// MARK: - 一条消息

private struct BubbleMaxWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 300
}

extension EnvironmentValues {
    var bubbleMaxWidth: CGFloat {
        get { self[BubbleMaxWidthKey.self] }
        set { self[BubbleMaxWidthKey.self] = newValue }
    }
}

struct MessageRow: View {
    @EnvironmentObject private var store: ChatStore

    let message: Message
    let onEdit: (Message) -> Void
    let onDelete: (Message) -> Void

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
        case .me, .gu:
            let isMe = message.kind == .me
            VStack(alignment: isMe ? .trailing : .leading, spacing: 6) {
                if !message.thinking.isEmpty || !message.tools.isEmpty {
                    HStack(spacing: 6) {
                        if !message.thinking.isEmpty {
                            ThinkingView(text: message.thinking, live: false)
                        }
                        if !message.tools.isEmpty {
                            ToolChip(names: message.tools)
                        }
                    }
                }
                ForEach(Array(message.images.enumerated()), id: \.offset) { _, url in
                    MessageImage(url: url)
                }
                if message.voice && !isMe && !message.text.isEmpty {
                    VoiceBar(messageID: message.id, text: message.text, pending: false) {
                        bubbleList(isMe: isMe)
                    }
                    .contextMenu { menu(copying: message.text) }
                } else {
                    bubbleList(isMe: isMe)
                }
                if message.fromHeartbeat && !isMe {
                    Text("主动找你的")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .padding(.leading, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        }
    }

    /// 一条消息的文字气泡（分条的话是好几个）。
    @ViewBuilder
    private func bubbleList(isMe: Bool) -> some View {
        ForEach(Array(message.bubbles.enumerated()), id: \.offset) { _, text in
            Bubble(text: text, isMe: isMe)
                .contextMenu { menu(copying: text) }
        }
    }

    @ViewBuilder
    private func menu(copying text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("拷贝", systemImage: "doc.on.doc")
        }
        // 本地刚发、还没落库的那条，后端还不认识它。
        if !message.isLocal {
            if message.kind == .gu {
                Button {
                    Task { await store.regenerate(message) }
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
                .disabled(store.isReplying)
            }
            Button {
                onEdit(message)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete(message)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// 网页的气泡：圆角、淡粉毛玻璃、很浅的影子。样子跟「设置 → 玻璃效果」走：
/// 我的消息一套，Cloudy 一套，ChatGPT 一套，浅色深色各一套。
struct Bubble: View {
    let text: String
    var isMe = false
    @Environment(\.bubbleMaxWidth) private var maxWidth
    @Environment(\.colorScheme) private var scheme
    @Environment(\.assistantID) private var assistant
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        let style = appearance.style(isMe ? "me" : assistant, scheme == .dark ? "dark" : "light")
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        Text(Self.render(text))
            .font(Theme.bubbleFont)
            .lineSpacing(Theme.bubbleLineSpacing)
            .foregroundStyle(style.textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    // 网页是 backdrop-filter 模糊；这里用系统的毛玻璃材质，模糊调到 0 就不要它。
                    if style.blur > 0 { shape.fill(.ultraThinMaterial) }
                    shape.fill(style.backgroundColor)
                }
            }
            .overlay(shape.stroke(style.borderColor, lineWidth: style.borderWidth))
            .shadow(color: Theme.bubbleShadow, radius: 10, y: 6)
            // 自己说的靠右：这个框占满 85% 宽，气泡贴着框的右边。
            .frame(maxWidth: maxWidth, alignment: isMe ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 只认行内 Markdown（加粗、斜体、代码、链接），换行原样保留。解析不了就当纯文本。
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 网页回复上方那颗小胶囊。
struct Chip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.chipText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.chip))
            .overlay(Capsule().stroke(Theme.chipBorder, lineWidth: 1))
            .shadow(color: Theme.bubbleShadow.opacity(0.6), radius: 5, y: 3)
    }
}

/// 「thinking ›」胶囊，点开在下面展开思考内容。
struct ThinkingView: View {
    let text: String
    /// 还在想：小灯泡跟着呼吸。
    let live: Bool
    @State private var expanded = false
    @Environment(\.bubbleMaxWidth) private var maxWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                Chip {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11))
                        .symbolEffect(.pulse, isActive: live)
                    Text("thinking")
                    Text("›")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.chipText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.chip))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.chipBorder, lineWidth: 1))
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}

struct ToolChip: View {
    let names: [String]

    var body: some View {
        Chip {
            Image(systemName: "wrench")
                .font(.system(size: 10.5))
            Text(names.count == 1 ? names[0] : "\(names[0]) 等 \(names.count) 个")
                .lineLimit(1)
        }
    }
}

struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(
            sameYear
                ? .dateTime.month().day().weekday(.wide)
                : .dateTime.year().month().day().weekday(.wide)
        )
    }
}

struct EditMessageSheet: View {
    let message: Message
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(message: Message, onSave: @escaping (String) -> Void) {
        self.message = message
        self.onSave = onSave
        _text = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .background(Theme.background)
                .navigationTitle(message.kind == .me ? "改我说的话" : "改这条回复")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = .pi
            }
        }
    }
}
