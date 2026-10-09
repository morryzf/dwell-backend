import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore

    @State private var draft = ""
    @State private var showChats = false
    @State private var sentCount = 0
    @FocusState private var inputFocused: Bool

    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.messages) { message in
                        MessageRow(message: message)
                    }
                    if !store.streamingText.isEmpty {
                        Bubble(text: store.streamingText, kind: .gu)
                    } else if store.isReplying {
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
            .onChange(of: store.messages) { _, _ in scrollToBottom(proxy) }
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
    }

    // MARK: - 输入框

    private var inputBar: some View {
        VStack(spacing: 4) {
            if !store.status.isEmpty {
                Text(store.status)
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }
            HStack(alignment: .bottom, spacing: 8) {
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

    @ViewBuilder
    private var sendButton: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if store.isReplying && empty {
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
                draft = ""
                sentCount += 1
                Task { await store.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(empty ? Theme.dim.opacity(0.5) : Theme.accent)
            }
            .disabled(empty)
            .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
            .accessibilityLabel("发送")
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

// MARK: - 气泡

struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
        case .me, .gu:
            VStack(alignment: message.kind == .me ? .trailing : .leading, spacing: 6) {
                ForEach(Array(message.bubbles.enumerated()), id: \.offset) { _, text in
                    Bubble(text: text, kind: message.kind)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.kind == .me ? .trailing : .leading)
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
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("拷贝", systemImage: "doc.on.doc")
                }
            }
    }

    /// 只认行内 Markdown（加粗、斜体、代码、链接），换行原样保留。解析不了就当纯文本。
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
