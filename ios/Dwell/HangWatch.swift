import Foundation
import UIKit

/// 卡住的时候留个现场。
///
/// 主线程每半秒报一次平安，顺手记下这一刻聊天页的状态；另一条线程盯着它。
/// 超过 3 秒没报平安，就把最后一次的状态和最近做过的几十件事存进手机里；
/// 缓过来了记下卡了多久，缓不过来（只能杀掉 app）下次打开时也还在。
/// 下次回到前台时发给后端，系统日志里就有一条「app 卡住」，点「看现场」能看到这些。
final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()

    private let lock = NSLock()
    private struct Crumb { var time: String; let text: String; var count: Int }
    private var crumbs: [Crumb] = []
    private var lastBeat = Date()
    private var lastState = ""
    private var active = true
    private var stuckSince: Date?
    private var started = false
    private var iosVersion = ""
    /// 主线程上取一下聊天页此刻的状态（ChatStore 填）。
    @MainActor var stateProvider: (() -> String)?

    private static let pendingKey = "hangReportsPending"
    private static let maxCrumbs = 60
    private static let threshold: TimeInterval = 3

    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // 空转：同一件事一秒来上百次、连着好几秒（比如布局来回算、滚动来回触发）。
    // 这时主线程其实还在转，「多久没报平安」抓不到，要靠数次数。
    private var windowStart = Date()
    private var windowCounts: [String: Int] = [:]
    private var hotSeconds = 0
    private var stormReported = false
    private static let stormPerSecond = 120

    /// 记一件刚做的事。同一件事连着来就只记次数，不刷满。
    func note(_ text: String) {
        var storm: String?
        lock.lock()
        let clock = Date()
        if clock.timeIntervalSince(windowStart) >= 1 {
            let top = windowCounts.max { $0.value < $1.value }
            if let top, top.value >= Self.stormPerSecond {
                hotSeconds += 1
                if hotSeconds >= 3 && !stormReported {
                    stormReported = true
                    storm = "\(top.key) \(top.value) 次/秒，连着 \(hotSeconds) 秒"
                }
            } else {
                hotSeconds = 0
                if (top?.value ?? 0) < 20 { stormReported = false }
            }
            windowStart = clock
            windowCounts = [:]
        }
        windowCounts[text, default: 0] += 1
        lock.unlock()
        if let storm { save(extra: ["storm": storm]) }

        lock.lock()
        defer { lock.unlock() }
        let now = stamp.string(from: clock)
        if let last = crumbs.indices.last, crumbs[last].text == text {
            crumbs[last].count += 1
            crumbs[last].time = now
            return
        }
        crumbs.append(Crumb(time: now, text: text, count: 1))
        if crumbs.count > Self.maxCrumbs { crumbs.removeFirst(crumbs.count - Self.maxCrumbs) }
    }

    @MainActor
    func start() {
        guard !started else { return }
        started = true
        iosVersion = UIDevice.current.systemVersion
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(true)
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(false)
        }
        let watcher = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                self?.check()
            }
        }
        watcher.name = "dwell.hangwatch"
        watcher.qualityOfService = .utility
        watcher.start()
    }

    @MainActor
    private func beat() {
        let state = stateProvider?() ?? ""
        lock.lock()
        let now = Date()
        let recovered = stuckSince
        lastBeat = now
        lastState = state
        stuckSince = nil
        lock.unlock()
        if let since = recovered {
            // 缓过来了：把刚才那条补上卡了多久。
            finish(seconds: now.timeIntervalSince(since) + Self.threshold)
        }
    }

    private func setActive(_ on: Bool) {
        lock.lock()
        active = on
        lastBeat = Date()
        lock.unlock()
    }

    private func check() {
        lock.lock()
        let late = Date().timeIntervalSince(lastBeat)
        guard active, stuckSince == nil, late > Self.threshold else { lock.unlock(); return }
        stuckSince = Date()
        lock.unlock()
        save(extra: [:])
    }

    /// 把此刻的现场存进手机（卡住、空转都走这里）。
    private func save(extra: [String: Any]) {
        lock.lock()
        var report: [String: Any] = [
            "at": Int(Date().timeIntervalSince1970),
            "state": lastState,
            "crumbs": crumbs.map { "\($0.time) \($0.text)" + ($0.count > 1 ? " ×\($0.count)" : "") },
            "recovered": false,
            "seconds": 0,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "ios": iosVersion,
        ]
        report.merge(extra) { _, new in new }
        lock.unlock()
        var pending = UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]] ?? []
        pending.append(report)
        UserDefaults.standard.set(Array(pending.suffix(10)), forKey: Self.pendingKey)
    }

    private func finish(seconds: Double) {
        var pending = UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]] ?? []
        guard var last = pending.popLast() else { return }
        last["recovered"] = true
        last["seconds"] = Int(seconds.rounded())
        pending.append(last)
        UserDefaults.standard.set(pending, forKey: Self.pendingKey)
    }

    /// 把存着的现场发给后端；发成功的才删。
    func upload() async {
        let pending = UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]] ?? []
        guard !pending.isEmpty else { return }
        var left: [[String: Any]] = []
        for report in pending {
            do {
                _ = try await API.shared.request("POST", "api/client-reports", body: ["kind": "hang", "report": report])
            } catch {
                left.append(report)
            }
        }
        UserDefaults.standard.set(left, forKey: Self.pendingKey)
    }
}
