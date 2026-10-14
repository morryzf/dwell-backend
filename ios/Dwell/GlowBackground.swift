import SwiftUI

/// 光晕背景的一套颜色：一个底色，三个光晕色。浅色、深色各一套。
struct GlowPalette: Codable, Equatable {
    var base: String
    var colors: [String]
}

/// 一位助手的光晕背景：两套颜色 + 速度 + 强度，只存在这台手机上。
struct Glow: Codable, Equatable {
    var light: GlowPalette
    var dark: GlowPalette
    /// 0 静止，1 慢，2 中
    var speed: Int
    /// 0–100：光晕有多浓
    var intensity: Double

    func palette(_ mode: String) -> GlowPalette { mode == "dark" ? dark : light }

    static let defaults = Glow(light: GlowPreset.sakura.light, dark: GlowPreset.sakura.dark, speed: 1, intensity: 70)
}

struct GlowPreset: Identifiable {
    let id: String
    let name: String
    let light: GlowPalette
    let dark: GlowPalette

    static let sakura = GlowPreset(
        id: "sakura", name: "樱花",
        light: GlowPalette(base: "#fcf6f8", colors: ["#f2a3bf", "#f7c6a3", "#cfa9ef"]),
        dark: GlowPalette(base: "#1a1116", colors: ["#a8476f", "#8a3f7a", "#6e4a8f"]))

    static let all: [GlowPreset] = [
        sakura,
        GlowPreset(id: "sunset", name: "晚霞",
                   light: GlowPalette(base: "#fbf6f3", colors: ["#f49aae", "#f9be82", "#b49ae8"]),
                   dark: GlowPalette(base: "#17111a", colors: ["#b0446b", "#c0703f", "#5b3f9e"])),
        GlowPreset(id: "seamist", name: "海雾",
                   light: GlowPalette(base: "#f4f8fa", colors: ["#86c6dc", "#a9c1f0", "#9fdcc2"]),
                   dark: GlowPalette(base: "#0e1418", colors: ["#2f7a8f", "#3b5ca8", "#2d8a6e"])),
        GlowPreset(id: "night", name: "夜航",
                   light: GlowPalette(base: "#f5f5fb", colors: ["#9aa6ee", "#c3a9ee", "#88c2ec"]),
                   dark: GlowPalette(base: "#0c0d18", colors: ["#3a3f9e", "#6b3a9e", "#1f6a8f"])),
        GlowPreset(id: "honey", name: "蜜桃",
                   light: GlowPalette(base: "#fdf8f3", colors: ["#f8ad85", "#f4d27e", "#f099a8"]),
                   dark: GlowPalette(base: "#18120e", colors: ["#b5603d", "#a8822f", "#9e3f55"])),
    ]
}

/// 会动的光晕：几团很大、边缘化开的颜色沿着各自的慢路线飘，交叠的地方混出新的颜色。
/// 用的是径向渐变而不是模糊滤镜，每帧画起来很省；静止、减弱动态效果、切到后台、上面盖着整页时都停住。
struct GlowBackground: View {
    let glow: Glow
    var paused = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 每一团：起点、飘多远、绕多快、从哪儿开始、多大、用第几个颜色。坐标按屏幕宽高的比例算。
    private struct Blob {
        let x, y, dx, dy, fx, fy, phase, radius: Double
        let color: Int
    }

    private static let blobs: [Blob] = [
        Blob(x: 0.25, y: 0.20, dx: 0.32, dy: 0.16, fx: 1.0, fy: 0.8, phase: 0, radius: 0.36, color: 0),
        Blob(x: 0.75, y: 0.42, dx: 0.30, dy: 0.20, fx: 0.7, fy: 1.1, phase: 2.1, radius: 0.33, color: 1),
        Blob(x: 0.30, y: 0.72, dx: 0.30, dy: 0.18, fx: 0.9, fy: 0.6, phase: 4.2, radius: 0.38, color: 2),
        Blob(x: 0.72, y: 0.92, dx: 0.28, dy: 0.12, fx: 0.6, fy: 0.9, phase: 1.3, radius: 0.30, color: 1),
    ]

    var body: some View {
        let dark = scheme == .dark
        let palette = dark ? glow.dark : glow.light
        let still = glow.speed == 0 || reduceMotion
        let frozen = still || paused || scenePhase != .active
        // 「慢」大约 14 秒绕一圈，「中」快一倍。
        let rate = glow.speed >= 2 ? 2.0 : 1.0
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: frozen)) { timeline in
            let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 36_000) * rate
            Canvas { context, size in
                Self.draw(&context, size: size, t: t, palette: palette, dark: dark, intensity: glow.intensity / 100)
            }
        }
        .drawingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private static func draw(_ context: inout GraphicsContext, size: CGSize, t: Double,
                             palette: GlowPalette, dark: Bool, intensity: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hexString: palette.base)))
        guard !palette.colors.isEmpty else { return }
        // 深色时用「滤色」叠：交叠的地方更亮，像雾里的光；浅色时正常叠，不会发灰。
        context.blendMode = dark ? .screen : .normal
        let omega = 2 * Double.pi / 14
        let span = max(size.width, size.height)
        let alpha = min(1, intensity * (dark ? 0.9 : 1.0))
        for blob in blobs {
            let cx = (blob.x + blob.dx * sin(omega * blob.fx * t + blob.phase)) * size.width
            let cy = (blob.y + blob.dy * cos(omega * blob.fy * t + blob.phase)) * size.height
            let r = blob.radius * span * (1 + 0.15 * sin(omega * 0.5 * t + blob.phase * 1.7))
            let color = Color(hexString: palette.colors[blob.color % palette.colors.count])
            let gradient = Gradient(stops: [
                .init(color: color.opacity(alpha), location: 0),
                .init(color: color.opacity(alpha * 0.85), location: 0.3),
                .init(color: color.opacity(alpha * 0.35), location: 0.65),
                .init(color: color.opacity(0), location: 1),
            ])
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect),
                         with: .radialGradient(gradient, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
        }
    }
}
