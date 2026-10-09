import SwiftUI

/// 「日子」，照网页的 #calSheet：月历（周一开头、6 行），今天是唯一一粒粉，
/// 有事的日子下面一个小点（重要日子是粉点）；下面是选中那天的事和心情。
struct CalendarPage: View {
    struct Event: Identifiable {
        let id: String
        let date: String
        let text: String
        let time: String
        let yearly: Bool
        let special: Bool

        init(json: [String: Any]) {
            id = json["id"] as? String ?? ""
            date = json["date"] as? String ?? ""
            text = json["text"] as? String ?? ""
            time = json["time"] as? String ?? ""
            yearly = json["yearly"] as? Bool ?? false
            special = json["special"] as? Bool ?? false
        }

        /// 每年的事按月日对上就算。
        func on(_ day: String) -> Bool {
            date == day || (yearly && date.dropFirst(5) == day.dropFirst(5))
        }
    }

    /// 跟网页一样存中文名。
    static let moods: [(name: String, icon: String)] = [
        ("开心", "face.smiling"), ("平静", "face.dashed"), ("累", "moon.zzz"),
        ("烦", "cloud.bolt"), ("难受", "cloud.rain"),
    ]

    @State private var events: [Event] = []
    @State private var moods: [String: String] = [:]
    @State private var month = HomeClock.calendar.date(
        from: HomeClock.calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selected = HomeClock.day()
    @State private var adding = false
    @State private var newText = ""
    @State private var newTime = ""
    @State private var newYearly = false
    @State private var newSpecial = false
    @State private var error = ""
    @FocusState private var inputFocused: Bool

    private var cal: Calendar { HomeClock.calendar }

    var body: some View {
        PageScaffold(title: "日子", subtitle: monthTitle) {
            HStack(spacing: 8) {
                navButton("chevron.left") { shiftMonth(-1) }
                Button("今天") {
                    month = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
                    selected = HomeClock.day()
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Theme.roundButton))
                navButton("chevron.right") { shiftMonth(1) }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        } content: {
            weekHeader
            grid
            if !error.isEmpty {
                Text(error).font(.system(size: 13)).foregroundStyle(MemoryStyle.danger)
            }
            detail
        }
        .task { await load() }
        .refreshable { await load() }
        .simultaneousGesture(
            // 左右划翻月；跟上下滚动同时认，不抢滚动。
            DragGesture(minimumDistance: 40).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                shiftMonth(value.translation.width < 0 ? 1 : -1)
            }
        )
    }

