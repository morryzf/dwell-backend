import SwiftUI

/// 侧边栏里那几页（清单、日子、用量）共用的架子，照网页的 .sheetWrap.page：
/// 左上一个返回箭头，下面衬线大标题 + 一行小字，再往下是内容，铺在方格纸上。
struct PageScaffold<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 26, weight: .regular, design: .serif))
                            .foregroundStyle(Theme.text)
                        Text(subtitle)
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    trailing
                }
                .padding(.bottom, 8)
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PaperBackground())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("返回")
                Spacer()
            }
            .padding(.horizontal, 12)
        }
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// 网页的 .hsect：一行很淡、字距拉开的小标题。
struct PageSection: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .tracking(1.4)
            .foregroundStyle(Theme.dim)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
    }
}

/// 网页的 .hrow：一张圆角玻璃卡片。
struct PageRow<Content: View>: View {
    var dim = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
            .shadow(color: Theme.bubbleShadow, radius: 10, y: 6)
            .opacity(dim ? 0.7 : 1)
    }
}

/// 网页的「＋ 新增一项」：虚线框，点开才是输入框。
struct DashedAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 14))
                Text(title).font(.system(size: 15))
                Spacer()
            }
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.dim.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
        .buttonStyle(.plain)
    }
}

/// 可开可关的小胶囊（「每天」「每年」「重要日子」）。
struct ToggleChip: View {
    let title: String
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(on ? .white : Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(on ? Theme.send : Theme.roundButton))
                .overlay(Capsule().stroke(on ? .clear : MemoryStyle.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 家里的「今天」「现在几点」都按北京时间算——跟网页、跟服务器一致，出差换了时区也不会对不上。
enum HomeClock {
    static let zone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.firstWeekday = 2   // 周一开头
        return c
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = zone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    static let dayFormat = formatter("yyyy-MM-dd")
    static let hmFormat = formatter("HH:mm")

    static func day(_ date: Date = Date()) -> String { dayFormat.string(from: date) }
    static func hm(_ date: Date = Date()) -> String { hmFormat.string(from: date) }
    static func date(_ day: String) -> Date? { dayFormat.date(from: day) }

    static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func weekday(_ date: Date) -> String {
        weekdays[calendar.component(.weekday, from: date) - 1]
    }
}

/// 时间输入：一个「几点」的小胶囊，点开是系统的时间滚轮；可以清空。
struct OptionalTimeField: View {
    @Binding var value: String   // "HH:mm" 或空
    @State private var picking = false

    var body: some View {
        Button {
            if value.isEmpty { value = HomeClock.hm() }
            picking = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 12))
                Text(value.isEmpty ? "几点" : value).monospacedDigit()
            }
            .font(.system(size: 13))
            .foregroundStyle(value.isEmpty ? Theme.dim : Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.roundButton))
            .overlay(Capsule().stroke(MemoryStyle.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $picking) {
            VStack(spacing: 8) {
                DatePicker("", selection: Binding(
                    get: { HomeClock.hmFormat.date(from: value) ?? Date() },
                    set: { value = HomeClock.hm($0) }
                ), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.timeZone, HomeClock.zone)
                HStack {
                    Button("不定时间") { value = ""; picking = false }
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Button("好") { picking = false }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
            .presentationCompactAdaptation(.popover)
        }
    }
}
