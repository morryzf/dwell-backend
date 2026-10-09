import PhotosUI
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore

    @State private var draft = ""
    @State private var showChats = false
    @State private var sentCount = 0
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pendingImages: [PendingImage] = []
    @State private var preparingImages = false
    @State private var editing: Message?
    @State private var deleting: Message?
    @FocusState private var inputFocused: Bool

    private let bottomID = "bottom"
    /// 后端一次最多收两张图。
    private let maxImages = 2

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
                    if !store.streamingText.isEmpty {
                        Bubble(text: store.streamingText, kind: .gu)
                    } else if store.isReplying && store.streamingThinking.isEmpty {
                        TypingDots()
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            // 原生 app 最舒服的一点：往下一拖，键盘跟着手指收回去。
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            // 只在最底下多了新消息时才滚到底；往上翻出更早的消息时不能把人拽回去。
            .onChange(of: store.messages.last?.id) { _, _ in scrollToBottom(proxy) }
            .onChange(of: store.streamingText) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: inputFocused) { _, focused in
                if focused { scrollToBottom(proxy) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        }
        .navigationTitle(store.assistant?.name ?? "Dwell")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showChats) {
            ChatListView()
                .environmentObject(store)
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
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            if !store.status.isEmpty {
                Text(store.status)
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }
            if !pendingImages.isEmpty || preparingImages {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $pickedItems,
                             maxSelectionCount: max(1, maxImages - pendingImages.count),
                             matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 34, height: 38)
                }
                .disabled(pendingImages.count >= maxImages)
                .accessibilityLabel("选图片")

                TextField("说点什么", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var attachmentStrip: some View {
        HStack(spacing: 8) {
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
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.dim)
            }
            .accessibilityLabel("停下")
        } else {
            Button {
                let text = draft
                let images = pendingImages
                draft = ""
                pendingImages = []
                sentCount += 1
                Task { await store.send(text, images: images) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Theme.accent : Theme.dim.opacity(0.5))
            }
            .disabled(!canSend || preparingImages)
            .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
            .accessibilityLabel("发送")
        }
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

    // MARK: - 顶栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showChats = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("聊天列表")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
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
                Image(systemName: "ellipsis.circle")
            }
        }
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

struct MessageRow: View {
    @EnvironmentObject private var store: ChatStore

    let message: Message
    let onEdit: (Message) -> Void
    let onDelete: (Message) -> Void

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
        case .me, .gu:
            let isMe = message.kind == .me
            VStack(alignment: isMe ? .trailing : .leading, spacing: 6) {
                if !message.thinking.isEmpty {
                    ThinkingView(text: message.thinking, live: false)
                }
                if !message.tools.isEmpty {
                    Label("用了 " + message.tools.joined(separator: "、"), systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                ForEach(Array(message.images.enumerated()), id: \.offset) { _, url in
                    MessageImage(url: url)
                }
                ForEach(Array(message.bubbles.enumerated()), id: \.offset) { _, text in
                    Bubble(text: text, kind: message.kind)
                        .contextMenu { menu(copying: text) }
                }
                if message.fromHeartbeat && !isMe {
                    Text("主动找你的")
                        .font(.caption2)
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
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

struct Bubble: View {
    let text: String
    let kind: Message.Kind

    var body: some View {
        let isMe = kind == .me
        Text(Self.render(text))
            .font(.body)
            .lineSpacing(3)
            .padding(.horizontal, isMe ? 14 : 2)
            .padding(.vertical, isMe ? 9 : 2)
            .background {
                // 跟网页一样：自己说的话在气泡里，回复直接铺在背景上。
                if isMe {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.userBubble)
                }
            }
            .frame(maxWidth: isMe ? 300 : .infinity, alignment: isMe ? .trailing : .leading)
    }

    /// 只认行内 Markdown（加粗、斜体、代码、链接），换行原样保留。解析不了就当纯文本。
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 回复前的思考，默认折起来，点开看。
struct ThinkingView: View {
    let text: String
    /// 还在想：标题显示「在想…」。
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text(live ? "在想…" : "想了想")
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.caption)
                .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.dim.opacity(0.3)).frame(width: 2)
                    }
                    .textSelection(.enabled)
            }
        }
    }
}

struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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
                    .fill(Theme.dim)
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
