import SwiftUI

/// 记忆面板。照着网页的记忆控制台排：顶上「记忆」，一段说明和按需记忆的状态，
/// 四个页签（记忆卡 / 待确认 / 摘要 / 设置），下面是卡片。
struct MemoryView: View {
    @StateObject private var store: MemoryStore
    @State private var leaving: [String: Edge] = [:]
    @Environment(\.dismiss) private var dismiss

    let chatTitle: String

    @State private var searchOpen = false
    @State private var historyOf: MemoryCard?
    @State private var timelineOf: MemoryCard?
    @State private var adding: MemoryCard?
    @State private var editing: MemoryCard?
    @State private var editingDraft: MemoryCard?
    @State private var sourceOf: (card: MemoryCard, isDraft: Bool)?
    @State private var confirmDelete: MemoryCard?
    @State private var confirmDiscardAll = false

    init(chatID: String, chatTitle: String) {
        _store = StateObject(wrappedValue: MemoryStore(chatID: chatID))
        self.chatTitle = chatTitle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intro
                    tabBar
                    switch store.tab {
                    case .cards: cardsPanel
                    case .review: reviewPanel
                    case .summary: MemorySummaryPanel(store: store)
                    case .settings: MemorySettingsPanel(store: store)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $historyOf) { card in
                MemoryHistorySheet(card: card, store: store)
            }
            .sheet(item: $timelineOf) { card in
                MemoryTimelineSheet(card: card, store: store)
            }
            .environment(\.memoryTimelineTap, { card in timelineOf = card })
            .confirmationDialog("这件事已经有主卡了", isPresented: Binding(get: { store.demoteAsk != nil },
                                                                     set: { if !$0 { store.demoteAsk = nil } }),
                                titleVisibility: .visible, presenting: store.demoteAsk) { ask in
                Button("把原来那张改成副卡，这张当主卡") {
                    Task {
                        let ok = ask.isNew ? await store.add(ask.card, demote: true) : await store.save(ask.card, demote: true)
                        if ok { if ask.isNew { adding = nil } else { editing = nil } }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { ask in
                Text(ask.message)
            }
            // 卡片上点「事件：…」：打开筛选那一栏，只看这件事的卡。
            .environment(\.memoryThreadTap, { name in
                withAnimation { searchOpen = true }
                Task { await store.showThread(name) }
            })
            .background(PaperBackground())
            .navigationTitle("记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        withAnimation { searchOpen.toggle() }
                        store.tab = .cards
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(searchOpen ? Theme.accent : Theme.text)
                    }
                    .accessibilityLabel("搜索记忆")
                    Button {
                        store.tab = .cards
                        adding = MemoryCard.blank(chatID: store.chatID)
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加记忆卡")
                }
            }
            .tint(Theme.text)
            .overlay(alignment: .bottom) { toastView }
            .task { await store.loadAll() }
            .onDisappear { store.stopPolling() }
            .sheet(isPresented: Binding(get: { sourceOf != nil }, set: { if !$0 { sourceOf = nil } })) {
                if let sourceOf {
                    MemorySourceSheet(store: store, card: sourceOf.card, isDraft: sourceOf.isDraft)
                }
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
            .confirmationDialog("全部忽略？", isPresented: $confirmDiscardAll, titleVisibility: .visible) {
                Button("全部忽略（\(store.drafts.count)）", role: .destructive) {
                    Task { await store.discardAll() }
                }
            }
        }
    }

    // MARK: - 顶部说明

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chatTitle)
                .font(.system(size: 25, weight: .regular, design: .serif))
                .foregroundStyle(Theme.text)
            Text("记忆卡把重要细节拆成可以管理的小条目；摘要维持这段关系的连续性。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: store.injectionEnabled ? "checkmark" : "pause.circle")
                Text(store.injectionEnabled
                     ? "按需记忆已开启：每轮最多带入 5 条相关卡片；隐藏、归档和过期内容会自动排除。"
                     : "按需记忆已关闭：回复时不会带入记忆卡。可以在「设置」里打开。")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(store.injectionEnabled ? MemoryStyle.sage : Theme.dim)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(MemoryStyle.banner))
        }
        .padding(.top, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.cards, "记忆卡", count: store.activeCount)
            tabButton(.review, "待确认", count: store.drafts.count)
            tabButton(.summary, "摘要", count: nil)
            tabButton(.settings, "设置", count: nil)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MemoryStyle.tabBar))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
    }

    private func tabButton(_ tab: MemoryStore.Tab, _ title: String, count: Int?) -> some View {
        let selected = store.tab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { store.tab = tab }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .bold : .regular))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(MemoryStyle.countPill))
                }
            }
            .minimumScaleFactor(0.8)
            .foregroundStyle(selected ? Theme.text : Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 3)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(MemoryStyle.tabSelected)
                        .shadow(color: Theme.bubbleShadow, radius: 6, y: 3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 记忆卡

    @ViewBuilder
    private var cardsPanel: some View {
        if let injection = store.lastInjection {
            DisclosureGroup {
                VStack(spacing: 10) {
                    ForEach(injection.items) { card in
                        MemoryCardView(card: card, labels: store.labels, kind: .used, currentChatID: store.chatID)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("最近一次带入 · \(injection.usedAt.formatted(date: .abbreviated, time: .shortened)) · \(injection.items.count) 条")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
            .tint(Theme.dim)
        }
        if searchOpen { searchPanel }
        if let draft = adding {
            MemoryCardEditor(card: draft, title: "添加记忆卡", saveLabel: "添加", events: eventChoices) { card in
                if await store.add(card) { adding = nil }
            } onCancel: { adding = nil }
        }
        if store.cards.isEmpty && !store.loadingCards {
            MemoryEmpty(
                title: isSearching ? "没有符合条件的记忆" : "还没有正式记忆卡",
                text: isSearching ? "换个关键词或筛选条件看看。" : "先到「待确认」生成候选，并逐条采用；也可以点右上角 ＋ 自己写一张。"
            )
        }
        LazyVStack(spacing: 11) {
            ForEach(store.cards) { card in
                if editing?.id == card.id, let editing {
                    MemoryCardEditor(card: editing, title: "编辑", saveLabel: "保存", events: eventChoices) { edited in
                        if await store.save(edited) { self.editing = nil }
                    } onCancel: { self.editing = nil }
                } else {
                    MemoryCardView(card: card, labels: store.labels, kind: .card, currentChatID: store.chatID) {
                        cardActions(card)
                    } onSource: {
                        sourceOf = (card, false)
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

    private var eventChoices: [(name: String, hasMain: Bool)] {
        store.threads.map { ($0.name, $0.hasMain) }
    }

    private var isSearching: Bool {
        !store.query.isEmpty || store.filter != "all" || !store.topic.isEmpty || !store.thread.isEmpty
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    .font(.system(size: 14))
                    .submitLabel(.search)
                    .onSubmit { Task { await store.loadCards(reset: true) } }
                Button {
                    Task { await store.loadCards(reset: true) }
                } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                }
            }
            .padding(6)
            .padding(.trailing, 8)
            .background(Capsule().fill(Theme.composer))
            .overlay(Capsule().stroke(MemoryStyle.border, lineWidth: 1))
            .onChange(of: store.filter) { _, _ in Task { await store.loadCards(reset: true) } }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    topicChip("", "全部类别")
                    ForEach(MemoryTaxonomy.topics) { choice in
                        topicChip(choice.key, store.labels.topic(choice.key))
                    }
                }
            }
            // 按事件看：一件事的主卡和细节卡排在一起。
            if !store.threads.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.threads, id: \.name) { item in
                            let on = store.thread == item.name
                            Button {
                                Task { await store.showThread(item.name) }
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
    }

    private func topicChip(_ key: String, _ label: String) -> some View {
        let on = store.topic == key
        return Button {
            store.topic = key
            Task { await store.loadCards(reset: true) }
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

    @ViewBuilder
    private func cardActions(_ card: MemoryCard) -> some View {
        if card.isArchived {
            Button("恢复") { Task { await store.setStatus(card, "active") } }
                .buttonStyle(MemoryButtonStyle(kind: .normal))
            Button("永久删除") { confirmDelete = card }
                .buttonStyle(MemoryButtonStyle(kind: .danger))
        } else {
            Button("编辑") { editing = card }
                .buttonStyle(MemoryButtonStyle(kind: .normal))
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

    // MARK: - 待确认

    @ViewBuilder
    private var reviewPanel: some View {
        Button {
            Task { await store.generateDrafts() }
        } label: {
            HStack(spacing: 8) {
                if store.cardState.isBusy { ProgressView().tint(.white).controlSize(.small) }
                Text(store.cardState.isBusy ? "正在整理…" : "生成未处理分段的记忆卡草稿")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MemoryButtonStyle(kind: .primary, large: true))
        .disabled(store.cardState.isBusy)

        if !store.cardState.error.isEmpty && store.cardState.status == "error" {
            MemoryNote(text: store.cardState.error, isError: true)
        } else if !store.cardState.note.isEmpty {
            MemoryNote(text: store.cardState.note, isError: false)
        }

        if !store.drafts.isEmpty {
            HStack(spacing: 10) {
                Button("采用全部（\(store.drafts.count)）") { Task { await store.acceptAll() } }
                    .buttonStyle(MemoryButtonStyle(kind: .normal, large: true))
                Button("全部忽略（\(store.drafts.count)）") { confirmDiscardAll = true }
                    .buttonStyle(MemoryButtonStyle(kind: .dangerQuiet, large: true))
            }
        } else if !store.cardState.isBusy {
            MemoryEmpty(title: "没有待确认的记忆", text: "每累计 50 条旧消息会自动生成一批；也可以点上面的按钮现在就整理。")
        }

        LazyVStack(spacing: 11) {
            ForEach(store.drafts) { draft in
                if editingDraft?.id == draft.id, let editingDraft {
                    MemoryCardEditor(card: editingDraft, title: "先修改再采用", saveLabel: "采用", events: eventChoices) { edited in
                        if await store.accept(draft, edited: edited) { self.editingDraft = nil }
                    } onCancel: { self.editingDraft = nil }
                } else {
                    MemoryCardView(card: draft, labels: store.labels, kind: .draft, currentChatID: store.chatID,
                                   target: draft.targetCardID.flatMap { store.draftTargets[$0] }) {
                        Button("采用") {
                            leaving[draft.id] = .leading
                            Task { _ = await store.accept(draft) }
                        }
                            .buttonStyle(MemoryButtonStyle(kind: .primary))
                        Button("先修改") { editingDraft = draft }
                            .buttonStyle(MemoryButtonStyle(kind: .normal))
                        if draft.action != "update" && draft.action != "revise" && draft.action != "append" {
                            Button("拆开") { Task { await store.splitDraft(draft) } }
                                .buttonStyle(MemoryButtonStyle(kind: .quiet))
                        }
                        Button("忽略") {
                            leaving[draft.id] = .trailing
                            Task { await store.discard(draft) }
                        }
                            .buttonStyle(MemoryButtonStyle(kind: .quiet))
                    } onSource: {
                        sourceOf = (draft, true)
                    }
                    // 采用往左收、忽略往右扔，滑出去的同时淡掉。
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .move(edge: leaving[draft.id] ?? .trailing).combined(with: .opacity)))
                }
            }
        }
    }

    // MARK: - 提示

    @ViewBuilder
    private var toastView: some View {
        if !store.toast.isEmpty {
            Text(store.toast)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.composer))
                .overlay(Capsule().stroke(MemoryStyle.border, lineWidth: 1))
                .shadow(color: Theme.composerShadow, radius: 10, y: 6)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: store.toast) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { store.toast = "" }
                }
        }
    }
}

// MARK: - 一张卡

struct MemoryCardView<Actions: View>: View {
    enum Kind { case card, draft, used }

    let card: MemoryCard
    let labels: MemoryLabels
    let kind: Kind
    let currentChatID: String
    var target: MemoryCard? = nil
    @ViewBuilder var actions: Actions
    var onSource: () -> Void = {}
    @Environment(\.memoryThreadTap) private var onThread
    @Environment(\.memoryTimelineTap) private var onTimeline
    @State private var actionsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind == .draft && card.action == "append" {
                // 给主卡加一步：哪件事、哪天，新的这一步整段都是新加的。
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 10.5))
                    Text("给主卡 · \(target?.thread ?? card.thread) 加一步")
                    let day = TimelineNode(date: card.nodeDate, text: "").label
                    if !day.isEmpty {
                        Text("· " + day).foregroundStyle(Theme.dim)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
            if kind != .draft, card.isMain, let latest = card.timeline.last {
                // 主卡在列表里只露最新的一步，整条时间线点开看。
                VStack(alignment: .leading, spacing: 5) {
                    if !latest.label.isEmpty {
                        Text(latest.label)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    }
                    Text(latest.text)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.bubbleText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { onTimeline(card) } label: {
                        HStack(spacing: 3) {
                            Text("时间线 · \(card.timeline.count) 步")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Text(card.action == "revise" && target != nil
                         ? Self.highlightAdded(card.content, comparedTo: target?.content ?? "")
                         : card.action == "append" ? Self.highlightAdded(card.content, comparedTo: "")
                         : AttributedString(card.content))
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.bubbleText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if kind != .used {
                        Text(labels.type(card.memoryType))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(MemoryStyle.badge))
                    }
                }
            }
            MemoryTagFlow(tags: tags)
            if !card.thread.isEmpty {
                // 这张卡属于哪件事；点一下只看这件事的卡。
                Button { onThread(card.thread) } label: {
                    // 主卡醒目一点：实心底、白字；副卡是淡底。
                    HStack(spacing: 4) {
                        Image(systemName: card.isMain ? "star.fill" : "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 9.5))
                        Text((card.isMain ? "主卡 · " : "副卡 · ") + card.thread)
                    }
                    .font(.system(size: 11.5, weight: card.isMain ? .semibold : .regular))
                    .foregroundStyle(card.isMain ? .white : Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(card.isMain ? Theme.send : Theme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            if let target, card.action == "revise" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("采用后，原卡会改成上面这样：")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.dim)
                    Text(target.content)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .strikethrough(true, color: Theme.dim.opacity(0.7))
                        .foregroundStyle(Theme.dim)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.dim.opacity(0.1)))
            } else if let target, card.action == "replace" {
                // 更新：上面是新的情况，下面划掉的是要被收起来的旧卡，一眼对照。
                VStack(alignment: .leading, spacing: 4) {
                    Text("采用后，这张旧卡会收进归档：")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.dim)
                    Text(target.content)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .strikethrough(true, color: Theme.dim.opacity(0.7))
                        .foregroundStyle(Theme.dim)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.dim.opacity(0.1)))
            } else if let target {
                Text(card.action == "split" ? "拆自原卡：\(target.content)"
                     : "原主题：\(target.topics.map(labels.topic).joined(separator: "、"))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
            }
            if kind != .used {
                HStack(spacing: 8) {
                    if card.hasSource {
                        Button(action: onSource) {
                            HStack(spacing: 3) {
                                Text(card.sourceLabel)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.dim)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(card.sourceLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.dim)
                    }
                    Spacer(minLength: 0)
                    // 正式记忆卡的那排按钮平时收着，点「⋯」再展开；待确认的要马上做决定，一直露着。
                    if kind == .card {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { actionsOpen.toggle() }
                        } label: {
                            Image(systemName: actionsOpen ? "chevron.up" : "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 34, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(actionsOpen ? "收起操作" : "更多操作")
                    }
                }
                if kind != .card || actionsOpen {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { actions }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(MemoryStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
        .opacity(card.isHidden ? 0.6 : 1)
    }

    private var tags: [String] {
        var out = card.topics.map(labels.topic)
        out.append(labels.importance(card.importance))
        out.append(labels.retention(card.retention) + (card.validUntil.map { " · 到 \($0)" } ?? ""))
        if card.isHidden { out.append("已隐藏") }
        if kind == .card && !card.chatID.isEmpty && card.chatID != currentChatID {
            out.append("来自 " + (card.chatName.isEmpty ? "别的窗口" : card.chatName))
        }
        if kind == .card {
            if card.sharedFrom != nil { out.append("共享来的") } else if card.sharedCount > 0 { out.append("已共享") }
        }
        if kind == .draft && card.action == "update" { out.append("重新分类") }
        if kind == .draft && card.action == "split" { out.append("拆分") }
        if kind == .draft && card.action == "replace" { out.append("更新旧卡") }
        if kind == .draft && card.action == "revise" { out.append(card.isMain ? "更新主卡" : "补全") }
        if kind == .draft && card.action == "append" { out.append("时间线") }
        return out
    }
}

extension MemoryCardView {
    /// 新文字里比旧文字多出来的那段标成醒目的颜色：前后没变的部分照常，中间新加（或改了）的上色。
    /// 主卡更新一般是在原来后面接着写，所以多半是结尾那一段亮起来。
    static func highlightAdded(_ new: String, comparedTo old: String) -> AttributedString {
        let a = Array(new), b = Array(old)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var out = AttributedString(String(a[..<prefix]))
        var added = AttributedString(String(a[prefix..<(a.count - suffix)]))
        added.foregroundColor = Theme.accent
        added.backgroundColor = Theme.accent.opacity(0.12)
        out += added
        out += AttributedString(String(a[(a.count - suffix)...]))
        return out
    }
}

extension MemoryCardView where Actions == EmptyView {
    init(card: MemoryCard, labels: MemoryLabels, kind: Kind, currentChatID: String) {
        self.init(card: card, labels: labels, kind: kind, currentChatID: currentChatID, actions: { EmptyView() })
    }
}

/// 标签一行放不下就换行。
struct MemoryTagFlow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MemoryStyle.tag))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 编辑一张卡

struct MemoryCardEditor: View {
    @State private var card: MemoryCard
    let title: String
    let saveLabel: String
    let onSave: (MemoryCard) async -> Void
    let onCancel: () -> Void
    /// 已有的事件，以及各自有没有主卡。
    let events: [(name: String, hasMain: Bool)]
    @State private var saving = false
    /// 选的是「新事件…」时，新名字写在这里。
    @State private var newEvent = ""
    @State private var choosingNew = false

    init(card: MemoryCard, title: String, saveLabel: String, events: [(name: String, hasMain: Bool)] = [],
         onSave: @escaping (MemoryCard) async -> Void, onCancel: @escaping () -> Void) {
        _card = State(initialValue: card)
        self.title = title
        self.saveLabel = saveLabel
        self.events = events
        self.onSave = onSave
        self.onCancel = onCancel
        let known = events.contains { $0.name == card.thread }
        _choosingNew = State(initialValue: !card.thread.isEmpty && !known)
        _newEvent = State(initialValue: known ? "" : card.thread)
    }

    /// 选了某件事：身份默认沿用原来的；原来没有的，那件事还没主卡就当主卡，有了就当副卡。
    private func pick(_ name: String) {
        choosingNew = false
        let wasSame = name == card.thread
        card.thread = name
        if name.isEmpty {
            card.threadRole = ""
        } else if !wasSame || card.threadRole.isEmpty {
            let hasMain = events.first { $0.name == name }?.hasMain ?? false
            card.threadRole = hasMain ? "detail" : "main"
        }
    }

    private var eventMenu: some View {
        Menu {
            Button("不属于任何事件") { pick("") }
            if !events.isEmpty {
                Section("已有的事件") {
                    ForEach(events, id: \.name) { event in
                        Button(event.hasMain ? event.name : event.name + "（还没有主卡）") { pick(event.name) }
                    }
                }
            }
            Button("新事件…") {
                choosingNew = true
                card.thread = newEvent
                card.threadRole = "main"
            }
        } label: {
            HStack {
                Text(choosingNew ? "新事件" : (card.thread.isEmpty ? "不属于任何事件" : card.thread))
                    .foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            .font(.system(size: 14))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("记忆内容")
            if card.isMain && !card.timeline.isEmpty {
                Text("主卡的内容是一条时间线，在「时间线」里一步一步改。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
            } else {
                TextEditor(text: $card.content)
                    .font(.system(size: 14))
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
            }

            label("属于哪件事")
            eventMenu
            if choosingNew {
                TextField("新事件的名字，如：追音音", text: Binding(get: { newEvent }, set: { value in
                    newEvent = value
                    card.thread = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }))
                .font(.system(size: 14))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
            }
            if !card.thread.isEmpty {
                // 一件事只有一张主卡：写清是什么事、跟谁有关、现在到哪一步；其余的都是副卡，记细节。
                Toggle(isOn: Binding(get: { card.threadRole == "main" },
                                     set: { card.threadRole = $0 ? "main" : "detail" })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("作为这件事的主卡").font(.system(size: 14)).foregroundStyle(Theme.text)
                        Text(card.threadRole == "main" ? "写清是什么事、跟谁有关、现在到哪一步"
                                                       : "现在是副卡，记这件事里的一个细节")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
                .tint(Theme.send)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
            }

            label("类型")
            picker($card.memoryType, MemoryTaxonomy.types)
            label("重要程度")
            picker($card.importance, MemoryTaxonomy.importance)
            label("保存时间")
            picker($card.retention, MemoryTaxonomy.retention)
            if card.retention == "time_bound" {
                label("有效至")
                DatePicker("", selection: untilBinding, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
            }

            label("主题（最多选 3 个）")
            FlowLayout(spacing: 8) {
                ForEach(MemoryTaxonomy.topics) { choice in
                    let key = choice.key, name = choice.label
                    let on = card.topics.contains(key)
                    Button {
                        if on {
                            card.topics.removeAll { $0 == key }
                        } else if card.topics.count < 3 {
                            card.topics.append(key)
                        }
                    } label: {
                        Text(name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(on ? .white : Theme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(on ? Theme.send : MemoryStyle.tag))
                            .overlay(Capsule().stroke(on ? .clear : MemoryStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(!on && card.topics.count >= 3 ? 0.45 : 1)
                }
            }

            HStack(spacing: 10) {
                Button {
                    saving = true
                    Task {
                        await onSave(card)
                        saving = false
                    }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.white).controlSize(.small) }
                        Text(saveLabel)
                    }
                }
                .buttonStyle(MemoryButtonStyle(kind: .primary))
                .disabled(saving || card.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", action: onCancel)
                    .buttonStyle(MemoryButtonStyle(kind: .quiet))
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MemoryStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.dim)
    }

    /// 跟「属于哪件事」同一个样子：字小一号，右边一个上下箭头。系统的菜单选择器改不了字号。
    private func picker(_ selection: Binding<String>, _ options: [MemoryChoice]) -> some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(options) { choice in Text(choice.label).tag(choice.key) }
            }
        } label: {
            HStack {
                Text(options.first { $0.key == selection.wrappedValue }?.label ?? selection.wrappedValue)
                    .foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            .font(.system(size: 14))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var untilBinding: Binding<Date> {
        Binding {
            card.validUntil.flatMap(Self.dayFormat.date(from:)) ?? Date().addingTimeInterval(7 * 86400)
        } set: {
            card.validUntil = Self.dayFormat.string(from: $0)
        }
    }
}

// MARK: - 看原文

struct MemorySourceSheet: View {
    @ObservedObject var store: MemoryStore
    let card: MemoryCard
    let isDraft: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var messages: [MemorySourceMessage] = []
    @State private var canExpand = false
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.content)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.banner))
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if messages.isEmpty {
                        MemoryEmpty(title: "原文找不到了", text: "这段对话可能已经被删除。")
                    }
                    ForEach(messages) { message in
                        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                            Text(message.made.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim)
                            Text(message.content)
                                .font(Theme.bubbleFont)
                                .lineSpacing(Theme.bubbleLineSpacing)
                                .foregroundStyle(Theme.bubbleText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(message.cited ? Theme.accent : Theme.bubbleBorder, lineWidth: message.cited ? 1.5 : 1)
                                )
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                    }
                    if canExpand {
                        Button("看整段原文") { Task { await load(full: true) } }
                            .buttonStyle(MemoryButtonStyle(kind: .normal, large: true))
                    }
                }
                .padding(18)
            }
            .background(PaperBackground())
            .navigationTitle("原文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .tint(Theme.text)
            .task { await load(full: false) }
        }
    }

    private func load(full: Bool) async {
        loading = true
        let result = await store.source(of: card, isDraft: isDraft, full: full)
        messages = result.messages
        canExpand = result.canExpand
        loading = false
    }
}

// MARK: - 小零件

struct MemoryEmpty: View {
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }
}

struct MemoryNote: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(isError ? MemoryStyle.danger : Theme.dim)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.banner))
    }
}

struct MemoryButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, quiet, danger, dangerQuiet }
    let kind: Kind
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, large ? 10 : 7)
            .frame(maxWidth: large ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: large ? 14 : 11, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: large ? 14 : 11, style: .continuous)
                .stroke(kind == .primary ? .clear : MemoryStyle.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .normal: return Theme.text
        case .quiet: return Theme.dim
        case .danger, .dangerQuiet: return MemoryStyle.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Theme.send
        case .normal: return MemoryStyle.buttonFill
        case .quiet, .danger, .dangerQuiet: return .clear
        }
    }
}

