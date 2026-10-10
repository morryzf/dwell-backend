import SwiftUI

/// 「专注」：上面切「正计时 / 番茄钟」。
/// 正计时照 YPT：分科目，点一下开始、再点一下停；记录存在服务器上，网页、app 和他看到的是同一份。
/// 番茄钟只在这台手机上计时，到点用本地通知提醒；做完一轮可以记到某个科目里。
struct FocusPage: View {
    @AppStorage("dwell.focus.mode") private var mode = "stopwatch"

    var body: some View {
        PageScaffold(title: "专注", subtitle: mode == "stopwatch" ? "安静做完这一件事" : "一轮一轮来") {
            HStack(spacing: 6) {
                modeButton("正计时", "stopwatch")
                modeButton("番茄钟", "pomodoro")
                Spacer()
            }
            .padding(.top, 12)
            .padding(.bottom, 6)
            if mode == "stopwatch" {
                StopwatchPane()
            } else {
                PomodoroPane()
            }
        }
    }

    private func modeButton(_ title: String, _ key: String) -> some View {
        Button { mode = key } label: {
            Text(title)
                .font(.system(size: 13.5, weight: mode == key ? .semibold : .regular))
                .foregroundStyle(mode == key ? Theme.text : Theme.dim)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(mode == key ? Theme.bubble : .clear))
                .overlay(Capsule().stroke(mode == key ? Theme.bubbleBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == key ? .isSelected : [])
    }
}

// MARK: - 数据

struct FocusSubject: Identifiable, Equatable {
    let id: String
    let name: String
    let color: String

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? ""
        color = json["color"] as? String ?? "#D9A7B7"
    }

    var tint: Color { Color(hexString: color) }

    /// 新建科目时挑的颜色：都是偏灰的柔色，跟整套粉灰的皮放在一起不跳。
    static let palette = ["#D9A7B7", "#7F9A84", "#8FA9C9", "#D4B483", "#A99BC9", "#D98E7F", "#7FB0AE", "#9A9097"]
}

/// 专注页的状态：拿服务器的快照，正在计时的那一段按手机时钟往上加。
@MainActor
final class FocusStore: ObservableObject {
    static let shared = FocusStore()

    struct Session: Identifiable {
        let id: String
        let subjectID: String
        let subject: String
        let color: String
        let started: Int
        let ended: Int?
        let seconds: Int
    }

    @Published var subjects: [FocusSubject] = []
    @Published var runningSubject: String?
    @Published var runningStarted = 0
    @Published var todayTotal = 0
    @Published var bySubject: [String: Int] = [:]
    @Published var sessions: [Session] = []
    @Published var goalMinutes = 0
    @Published var share = true
    @Published var loaded = false
    @Published var error = ""
    /// 快照是在什么时候拿的（手机时钟），用来把正在计时的那段往上加。
    private var fetchedAt = Date()

    func apply(_ json: [String: Any]) {
        subjects = (json["subjects"] as? [[String: Any]] ?? []).map(FocusSubject.init(json:))
        let running = json["running"] as? [String: Any]
        runningSubject = running?["subject_id"] as? String
        runningStarted = running?["started"] as? Int ?? 0
        let today = json["today"] as? [String: Any] ?? [:]
        todayTotal = today["total"] as? Int ?? 0
        bySubject = today["by_subject"] as? [String: Int] ?? [:]
        sessions = (today["sessions"] as? [[String: Any]] ?? []).map {
            Session(id: $0["id"] as? String ?? "", subjectID: $0["subject_id"] as? String ?? "",
                    subject: $0["subject"] as? String ?? "", color: $0["color"] as? String ?? "#D9A7B7",
                    started: $0["started"] as? Int ?? 0, ended: $0["ended"] as? Int,
                    seconds: $0["seconds"] as? Int ?? 0)
        }
        let settings = json["settings"] as? [String: Any] ?? [:]
        goalMinutes = settings["goal_minutes"] as? Int ?? 0
        share = settings["share"] as? Bool ?? true
        fetchedAt = Date()
        loaded = true
        error = ""
    }

