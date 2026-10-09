import SwiftUI

/// 「用量」，照网页的 #usageSheet：两个夹子页签，Subscription 是 Claude 订阅额度，
/// OpenRouter 是余额、今日 / 本周 / 本月、命中率和一张柱状图。
struct UsagePage: View {
    @State private var tab = "sub"
    @State private var sub: [String: Any]?
    @State private var subStatus = ""
    @State private var subBad = false
    @State private var or: [String: Any]?
    @State private var orStatus = ""
    @State private var orBad = false
    @State private var loading = false
    @AppStorage("dwell.usageCurrency") private var currency = "USD"
    @State private var range = "daily"
    @State private var selectedStart = ""

    var body: some View {
        PageScaffold(title: "用量", subtitle: tab == "sub" ? "Claude 订阅额度" : "OpenRouter 花了多少") {
            Button {
                Task { await load(refresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.roundButton))
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .opacity(loading ? 0.5 : 1)
            .padding(.top, 4)
            .accessibilityLabel("刷新")
        } content: {
            tabs
            VStack(alignment: .leading, spacing: 12) {
                if tab == "sub" { subPane } else { orPane }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(UsageStyle.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
        }
        .task(id: tab) { await load(refresh: false) }
        .refreshable { await load(refresh: true) }
    }

    // MARK: - 页签

    private var tabs: some View {
        HStack(spacing: 6) {
            tabButton("Subscription", "sub")
            tabButton("OpenRouter", "or")
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func tabButton(_ title: String, _ key: String) -> some View {
        Button { tab = key } label: {
            Text(title)
                .font(.system(size: 13.5, weight: tab == key ? .semibold : .regular))
                .foregroundStyle(tab == key ? Theme.text : Theme.dim)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(tab == key ? UsageStyle.card : .clear))
                .overlay(Capsule().stroke(tab == key ? Theme.bubbleBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == key ? .isSelected : [])
    }

    // MARK: - Subscription

    @ViewBuilder
    private var subPane: some View {
        let windows = (sub?["windows"] as? [[String: Any]]) ?? []
        VStack(alignment: .leading, spacing: 2) {
            Text("CLAUDE").font(.system(size: 11.5, weight: .semibold)).tracking(1.6).foregroundStyle(Theme.dim)
            Text(planText).font(.system(size: 14)).foregroundStyle(Theme.text)
        }
        statusLine(subStatus, bad: subBad)
        if sub != nil && windows.isEmpty {
            Text("还没有拿到额度数字。" + ((sub?["error"] as? String).map { "\n" + $0 } ?? ""))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.dim)
                .padding(.vertical, 8)
        }
        ForEach(["session", "weekly", "extra"], id: \.self) { key in
            let items = windows.filter { $0["group"] as? String == key }
            if !items.isEmpty {
                if key == "weekly" {
                    Text("Weekly limits").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 6)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, window in
                    SubscriptionCard(window: window)
                }
            }
        }
        if let sub {
            let notes = [Self.stamp(sub["fetched_at"]).map { "更新于 " + $0 },
                         "数字来自 Claude 账号本身，claude.ai、Claude Code 和这里的用量算在一起"].compactMap { $0 }
            note(notes.joined(separator: " · "))
        }
    }

    private var planText: String {
        guard let sub else { return " " }
        let raw = sub["plan"] as? String ?? ""
        let plan = raw.isEmpty ? "订阅账号" : raw.prefix(1).uppercased() + raw.dropFirst()
        let email = sub["email"] as? String ?? ""
        return email.isEmpty ? plan : plan + " · " + email
    }

    // MARK: - OpenRouter

    private var rate: Double { Self.num((or?["exchange_rate"] as? [String: Any])?["rate"]) }
    private var rateOK: Bool { ((or?["exchange_rate"] as? [String: Any])?["available"] as? Bool ?? false) && rate > 0 }
    private var cny: Bool { currency == "CNY" && rateOK }

    private func amount(_ value: Any?) -> String {
        let v = Self.num(value) * (cny ? rate : 1)
        let digits = v > 0 && v < 1 ? 4 : 2
        return (cny ? "¥" : "$") + v.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
    }

    private func exactAmount(_ value: Any?) -> String {
        let v = Self.num(value) * (cny ? rate : 1)
        return (cny ? "¥" : "$") + v.formatted(.number.precision(.fractionLength(2...8)).locale(Locale(identifier: "en_US")))
    }

    private var points: [[String: Any]] {
        ((or?["series"] as? [String: Any])?[range] as? [[String: Any]]) ?? []
    }

    private static let rangeTitles = ["daily": "最近 7 天", "weekly": "最近 8 周", "monthly": "最近 12 个月"]

    @ViewBuilder
    private var orPane: some View {
        HStack {
            Spacer()
            Picker("币种", selection: Binding(get: { cny ? "CNY" : "USD" }, set: { currency = $0 })) {
                Text("USD").tag("USD")
                Text("CNY").tag("CNY")
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .disabled(!rateOK)
        }
        statusLine(orStatus, bad: orBad)
        if let or {
            let balance = or["balance"] as? [String: Any] ?? [:]
            let key = or["current_key"] as? [String: Any] ?? [:]
            let balanceOK = balance["available"] as? Bool ?? false
            let keyOK = key["available"] as? Bool ?? false

            UsageTile {
                Text("账户余额").font(.system(size: 13)).foregroundStyle(Theme.dim)
                Text(balanceOK ? amount(balance["remaining"]) : "暂不可用")
                    .font(.system(size: 32, design: .serif).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Text(balanceOK
                     ? "累计充值 \(amount(balance["total_credits"])) · 已使用 \(amount(balance["total_usage"]))"
                     : (balance["error"] as? String ?? "OpenRouter 暂未返回账户余额"))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }

            HStack(spacing: 8) {
                ForEach(["usage_daily", "usage_weekly", "usage_monthly"], id: \.self) { field in
                    UsageTile {
                        Text(["usage_daily": "今日", "usage_weekly": "本周"][field] ?? "本月").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        Text(keyOK ? amount(key[field]) : "—")
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
            }

            hitRate
            chart

            let warnings = [balanceOK ? nil : (balance["error"] as? String).map { "余额：" + $0 },
                            keyOK ? nil : (key["error"] as? String).map { "当前密钥：" + $0 }].compactMap { $0 }
            if !warnings.isEmpty {
                Text(warnings.joined(separator: "；")).font(.system(size: 12.5)).foregroundStyle(MemoryStyle.danger)
            }
            note(orNotes)
        }
    }

    private var hitRate: some View {
        let requests = points.reduce(0) { $0 + max(0, Int(Self.num($1["requests"]))) }
        let hits = points.reduce(0) { $0 + max(0, Int(Self.num($1["cache_hits"]))) }
        return UsageTile {
            Text("请求命中率").font(.system(size: 13)).foregroundStyle(Theme.dim)
            Text(requests > 0 ? String(format: "%.1f%%", Double(hits) / Double(requests) * 100) : "—")
                .font(.system(size: 28, design: .serif).monospacedDigit())
                .foregroundStyle(Theme.accent)
            Text(requests > 0 ? "\(Self.rangeTitles[range] ?? "") · \(hits) / \(requests) 次命中" : "从本次更新后的请求开始统计")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.dim)
        }
    }

    // MARK: - 柱状图

    /// 单一系列：一种颜色（粉），标题说明是什么，不要图例；点一根柱子看具体数。
    private var chart: some View {
        let list = points
        let total = list.reduce(0) { $0 + Self.num($1["cost"]) }
        let maxCost = list.map { Self.num($0["cost"]) }.max() ?? 0
        let selected = list.first { $0["start"] as? String == selectedStart } ?? list.last
        return UsageTile {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.rangeTitles[range] ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("合计 " + amount(total)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.dim)
                }
                Spacer()
                Picker("范围", selection: $range) {
                    Text("日").tag("daily")
                    Text("周").tag("weekly")
                    Text("月").tag("monthly")
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            // 选中那根柱子的具体数。
            VStack(alignment: .leading, spacing: 2) {
                if let selected {
                    Text(Self.periodLabel(selected["start"] as? String ?? "", range) + " · " + exactAmount(selected["cost"]))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.text)
                    Text(Self.hitText(selected)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
                } else {
                    Text("还没有具体数值").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("产生用量后会显示在这里").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.1)))

            if list.isEmpty {
                Text("还没有可展示的用量")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                HStack(alignment: .bottom, spacing: list.count > 8 ? 3 : 6) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, point in
                        bar(point, max: maxCost, selected: (point["start"] as? String) == (selected?["start"] as? String))
                    }
                }
                .frame(height: 170)
                .animation(.easeOut(duration: 0.2), value: range)
            }
        }
        .onChange(of: range) { _, _ in selectedStart = "" }
    }

    private func bar(_ point: [String: Any], max: Double, selected: Bool) -> some View {
        let start = point["start"] as? String ?? ""
        let cost = Self.num(point["cost"])
        let fraction = max > 0 ? Swift.max(cost > 0 ? 0.04 : 0.02, cost / max) : 0.02
        return Button {
            selectedStart = start
        } label: {
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.dim.opacity(0.1))
                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2,
                                               bottomTrailingRadius: 2, topTrailingRadius: 4, style: .continuous)
                            .fill(Theme.accent.opacity(selected ? 1 : 0.6))
                            .frame(height: geo.size.height * fraction)
                    }
                }
                Text(Self.tickLabel(start, range))
                    .font(.system(size: 10.5, weight: selected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? Theme.text : Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.periodLabel(start, range))，\(exactAmount(cost))，\(Self.hitText(point))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var orNotes: String {
        var notes = ["按 UTC 统计", "金额为当前 OpenRouter 密钥在 Dwell 中的用量"]
        if cny {
            notes.append(String(format: "按 1 USD ≈ %.4f CNY 换算", rate))
            if (or?["exchange_rate"] as? [String: Any])?["stale"] as? Bool ?? false { notes.append("汇率为最近缓存") }
        }
        if let stamp = Self.stamp(or?["generated_at"]) { notes.append("更新于 " + stamp) }
        return notes.joined(separator: " · ")
    }

    // MARK: - 小零件

    @ViewBuilder
    private func statusLine(_ text: String, bad: Bool) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(bad ? MemoryStyle.danger : Theme.dim)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.dim)
            .padding(.top, 4)
    }

    // MARK: - 读

    private func load(refresh: Bool) async {
        loading = true
        defer { loading = false }
        if tab == "sub" {
            subStatus = sub == nil ? "正在读取订阅额度…" : "正在刷新…"
            subBad = false
            do {
                let data = try await API.shared.request("GET", "api/subscription/usage",
                                                        query: refresh ? ["refresh": "true"] : [:])
                sub = data
                subStatus = data["source"] as? String == "observed" ? Self.observedNote(data) : ""
            } catch {
                subStatus = (error as? APIError)?.message ?? "暂时拿不到订阅额度"
                subBad = true
            }
        } else {
            orStatus = or == nil ? "正在读取用量…" : "正在刷新…"
            orBad = false
            do {
                or = try await API.shared.request("GET", "api/openrouter/usage")
                orStatus = ""
            } catch {
                orStatus = (error as? APIError)?.message ?? "暂时拿不到 OpenRouter 用量"
                orBad = true
            }
        }
    }

    private static func observedNote(_ data: [String: Any]) -> String {
        let windows = data["windows"] as? [[String: Any]] ?? []
        let seen = windows.map { num($0["observed_at"]) }.max() ?? 0
        return "官方用量接口这次没有给出数字，下面是最近一次聊天时 Claude Code 报来的额度"
            + (seen > 0 ? "（记于 \(stamp(seen) ?? "")）" : "") + "。"
    }

    static func num(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d HH:mm:ss"
        return f
    }()

    static func stamp(_ value: Any?) -> String? {
        let ts = num(value)
        return ts > 0 ? stampFormat.string(from: Date(timeIntervalSince1970: ts)) : nil
    }

    static func tickLabel(_ start: String, _ range: String) -> String {
        let parts = start.split(separator: "-").compactMap { Int($0) }
        if range == "monthly" { return parts.count > 1 ? "\(parts[1])月" : start }
        return parts.count > 2 ? "\(parts[1])/\(parts[2])" : start
    }

    static func periodLabel(_ start: String, _ range: String) -> String {
        let p = start.split(separator: "-").compactMap { Int($0) }
        if range == "monthly" && p.count >= 2 { return "\(p[0])年\(p[1])月" }
        guard p.count >= 3 else { return start }
        if range == "weekly" {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            if let first = utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
               let end = utc.date(byAdding: .day, value: 6, to: first) {
                let c = utc.dateComponents([.month, .day], from: end)
                return "\(p[0])年\(p[1])月\(p[2])日–\(c.month ?? 0)月\(c.day ?? 0)日"
            }
        }
        return "\(p[0])年\(p[1])月\(p[2])日"
    }

    static func hitText(_ point: [String: Any]) -> String {
        let requests = max(0, Int(num(point["requests"])))
        let hits = max(0, Int(num(point["cache_hits"])))
        return requests > 0
            ? "缓存命中 \(hits)/\(requests) · " + String(format: "%.1f%%", Double(hits) / Double(requests) * 100)
            : "命中率暂无数据"
    }
}

/// 订阅额度的一张卡：名字、用了百分之几、一条进度条、几点重置。
private struct SubscriptionCard: View {
    let window: [String: Any]

