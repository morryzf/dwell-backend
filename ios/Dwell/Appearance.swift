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
    /// paper / image / glow；没设过就看有没有背景图。
    @Published private(set) var backgroundKinds: [String: String] = [:]
    @Published private(set) var glows: [String: Glow] = [:]

    // MARK: 消息玻璃

    @Published private(set) var messageStyles: [String: [String: MessageStyle]] = [:]

    // MARK: 界面玻璃（输入框、侧边栏、整页弹窗；见 Glass.swift）

    /// iOS 26 上用系统的 Liquid Glass；关掉就回到磨砂玻璃。老系统上这个开关不起作用。
    @Published var liquidGlass: Bool {
        didSet { UserDefaults.standard.set(liquidGlass, forKey: "dwell.liquidGlass") }
    }

    /// 现在是不是真的在用 Liquid Glass（开着，而且系统够新）。
    var usesLiquidGlass: Bool {
        guard liquidGlass else { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    @Published var interfaceGlass: [String: [String: GlassValue]] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(interfaceGlass) {
                UserDefaults.standard.set(data, forKey: "dwell.interfaceGlass")
            }
        }
    }

    private init() {
        theme = UserDefaults.standard.string(forKey: "dwell.theme") ?? "auto"
        liquidGlass = UserDefaults.standard.object(forKey: "dwell.liquidGlass") as? Bool ?? true
        for who in ["cloudy", "chatgpt"] {
            if let data = try? Data(contentsOf: Self.backgroundURL(who)), let image = UIImage(data: data) {
                backgrounds[who] = image
            }
            if let value = UserDefaults.standard.object(forKey: "dwell.backgroundOverlay.\(who)") as? Double {
                overlays[who] = value
            }
            backgroundKinds[who] = UserDefaults.standard.string(forKey: "dwell.backgroundKind.\(who)")
        }
        if let data = UserDefaults.standard.data(forKey: "dwell.messageStyle"),
           let saved = try? JSONDecoder().decode([String: [String: MessageStyle]].self, from: data) {
            messageStyles = saved
        }
        if let data = UserDefaults.standard.data(forKey: "dwell.glow"),
           let saved = try? JSONDecoder().decode([String: Glow].self, from: data) {
            glows = saved
        }
        if let data = UserDefaults.standard.data(forKey: "dwell.interfaceGlass"),
           let saved = try? JSONDecoder().decode([String: [String: GlassValue]].self, from: data) {
            interfaceGlass = saved
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
            if backgroundKinds[who] == "image" { setBackgroundKind("paper", for: who) }
            return
        }
        let small = PendingImage.resize(image, maxSide: 1440)
        guard let data = small.jpegData(compressionQuality: 0.78) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        backgrounds[who] = small
        setBackgroundKind("image", for: who)
    }

    /// 现在铺的是哪种：选了图片却没有图，就还是方格纸。
    func backgroundKind(_ who: String) -> String {
        let hasImage = backgrounds[who] != nil
        switch backgroundKinds[who] {
        case "glow": return "glow"
        case "paper": return "paper"
        default: return hasImage ? "image" : "paper"
        }
    }

    func setBackgroundKind(_ kind: String, for who: String) {
        backgroundKinds[who] = kind
        UserDefaults.standard.set(kind, forKey: "dwell.backgroundKind.\(who)")
    }

    // MARK: 光晕

    func glow(_ who: String) -> Glow { glows[who] ?? .defaults }

    func setGlow(_ glow: Glow, for who: String) {
        var value = glow
        value.intensity = min(100, max(0, value.intensity.rounded()))
        glows[who] = value
        saveGlows()
    }

    func resetGlow(for who: String) {
        glows[who] = nil
        saveGlows()
    }

    private func saveGlows() {
        if let data = try? JSONEncoder().encode(glows) {
            UserDefaults.standard.set(data, forKey: "dwell.glow")
        }
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
            ? MessageStyle(blur: 10, background: "#4f4148", backgroundOpacity: 62, border: "#f2c9dc",
                           borderOpacity: 18, borderWidth: 1, text: "#f7edf2", radius: 18)
            : MessageStyle(blur: 10, background: "#f6e8ee", backgroundOpacity: 48, border: "#ffffff",
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
    /// 先换到 sRGB 再四舍五入：取色器给的是广色域的颜色，直接取再截断会差一点点，
    /// 存回去再读出来就变了色，滑块一动别的滑块也跟着跳。
    var hexString: String {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = UIColor(self).cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)
        let parts = (cg?.components ?? [0, 0, 0]).map { min(1, max(0, $0)) }
        let rgb = (parts.count >= 3 ? Array(parts.prefix(3)) : [parts[0], parts[0], parts[0]])
            .map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
    }
}

/// 聊天页的底：会动的光晕；或者自己的背景图，上面盖一层渐变遮罩（越往下越浓，跟网页一样）；或者方格纸。
struct ChatBackground: View {
    let assistant: String
    /// 上面盖着整页（设置、侧栏里的页面）时，光晕停住不画。
    var paused = false
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        if appearance.backgroundKind(assistant) == "glow" {
            GlowBackground(glow: appearance.glow(assistant), paused: paused)
        } else if appearance.backgroundKind(assistant) == "image", let image = appearance.background(assistant) {
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
            // 铺满裁掉的那部分图也会接手指，挡住上面的东西；背景本来就不用点。
            .allowsHitTesting(false)
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