    /// 快照之后又过了几秒（只有在计时的时候才算）。
    func extra(at now: Date) -> Int {
        runningSubject == nil ? 0 : max(0, Int(now.timeIntervalSince(fetchedAt)))
    }

    func total(at now: Date) -> Int { todayTotal + extra(at: now) }

    func seconds(of subject: String, at now: Date) -> Int {
        (bySubject[subject] ?? 0) + (subject == runningSubject ? extra(at: now) : 0)
    }

    func load() async {
        do {
            apply(try await API.shared.request("GET", "api/focus"))
        } catch {
            self.error = (error as? APIError)?.message ?? "计时记录没拿到"
        }
    }

    @discardableResult
    func act(_ body: [String: Any]) async -> Bool {
        do {
            apply(try await API.shared.request("POST", "api/focus", body: body))
            return true
        } catch {
            self.error = (error as? APIError)?.message ?? "没成，再试一次"
            return false
        }
    }

    func toggle(_ subject: FocusSubject) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if runningSubject == subject.id {
            await act(["action": "stop"])
        } else {
            await act(["action": "start", "subject_id": subject.id])
        }
    }
}

enum FocusFormat {
    /// 1:02:03 / 12:03
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 2小时14分 / 35分
    static func words(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60)小时" : "\(minutes / 60)小时\(minutes % 60)分" }
        return "\(minutes)分"
    }

    static func hm(_ ts: Int) -> String {
        HomeClock.hm(Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

// MARK: - 正计时

private struct StopwatchPane: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var focus = FocusStore.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var editing: FocusSubject?
    @State private var adding = false
    @State private var deleting: FocusSubject?
    @State private var showGoal = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 0) {
                hero(now)
                PageSection(text: "科目")
                VStack(spacing: 9) {
                    ForEach(focus.subjects) { subject in
                        subjectRow(subject, now: now)
                    }
                    DashedAddButton(title: focus.subjects.isEmpty ? "先建一个科目" : "添加科目") { adding = true }
                }
                if !focus.sessions.isEmpty {
                    PageSection(text: "今天的每一段")
                    timeline(now)
                }
                FocusWeek()
                settings
            }
        }
        .task { await focus.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await focus.load() } }
        }
        .sheet(isPresented: $adding) {
            SubjectEditor(subject: nil) { name, color in
                Task { await focus.act(["action": "add_subject", "name": name, "color": color]) }
            }
        }
        .sheet(item: $editing) { subject in
            SubjectEditor(subject: subject) { name, color in
                Task { await focus.act(["action": "edit_subject", "id": subject.id, "name": name, "color": color]) }
            }
        }
        .confirmationDialog("删掉「\(deleting?.name ?? "")」？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let subject = deleting {
                    Task { await focus.act(["action": "del_subject", "id": subject.id]) }
                }
            }
        } message: {
            Text("以前记下的时间还算在那几天里，只是不再出现在科目列表。")
        }
    }

    // 大数字：今天一共多久；在计时的话下面写正在做哪一科。
    private func hero(_ now: Date) -> some View {
        let total = focus.total(at: now)
        let running = focus.subjects.first { $0.id == focus.runningSubject }
        return VStack(spacing: 8) {
            Text(FocusFormat.clock(total))
                .font(.system(size: 54, weight: .light, design: .serif).monospacedDigit())
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
            if let running {
                HStack(spacing: 6) {
                    Circle().fill(running.tint).frame(width: 8, height: 8)
                    Text("正在 · \(running.name) · \(FocusFormat.clock(Int(now.timeIntervalSince1970) - focus.runningStarted))")
                        .monospacedDigit()
                }
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text)
            } else {
                Text(focus.loaded ? (total > 0 ? "今天一共" : "今天还没开始") : "正在读计时…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.dim)
            }
            if focus.goalMinutes > 0 {
                let goal = focus.goalMinutes * 60
                VStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.dim.opacity(0.15))
                            Capsule().fill(Theme.accent)
                                .frame(width: geo.size.width * min(1, Double(total) / Double(goal)))
                        }
                    }
                    .frame(height: 6)
                    Text(total >= goal ? "今天的目标做到了" : "目标 \(FocusFormat.words(goal)) · 还差 \(FocusFormat.words(goal - total))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: 240)
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
            if !focus.error.isEmpty {
                Text(focus.error).font(.system(size: 12.5)).foregroundStyle(MemoryStyle.danger)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func subjectRow(_ subject: FocusSubject, now: Date) -> some View {
        let on = focus.runningSubject == subject.id
        return Button {
            Task { await focus.toggle(subject) }
        } label: {
            PageRow {
                Circle().fill(subject.tint).frame(width: 12, height: 12)
                Text(subject.name)
                    .font(.system(size: 15.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(FocusFormat.clock(focus.seconds(of: subject.id, at: now)))
                    .font(.system(size: 15, weight: on ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(on ? subject.tint : Theme.dim)
                Image(systemName: on ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? .white : Theme.text)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? subject.tint : Theme.roundButton))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(on ? subject.tint.opacity(0.7) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(subject.name)，今天 \(FocusFormat.words(focus.seconds(of: subject.id, at: now)))")
        .accessibilityHint(on ? "点一下停" : "点一下开始")
        .contextMenu {
            Button { editing = subject } label: { Label("改名字和颜色", systemImage: "pencil") }
            Button(role: .destructive) { deleting = subject } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func timeline(_ now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(focus.sessions.reversed()) { item in
                let running = item.ended == nil
                HStack(spacing: 10) {
                    Capsule().fill(Color(hexString: item.color)).frame(width: 4, height: 22)
                    Text("\(FocusFormat.hm(item.started))–\(running ? "现在" : FocusFormat.hm(item.ended ?? item.started))")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                    Text(item.subject).font(.system(size: 14)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(FocusFormat.words(item.seconds + (running ? focus.extra(at: now) : 0)))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .contextMenu {
                    if !running {
                        Button(role: .destructive) {
                            Task { await focus.act(["action": "del_session", "id": item.id]) }
                        } label: { Label("删掉这一段", systemImage: "trash") }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
    }

    private var settings: some View {
        VStack(spacing: 9) {
            PageSection(text: "设置").frame(maxWidth: .infinity, alignment: .leading)
            PageRow {
                Text("每天的目标").font(.system(size: 15)).foregroundStyle(Theme.text)
                Spacer()
                Text(focus.goalMinutes == 0 ? "不设" : FocusFormat.words(focus.goalMinutes * 60))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                Stepper("每天的目标", value: Binding(get: { focus.goalMinutes }, set: { value in
                    focus.goalMinutes = value
                    Task { await focus.act(["action": "settings", "goal_minutes": value]) }
                }), in: 0...(16 * 60), step: 30)
                .labelsHidden()
            }
            PageRow {
                Toggle("让 \(store.assistant?.name ?? "Cloudy") 看到今天的计时", isOn: Binding(get: { focus.share }, set: { value in
                    focus.share = value
                    Task { await focus.act(["action": "settings", "share": value]) }
                }))
                .font(.system(size: 15))
                .tint(Theme.send)
            }
            Text("记录存在服务器上，网页和 app 是同一份。开着上面这个，聊天时他会知道你今天专注了多久、在做哪一科；家里的工具开着时，他还能查以前的记录。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
    }
}

// MARK: - 这一周

/// 最近 7 天每天专注了多久：一个系列一种颜色（粉），点一根柱子看那天各科多少。
private struct FocusWeek: View {
    @ObservedObject private var focus = FocusStore.shared
    @State private var days: [(date: String, total: Int, bySubject: [String: Int])] = []
    @State private var names: [String: FocusSubject] = [:]
    @State private var selected = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageSection(text: "最近 7 天")
            if !days.isEmpty {
                let maxTotal = max(days.map(\.total).max() ?? 0, 1)
                let pick = days.first { $0.date == selected } ?? days[days.count - 1]
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(label(pick.date, long: true)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(FocusFormat.words(pick.total)).font(.system(size: 13.5).monospacedDigit()).foregroundStyle(Theme.dim)
                    }
                    if pick.total > 0 {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(pick.bySubject.sorted { $0.value > $1.value }, id: \.key) { key, value in
                                HStack(spacing: 8) {
                                    Circle().fill(names[key]?.tint ?? Theme.dim).frame(width: 7, height: 7)
                                    Text(names[key]?.name ?? "已删的科目").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(FocusFormat.words(value)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.dim)
                                }
                            }
                        }
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(days, id: \.date) { day in
                            let on = day.date == pick.date
                            Button { selected = day.date } label: {
                                VStack(spacing: 6) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .bottom) {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.dim.opacity(0.1))
                                            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2,
                                                                   bottomTrailingRadius: 2, topTrailingRadius: 4, style: .continuous)
                                                .fill(Theme.accent.opacity(on ? 1 : 0.6))
                                                .frame(height: geo.size.height * max(day.total > 0 ? 0.04 : 0.02, Double(day.total) / Double(maxTotal)))
                                        }
                                    }
                                    Text(label(day.date, long: false))
                                        .font(.system(size: 10.5, weight: on ? .bold : .regular))
                                        .foregroundStyle(on ? Theme.text : Theme.dim)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(label(day.date, long: true))，\(FocusFormat.words(day.total))")
                        }
                    }
                    .frame(height: 130)
                }
                .padding(15)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
            }
        }
        // 计时停下、科目变了都重读一遍；正在计时的时候不每秒去问服务器。
        .task(id: "\(focus.todayTotal)-\(focus.subjects.count)-\(focus.runningSubject ?? "")") { await load() }
    }

    private func label(_ date: String, long: Bool) -> String {
        guard let day = HomeClock.date(date) else { return date }
        let c = HomeClock.calendar
        if date == HomeClock.day() { return long ? "今天" : "今" }
        return long ? "\(c.component(.month, from: day))月\(c.component(.day, from: day))日 \(HomeClock.weekday(day))"
                    : String(HomeClock.weekday(day).suffix(1))
    }

    private func load() async {
        let end = HomeClock.day()
        guard let today = HomeClock.date(end),
              let first = HomeClock.calendar.date(byAdding: .day, value: -6, to: today),
              let json = try? await API.shared.request("GET", "api/focus/days",
                                                       query: ["start": HomeClock.day(first), "end": end]) else { return }
        names = Dictionary(uniqueKeysWithValues: (json["subjects"] as? [[String: Any]] ?? [])
            .map(FocusSubject.init(json:)).map { ($0.id, $0) })
        days = (json["days"] as? [[String: Any]] ?? []).map {
            (date: $0["date"] as? String ?? "", total: $0["total"] as? Int ?? 0,
             bySubject: $0["by_subject"] as? [String: Int] ?? [:])
        }
    }
}

// MARK: - 新建 / 改科目

private struct SubjectEditor: View {
    let subject: FocusSubject?
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = FocusSubject.palette[0]
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TextField("科目名字，比如：数学", text: $name)
                    .font(.system(size: 17))
                    .focused($focused)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bubble))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
                HStack(spacing: 12) {
                    ForEach(FocusSubject.palette, id: \.self) { hex in
                        Button { color = hex } label: {
                            Circle()
                                .fill(Color(hexString: hex))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Theme.text, lineWidth: color == hex ? 2 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("颜色 \(hex)")
                        .accessibilityAddTraits(color == hex ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 4)
                Spacer()
            }
            .padding(20)
            .background(PaperBackground())
            .navigationTitle(subject == nil ? "新科目" : "改科目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") {
                        onSave(name.trimmingCharacters(in: .whitespaces), color)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = subject?.name ?? ""
                color = subject?.color.uppercased() ?? FocusSubject.palette[0]
                focused = true
            }
        }
        .presentationDetents([.height(260)])
    }
}
