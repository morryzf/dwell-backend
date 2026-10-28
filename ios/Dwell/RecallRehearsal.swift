import SwiftUI

/// 演练页上的一张卡：整张卡（能直接编辑、带进下一条），加上第几名、比第一名弱多少、为什么被找出来。
struct RecallCard: Identifiable, Equatable {
    let card: MemoryCard
    let rank: Int?
    /// 0–1：分数和第一名比。只拿来画那条细线，不显示数字。
    let strength: Double
    let reasons: [String]
    var id: String { card.id }

    init(json: [String: Any]) {
        card = MemoryCard(json: json)
        rank = json["rank"] as? Int
        strength = (json["strength"] as? NSNumber)?.doubleValue ?? 0
        reasons = json["reasons"] as? [String] ?? []
    }
}

/// 召回演练：拿一句话照聊天时的办法找一遍记忆卡，看会带上哪几张、为什么，哪几张差一点。
/// 只是查：不发给 Cloudy，不记进「最近一次带入」，不动任何卡。
struct RecallRehearsalView: View {
    @ObservedObject var store: MemoryStore
    @EnvironmentObject private var chat: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text = ""
    /// 最近一次真聊天时她说的那句；改过之后可以一键改回来。
    @State private var original = ""
    @State private var query = ""
    @State private var borrowed = false
    @State private var vector = true
    @State private var injectionOn = true
    @State private var picked: [RecallCard] = []
    @State private var mains: [RecallCard] = []
    @State private var near: [RecallCard] = []
    @State private var thenAt: Date?
    @State private var thenItems: [(id: String, content: String)] = []

    @State private var loading = false
    @State private var loaded = false
    @State private var appeared = false
    @State private var showNear = false
    @State private var showQuery = false
    @State private var editing: MemoryCard?
    @State private var toast = ""
    @State private var runTask: Task<Void, Never>?
    /// 上一次拿去找的那句：结果回来把输入框填上时，不要因为「字变了」再找一遍。
    @State private var lastRun: String?

    /// 一排一排画：标题和卡混在同一个列表里，卡从「会带上」掉进「差一点」时是挪过去的，不是消失再出现。
    private enum Row: Identifiable {
        case header(id: String, title: String, count: Int?)
        case card(RecallCard, faint: Bool, main: Bool)