enum MemoryStyle {
    // 数值量自网页记忆控制台（.mc-card / .mc-tag / .mc-badge / .mc-btn）。
    static let card = Color(light: Color(hex: 0xF1EDEF), dark: Color(hex: 0x433D41))
    static let border = Color(light: Color(hex: 0xDFD7DA), dark: Color.white.opacity(0.12))
    static let tag = Color(light: Color(hex: 0xFFFDFD), dark: Color(hex: 0x4D464B))
    static let badge = Color(light: Color(hex: 0xFBF4F5), dark: Color(hex: 0x524A50))
    static let tabBar = Color(light: Color(hex: 0xFCF9FA).opacity(0.9), dark: Color(hex: 0x433D41))
    static let field = Color(light: Color.white.opacity(0.92), dark: Color(hex: 0x3B3639))
    static let banner = Color(light: Color(hex: 0xEBE6E9).opacity(0.72), dark: Color(hex: 0x433D41))
    static let buttonFill = Color(light: Color(hex: 0xFFFDFD), dark: Color(hex: 0x524A50))
    static let tabSelected = Color(light: Color(hex: 0xFFFDFD), dark: Color(hex: 0x5A5157))
    static let countPill = Color(light: Color(hex: 0xEFE4E8), dark: Color(hex: 0x5F555B))
    static let sage = Color(light: Color(hex: 0x7F9A84), dark: Color(hex: 0xA8C0A0))
    static let danger = Color(light: Color(hex: 0xBD7187), dark: Color(hex: 0xE59AB8))
}

