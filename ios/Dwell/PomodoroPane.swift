import Combine
import SwiftUI
import UserNotifications

/// 番茄钟：照网页的 #focusSheet。计时只在这台手机上，到点用本地通知提醒（不用 Bark，锁屏也会响）。
/// 选了科目的话，做完的那一轮会记进正计时的记录里。
struct PomodoroPane: View {
    @AppStorage("dwell.pomo.focusMinutes") private var focusMinutes = 25
    @AppStorage("dwell.pomo.breakMinutes") private var breakMinutes = 5
    @AppStorage("dwell.pomo.phase") private var phase = "focus"
    /// 正在走的话是到点的时刻（Unix 秒）；0 = 没在走。
    @AppStorage("dwell.pomo.endsAt") private var endsAt = 0.0
    /// 没在走的时候还剩几秒；0 = 这一阶段还没开始过。
    @AppStorage("dwell.pomo.remaining") private var remaining = 0
    @AppStorage("dwell.pomo.task") private var task = ""
    @AppStorage("dwell.pomo.subject") private var subjectID = ""
    @AppStorage("dwell.pomo.countDate") private var countDate = ""
    @AppStorage("dwell.pomo.count") private var count = 0

    @ObservedObject private var focus = FocusStore.shared
    @State private var now = Date()
    @State private var note = ""

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var phaseSeconds: Int { (phase == "focus" ? focusMinutes : breakMinutes) * 60 }
    private var running: Bool { endsAt > 0 }
    private var left: Int {
        running ? max(0, Int((endsAt - now.timeIntervalSince1970).rounded(.up))) : (remaining > 0 ? remaining : phaseSeconds)
    }
    private var todayCount: Int { countDate == HomeClock.day() ? count : 0 }
    private var tint: Color { phase == "focus" ? Theme.accent : MemoryStyle.sage }

    var body: some View {
        VStack(spacing: 0) {
            ring
                .padding(.top, 18)
            Text("今天完成了 \(todayCount) 轮")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .padding(.top, 12)

            TextField("这一轮想做什么？", text: $task)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bubble))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
                .padding(.top, 16)

            HStack(spacing: 10) {
                smallButton("重来") { reset() }
                Button { running ? pause() : start() } label: {
                    Text(running ? "暂停" : (remaining > 0 ? "继续" : (phase == "focus" ? "开始专注" : "开始休息")))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(Theme.send))
                }
                .buttonStyle(.plain)
                smallButton("换阶段") { switchPhase() }
            }
            .padding(.top, 14)

            if !note.isEmpty {
                Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.dim).padding(.top, 10)
            }

            VStack(spacing: 9) {
                PageSection(text: "时长").frame(maxWidth: .infinity, alignment: .leading)
                minutesRow("专注", value: $focusMinutes, range: 1...180)
                minutesRow("休息", value: $breakMinutes, range: 1...90)
                PageSection(text: "记到").frame(maxWidth: .infinity, alignment: .leading)
                PageRow {
                    Text("做完一轮记到").font(.system(size: 15)).foregroundStyle(Theme.text)
                    Spacer()
                    Picker("做完一轮记到", selection: $subjectID) {
                        Text("不记").tag("")
                        ForEach(focus.subjects) { subject in
                            Text(subject.name).tag(subject.id)
                        }
                    }
                    .tint(Theme.accent)
                }
                Text("计时只在这台手机上，到点会用手机通知提醒。选了科目的话，每做完一轮专注，就记进「正计时」那边这一科的时间里。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
        }
        .onReceive(ticker) { date in
            now = date
            if running && date.timeIntervalSince1970 >= endsAt { finish() }
        }
        .onAppear {
            now = Date()
            if running && now.timeIntervalSince1970 >= endsAt { finish() }
        }
        .task { if !focus.loaded { await focus.load() } }
        .onChange(of: focusMinutes) { _, _ in if !running && phase == "focus" { remaining = 0 } }
        .onChange(of: breakMinutes) { _, _ in if !running && phase == "break" { remaining = 0 } }
    }

    private var ring: some View {
        let fraction = phaseSeconds > 0 ? Double(left) / Double(phaseSeconds) : 0
        return ZStack {
            Circle().stroke(Theme.dim.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(1, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: left)
            VStack(spacing: 6) {
                Text(FocusFormat.clock(left))
                    .font(.system(size: 46, weight: .light, design: .serif).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Text((phase == "focus" ? "专注" : "休息") + " · " + (running ? "进行中" : (remaining > 0 ? "暂停中" : "待开始")))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 220, height: 220)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .frame(width: 76, height: 44)
                .background(Capsule().fill(Theme.roundButton))
                .overlay(Capsule().stroke(MemoryStyle.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func minutesRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        PageRow {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.text)
            Spacer()
            Text("\(value.wrappedValue) 分钟")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.accent)
            Stepper(title, value: value, in: range).labelsHidden()
        }
        .disabled(running)
    }

    // MARK: - 计时

    private func start() {
        let seconds = remaining > 0 ? remaining : phaseSeconds
        endsAt = Date().timeIntervalSince1970 + Double(seconds)
        remaining = seconds
        note = ""
        Self.schedule(at: endsAt, phase: phase, task: task)
    }

    private func pause() {
        remaining = max(1, Int((endsAt - Date().timeIntervalSince1970).rounded(.up)))
        endsAt = 0
        Self.cancel()
    }

    private func reset() {
        endsAt = 0
        remaining = 0
        note = ""
        Self.cancel()
    }

    private func switchPhase() {
        reset()
        phase = phase == "focus" ? "break" : "focus"
    }

    /// 到点：专注那一轮算一轮，选了科目就记进去；然后换到下一阶段，等她点开始。
    private func finish() {
        let ended = endsAt
        let wasFocus = phase == "focus"
        endsAt = 0
        remaining = 0
        phase = wasFocus ? "break" : "focus"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard wasFocus else {
            note = "休息好了，再来一轮？"
            return
        }
        let today = HomeClock.day()
        count = countDate == today ? count + 1 : 1
        countDate = today
        note = "这一轮做完了，歇一会儿"
        if !subjectID.isEmpty {
            let started = Int(ended) - focusMinutes * 60
            Task {
                if await focus.act(["action": "log", "subject_id": subjectID, "started": started,
                                    "ended": Int(ended), "source": "pomodoro"]) {
                    let name = focus.subjects.first { $0.id == subjectID }?.name ?? "那一科"
                    note = "这一轮做完了，记进了「\(name)」"
                }
            }
        }
    }

    // MARK: - 本地通知

    private static let notificationID = "dwell.pomodoro"

    private static func schedule(at endsAt: Double, phase: String, task: String) {
        let center = UNUserNotificationCenter.current()
        let id = notificationID
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = phase == "focus" ? "这一轮专注做完了" : "休息结束了"
            content.body = phase == "focus"
                ? (task.isEmpty ? "歇一会儿吧。" : "「\(task)」做完一轮，歇一会儿吧。")
                : "回来再做一轮？"
            content.sound = .default
            let interval = max(1, endsAt - Date().timeIntervalSince1970)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    private static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
    }
}
