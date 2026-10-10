import SafariServices
import SwiftUI

/// 侧边栏，照网页的 #drawer 画：顶上「Cloudy Studio」，两位助手的切换，
/// 中间一条月相时间线两边交错挂着各个页面，下面是 Recents，最底下设置和日夜按钮。
struct Sidebar: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.colorScheme) private var scheme

    @Binding var isOpen: Bool
    let onSettings: () -> Void
    /// 已经搬进 app 的页面（Tasks / Calendar / Focus / Library / Heartbeat / Usage）交给聊天页去开。
    let onPage: (NativePage) -> Void

    @State private var scope = "live"
    @State private var chats: [ChatSummary] = []
    @State private var loading = false
    @State private var renaming: ChatSummary?
    @State private var newName = ""
    @State private var deleting: ChatSummary?
    @State private var notYet: (title: String, sub: String)?
    @State private var showWeb = false

    private static let tools: [(title: String, sub: String)] = [
        ("Tasks", "little to-dos"), ("Calendar", "days worth circling"),
        ("Focus", "one thing at a time"), ("Journal", "words for the day"),
        ("Library", "pages, read slowly"), ("Archive", "chats, tucked away"),
        ("Heartbeat", "when he reaches out"), ("Usage", "what it all costs"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Cloudy Studio")
                .font(.custom("Ephesis", size: 36))
                .foregroundStyle(SidebarStyle.brandInk)
                .padding(.top, 4)
                .padding(.bottom, 12)
            assistantSwitch
            ScrollView {
                VStack(spacing: 0) {
                    timeline
                    recentsHeader
                    recents
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            foot
        }
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background {
            UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28, style: .continuous)
                        .fill(SidebarStyle.tint)
                )
                .overlay(
                    UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28, style: .continuous)
                        .stroke(SidebarStyle.edge, lineWidth: 1)
                )
                .shadow(color: Color(red: 72/255, green: 52/255, blue: 62/255).opacity(0.18), radius: 18, x: 14)
                .ignoresSafeArea()
        }
        .task(id: scope) { await load() }
        .task(id: store.chatID) { await load() }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let chat = renaming {
                    Task {
                        try? await API.shared.renameChat(chat.id, name: newName)
                        await load()
                        if chat.id == store.chatID { await store.refresh() }
                    }
                }
            }
        }
        .confirmationDialog("删除「\(deleting?.title ?? "")」？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let chat = deleting {
                    Task {
                        try? await API.shared.deleteChat(chat.id)
                        await load()
                        if chat.current { await store.refresh() }
                    }
                }
            }
        } message: {
            Text("里面所有消息都会永久删除，不能恢复。")
        }
        .confirmationDialog(notYet.map { "\($0.title) 还没搬进 app" } ?? "", isPresented: Binding(
            get: { notYet != nil }, set: { if !$0 { notYet = nil } }
        ), titleVisibility: .visible) {
            Button("在网页里打开") { showWeb = true }
        } message: {
            Text("这一页先在网页里用，之后再一页页搬过来。")
        }
        .sheet(isPresented: $showWeb) {
            if let url = API.shared.baseURL {
                SafariView(url: url).ignoresSafeArea()
            }
        }
    }

    // MARK: - 助手切换

    private var assistantSwitch: some View {
        HStack(spacing: 8) {
            ForEach(store.assistant?.all ?? []) { item in
                let on = item.id == store.assistant?.id
                Button {
                    guard !on else { return }
                    Task {
                        await store.switchAssistant(item.id)
                        await load()
                    }
                } label: {
                    Text(item.name)
                        .font(.system(size: 15, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(SidebarStyle.chipOn)
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(SidebarStyle.chipBorder, lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    // MARK: - 月相时间线

    /// 跟网页的 .drawer-timeline 一样：三列（左 / 30 / 右），每格 40 高，
    /// 第 n 个页面占第 n、n+1 两格，单数挂左边、双数挂右边，中轴是一整条月相图。
    private var timeline: some View {
        GeometryReader { geo in
            let side = (geo.size.width - 30) / 2
            ZStack(alignment: .topLeading) {
                Image("DrawerSky")
                    .renderingMode(.template)
                    .foregroundStyle(SidebarStyle.brandInk)
                    .frame(width: 40, height: 384)
                    .offset(x: side - 5, y: 0)
                ForEach(Array(Self.tools.enumerated()), id: \.offset) { index, tool in
                    let left = index % 2 == 0
                    Button {
                        if let page = NativePage(rawValue: tool.title) {
                            onPage(page)
                        } else {
                            notYet = tool
                        }
                    } label: {
                        VStack(alignment: left ? .trailing : .leading, spacing: 2) {
                            Text(tool.title)
                                .font(.custom("Ephesis", size: 27))
                                .foregroundStyle(SidebarStyle.brandInk)
                            Text(tool.sub)
                                .font(.system(size: 10.5).italic())
                                .tracking(0.42)
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(left ? .trailing : .leading, 12)
                        .frame(width: side, height: 80, alignment: left ? .trailing : .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: side, height: 80)
                    .offset(x: left ? 0 : side + 30, y: 14 + CGFloat(index) * 40)
                }
            }
        }
        .frame(height: 384)
        .padding(.top, -24)
    }

    // MARK: - Recents

    private var recentsHeader: some View {
        HStack {
            Text(scope == "box" ? "Archived" : "Recents")
                .font(.system(size: 15))
                .foregroundStyle(Theme.dim)
            Spacer()
            Button {
                scope = scope == "box" ? "live" : "box"
            } label: {
                Image(systemName: "archivebox")
                    .foregroundStyle(scope == "box" ? Theme.accent : Theme.text)
            }
            .accessibilityLabel(scope == "box" ? "返回最近对话" : "查看已收纳对话")
            Button {
                Task {
                    await store.newChat()
                    isOpen = false
                }
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.text)
            }
            .padding(.leading, 18)
            .accessibilityLabel("新对话")
        }
        .font(.system(size: 17))
        .buttonStyle(.plain)
        .padding(.horizontal, 26)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var recents: some View {
        if chats.isEmpty && !loading {
            Text(scope == "box" ? "收纳盒是空的" : "还没有聊天记录")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .padding(.vertical, 20)
        }
        // 网页的 .drawer-chat-list：行本身透明，只有正在聊的那一个垫一块浅底。
        LazyVStack(spacing: 3) {
            ForEach(chats) { chat in
                let here = chat.id == store.chatID
                Button {
                    Task { await open(chat) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chat.name.isEmpty ? "没名字" : chat.name)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(chat.preview.isEmpty ? "还没说过话" : chat.preview)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(here ? "在这儿" : Self.ago(chat.last))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .padding(.top, 1)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(minHeight: 47)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(here ? SidebarStyle.row : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        newName = chat.name
                        renaming = chat
                    } label: { Label("重命名", systemImage: "tag") }
                    Button {
                        Task {
                            try? await API.shared.archiveChat(chat.id, archived: !chat.archived)
                            await load()
                            if chat.id == store.chatID { await store.refresh() }
                        }
                    } label: {
                        Label(chat.archived ? "放出收纳" : "收进收纳", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        deleting = chat
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - 底部

    private var foot: some View {
        HStack {
            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(SidebarStyle.chipOn))
                    .overlay(Circle().stroke(SidebarStyle.chipBorder, lineWidth: 1))
            }
            .accessibilityLabel("设置")
            Spacer()
            Button {
                // 跟网页一样：日间夜间直接切。
                appearance.theme = scheme == .dark ? "light" : "dark"
            } label: {
                Image(systemName: scheme == .dark ? "moon" : "sun.max")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(scheme == .dark ? "切换日间模式" : "切换夜间模式")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    // MARK: - 行为

    private func load() async {
        loading = true
        defer { loading = false }
        chats = (try? await API.shared.chats(scope: scope)) ?? []
    }

    private func open(_ chat: ChatSummary) async {
        if chat.id == store.chatID {
            isOpen = false
            return
        }
        if chat.archived {
            store.flash("这间收起来了——先从收纳里放出来才能进")
            return
        }
        await store.switchChat(chat.id)
        isOpen = false
    }

    /// 跟网页的 ago 一样：刚刚 / 5m / 3h / 2d
    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

enum SidebarStyle {
    static let brandInk = Color(light: 0x5A4454, dark: 0xE6D6E1)
    static let tint = Color(light: Color(red: 247/255, green: 236/255, blue: 241/255).opacity(0.51),
                            dark: Color(hex: 0x3A3538).opacity(0.62))
    static let edge = Color(light: Color.white.opacity(0.72), dark: Color.white.opacity(0.1))
    static let chipOn = Color(light: Color.white.opacity(0.37), dark: Color.white.opacity(0.08))
    static let chipBorder = Color(light: Color.white.opacity(0.48), dark: Color.white.opacity(0.14))
    static let row = Color(light: Color.white.opacity(0.78), dark: Color(red: 1, green: 235/255, blue: 244/255).opacity(0.08))
}

/// 还没搬进 app 的页面先在网页里打开。用 Safari 的视图，网页那边的登录状态还在。
/// 侧边栏里已经做成原生的那几页。
enum NativePage: String, Identifiable {
    case tasks = "Tasks", calendar = "Calendar", usage = "Usage", heartbeat = "Heartbeat", focus = "Focus", library = "Library"
    var id: String { rawValue }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