private struct MemoryThreadTapKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    /// 点卡片上的「事件：…」做什么（记忆页设成「只看这件事」）。
    var memoryThreadTap: (String) -> Void {
        get { self[MemoryThreadTapKey.self] }
        set { self[MemoryThreadTapKey.self] = newValue }
    }
}

/// 主卡的旧版本：主卡在原卡上更新，改之前的内容按时间倒着排。
struct MemoryHistorySheet: View {
    let card: MemoryCard
    @ObservedObject var store: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [(text: String, reason: String, made: Date)] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("现在", card.content, nil)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        section(item.made.formatted(date: .abbreviated, time: .shortened)
                                + (item.reason.isEmpty ? "" : " · " + item.reason), item.text, nil)
                    }
                    if loaded && items.isEmpty {
                        Text("还没有旧版本。").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    }
                }
                .padding(18)
            }
            .background(PaperBackground())
            .navigationTitle("主卡 · \(card.thread)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } }
            }
            .task {
                items = await store.history(card)
                loaded = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func section(_ title: String, _ text: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.dim)
            Text(text).font(.system(size: 13.5)).lineSpacing(4).foregroundStyle(Theme.bubbleText).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MemoryStyle.card))
    }
}

private struct MemoryTimelineTapKey: EnvironmentKey {
    static let defaultValue: (MemoryCard) -> Void = { _ in }
}

