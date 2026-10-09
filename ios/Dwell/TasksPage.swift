import SwiftUI

/// 「清单」，照网页的 #todoSheet：上面一栏是她的（两位助手共用），下面一栏是当前这位助手自己的活。
/// 她的那栏能勾、能删、能新增；助手那栏只看不动，那是他自己管的。
struct TasksPage: View {
    struct Todo: Identifiable {
        let id: String
        let text: String
        let done: Bool
        let at: String
        let by: String
        let fixed: Bool

        init(json: [String: Any]) {
            id = json["id"] as? String ?? ""
            text = json["text"] as? String ?? ""
            done = json["done"] as? Bool ?? false
            at = json["at"] as? String ?? ""
            by = json["by"] as? String ?? ""
            fixed = (json["fixed"] as? Int ?? 0) != 0 || (json["fixed"] as? Bool ?? false)
        }

        /// 过期 = 挂了时间、时间过了、还没做（活算，不看响没响过）。
        var isLate: Bool { !at.isEmpty && !done && at <= HomeClock.hm() }

        /// 底下那行小字：每天 · 谁记的。
        var meta: String {
            var bits: [String] = []
            if fixed { bits.append("每天") }
            bits.append(["gu": "顾屿", "cloudy": "Cloudy", "chatgpt": "ChatGPT"][by] ?? "Morry")
            return bits.joined(separator: " · ")
        }
    }

    @EnvironmentObject private var store: ChatStore

    @State private var hers: [Todo] = []
    @State private var mine: [Todo] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var newText = ""
    @State private var newTime = ""
    @State private var newDaily = false
    @State private var error = ""
    @FocusState private var inputFocused: Bool

    private var paid: Int { hers.filter(\.done).count }

    var body: some View {
        PageScaffold(title: "清单", subtitle: subtitle) {
            ProgressRing(fraction: hers.isEmpty ? 0 : Double(paid) / Double(hers.count))
                .padding(.top, 6)
        } content: {
            if !error.isEmpty {
                Text(error).font(.system(size: 13)).foregroundStyle(MemoryStyle.danger).padding(.top, 8)
            }

            PageSection(text: "Plum 的")
            VStack(spacing: 9) {
                if hers.isEmpty && loaded {
                    PageRow { Text("空的——等他布置，或者自己写一条").font(.system(size: 13.5)).foregroundStyle(Theme.dim) }
                }
                ForEach(Self.sorted(hers)) { todo in
                    row(todo, side: "hers", canTouch: true)
                }
                if adding {
                    addForm
                } else {
                    DashedAddButton(title: "新增一项") {
                        adding = true
                        inputFocused = true
                    }
                }
            }

            PageSection(text: "\(store.assistant?.name ?? "Cloudy") 的活")
            VStack(spacing: 9) {
                if mine.isEmpty && loaded {
                    PageRow { Text("他这会儿手上没挂着活").font(.system(size: 13.5)).foregroundStyle(Theme.dim) }
                }
                ForEach(Self.sorted(mine)) { todo in
                    row(todo, side: "mine", canTouch: false)
                }
            }

            footer
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var subtitle: String {
        let now = Date()
        let month = HomeClock.calendar.component(.month, from: now)
        let day = HomeClock.calendar.component(.day, from: now)
        return "\(month)/\(day) \(HomeClock.weekday(now)) · 完成 \(paid)/\(hers.count)"
    }

    private func row(_ todo: Todo, side: String, canTouch: Bool) -> some View {
        PageRow(dim: todo.done) {
            Button {
                Task { await act(["action": "toggle", "list": side, "id": todo.id]) }
            } label: {
                CheckBox(on: todo.done)
            }
            .buttonStyle(.plain)
            .disabled(!canTouch)
            .opacity(canTouch ? 1 : 0.6)
            .accessibilityLabel(todo.done ? "标成没做" : "标成做完")

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.text)
                    .font(.system(size: 15.5))
                    .foregroundStyle(Theme.text)
                    .strikethrough(todo.done, color: Theme.dim)
                Text(todo.meta)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
                    .strikethrough(todo.done, color: Theme.dim)
            }
            Spacer(minLength: 4)
            if !todo.at.isEmpty {
                Text(todo.at)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    // 过期的那颗时间用粉色盯着她；没过期的淡一点。
                    .foregroundStyle(todo.isLate ? Theme.accent : Theme.accent.opacity(todo.done ? 0.5 : 0.85))
            }
            if canTouch {
                Button {
                    Task { await act(["action": "del", "list": side, "id": todo.id]) }
                } label: {
                    Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删掉")
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("这件事是…", text: $newText)
                .font(.system(size: 15.5))
                .focused($inputFocused)
                .submitLabel(.done)
                .onSubmit { Task { await add() } }
            HStack(spacing: 8) {
                OptionalTimeField(value: $newTime)
                ToggleChip(title: "每天", on: $newDaily)
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

    /// 底下那张小票：今天也辛苦了，加一串票号（年月日 + 总数 + 完成数，跟网页一样）。
    private var footer: some View {
        let now = Date()
        let c = HomeClock.calendar
        let code = String(format: "%02d%02d%02d%02d%02d", c.component(.year, from: now) % 100,
                          c.component(.month, from: now), c.component(.day, from: now), hers.count, paid)
        return VStack(spacing: 6) {
            Text("今天也辛苦了，Morry").tracking(0.7)
            Text("MORRY · CLOUDY GENERAL STORE · #\(code)").tracking(3.3).multilineTextAlignment(.center)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.dim)
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }

    // MARK: - 读写

    /// 排序：过期的浮到最上面盯着她，然后是挂了时间的（按时间），最后是没时间的。
    static func sorted(_ list: [Todo]) -> [Todo] {
        list.enumerated().sorted { a, b in
            let la = a.element.isLate ? 0 : 1, lb = b.element.isLate ? 0 : 1
            if la != lb { return la < lb }
            switch (a.element.at.isEmpty, b.element.at.isEmpty) {
            case (false, false) where a.element.at != b.element.at: return a.element.at < b.element.at
            case (false, true): return true
            case (true, false): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    private func apply(_ json: [String: Any]) {
        hers = (json["hers"] as? [[String: Any]] ?? []).map(Todo.init(json:))
        mine = (json["mine"] as? [[String: Any]] ?? []).map(Todo.init(json:))
        loaded = true
    }

    private func load() async {
        do {
            apply(try await API.shared.request("GET", "api/todos"))
            error = ""
        } catch {
            self.error = "清单拿不到，网抖了一下，再开一次试试"
        }
    }

    private func act(_ body: [String: Any]) async {
        do {
            apply(try await API.shared.request("POST", "api/todos", body: body))
            error = ""
        } catch {
            self.error = "没记上，再试一次"
        }
    }

    private func add() async {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        await act(["action": "add", "list": "hers", "text": text, "by": "her", "at": newTime, "fixed": newDaily])
        newText = ""
        newTime = ""
        newDaily = false
        adding = false
    }
}

/// 网页的勾选框：没做是一圈淡淡的圆角方框，做完是填满的鼠尾草绿加白勾。
struct CheckBox: View {
    let on: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(on ? MemoryStyle.sage : .clear)
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .stroke(on ? .clear : Theme.text.opacity(0.45), lineWidth: 1.8)
            if on {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
}

/// 标题右边那枚安静的完成度小圆环。
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.dim.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: fraction)
        }
        .frame(width: 24, height: 24)
        .accessibilityElement()
        .accessibilityLabel("完成了 \(Int((fraction * 100).rounded()))%")
    }
}
