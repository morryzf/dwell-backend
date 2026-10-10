import SwiftUI
import UIKit

/// 外观设置：日夜模式、聊天背景、消息玻璃效果。
/// 跟网页一样只存在这台设备上——网页存在浏览器里，这里存在 app 里，两边互不影响，也不上传。
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()

    // MARK: 日夜

    /// auto / light / dark
    @Published var theme: String {
        didSet { UserDefaults.standard.set(theme, forKey: "dwell.theme") }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // MARK: 聊天背景（两位助手各一张）

    @Published private(set) var backgrounds: [String: UIImage] = [:]
    @Published private(set) var overlays: [String: Double] = [:]

    // MARK: 消息玻璃

    @Published private(set) var messageStyles: [String: [String: MessageStyle]] = [:]

    private init() {
        theme = UserDefaults.standard.string(forKey: "dwell.theme") ?? "auto"
        for who in ["cloudy", "chatgpt"] {
            if let data = try? Data(contentsOf: Self.backgroundURL(who)), let image = UIImage(data: data) {
                backgrounds[who] = image
            }
            if let value = UserDefaults.standard.object(forKey: "dwell.backgroundOverlay.\(who)") as? Double {
                overlays[who] = value
            }
        }
        if let data = UserDefaults.standard.data(forKey: "dwell.messageStyle"),
           let saved = try? JSONDecoder().decode([String: [String: MessageStyle]].self, from: data) {
            messageStyles = saved
        }
    }

    // MARK: 背景

    func background(_ who: String) -> UIImage? { backgrounds[who] }

    /// 网页默认 54%。
    func overlay(_ who: String) -> Double { overlays[who] ?? 54 }

    func setOverlay(_ value: Double, for who: String) {
        overlays[who] = min(100, max(0, value.rounded()))
        UserDefaults.standard.set(overlays[who], forKey: "dwell.backgroundOverlay.\(who)")
    }

    /// 跟网页的 shrinkBackground 一样：长边压到 1440，JPEG 0.78。
    func setBackground(_ image: UIImage?, for who: String) {
        let url = Self.backgroundURL(who)
        guard let image else {
            backgrounds[who] = nil
            try? FileManager.default.removeItem(at: url)
            return
        }
        let small = PendingImage.resize(image, maxSide: 1440)
        guard let data = small.jpegData(compressionQuality: 0.78) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        backgrounds[who] = small
    }

    private static func backgroundURL(_ who: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("backgrounds/\(who).jpg")
    }

    // MARK: 消息样式

    /// role：me / cloudy / chatgpt；mode：light / dark
    func style(_ role: String, _ mode: String) -> MessageStyle {
        messageStyles[role]?[mode] ?? MessageStyle.defaults(mode)
    }

    func setStyle(_ style: MessageStyle, role: String, mode: String) {
        messageStyles[role, default: [:]][mode] = style
        saveStyles()
    }

    func resetStyle(role: String, mode: String) {
        messageStyles[role]?[mode] = nil
        saveStyles()
    }

    private func saveStyles() {
        if let data = try? JSONEncoder().encode(messageStyles) {
            UserDefaults.standard.set(data, forKey: "dwell.messageStyle")
        }
    }
}

/// 一种消息的玻璃样式。字段和默认值照网页的 MESSAGE_STYLE_DEFAULTS。
struct MessageStyle: Codable, Equatable {
    var blur: Double
    var background: String
    var backgroundOpacity: Double
    var border: String
    var borderOpacity: Double
    var borderWidth: Double
    var text: String
    var radius: Double

    static func defaults(_ mode: String) -> MessageStyle {
        mode == "dark"
            ? MessageStyle(blur: 16, background: "#4f4148", backgroundOpacity: 62, border: "#f2c9dc",
                           borderOpacity: 18, borderWidth: 1, text: "#f7edf2", radius: 18)
            : MessageStyle(blur: 16, background: "#f6e8ee", backgroundOpacity: 48, border: "#ffffff",
                           borderOpacity: 38, borderWidth: 1, text: "#514a4f", radius: 18)
    }

    var backgroundColor: Color { Color(hexString: background).opacity(backgroundOpacity / 100) }
    var borderColor: Color { Color(hexString: border).opacity(borderOpacity / 100) }
    var textColor: Color { Color(hexString: text) }
}

extension Color {
    init(hexString: String) {
        let clean = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self.init(hex: UInt32(clean, radix: 16) ?? 0)
    }

    /// 取色器给回来的颜色转回 #rrggbb。
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

/// 聊天页的底：有自己的背景图就铺图，上面盖一层渐变遮罩（越往下越浓，跟网页一样）；没有就是方格纸。
struct ChatBackground: View {
    let assistant: String
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        if let image = appearance.background(assistant) {
            let overlay = appearance.overlay(assistant) / 100
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(
                        LinearGradient(colors: [Theme.background.opacity(max(0, overlay - 0.1)),
                                                Theme.background.opacity(min(1, overlay + 0.1))],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            .ignoresSafeArea()
        } else {
            PaperBackground()
        }
    }
}

private struct AssistantKey: EnvironmentKey {
    static let defaultValue = "cloudy"
}

extension EnvironmentValues {
    /// 当前是哪位助手：气泡按这位的玻璃样式画。
    var assistantID: String {
        get { self[AssistantKey.self] }
        set { self[AssistantKey.self] = newValue }
    }
}
