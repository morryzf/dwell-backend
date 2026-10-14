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
    /// 点了哪条消息，它下面那排按钮（编辑、朗读、重新生成、删除、更多、时间）就亮出来；一次只开一条。
    @State private var actionsFor: String?
    @State private var versionsFor: Message?
    @State private var showSearch = false
    /// 多选删除：nil 是没在选；一个集合就是正在选、已经勾了哪些。
    @State private var selection: Set<String>?
    @State private var confirmBulkDelete = false
    /// 最底下那条看得见吗。看不见（往上翻了）就在输入框上面放一颗回到底部的箭头。
    @State private var atBottom = true
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
        .background(ChatBackground(assistant: store.assistant?.id ?? "cloudy",
                                   paused: showSettings || page != nil || showCamera))
        .environment(\.assistantID, store.assistant?.id ?? "cloudy")
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .overlay { drawer }
        // 设置一点开就是整屏，不会往下一划就整页关掉；右上角的叉关。
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView().environmentObject(store).glassSheet()
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
            .glassSheet()
        }
        .sheet(isPresented: $showMemory, onDismiss: {
            Task { await store.refreshMemoryBadge() }
        }) {
            MemoryView(chatID: store.chatID, chatTitle: headerTitle).glassSheet()
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet().environmentObject(store)
        }
        .sheet(item: $versionsFor) { message in
            VersionsSheet(message: message)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $editing) { message in
            // 点哪个气泡都打开这一整轮回复（我的消息就是这一整条）。
            let parts = store.turn(of: message)
            EditMessageSheet(message: message, parts: parts) { text in
                Task { await store.editTurn(parts, to: text) }
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
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTools) {
            ToolsSheet().environmentObject(store)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showModel) {
            ModelSheet().environmentObject(store)
                .presentationDetents([.medium, .large])
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.hasMore {
                        olderButton(proxy)
                    }
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                        let newDay = index == 0 || !Calendar.current.isDate(message.at, inSameDayAs: store.messages[index - 1].at)
                        if newDay {
                            DaySeparator(date: message.at).padding(.vertical, 8)
                        }
                        // 同一个人连着说：气泡之间 6；换人说话：空 22，一眼分得出谁是谁。
                        let sameSpeaker = index > 0 && store.messages[index - 1].kind == message.kind
                        HStack(alignment: .center, spacing: 10) {
                            // 多选模式：每条前面一个小圆圈，点消息就是勾选。
                            if let selection, message.kind != .system, !message.isLocal {
                                Image(systemName: selection.contains(message.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(selection.contains(message.id) ? Theme.accent : Theme.dim)
                                    .onTapGesture { toggleSelected(message.id) }
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            MessageRow(message: message,
                                       actionsOpen: selection == nil && actionsFor == message.id,
                                       onToggleActions: {
                                           if selection != nil {
                                               toggleSelected(message.id)
                                           } else {
                                               withAnimation(.easeOut(duration: 0.18)) {
                                                   actionsFor = actionsFor == message.id ? nil : message.id
                                               }
                                           }
                                       },
                                       onEdit: { editing = $0 },
                                       onDelete: { deleting = $0 },
                                       onVersions: { versionsFor = $0 },
                                       onSelect: {
                                           withAnimation(.easeOut(duration: 0.2)) {
                                               actionsFor = nil
                                               selection = [message.id]
                                           }
                                       })
                        }
                        .padding(.top, newDay || index == 0 ? 0 : (sameSpeaker ? 6 : 22))
                    }
                    Color.clear.frame(height: 16)
                    if !store.streamingThinking.isEmpty {
                        ThinkingView(text: store.streamingThinking, live: store.streamingText.isEmpty)
                            .padding(.bottom, 6)
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
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom)
            // 原生 app 最舒服的一点：往下一拖，键盘跟着手指收回去。
            .scrollDismissesKeyboard(.interactively)
            // 点一下聊天记录的空白处，键盘也收起来（跟系统信息 app 一样）。
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            // 在聊天记录上任何地方往右一划，侧边栏就出来（不用非得从屏幕最边上划）。
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if !drawerOpen && dx > 70 && abs(dy) < dx * 0.6 {
                            inputFocused = false
                            withAnimation(.easeOut(duration: 0.24)) { drawerOpen = true }
                        }
                    }
            )
            // 只在最底下多了新消息时才滚到底；往上翻出更早的消息时不能把人拽回去。
            .onChange(of: store.messages.last?.id) { _, _ in scrollToBottom(proxy) }
            .onChange(of: store.streamingText) { _, _ in scrollToBottom(proxy, animated: false) }
            // 点输入框：原来就在最底下的，等键盘升上来再贴底；正往上翻着看的，就别动她的位置。
            .onChange(of: inputFocused) { _, focused in
                guard focused, atBottom else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    scrollToBottom(proxy, animated: false)
                }
            }
            // 搜索里点开的那句：滚到正中，闪一下就好。
            .onChange(of: store.jumpTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
                store.jumpTarget = nil
            }
            // 往上翻了：输入框上面一颗小箭头，点一下回到最新。
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 38, height: 38)
                            .buttonGlass(Circle())
                            .frostedOnly { $0.shadow(color: Theme.composerShadow, radius: 9, y: 6) }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityLabel("回到最新的消息")
                }
            }
            .animation(.easeOut(duration: 0.2), value: atBottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selection != nil { selectionBar } else { inputBar }
            }
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
            .background(GlassBackground(surface: .composer, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .frostedOnly { view in
                view
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.composerBorder, lineWidth: 1))
                    .shadow(color: Theme.composerShadow, radius: 11, y: 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
        // 输入框四周到屏幕底：越往下越糊，聊天记录从这儿渐渐隐进去，不是一刀切开。
        // 从输入框上沿再往上多铺 24，渐变才看得见（下半截被输入框自己挡着）。
        .background {
            FadingBlur(fadeTo: .bottom)
                .padding(.top, -24)
                .ignoresSafeArea(edges: .bottom)
        }
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
                    .buttonGlass(Capsule())
                    .frostedOnly { $0.shadow(color: Theme.composerShadow, radius: 9, y: 6) }
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
            .buttonGlass(Circle(), tint: Theme.send, fallback: Theme.send)
            .frostedOnly { $0.shadow(color: Theme.sendShadow, radius: 6, y: 5) }
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
                // 两道横线，上长下短。
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().frame(width: 19, height: 2.2)
                    Capsule().frame(width: 12, height: 2.2)
                }
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
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
        // 顶栏不再是一整块实色：从上往下渐渐变透明的模糊，下面的聊天隐约透上来。
        .background(
            FadingBlur(fadeTo: .top)
                .padding(.bottom, -28)
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
                showSearch = true
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
            Button {
                Task { await store.newChat() }
            } label: {
                Label("新窗口", systemImage: "square.and.pencil")
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

    private func toggleSelected(_ id: String) {
        guard var set = selection else { return }
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        selection = set
    }

    /// 多选时输入框换成这一条：取消、已选几条、删除。
    private var selectionBar: some View {
        let count = selection?.count ?? 0
        return HStack {
            Button("取消") {
                withAnimation(.easeOut(duration: 0.2)) { selection = nil }
            }
            .foregroundStyle(Theme.text)
            Spacer()
            Text(count == 0 ? "点消息来选" : "已选 \(count) 条")
                .font(.system(size: 14))
                .foregroundStyle(Theme.dim)
            Spacer()
            Button("删除") { confirmBulkDelete = true }
                .fontWeight(.semibold)
                .foregroundStyle(count == 0 ? Theme.dim : MemoryStyle.danger)
                .disabled(count == 0)
        }
        .font(.system(size: 16))
        .padding(.horizontal, 22)
        .frame(height: 56)
        .background(GlassBackground(surface: .composer, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .confirmationDialog("删除这 \(count) 条消息？", isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let ids = Array(selection ?? [])
                Task {
                    await store.bulkDelete(ids)
                    withAnimation(.easeOut(duration: 0.2)) { selection = nil }
                }
            }
        } message: {
            Text("删了之后的聊天不会再读到它们，也找不回来。")
        }
    }

    /// 聊天记录是懒加载的，滚过去的路上上面的气泡才量出真高度，第一下常常差一截；
    /// 所以落地后再补两下（不带动画），保证真的到最底。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            proxy.scrollTo(bottomID, anchor: .bottom)
            try? await Task.sleep(nanoseconds: 350_000_000)
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
    @ObservedObject private var voice = VoicePlayer.shared

    let message: Message
    let actionsOpen: Bool
    let onToggleActions: () -> Void
    let onEdit: (Message) -> Void
    let onDelete: (Message) -> Void
    let onVersions: (Message) -> Void
    /// 「⋯」里点「选择消息」：进入多选，先把这条勾上。
    let onSelect: () -> Void

    @State private var showUsage = false

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
                if message.fromHeartbeat && !isMe {
                    Divider(text: "\(store.assistant?.name ?? "Cloudy") 主动发了一条消息")
                        .padding(.bottom, 4)
                }
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
                    .onTapGesture { onToggleActions() }
                } else {
                    bubbleList(isMe: isMe)
                }
                footer(isMe: isMe)
                if message.usage.cacheCheckpoint {
                    Divider(text: "已达50条缓存点，下一条将重新缓存").padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        }
    }

    /// 一条消息的文字气泡（分条的话是好几个）。最后一个带小尖角：他的在左下，我的在右下。
    @ViewBuilder
    private func bubbleList(isMe: Bool) -> some View {
        let parts = message.bubbles
        ForEach(Array(parts.enumerated()), id: \.offset) { index, text in
            Bubble(text: text, isMe: isMe, tail: true)
                .contentShape(Rectangle())
                .onTapGesture { onToggleActions() }
                .contextMenu { menu(copying: text) }
        }
    }

    /// 气泡下面那一行：点开消息时左边是一排按钮和时间，他的回复右边一直挂着这轮用了多少 token。
    @ViewBuilder
    private func footer(isMe: Bool) -> some View {
        let tokens = !isMe ? message.usage.shown : 0
        if (actionsOpen && !message.isLocal) || tokens > 0 {
            HStack(spacing: 14) {
                if isMe { Spacer(minLength: 0) }
                if actionsOpen && !message.isLocal {
                    actions(isMe: isMe)
                        .transition(.opacity)
                }
                if !isMe {
                    Spacer(minLength: 0)
                    if tokens > 0 {
                        Button { showUsage.toggle() } label: {
                            Text("\(tokens.formatted()) tokens")
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(Theme.dim.opacity(0.66))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showUsage) {
                            UsageDetail(usage: message.usage)
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
    }

    private func actions(isMe: Bool) -> some View {
        HStack(spacing: 14) {
            iconButton("pencil", "编辑消息") { onEdit(message) }
            if !isMe {
                let playing = voice.currentID == message.id && voice.state != .idle
                iconButton(playing ? "stop.fill" : "speaker.wave.2", playing ? "停止朗读" : "播放整轮回复") {
                    voice.toggle(message.id)
                }
                iconButton("arrow.clockwise", "重新生成") {
                    Task { await store.regenerate(message) }
                }
                .disabled(store.isReplying)
            }
            iconButton("trash", "删除消息") { onDelete(message) }
            Menu {
                Button { onSelect() } label: { Label("选择消息", systemImage: "checkmark.circle") }
                Button {
                    Task { await quote() }
                } label: { Label("摘进最喜欢的话", systemImage: "quote.bubble") }
                if !isMe {
                    Button { onVersions(message) } label: { Label("查看版本", systemImage: "clock.arrow.circlepath") }
                }
                Button {
                    Task { await branch() }
                } label: { Label("从这里创建分支", systemImage: "arrow.triangle.branch") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel("更多消息操作")
            Text(message.at.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.dim)
        }
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.dim)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func quote() async {
        let day = HomeClock.day(message.at)
        do {
            _ = try await API.shared.request("POST", "api/quotes", body: ["quote": message.text, "date": day])
            store.flash("收进最喜欢的话了")
        } catch {
            store.flash("没收进去，再试一次")
        }
    }

    private func branch() async {
        do {
            let json = try await API.shared.request("POST", "api/messages/\(message.id)/branch")
            if let chat = (json["chat"] as? [String: Any])?["id"] as? String {
                await store.switchChat(chat)
                store.flash("开了一个新分支")
            } else {
                await store.refresh()
            }
        } catch {
            store.flash("分支没开成")
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

    /// 网页的那种居中细线 + 小字（主动消息、缓存点）。
    private struct Divider: View {
        let text: String

        var body: some View {
            HStack(spacing: 10) {
                LinearGradient(colors: [.clear, Theme.dim.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                Text(text).font(.system(size: 11)).tracking(0.6).foregroundStyle(Theme.dim).fixedSize()
                LinearGradient(colors: [Theme.dim.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

/// 点 token 数弹出来的明细，跟网页的 .msg-usage-pop 一样几行。
struct UsageDetail: View {
    let usage: MessageUsage

    var body: some View {
        let cacheUsed = usage.cached > 0 || usage.cacheWrite > 0
        VStack(alignment: .leading, spacing: 6) {
            row("↑", "\(usage.input.formatted()) " + (cacheUsed ? "未缓存输入" : "输入"))
            if usage.cached > 0 { row("↳", "\(usage.cached.formatted()) 缓存读取") }
            if usage.cacheWrite > 0 { row("↟", "\(usage.cacheWrite.formatted()) 缓存写入") }
            row("↓", "\(usage.output.formatted()) 输出")
            if usage.tokensPerSecond > 0 { row("ϟ", String(format: "%.1f tokens/s", usage.tokensPerSecond)) }
            if usage.durationMS > 0 {
                let seconds = Double(usage.durationMS) / 1000
                row("◷", seconds < 10 ? String(format: "%.1f 秒", seconds) : "\(Int(seconds.rounded())) 秒")
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(Theme.text)
        .padding(14)
        .frame(minWidth: 170, alignment: .leading)
    }

    private func row(_ mark: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(mark).foregroundStyle(Theme.dim).frame(width: 16)
            Text(text)
        }
    }
}

/// 「查看版本」：重新生成、编辑之前的旧版本都在这里。
struct VersionsSheet: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var versions: [(text: String, title: String)] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    card("当前版本", current.isEmpty ? message.text : current)
                    ForEach(Array(versions.enumerated()), id: \.offset) { _, item in
                        card(item.title, item.text)
                    }
                    if loaded && versions.isEmpty {
                        Text("这条回复还没有旧版本。").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    }
                }
                .padding(18)
            }
            .background(PaperBackground())
            .navigationTitle("版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func card(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.dim)
            Text(text).font(.system(size: 14.5)).lineSpacing(5).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bubble))
    }

    private func load() async {
        guard let json = try? await API.shared.request("GET", "api/messages/\(message.id)/versions") else {
            loaded = true
            return
        }
        current = (json["current"] as? [String: Any])?["content"] as? String ?? (json["current"] as? String ?? "")
        let items = json["versions"] as? [[String: Any]] ?? []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        versions = items.enumerated().map { index, item in
            let reason = (item["reason"] as? String) == "regenerated" ? "重新生成前" : "编辑前"
            let made = (item["made"] as? NSNumber).map { " · " + formatter.string(from: Date(timeIntervalSince1970: $0.doubleValue)) } ?? ""
            return (text: item["content"] as? String ?? "", title: "旧版本 \(index + 1)（\(reason)）" + made)
        }
        loaded = true
    }
}

/// 网页的气泡：圆角、淡粉毛玻璃、很浅的影子。样子跟「设置 → 玻璃效果」走：
/// 我的消息一套，Cloudy 一套，ChatGPT 一套，浅色深色各一套。
struct Bubble: View {
    let text: String
    var isMe = false
    /// 最后一个气泡带个小尖角：他的在左下，我的在右下。
    var tail = false
    @Environment(\.bubbleMaxWidth) private var maxWidth
    @Environment(\.colorScheme) private var scheme
    @Environment(\.assistantID) private var assistant
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        let style = appearance.style(isMe ? "me" : assistant, scheme == .dark ? "dark" : "light")
        let r = style.radius
        let tip: CGFloat = min(5, r)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: tail && !isMe ? tip : r,
            bottomTrailingRadius: tail && isMe ? tip : r,
            topTrailingRadius: r,
            style: .continuous)
        let rendered = Self.render(text)
        Group {
            if Self.hasEmphasis(rendered) {
                // 有斜体：中文字体没有斜体字形，SwiftUI 画不歪，换 UIKit 把那几个字倾斜着画。
                SlantedText(text: rendered, color: UIColor(style.textColor))
            } else {
                Text(rendered)
                    .font(Theme.bubbleFont)
                    .lineSpacing(Theme.bubbleLineSpacing)
                    .foregroundStyle(style.textColor)
            }
        }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if appearance.usesLiquidGlass, #available(iOS 26.0, *) {
                    // Liquid Glass：气泡的底色当作玻璃的染色。
                    LiquidPane(shape: shape, glass: LiquidGlass.make(
                        tint: style.backgroundColor,
                        clear: BlurLevel.of(style.blur).rawValue <= BlurLevel.faint.rawValue))
                } else {
                    ZStack {
                        // 模糊按设置的档位；调到「关」就不模糊。
                        if style.blur > 0 { BackdropBlur(radius: style.blur).clipShape(shape) }
                        shape.fill(style.backgroundColor)
                    }
                }
            }
            .frostedOnly { view in
                view
                    .overlay(shape.stroke(style.borderColor, lineWidth: style.borderWidth))
                    .shadow(color: Theme.bubbleShadow, radius: 10, y: 6)
            }
            // 自己说的靠右：这个框占满 85% 宽，气泡贴着框的右边。
            .frame(maxWidth: maxWidth, alignment: isMe ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 只认行内 Markdown（加粗、斜体、代码、链接），换行原样保留。解析不了就当纯文本。
    /// 标准 Markdown 对中文里的 *…* 很挑（挨着标点就不认），剩下没认出来的 *…* 再补认成斜体。
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let plain = String(attr.characters)
        guard plain.contains("*"),
              let regex = try? NSRegularExpression(pattern: "(?<!\\*)\\*([^*\\n]+?)\\*(?!\\*)") else { return attr }
        let ns = plain as NSString
        // 从后往前改，前面的位置不会被挪动。
        for match in regex.matches(in: plain, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let whole = Range(match.range, in: plain), let inner = Range(match.range(at: 1), in: plain) else { continue }
            let start = plain.distance(from: plain.startIndex, to: whole.lowerBound)
            let innerStart = plain.distance(from: plain.startIndex, to: inner.lowerBound)
            let innerEnd = plain.distance(from: plain.startIndex, to: inner.upperBound)
            let chars = attr.characters
            let a = chars.index(chars.startIndex, offsetBy: innerStart)
            let b = chars.index(chars.startIndex, offsetBy: innerEnd)
            var intent = attr[a..<b].inlinePresentationIntent ?? []
            intent.insert(.emphasized)
            attr[a..<b].inlinePresentationIntent = intent
            let closing = attr.characters.index(attr.characters.startIndex, offsetBy: innerEnd)
            attr.characters.remove(at: closing)
            let opening = attr.characters.index(attr.characters.startIndex, offsetBy: start)
            attr.characters.remove(at: opening)
        }
        return attr
    }

    static func hasEmphasis(_ attr: AttributedString) -> Bool {
        attr.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }
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

    /// parts：要一起改的那几条（他的一整轮回复会拆成好几条），中间空一行连起来。
    init(message: Message, parts: [Message], onSave: @escaping (String) -> Void) {
        self.message = message
        self.onSave = onSave
        _text = State(initialValue: parts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n"))
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

/// 带斜体的气泡文字：用 UILabel 画，斜体那几段用 obliqueness 倾斜（中文也会歪）。
/// 粗体、行内代码、链接照常；字号、行距跟普通气泡一样。
struct SlantedText: UIViewRepresentable {
    let text: AttributedString
    let color: UIColor

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = Self.convert(text, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), width), height: ceil(size.height))
    }

    static func convert(_ text: AttributedString, color: UIColor) -> NSAttributedString {
        let size: CGFloat = 14.5
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Theme.bubbleLineSpacing
        let out = NSMutableAttributedString()
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            // 斜体只靠倾斜，不再换斜体字体：英文本来就有斜体，叠在一起会歪两次。
            let font: UIFont = intent.contains(.code)
                ? .monospacedSystemFont(ofSize: size - 1, weight: .regular)
                : .systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if intent.contains(.emphasized) { attrs[.obliqueness] = 0.2 }
            if run.link != nil {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

/// 渐进模糊：一边是磨砂，往另一边慢慢淡到全透明（iOS 那种顶栏、底栏的感觉）。
/// fadeTo 是「最糊」的那一边。
struct FadingBlur: View {
    let fadeTo: VerticalEdge

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.85), location: 0.45),
                    .init(color: .clear, location: 1),
                ], startPoint: fadeTo == .top ? .top : .bottom, endPoint: fadeTo == .top ? .bottom : .top)
            )
            .allowsHitTesting(false)
    }
}