extension EnvironmentValues {
    /// 点主卡上的「时间线 ›」：打开整条时间线。
    var memoryTimelineTap: (MemoryCard) -> Void {
        get { self[MemoryTimelineTapKey.self] }
        set { self[MemoryTimelineTapKey.self] = newValue }
    }
}

/// 主卡的时间线：左边一条细线，每一步一个点，最新的那一步点是实心的；右边是日子和这一步发生了什么。
/// 右上角「编辑」进到逐条改：改日子、改字、删一步、加一步。
struct MemoryTimelineSheet: View {
    @State var card: MemoryCard
    @ObservedObject var store: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var nodes: [TimelineNode] = []
    @State private var appeared = false
    @State private var saving = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("主卡 · \(card.thread)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.bottom, 18)
                    if editing { editor } else { timeline }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(PaperBackground())
            .navigationTitle("时间线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if editing {
                        Button("取消") { withAnimation(.easeOut(duration: 0.2)) { editing = false } }
                    } else {
                        Button("历史") { showHistory = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editing {
                        Button("保存") { Task { await save() } }
                            .disabled(saving || nodes.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    } else {
                        Button("编辑") {
                            nodes = card.timeline
                            withAnimation(.easeOut(duration: 0.2)) { editing = true }
                        }
                    }
                }
            }
            .sheet(isPresented: $showHistory) { MemoryHistorySheet(card: card, store: store) }
            .onAppear {
                // 一步一步浮出来：每步晚 40 毫秒，0.2 秒，只动透明度和位移。
                if reduceMotion { appeared = true } else { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
            }
        }
        .presentationDetents([.large])
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(card.timeline.enumerated()), id: \.offset) { index, node in
                let last = index == card.timeline.count - 1
                HStack(alignment: .top, spacing: 14) {
                    // 左边那一栏：点 + 往下接到下一步的线。
                    VStack(spacing: 0) {
                        dot(newest: last)
                            .padding(.top, 3)
                        if !last {
                            Rectangle()
                                .fill(Theme.accent.opacity(0.22))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                                .padding(.top, 4)
                        }
                    }
                    .frame(width: 14)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(node.label.isEmpty ? "某天" : node.label)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(last ? Theme.accent : Theme.dim)
                        Text(node.text)
                            .font(.system(size: 14.5))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.bubbleText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, last ? 0 : 26)
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2).delay(Double(index) * 0.04), value: appeared)
            }
            if card.timeline.isEmpty {
                Text("还没有任何一步。点右上角「编辑」加一步。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private func dot(newest: Bool) -> some View {
        ZStack {
            if newest {
                Circle().fill(Theme.accent.opacity(0.18)).frame(width: 18, height: 18)
                Circle().fill(Theme.accent).frame(width: 10, height: 10)
            } else {
                Circle().fill(MemoryStyle.card).frame(width: 10, height: 10)
                Circle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 2).frame(width: 10, height: 10)
            }
        }
        .frame(width: 14, height: 14)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($nodes) { $node in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        DatePicker("", selection: dateBinding($node.date), displayedComponents: .date)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                        Spacer()
                        Button(role: .destructive) {
                            withAnimation(.easeOut(duration: 0.2)) { nodes.removeAll { $0.id == node.id } }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(MemoryStyle.danger)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删掉这一步")
                    }
                    TextEditor(text: $node.text)
                        .font(.system(size: 14))
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MemoryStyle.field))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MemoryStyle.card))
            }
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    nodes.append(TimelineNode(date: Self.format.string(from: Date()), text: ""))
                }
            } label: {
                Label("加一步", systemImage: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MemoryButtonStyle(kind: .normal, large: true))
            Text("保存时会按日子重新排好。改之前的那版会留在「历史」里。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)
        }
    }

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dateBinding(_ text: Binding<String>) -> Binding<Date> {
        Binding(get: { Self.format.date(from: text.wrappedValue) ?? Date() },
                set: { text.wrappedValue = Self.format.string(from: $0) })
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let kept = nodes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let updated = await store.saveTimeline(card, kept) {
            card = updated
            withAnimation(.easeOut(duration: 0.2)) { editing = false }
        }
    }
}
