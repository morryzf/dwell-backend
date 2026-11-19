import SwiftUI

// MARK: - 搜索页

/// 搜索记忆：单独一页。上面是搜索框和几排筛选，下面是找到的卡，卡上的操作跟记忆页里一样。
/// 用的是它自己的一份列表，这里怎么搜、怎么筛，退回去记忆页还是原来那一整列。
struct MemorySearchPage: View {
    @StateObject private var store: MemoryStore
    /// 从卡片上的「事件：…」点进来的：先选中这件事，不抢着弹键盘。
    private let startThread: String
    @State private var loaded = false
    /// 上一次真去搜的那句，字没变就不重搜。
    @State private var searched = ""
    @FocusState private var focused: Bool

    init(chatID: String, thread: String) {
        _store = StateObject(wrappedValue: MemoryStore(chatID: chatID))
        startThread = thread
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchBar
                MemoryKindFilter(store: store)
                topics
                if !store.threads.isEmpty { threads }
                MemoryCardList(store: store,
                               emptyTitle: "没有符合条件的记忆",
                               emptyText: "换个关键词或筛选条件看看。",
                               onThread: { name in pickThread(name) })
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PaperBackground())
        .navigationTitle("搜索记忆")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.text)
        .overlay(alignment: .bottom) { MemoryToast(store: store) }
        // 从编辑页退回来时这里会再跑一遍，只有头一次才摆初始状态。
        .task {
            guard !loaded else { return }
            loaded = true
            store.thread = startThread
            if startThread.isEmpty {
                // 等这一页推到位再弹键盘，不然两个动画挤在一起。
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    focused = true
                }
            }
            await store.loadCards(reset: true)
        }
        // 边打边搜：停手一小会儿再去找，不用每次都点键盘上的「搜索」。
        .task(id: store.query) {
            guard loaded, store.query != searched else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
        .onChange(of: store.filter) { _, _ in Task { await search() } }
        .onDisappear { store.stopPolling() }
    }

    /// 上一趟还没回来就等它回来再搜，不然这一次会被直接丢掉，看到的还是旧结果。
    private func search() async {
        while store.loadingCards {
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
        }
        searched = store.query
        await store.loadCards(reset: true)
    }

    /// 只看这件事；再点一次同一个就取消。
    private func pickThread(_ name: String) {
        store.thread = store.thread == name ? "" : name
        Task { await search() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("筛选", selection: $store.filter) {
                    ForEach(MemoryTaxonomy.filters) { choice in
                        Text(choice.key == "archived" && store.archivedCount > 0
                             ? "\(choice.label) \(store.archivedCount)" : choice.label)
                            .tag(choice.key)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(MemoryTaxonomy.filters.first { $0.key == store.filter }?.label ?? "全部")
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(MemoryStyle.tag))
            }
            TextField("搜索记忆内容", text: $store.query)
                .font(.system(size: 15))
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await search() } }
            if store.query.isEmpty {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
            } else {
                Button {
                    store.query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空")
            }
        }
        .padding(6)
        .padding(.trailing, 8)
        .background(Capsule().fill(Theme.composer))
        .overlay(Capsule().stroke(MemoryStyle.border, lineWidth: 1))
    }

    private var topics: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                topicChip("", "全部类别")
                ForEach(MemoryTaxonomy.topics) { choice in
                    topicChip(choice.key, store.labels.topic(choice.key))
                }
            }
        }
    }

    private func topicChip(_ key: String, _ label: String) -> some View {
        let on = store.topic == key
        return Button {
            store.topic = key
            Task { await search() }
        } label: {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(on ? .white : Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(on ? Theme.send : MemoryStyle.tag))
                .overlay(Capsule().stroke(on ? .clear : MemoryStyle.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 按事件看：一件事的主卡和细节卡排在一起。
    private var threads: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.threads, id: \.name) { item in
                    let on = store.thread == item.name
                    Button {
                        pickThread(item.name)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 10.5))
                            Text("\(item.name) \(item.count)")
                            if on { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(on ? .white : Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(on ? Theme.send : MemoryStyle.tag))
                        .overlay(Capsule().stroke(on ? .clear : MemoryStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 全部 / 卡片 / 书签

/// 一排小字，不占地方。记忆页和搜索页都用。
struct MemoryKindFilter: View {
    @ObservedObject var store: MemoryStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach([("all", "全部"), ("cards", "卡片"), ("bookmarks", "书签")], id: \.0) { key, title in
                let on = store.kind == key
                Button {
                    guard !on else { return }
                    store.kind = key
                    Task { await store.loadCards(reset: true) }
                } label: {
                    Text(key == "bookmarks" && store.bookmarkCount > 0 ? "\(title) \(store.bookmarkCount)" : title)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.dim)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(Capsule().fill(on ? MemoryStyle.tabSelected : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - 一列卡

/// 记忆卡和书签排成的一列，连同卡上的操作：编辑（推进去一整页）、带进下一条、历史、归档……
/// 记忆页和搜索页各放一份，各管各的状态。
struct MemoryCardList: View {
    @ObservedObject var store: MemoryStore
    /// 聊天那边：「带进下一条消息」把卡放进输入框上面。
    @EnvironmentObject private var chat: ChatStore

    let emptyTitle: String
    let emptyText: String
    /// 点卡片上的「事件：…」做什么。
    let onThread: (String) -> Void

    /// 正在编辑的那张。页面退出去时不清掉，退场的那半秒里页面才不会空。
    @State private var editing: MemoryCard?
    @State private var editorOpen = false
    @State private var editingBookmark: MemoryCard?
    @State private var bookmarkOpen = false
    @State private var historyOf: MemoryCard?
    @State private var timelineOf: MemoryCard?
    @State private var sourceOf: MemoryCard?
    @State private var confirmDelete: MemoryCard?
    @State private var deletingBookmark: MemoryCard?

    private var assistantName: String { chat.assistant?.name ?? "Cloudy" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.cards.isEmpty && !store.loadingCards {
                MemoryEmpty(title: emptyTitle, text: emptyText)
            }
            LazyVStack(spacing: 11) {
                ForEach(store.cards) { card in
                    if card.isBookmark {
                        BookmarkCardView(card: card, assistantName: assistantName) {
                            editingBookmark = card
                            bookmarkOpen = true
                        } onSource: {
                            sourceOf = card
                        } onDelete: {
                            deletingBookmark = card
                        }
                    } else {
                        MemoryCardView(card: card, labels: store.labels, kind: .card, currentChatID: store.chatID) {
                            cardActions(card)
                        } onSource: {
                            sourceOf = card
                        }
                    }
                }
            }
            if store.hasMoreCards {
                Button {
                    Task { await store.loadCards(reset: false) }
                } label: {
                    HStack {
                        if store.loadingCards { ProgressView().controlSize(.small) }
                        Text("再显示 \(min(30, store.total - store.cards.count)) 条 · 还有 \(store.total - store.cards.count) 条")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MemoryButtonStyle(kind: .normal))
            }
        }
        .environment(\.memoryThreadTap, onThread)
        .environment(\.memoryTimelineTap, { card in timelineOf = card })
        .navigationDestination(isPresented: $editorOpen) {
            if let editing {
                MemoryCardEditor(card: editing, title: "编辑", saveLabel: "保存",
                                 events: store.threads.map { ($0.name, $0.hasMain) }, store: store) { edited, demote in
                    await store.save(edited, demote: demote)
                }
            }
        }
        .navigationDestination(isPresented: $bookmarkOpen) {
            if let card = editingBookmark { bookmarkPage(card) }
        }
        .sheet(item: $historyOf) { card in
            MemoryHistorySheet(card: card, store: store)
        }
        .sheet(item: $timelineOf) { card in
            MemoryTimelineSheet(card: card, store: store)
        }
        .sheet(item: $sourceOf) { card in
            MemorySourceSheet(store: store, card: card, isDraft: false)
        }
        .confirmationDialog("删掉这个书签？", isPresented: Binding(
            get: { deletingBookmark != nil }, set: { if !$0 { deletingBookmark = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let card = deletingBookmark { Task { await store.deleteBookmark(card) } }
                deletingBookmark = nil
            }
        } message: {
            Text("聊天里的原话不受影响，只是不再当作记忆。")
        }
        .confirmationDialog("永久删除这张记忆卡？", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                if let card = confirmDelete { Task { await store.deleteForever(card) } }
                confirmDelete = nil
            }
        } message: {
            Text("删除后无法恢复，与它关联的带入记录也会一起清除。")
        }
    }

    /// 改书签：也是一整页，里面还是那张表。
    private func bookmarkPage(_ card: MemoryCard) -> some View {
        ScrollView {
            BookmarkEditor(card: card, assistantName: assistantName) { label, why in
                if await store.updateBookmark(card, label: label == card.label ? nil : label,
                                              why: why == card.why ? nil : why) {
                    bookmarkOpen = false
                }
            } onRemoveLine: { line in
                if await store.updateBookmark(card, removing: line.id) {
                    // 去掉一句后换上新的那张；整张都没了就退出去。
                    if let fresh = store.cards.first(where: { $0.id == card.id }) {
                        editingBookmark = fresh
                    } else {
                        bookmarkOpen = false
                    }
                }
            } onCancel: {
                bookmarkOpen = false
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PaperBackground())
        .navigationTitle("编辑书签")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.text)
        .overlay(alignment: .bottom) { MemoryToast(store: store) }
    }

    @ViewBuilder
    private func cardActions(_ card: MemoryCard) -> some View {
        if card.isArchived {
            Button("恢复") { Task { await store.setStatus(card, "active") } }
                .buttonStyle(MemoryButtonStyle(kind: .normal))
            Button("永久删除") { confirmDelete = card }
                .buttonStyle(MemoryButtonStyle(kind: .danger))
        } else {
            Button("编辑") {
                editing = card
                editorOpen = true
            }
            .buttonStyle(MemoryButtonStyle(kind: .normal))
            Button(chat.isPicked(card) ? "已带上" : "带进下一条") {
                if chat.isPicked(card) {
                    chat.togglePick(card)
                    store.toast = "下一条消息不带这张了"
                } else if chat.togglePick(card) {
                    store.toast = "下一条消息会带上这张"
                } else {
                    store.toast = "最多带 \(ChatStore.maxPicks) 张"
                }
            }
            .buttonStyle(MemoryButtonStyle(kind: .quiet))
            if card.isMain {
                // 主卡在原卡上更新，之前的每一版都能翻。
                Button("历史") { historyOf = card }
                    .buttonStyle(MemoryButtonStyle(kind: .quiet))
            }
            // 单独读看不懂（只写了「那个女生」）的卡：让模型补上名字和事件，补好进待确认。
            // 主卡是时间线，直接在时间线里改，不用补全。
            if !card.isMain {
                Button("补全") { Task { await store.completeCard(card) } }
                    .buttonStyle(MemoryButtonStyle(kind: .quiet))
                    .disabled(store.cardState.isBusy)
            }
            if card.sharedFrom == nil && card.sharedCount == 0 {
                Button("共享") { Task { await store.share(card) } }
                    .buttonStyle(MemoryButtonStyle(kind: .quiet))
            }
            Button(card.isHidden ? "重新启用" : "暂时隐藏") {
                Task { await store.setStatus(card, card.isHidden ? "active" : "hidden") }
            }
            .buttonStyle(MemoryButtonStyle(kind: .quiet))
            Button("归档") { Task { await store.archive(card) } }
                .buttonStyle(MemoryButtonStyle(kind: .danger))
        }
    }
}
