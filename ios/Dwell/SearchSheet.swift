import SwiftUI

/// 「搜索」，照网页的 #findSheet：一个框翻聊天、心事簿、收藏的话、悄悄话、夜记和日历；
/// 右边的日历按钮按日子翻聊天。点到聊天里的一句，就切过去、滚到那句。
struct SearchSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    struct Hit: Identifiable {
        let id = UUID()
        let kind: String
        let date: String
        let snippet: String
        let chatID: String
        let messageID: String

        init(json: [String: Any]) {
            kind = json["kind"] as? String ?? ""
            date = json["date"] as? String ?? ""
            snippet = json["snippet"] as? String ?? ""
            chatID = json["chat_id"] as? String ?? ""
            messageID = json["message_id"] as? String ?? ""
        }
    }

    @State private var query = ""
    @State private var hits: [Hit] = []
    @State private var status = "翻的是聊天、心事簿、收藏的话、悄悄话、夜记和日历。\n想不起来哪天的事，就打一个词进去，或者点右边的日历按日子翻。"
    @State private var byDay = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                    TextField("找一句话、一个人、一天…", text: $query)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { run(now: true) }
                    Button {
                        byDay.toggle()
                        if byDay { query = ""; focused = false }
                    } label: {
                        Image(systemName: "calendar")
                            .foregroundStyle(byDay ? Theme.accent : Theme.dim)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(byDay ? Theme.accent.opacity(0.15) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("按日子翻聊天")
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bubble))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ScrollView {
                    if byDay {
                        FindCalendar { chatID, messageID in jump(chatID, messageID) }
                            .padding(16)
                    } else {
                        results.padding(16)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(PaperBackground())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .onChange(of: query) { _, _ in
                if !query.isEmpty { byDay = false }
                run(now: false)
            }
            .onAppear { focused = true }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(hits) { hit in
                Button { jump(hit.chatID, hit.messageID) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(hit.kind)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent.opacity(0.14)))
                            Text(hit.date).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
                            Spacer()
                            if !hit.chatID.isEmpty {
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.dim)
                            }
                        }
                        Text(highlight(hit.snippet))
                            .font(.system(size: 14.5))
                            .foregroundStyle(Theme.text)
                            .lineSpacing(4)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bubble))
                }
                .buttonStyle(.plain)
                .disabled(hit.chatID.isEmpty || hit.messageID.isEmpty)
            }
        }
    }

    /// 搜的那个词在片段里标粉。
    private func highlight(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let range = text.range(of: q, options: .caseInsensitive) {
            text[range].foregroundColor = Theme.accent
            text[range].font = .system(size: 14.5, weight: .semibold)
        }
        return text
    }

    private func run(now: Bool) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            status = "写点什么，我去翻"
            return
        }
        searchTask = Task {
            if !now { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            status = "翻着呢…"
            do {
                let json = try await API.shared.request("GET", "api/find", query: ["q": q])
                guard !Task.isCancelled else { return }
                hits = (json["hits"] as? [[String: Any]] ?? []).map(Hit.init(json:))
                status = hits.isEmpty ? "没找着——换个说法试试，或者那件事还没写下来" : "翻到 \(hits.count) 处"
            } catch {
                status = "翻不动了，再试一次"
            }
        }
    }

    private func jump(_ chatID: String, _ messageID: String) {
        guard !chatID.isEmpty, !messageID.isEmpty else { return }
        dismiss()
        Task { await store.open(chat: chatID, message: messageID) }
    }
}

/// 搜索里的日历：一个月一页，有聊天的日子带个小点；点一天，下面列出那天聊过的几间。
private struct FindCalendar: View {
    let onOpen: (String, String) -> Void

    struct DayChat: Identifiable {
        let id = UUID()
        let chatID: String
        let chatName: String
        let messageID: String
        let range: String
        let count: Int
        let snippet: String
    }

    @State private var month = HomeClock.calendar.date(
        from: HomeClock.calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var days: [String: Int] = [:]
    @State private var selected = ""
    @State private var chats: [DayChat] = []
    @State private var note = ""

    private var cal: Calendar { HomeClock.calendar }
    private var monthKey: String { String(HomeClock.day(month).prefix(7)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text("\(cal.component(.year, from: month)) 年 \(cal.component(.month, from: month)) 月")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(monthKey >= String(HomeClock.day().prefix(7)))
            }
            .foregroundStyle(Theme.text)
            .buttonStyle(.plain)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 36) }
                ForEach(1...dayCount, id: \.self) { n in
                    let key = monthKey + String(format: "-%02d", n)
                    let has = days[key] != nil
                    Button {
                        selected = key
                        Task { await loadDay(key) }
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(n)")
                                .font(.system(size: 14).monospacedDigit())
                                .foregroundStyle(key == selected ? .white : (has ? Theme.text : Theme.dim.opacity(0.5)))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(key == selected ? Theme.accent : .clear))
                            Circle().fill(has ? Theme.accent : .clear).frame(width: 4, height: 4)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!has)
                }
            }

            if !note.isEmpty {
                Text(note).font(.system(size: 13)).foregroundStyle(Theme.dim)
            }
            ForEach(chats) { chat in
                Button { onOpen(chat.chatID, chat.messageID) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(chat.chatName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            Text("\(chat.range) · \(chat.count) 句").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.dim)
                        }
                        Text(chat.snippet).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bubble))
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: monthKey) { await loadMonth() }
    }

    private var lead: Int { (cal.component(.weekday, from: month) + 5) % 7 }
    private var dayCount: Int { cal.range(of: .day, in: .month, for: month)?.count ?? 30 }

    private func shift(_ delta: Int) {
        if let next = cal.date(byAdding: .month, value: delta, to: month) { month = next }
    }

    private func loadMonth() async {
        let json = try? await API.shared.request("GET", "api/find/days", query: ["month": monthKey])
        days = (json?["days"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        // 落到这个月最近聊过的一天。
        if !(selected.hasPrefix(monthKey) && days[selected] != nil) {
            selected = days.keys.sorted().last ?? ""
        }
        if selected.isEmpty {
            chats = []
            note = "点一个带小点的日子，看那天聊了什么"
        } else {
            await loadDay(selected)
        }
    }

    private func loadDay(_ day: String) async {
        note = "翻着呢…"
        guard let json = try? await API.shared.request("GET", "api/find/day", query: ["date": day]) else {
            note = "翻不动了，再试一次"
            return
        }
        guard selected == day else { return }
        chats = (json["chats"] as? [[String: Any]] ?? []).map { c in
            let from = c["from"] as? String ?? "", to = c["to"] as? String ?? ""
            return DayChat(chatID: c["chat_id"] as? String ?? "", chatName: c["chat_name"] as? String ?? "",
                           messageID: c["message_id"] as? String ?? "",
                           range: from == to ? from : "\(from)–\(to)", count: (c["count"] as? NSNumber)?.intValue ?? 0,
                           snippet: (c["snippet"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "（那天只有他说了话）")
        }
        let parts = day.split(separator: "-")
        let label = parts.count == 3 ? "\(Int(parts[1]) ?? 0) 月 \(Int(parts[2]) ?? 0) 日" : day
        note = chats.isEmpty ? "\(label)没有聊天" : "\(label) · 聊了 \(chats.count) 间"
    }
}