    var body: some View {
        let used = window["used"].flatMap { $0 is NSNull ? nil : UsagePage.num($0) }
        let pct = min(100, max(0, used ?? 0))
        let label = window["label"] as? String ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(used.map { ($0 == $0.rounded() ? "\(Int($0))" : String(format: "%.1f", $0)) + "% used" } ?? "—")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.dim.opacity(0.15))
                    Capsule()
                        .fill(pct >= 90 ? UsageStyle.hot : Theme.accent)
                        .frame(width: geo.size.width * pct / 100)
                }
            }
            .frame(height: 8)
            if !foot.isEmpty {
                Text(foot).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bubble))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(pct))%")
    }

    private var foot: String {
        if window["group"] as? String == "extra", let limit = window["monthly_limit"], !(limit is NSNull) {
            let currency = window["currency"] as? String ?? ""
            let money: (Any?) -> String = { value in
                let text = String(format: "%.2f", UsagePage.num(value))
                return currency.isEmpty || currency == "USD" ? "$" + text : text + " " + currency
            }
            return "\(money(window["used_credits"])) of \(money(limit)) this month"
        }
        let ts = UsagePage.num(window["resets_at"])
        guard ts > 0 else { return "" }
        let at = Date(timeIntervalSince1970: ts), now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "HH:mm"
        var when = f.string(from: at)
        if !Calendar.current.isDate(at, inSameDayAs: now) {
            f.dateFormat = at.timeIntervalSince(now) < 6 * 86400 ? "EEE HH:mm" : "MMM d HH:mm"
            when = f.string(from: at)
        }
        return (at < now ? "Reset at " : "Resets at ") + when
    }
}

/// 用量页里的小白卡。
private struct UsageTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bubble))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
    }
}

enum UsageStyle {
    static let card = Color(light: 0xFFFFFF, dark: 0x433C41)
    /// 快用完（≥90%）时那条进度条换成深一点的玫红；旁边一直写着百分比，不只靠颜色。
    static let hot = Color(light: 0xC2647F, dark: 0xE08AA3)
}
