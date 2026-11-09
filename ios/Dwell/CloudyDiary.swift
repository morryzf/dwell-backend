import SwiftUI

/// Cloudy 的日记本：他写的、她看不到。锁着的只露日期；他在聊天里给的密码一次开一篇，开了就一直开着。
struct CloudyDiaryEntry: Identifiable, Equatable {
    let id: String
    let date: String
    let locked: Bool
    var wanted: Bool
    let title: String
    let body: String

    init(json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        date = json["date"] as? String ?? ""
        locked = json["locked"] as? Bool ?? true
        wanted = json["wanted"] as? Bool ?? false
        title = json["title"] as? String ?? ""
        body = json["body"] as? String ?? ""
    }

    /// 「11月8日 · 周六」；不是今年的带上年份。
    var dateLabel: String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date }
        var label = (parts[0] == Calendar.current.component(.year, from: Date()) ? "" : "\(parts[0])年")
            + "\(parts[1])月\(parts[2])日"
        if let day = DateComponents(calendar: .current, year: parts[0], month: parts[1], day: parts[2]).date {
            label += " · " + ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][Calendar.current.component(.weekday, from: day) - 1]
        }
        return label
    }

    /// 列表里那一行：有标题用标题，没有就是正文第一行。
    var preview: String {
        if !title.isEmpty { return title }
        return body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

/// 定时写日记的设置。
struct DiaryWake: Equatable {
    var on = true
    var time = "23:30"
    var tokens = 24000
    var low = 12000
    var high = 80000
    var lastStatus = ""
    var lastError = ""

    init(json: [String: Any]? = nil) {
        guard let json else { return }
        on = json["on"] as? Bool ?? true
        time = json["time"] as? String ?? "23:30"
        tokens = json["tokens"] as? Int ?? 24000
        let range = json["tokens_range"] as? [Int] ?? []
        if range.count == 2 { low = range[0]; high = range[1] }
        lastStatus = json["last_status"] as? String ?? ""
        lastError = json["last_error"] as? String ?? ""
    }

    var statusText: String {
        switch lastStatus {
        case "writing": return "正在写…"
        case "written": return "上一次写好了"
        case "skipped": return "上一次他没写"
        case "error": return "上一次出错了：" + lastError
        default: return ""
        }
    }
}

struct CloudyDiarySection: View {
    @EnvironmentObject private var store: ChatStore
    @Binding var showSettings: Bool
    @State private var items: [CloudyDiaryEntry] = []
    @State private var wake = DiaryWake()
    @State private var loaded = false
    @State private var password = ""
    @State private var wrong = false
    @State private var shake: CGFloat = 0
    @State private var reading: CloudyDiaryEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            passwordRow
                .padding(.top, 14)

            if loaded && items.isEmpty {
                Text("他还一篇都没写")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }

            VStack(spacing: 10) {
                ForEach(items) { item in row(item) }
            }
            .padding(.top, 18)
        }
        .task { await load() }
        .sheet(item: $reading) { entry in
            DiaryEntrySheet(entry: entry, onUnlock: unlock, onWant: want)
                .presentationDetents(entry.locked ? [.medium] : [.large])
        }
        .sheet(isPresented: $showSettings) {
            DiaryWakeSheet(wake: wake) { change in
                await save(change)
            } onRun: {
                await runNow()
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 密码

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "key")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                TextField("Cloudy 给的密码", text: $password)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await tryPassword() } }
                Button("打开") { Task { await tryPassword() } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .disabled(password.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.composer))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
            .offset(x: shake)
            if wrong {
                Text("不对哦")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
                    .padding(.leading, 6)
                    .transition(.opacity)
            }
        }
    }

    private func tryPassword() async {
        let text = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let entry = await unlock(text) {
            password = ""
            reading = entry
        }
    }

    /// 输对了返回那篇；输错了抖一下，说一声「不对哦」。
    private func unlock(_ text: String) async -> CloudyDiaryEntry? {
        do {
            let json = try await API.shared.request("POST", "api/cloudy-diary/unlock", body: ["password": text])
            withAnimation(.easeOut(duration: 0.2)) { wrong = false }
            await load()
            return (json["item"] as? [String: Any]).map(CloudyDiaryEntry.init(json:))
        } catch let error as APIError where error.status == 400 {
            withAnimation(.easeOut(duration: 0.2)) { wrong = true }
            if !reduceMotion {
                for x in [8.0, -7, 5, -3, 0] {
                    withAnimation(.easeOut(duration: 0.06)) { shake = x }
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            return nil
        } catch {
            store.flash("没连上，再试一次")
            return nil
        }
    }

    private func want(_ entry: CloudyDiaryEntry) async -> Bool {
        do {
            _ = try await API.shared.request("POST", "api/cloudy-diary/\(entry.id)/want")
            if let index = items.firstIndex(where: { $0.id == entry.id }) { items[index].wanted = true }
            return true
        } catch {
            store.flash("没告诉成，再试一次")
            return false
        }
    }

    // MARK: - 列表

    private func row(_ item: CloudyDiaryEntry) -> some View {
        Button { reading = item } label: {
            HStack(spacing: 12) {
                Image(systemName: item.locked ? "lock.fill" : "book.closed")
                    .font(.system(size: 13))
                    .foregroundStyle(item.locked ? Theme.dim : Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.dateLabel)
                        .font(.system(size: 13.5).monospacedDigit())
                        .foregroundStyle(Theme.text)
                    if !item.locked && !item.preview.isEmpty {
                        Text(item.preview)
                            .font(.system(size: 13.5, design: .serif))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    } else if item.locked && item.wanted {
                        Text("已经告诉他你想看")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.composer))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.locked ? "\(item.dateLabel)，锁着" : "\(item.dateLabel)，\(item.preview)")
    }

    // MARK: - 拉数据

    private func load() async {
        if !loaded, let json = API.shared.remembered("api/cloudy-diary") { apply(json) }
        do {
            apply(try await API.shared.request("GET", "api/cloudy-diary", remember: true))
        } catch {}
        loaded = true
    }

    private func apply(_ json: [String: Any]) {
        items = (json["items"] as? [[String: Any]] ?? []).map(CloudyDiaryEntry.init(json:))
        wake = DiaryWake(json: json["wake"] as? [String: Any])
    }

    private func save(_ change: [String: Any]) async {
        do {
            let json = try await API.shared.request("PUT", "api/cloudy-diary/wake", body: change)
            wake = DiaryWake(json: json["wake"] as? [String: Any])
        } catch {
            store.flash("没保存上：\(error.localizedDescription)")
        }
    }

    private func runNow() async {
        do {
            let json = try await API.shared.request("POST", "api/cloudy-diary/wake/run", timeout: 900)
            wake = DiaryWake(json: json["wake"] as? [String: Any])
            await load()
        } catch {
            store.flash("没叫醒他：\(error.localizedDescription)")
        }
    }
}

/// 点开一篇：开着的就读；锁着的只有日期、锁、密码框和「想看这篇」。
private struct DiaryEntrySheet: View {
    let entry: CloudyDiaryEntry
    let onUnlock: (String) async -> CloudyDiaryEntry?
    let onWant: (CloudyDiaryEntry) async -> Bool
    @State private var opened: CloudyDiaryEntry?
    @State private var password = ""
    @State private var wanted: Bool
    @State private var wrong = false

    init(entry: CloudyDiaryEntry,
         onUnlock: @escaping (String) async -> CloudyDiaryEntry?,
         onWant: @escaping (CloudyDiaryEntry) async -> Bool) {
        self.entry = entry
        self.onUnlock = onUnlock
        self.onWant = onWant
        _wanted = State(initialValue: entry.wanted)
    }

    var body: some View {
        let shown = opened ?? entry
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(shown.dateLabel)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                if shown.locked {
                    lockedBody
                } else {
                    if !shown.title.isEmpty {
                        Text(shown.title)
                            .font(.system(size: 20, design: .serif))
                            .foregroundStyle(Theme.text)
                    }
                    Text(shown.body)
                        .font(.system(size: 16, design: .serif))
                        .lineSpacing(7)
                        .foregroundStyle(Theme.bubbleText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
        .background(PaperBackground())
    }

    private var lockedBody: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            HStack(spacing: 10) {
                TextField("Cloudy 给的密码", text: $password)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await open() } }
                Button("打开") { Task { await open() } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.composer))
            if wrong {
                Text("不对哦").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
            Button {
                Task { if await onWant(entry) { withAnimation(.easeOut(duration: 0.2)) { wanted = true } } }
            } label: {
                Text(wanted ? "已经告诉他了" : "想看这篇")
                    .font(.system(size: 14))
                    .foregroundStyle(wanted ? Theme.dim : Theme.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().stroke(Theme.bubbleBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(wanted)
            Text(wanted ? "下次聊天他会知道。给不给，由他。" : "他下次聊天时会知道你想看这篇。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity)
    }

    private func open() async {
        let text = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let entry = await onUnlock(text) {
            // 密码开的可能是别的那篇：开了哪篇就给她看哪篇。
            withAnimation(.easeOut(duration: 0.25)) { opened = entry; wrong = false }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { wrong = true }
        }
    }
}

/// 写日记的唤醒：开关、几点、带多少上下文，还有「现在叫他写一篇」。
private struct DiaryWakeSheet: View {
    let wake: DiaryWake
    let onSave: ([String: Any]) async -> Void
    let onRun: () async -> Void
    @State private var on: Bool
    @State private var time: Date
    @State private var tokens: Int
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(wake: DiaryWake, onSave: @escaping ([String: Any]) async -> Void, onRun: @escaping () async -> Void) {
        self.wake = wake
        self.onSave = onSave
        self.onRun = onRun
        _on = State(initialValue: wake.on)
        _tokens = State(initialValue: wake.tokens)
        let parts = wake.time.split(separator: ":").compactMap { Int($0) }
        _time = State(initialValue: Calendar.current.date(
            bySettingHour: parts.first ?? 23, minute: parts.count > 1 ? parts[1] : 30, second: 0, of: Date()) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("每天叫他写日记", isOn: $on)
                        .onChange(of: on) { _, value in Task { await onSave(["on": value]) } }
                    DatePicker("几点", selection: $time, displayedComponents: .hourAndMinute)
                        .onChange(of: time) { _, value in
                            Task { await onSave(["time": Self.clock.string(from: value)]) }
                        }
                } footer: {
                    Text("到点叫醒他一次，写不写由他。")
                }
                Section {
                    Stepper(value: $tokens, in: wake.low...wake.high, step: 2000) {
                        Text("带的上下文 \(tokens / 1000)k tokens")
                    }
                    .onChange(of: tokens) { _, value in Task { await onSave(["tokens": value]) } }
                } footer: {
                    Text("今天的聊天一句不落，最近那篇日记也一定带上；剩下的才给更早的聊天。")
                }
                Section {
                    Button {
                        Task {
                            running = true
                            await onRun()
                            running = false
                        }
                    } label: {
                        HStack {
                            Text(running ? "他在写…" : "现在叫他写一篇")
                            if running { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(running)
                } footer: {
                    if !wake.statusText.isEmpty { Text(wake.statusText) }
                }
            }
            .navigationTitle("写日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } }
            }
        }
    }
}