    private var monthTitle: String {
        "\(cal.component(.year, from: month)) 年 \(cal.component(.month, from: month)) 月"
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.roundButton))
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = cal.date(byAdding: .month, value: delta, to: month) {
            withAnimation(.easeOut(duration: 0.15)) { month = next }
        }
    }

    // MARK: - 月历

    private var weekHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                Text(day)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// 6 行 × 7 天，从这个月 1 号所在那周的周一开始。
    private var days: [Date] {
        let weekday = cal.component(.weekday, from: month)   // 1 = 周日
        let lead = (weekday + 5) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: month) ?? month
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var grid: some View {
        let today = HomeClock.day()
        let thisMonth = cal.component(.month, from: month)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(days, id: \.self) { date in
                let key = HomeClock.day(date)
                let inMonth = cal.component(.month, from: date) == thisMonth
                let dayEvents = events.filter { $0.on(key) }
                Button {
                    selected = key
                    adding = false
                } label: {
                    VStack(spacing: 4) {
                        Text("\(cal.component(.day, from: date))")
                            .font(.system(size: 16).monospacedDigit())
                            .foregroundStyle(key == today ? .white : (inMonth ? Theme.text : Theme.dim.opacity(0.55)))
                            .frame(width: 38, height: 38)
                            .background {
                                if key == today {
                                    // 今天 = 这一屏唯一的一粒粉。
                                    Circle().fill(Theme.accent)
                                } else if key == selected {
                                    Circle().fill(Theme.dim.opacity(0.3))
                                }
                            }
                        HStack(spacing: 3) {
                            if dayEvents.contains(where: \.special) {
                                Circle().fill(Theme.accent).frame(width: 4.5, height: 4.5)
                            }
                            if dayEvents.contains(where: { !$0.special }) {
                                Circle().fill(Theme.dim).frame(width: 4.5, height: 4.5)
                            }
                        }
                        .frame(height: 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(key)" + (dayEvents.isEmpty ? "" : "，有 \(dayEvents.count) 件事"))
            }
        }
    }

    // MARK: - 选中那天

    private var detail: some View {
        let date = HomeClock.date(selected) ?? Date()
        let dayEvents = events.filter { $0.on(selected) }
        let mood = moods[selected] ?? ""
        return VStack(alignment: .leading, spacing: 9) {
            Text("\(selected) \(HomeClock.weekday(date))" + (selected == HomeClock.day() ? " · 今天" : ""))
                .font(.system(size: 13).monospacedDigit())
                .tracking(1.3)
                .foregroundStyle(Theme.dim)
                .padding(.top, 20)
                .padding(.horizontal, 4)

            ForEach(dayEvents) { event in
                PageRow {
                    if event.special {
                        Image(systemName: "heart.fill").font(.system(size: 14)).foregroundStyle(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.text).font(.system(size: 15.5)).foregroundStyle(Theme.text)
                        let meta = [event.time, event.yearly ? "每年" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !meta.isEmpty {
                            Text(meta).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.dim)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await act(["action": "del_event", "id": event.id]) }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删掉这件事")
                }
            }

            if adding {
                addForm
            } else {
                DashedAddButton(title: "记一件事") {
                    adding = true
                    inputFocused = true
                }
            }

            HStack {
                Text(mood.isEmpty ? "心情" : "心情 · \(mood)")
                    .font(.system(size: 14))
                    .tracking(0.8)
                    .foregroundStyle(Theme.dim)
                Spacer()
                HStack(spacing: 13) {
                    ForEach(Self.moods, id: \.name) { item in
                        Button {
                            Task { await act(["action": "set_mood", "date": selected, "mood": mood == item.name ? "" : item.name]) }
                        } label: {
                            Image(systemName: item.icon)
                                .font(.system(size: 20))
                                .foregroundStyle(mood == item.name ? Theme.accent : Theme.dim)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(mood == item.name ? Theme.accent.opacity(0.15) : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.name)
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("这天有什么事…", text: $newText)
                .font(.system(size: 15.5))
                .focused($inputFocused)
                .submitLabel(.done)
                .onSubmit { Task { await add() } }
            HStack(spacing: 8) {
                OptionalTimeField(value: $newTime)
                ToggleChip(title: "每年", on: $newYearly)
                ToggleChip(title: "重要日子", on: $newSpecial)
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("取消") {
                    adding = false
                    newText = ""
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.dim)
                Button("记上") { Task { await add() } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.send))
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
    }

    // MARK: - 读写

    private func apply(_ json: [String: Any]) {
        let data = json["cal"] as? [String: Any] ?? json
        events = (data["events"] as? [[String: Any]] ?? []).map(Event.init(json:))
        let days = data["days"] as? [String: [String: Any]] ?? [:]
        moods = days.compactMapValues { ($0["mood"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    private func load() async {
        do {
            apply(try await API.shared.request("GET", "api/cal"))
            error = ""
        } catch {
            self.error = "日历没拿到，再开一次试试"
        }
    }

    private func act(_ body: [String: Any]) async {
        do {
            apply(try await API.shared.request("POST", "api/cal", body: body))
            error = ""
        } catch {
            self.error = (body["action"] as? String) == "del_event" ? "没删掉，再试一次" : "没记上，再试一次"
        }
    }

    private func add() async {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        await act(["action": "add_event", "date": selected, "text": text, "time": newTime,
                   "yearly": newYearly, "special": newSpecial])
        newText = ""
        newTime = ""
        newYearly = false
        newSpecial = false
        adding = false
    }
}