        var id: String {
            switch self {
            case .header(let id, _, _): return id
            case .card(let item, _, _): return item.id
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = [.header(id: "h-picked", title: "会带上", count: picked.count + mains.count)]
        rows += picked.map { .card($0, faint: false, main: false) }
        rows += mains.map { .card($0, faint: false, main: true) }
        if !near.isEmpty {
            rows.append(.header(id: "h-near", title: "差一点", count: near.count))
            if showNear { rows += near.map { .card($0, faint: true, main: false) } }
        }
        return rows
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inputCard
                if loaded && picked.isEmpty && mains.isEmpty {
                    Text(text.isEmpty ? "说一句话试试，看会想起哪几张卡。" : "这句话一张卡也找不到。")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
                if !(picked.isEmpty && mains.isEmpty) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row)
                                .opacity(appeared || reduceMotion ? 1 : 0)
                                .offset(y: appeared || reduceMotion ? 0 : 8)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.25).delay(Double(min(index, 10)) * 0.04),
                                           value: appeared)
                        }
                    }
                }
                if thenAt != nil && text == original && !thenItems.isEmpty {
                    thenCard
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PaperBackground())
        .navigationTitle("召回演练")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !toast.isEmpty {
                Text(toast)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.chipText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.chip))
                    .padding(.bottom, 8)
                    .transition(.opacity)
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.easeOut(duration: 0.2)) { toast = "" }
                    }
            }
        }
        .task { await run(nil) }
        .onChange(of: text) { _, value in
            guard value != lastRun else { return }
            // 停下打字一会儿就重找，不用按按钮。
            runTask?.cancel()
            runTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await run(value)
            }
        }
        .sheet(item: $editing) { card in
            NavigationStack {
                ScrollView {
                    MemoryCardEditor(card: card, title: "编辑", saveLabel: "保存",
                                     events: store.threads.map { ($0.name, $0.hasMain) }) { edited in
                        if await store.save(edited) {
                            editing = nil
                            await run(text)
                        }
                    } onCancel: { editing = nil }
                    .padding(20)
                }
                .background(PaperBackground())
            }
            .presentationDetents([.large])
        }
    }

    // MARK: - 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("说一句话试试", text: $text, axis: .vertical)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .lineLimit(1...5)
            HStack(spacing: 10) {
                if loading { ProgressView().controlSize(.small) }
                if !original.isEmpty && text != original {
                    Button("改回原话") { text = original }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                }
                Spacer(minLength: 0)
                if !query.isEmpty {
                    Button(showQuery ? "收起" : "实际拿去找的话 ›") {
                        withAnimation(.easeOut(duration: 0.2)) { showQuery.toggle() }
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
                }
            }
            .buttonStyle(.plain)
            if showQuery {
                Text(query)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MemoryStyle.banner))
                    .transition(.opacity)
            }
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MemoryStyle.field))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
        .padding(.top, 8)
    }

    private var notes: [String] {
        var notes: [String] = []
        if borrowed { notes.append("这句很短，真聊天时会连上前面两句一起找") }
        if loaded && !vector && !text.isEmpty { notes.append("这次只按关键词找：没拿到向量") }
        if !injectionOn { notes.append("按需记忆现在关着：真聊天时不会自动带卡") }
        return notes
    }

    // MARK: - 结果

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .header(let id, let title, let count):
            if id == "h-near" {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1)) { showNear.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(title) · \(count ?? 0) 张")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showNear ? 90 : 0))
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 8)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(title) · \(count ?? 0) 张")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
        case .card(let item, let faint, let main):
            card(item, faint: faint, main: main)
        }
    }

    private func card(_ item: RecallCard, faint: Bool, main: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(main ? "+" : "\(item.rank ?? 0)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .frame(width: 16, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.card.content)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                if !item.card.thread.isEmpty {
                    Text((item.card.isMain ? "主卡 · " : "副卡 · ") + item.card.thread)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.dim)
                }
                if !item.reasons.isEmpty {
                    Text(item.reasons.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
                if !main {
                    // 跟第一名比有多强：一条细线，不写数字。
                    Capsule().fill(Theme.accent.opacity(0.2))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.accent)
                                .scaleEffect(x: max(0.04, item.strength), y: 1, anchor: .leading)
                        }
                }
            }
            Menu {
                Button {
                    let was = chat.isPicked(item.card)
                    if chat.togglePick(item.card) {
                        say(was ? "下一条消息不带这张了" : "下一条消息会带上这张")
                    } else {
                        say("最多带 \(ChatStore.maxPicks) 张")
                    }
                } label: {
                    Label(chat.isPicked(item.card) ? "不带进下一条" : "带进下一条", systemImage: "note.text")
                }
                Button { editing = item.card } label: { Label("编辑", systemImage: "pencil") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MemoryStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
        .opacity(faint ? 0.72 : 1)
        .transition(.opacity)
    }

    /// 那一轮真带了哪几张，跟现在会带的对一对：卡改过之后，看得出改得有没有用。
    private var thenCard: some View {
        let now = Set((picked + mains).map(\.id))
        let then = Set(thenItems.map(\.id))
        let fresh = (picked + mains).filter { !then.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("那时带了 \(thenItems.count) 张 · \(thenAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
            ForEach(thenItems, id: \.id) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(now.contains(item.id) ? "现在还在" : "现在不带了")
                        .font(.system(size: 11))
                        .foregroundStyle(now.contains(item.id) ? MemoryStyle.sage : MemoryStyle.danger)
                        .frame(width: 58, alignment: .leading)
                    Text(item.content)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                }
            }
            if !fresh.isEmpty {
                Text("现在新上来 \(fresh.count) 张：" + fresh.map { String($0.card.content.prefix(12)) + "…" }.joined(separator: "、"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MemoryStyle.banner))
        .padding(.top, 6)
    }

    // MARK: - 找

    private func say(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
    }

    /// value 是 nil：从最近一次真聊天那一轮出发，原话由后端填。
    private func run(_ value: String?) async {
        loading = true
        defer { loading = false }
        var body: [String: Any] = [:]
        if let value { body["text"] = value }
        guard let json = try? await API.shared.request("POST", "api/chats/\(store.chatID)/memory-recall/rehearse",
                                                       body: body) else {
            say("没找成，再试一次")
            return
        }
        // 打字比回答快：回来的这份已经不是输入框里那句了，就不要了。
        let answered = json["text"] as? String ?? ""
        if let value, value != text { return }
        let motion: Animation? = reduceMotion || !loaded ? nil : .spring(duration: 0.4, bounce: 0.12)
        withAnimation(motion) {
            if value == nil {
                original = json["original"] as? String ?? ""
                lastRun = answered
                text = answered
            } else {
                lastRun = value
            }
            query = json["query"] as? String ?? ""
            borrowed = json["borrowed"] as? Bool ?? false
            vector = json["vector"] as? Bool ?? false
            injectionOn = json["injection_enabled"] as? Bool ?? false
            picked = (json["picked"] as? [[String: Any]] ?? []).map(RecallCard.init(json:))
            mains = (json["mains"] as? [[String: Any]] ?? []).map(RecallCard.init(json:))
            near = (json["near"] as? [[String: Any]] ?? []).map(RecallCard.init(json:))
            if let then = json["then"] as? [String: Any] {
                thenAt = Date(timeIntervalSince1970: TimeInterval(then["at"] as? Int ?? 0))
                thenItems = (then["items"] as? [[String: Any]] ?? []).map {
                    (id: $0["id"] as? String ?? "", content: $0["content"] as? String ?? "")
                }
            }
        }
        if !loaded {
            loaded = true
            // 第一次打开：一张接一张淡进来。
            appeared = true
        }
    }
}
