import SwiftUI

/// 记忆面板。照着网页的记忆控制台排：顶上「记忆」，一段说明和按需记忆的状态，
/// 四个页签（记忆卡 / 待确认 / 摘要 / 设置），下面是卡片。
struct MemoryView: View {
    @StateObject private var store: MemoryStore
    @Environment(\.dismiss) private var dismiss

    let chatTitle: String

    @State private var searchOpen = false
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
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Theme.text)
            Text("记忆卡把重要细节拆成可以管理的小条目；摘要维持这段关系的连续性。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: store.injectionEnabled ? "checkmark" : "pause.circle")
                Text(store.injectionEnabled
                     ? "按需记忆已开启：每轮最多带入 5 条相关卡片；隐藏、归档和过期内容会自动排除。"
                     : "按需记忆已关闭：回复时不会带入记忆卡。可以在「设置」里打开。")
            }
            .font(.system(size: 13))
            .foregroundStyle(store.injectionEnabled ? MemoryStyle.sage : Theme.dim)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.banner))
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
        .background(Capsule().fill(Theme.composer))
        .overlay(Capsule().stroke(MemoryStyle.border, lineWidth: 1))
    }

    private func tabButton(_ tab: MemoryStore.Tab, _ title: String, count: Int?) -> some View {
        let selected = store.tab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { store.tab = tab }
        } label: {
            HStack(spacing: 5) {
                Text(title).fontWeight(selected ? .semibold : .regular)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(MemoryStyle.countPill))
                }
            }
            .font(.system(size: 14.5))
            .foregroundStyle(selected ? Theme.text : Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if selected {
                    Capsule().fill(MemoryStyle.tabSelected)
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
            MemoryCardEditor(card: draft, title: "添加记忆卡", saveLabel: "添加") { card in
                if await store.add(card) { adding = nil }
            } onCancel: { adding = nil }
        }
        if store.cards.isEmpty && !store.loadingCards {
            MemoryEmpty(
                title: isSearching ? "没有符合条件的记忆" : "还没有正式记忆卡",
                text: isSearching ? "换个关键词或筛选条件看看。" : "先到「待确认」生成候选，并逐条采用；也可以点右上角 ＋ 自己写一张。"
            )
        }
        LazyVStack(spacing: 12) {
            ForEach(store.cards) { card in
                if editing?.id == card.id, let editing {
                    MemoryCardEditor(card: editing, title: "编辑", saveLabel: "保存") { edited in
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

    private var isSearching: Bool {
        !store.query.isEmpty || store.filter != "all" || !store.topic.isEmpty
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
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(MemoryStyle.tag))
                }
                TextField("搜索记忆内容", text: $store.query)
                    .font(.system(size: 15))
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
        }
    }

    private func topicChip(_ key: String, _ label: String) -> some View {
        let on = store.topic == key
        return Button {
            store.topic = key
            Task { await store.loadCards(reset: true) }
        } label: {
            Text(label)
                .font(.system(size: 13.5))
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

        LazyVStack(spacing: 12) {
            ForEach(store.drafts) { draft in
                if editingDraft?.id == draft.id, let editingDraft {
                    MemoryCardEditor(card: editingDraft, title: "先修改再采用", saveLabel: "采用") { edited in
                        if await store.accept(draft, edited: edited) { self.editingDraft = nil }
                    } onCancel: { self.editingDraft = nil }
                } else {
                    MemoryCardView(card: draft, labels: store.labels, kind: .draft, currentChatID: store.chatID,
                                   target: draft.targetCardID.flatMap { store.draftTargets[$0] }) {
                        Button("采用") { Task { _ = await store.accept(draft) } }
                            .buttonStyle(MemoryButtonStyle(kind: .primary))
                        Button("先修改") { editingDraft = draft }
                            .buttonStyle(MemoryButtonStyle(kind: .normal))
                        if draft.action != "update" {
                            Button("拆开") { Task { await store.splitDraft(draft) } }
                                .buttonStyle(MemoryButtonStyle(kind: .quiet))
                        }
                        Button("忽略") { Task { await store.discard(draft) } }
                            .buttonStyle(MemoryButtonStyle(kind: .quiet))
                    } onSource: {
                        sourceOf = (draft, true)
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(card.content)
                    .font(.system(size: 15.5))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.bubbleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if kind != .used {
                    Text(labels.type(card.memoryType))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(MemoryStyle.badge))
                }
            }
            MemoryTagFlow(tags: tags)
            if let target {
                Text(card.action == "split" ? "拆自原卡：\(target.content)"
                     : "原主题：\(target.topics.map(labels.topic).joined(separator: "、"))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
            if kind != .used {
                if card.hasSource {
                    Button(action: onSource) {
                        Text("\(card.sourceLabel) · 看原文")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.dim)
                            .underline(color: Theme.dim.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(card.sourceLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { actions }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MemoryStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
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
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MemoryStyle.tag))
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
    @State private var saving = false

    init(card: MemoryCard, title: String, saveLabel: String,
         onSave: @escaping (MemoryCard) async -> Void, onCancel: @escaping () -> Void) {
        _card = State(initialValue: card)
        self.title = title
        self.saveLabel = saveLabel
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("记忆内容")
            TextEditor(text: $card.content)
                .font(.system(size: 15.5))
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))

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
                            .font(.system(size: 13.5))
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
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.dim)
    }

    private func picker(_ selection: Binding<String>, _ options: [MemoryChoice]) -> some View {
        Picker("", selection: selection) {
            ForEach(options) { choice in Text(choice.label).tag(choice.key) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
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
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
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
            .font(.system(size: large ? 15.5 : 15, weight: kind == .normal || kind == .primary ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, large ? 16 : 14)
            .padding(.vertical, large ? 12 : 9)
            .frame(maxWidth: large ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: large ? 16 : 14, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: large ? 16 : 14, style: .continuous)
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
    static let card = Color(light: Color.white.opacity(0.55), dark: Color(hex: 0x433D41))
    static let border = Color(light: Color(hex: 0xE9DFE3), dark: Color.white.opacity(0.12))
    static let tag = Color(light: Color.white.opacity(0.9), dark: Color(hex: 0x4D464B))
    static let badge = Color(light: Color(hex: 0xF6EFF1), dark: Color(hex: 0x524A50))
    static let field = Color(light: Color.white.opacity(0.92), dark: Color(hex: 0x3B3639))
    static let banner = Color(light: Color(hex: 0xF4EEF0).opacity(0.8), dark: Color(hex: 0x433D41))
    static let buttonFill = Color(light: Color.white, dark: Color(hex: 0x524A50))
    static let tabSelected = Color(light: Color.white, dark: Color(hex: 0x5A5157))
    static let countPill = Color(light: Color(hex: 0xEEE4E8), dark: Color(hex: 0x5F555B))
    static let sage = Color(light: Color(hex: 0x739A6C), dark: Color(hex: 0xA8C0A0))
    static let danger = Color(light: Color(hex: 0xC2668B), dark: Color(hex: 0xE59AB8))
}
