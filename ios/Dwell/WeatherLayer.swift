import SwiftUI

/// 外面的天气（后端 /api/weather 给的，固定城市）。
struct WeatherNow: Equatable {
    enum Kind: String { case clear, cloudy, fog, rain, snow, storm, unknown }

    var kind: Kind = .unknown
    /// "light" / "moderate" / "heavy"，晴天多云是空的。
    var intensity = ""
    var isDay = true

    init() {}

    init(json: [String: Any]) {
        kind = Kind(rawValue: json["condition"] as? String ?? "") ?? .unknown
        intensity = json["intensity"] as? String ?? ""
        isDay = json["is_day"] as? Bool ?? true
    }

    /// 0 小、1 中、2 大。
    var level: Int { intensity == "heavy" ? 2 : intensity == "moderate" ? 1 : 0 }

    /// 设置里的「预览」选项（"rain:heavy" 这样的字符串）：想先看看效果，不用等真的下雨。
    static func preview(_ raw: String) -> WeatherNow? {
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":")
        var now = WeatherNow()
        now.kind = Kind(rawValue: String(parts.first ?? "")) ?? .unknown
        now.intensity = parts.count > 1 ? String(parts[1]) : ""
        return now.kind == .unknown ? nil : now
    }
}

/// 天气叠层：铺在聊天背景上、蕾丝和气泡下面。下雨是雨点打在玻璃上，下雪是雪花飘。
/// 晴、多云、雾什么都不画。天气换了，新旧两层慢慢交叉淡过去，不硬切。
struct WeatherLayer: View {
    let weather: WeatherNow
    /// 上面盖着整页（设置、侧栏里的页面）时停住，跟光晕背景一个口径。
    var paused = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frozen = paused || reduceMotion || scenePhase != .active
        ZStack {
            if weather.kind == .rain || weather.kind == .storm {
                RainOnGlass(level: weather.kind == .storm ? 2 : weather.level, frozen: frozen)
                    .transition(.opacity)
            }
            if weather.kind == .snow {
                SnowFall(level: weather.level, frozen: frozen)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.8), value: weather.kind)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 两个特效共用的小随机数：同一组 (seed, salt) 永远给同一个 0..<1，
/// 所以每一帧都能从「现在几点」直接算出每颗雨点、每片雪花在哪，不用存任何状态。
private func unitRandom(_ seed: Int, _ salt: Int) -> Double {
    var v = UInt64(bitPattern: Int64(seed &* 31 &+ salt)) &* 0x9E37_79B9_7F4A_7C15
    v ^= v >> 33
    v &*= 0xC2B2_AE3D_27D4_EB4F
    v ^= v >> 29
    return Double(v & 0xFF_FFFF) / Double(0x100_0000)
}

// MARK: - 雨点打在玻璃上

/// 不是满屏斜线的雨——是玻璃窗这一侧的水：小水珠停在玻璃上慢慢聚大、淡去，
/// 时不时一颗聚重了，顺着玻璃往下滑出一道由小水珠组成的痕。
private struct RainOnGlass: View {
    /// 0 小雨、1 中雨、2 大雨：珠子更密、滑得更勤。
    let level: Int
    let frozen: Bool
    @Environment(\.colorScheme) private var scheme

    private var dropCount: Int { [30, 46, 64][level] }
    private var runnerGap: Double { [7.0, 4.2, 2.4][level] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: frozen)) { timeline in
            // 静止（减弱动态效果）时画在固定的一刻：有雨意，但一动不动。
            let t = frozen ? 1234.5 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 360_000)
            Canvas { context, size in
                draw(&context, size: size, t: t, dark: scheme == .dark)
            }
        }
        .drawingGroup()
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, t: Double, dark: Bool) {
        // 停在玻璃上的珠子：各有各的节拍，长出来、鼓一点、再淡掉，换个地方重来。
        for index in 0..<dropCount {
            let period = 16 + 18 * unitRandom(index, 1)
            let shifted = t + 1000 * unitRandom(index, 2)
            let cycle = Int(shifted / period)
            let phase = (shifted - Double(cycle) * period) / period
            let x = unitRandom(index &+ cycle &* 977, 3) * size.width
            let y = unitRandom(index &+ cycle &* 977, 4) * size.height
            let base = 2.2 + 3.4 * unitRandom(index &+ cycle &* 977, 5)
            let grown = base * (1 + 0.7 * min(1, phase * 2.5))
            // 前 8% 淡入，后 25% 淡出。
            let alpha = min(1, phase / 0.08) * min(1, (1 - phase) / 0.25)
            guard alpha > 0.02 else { continue }
            drawDrop(&context, x: x, y: y, radius: grown, alpha: alpha, dark: dark)
        }

        // 往下滑的那几道：一次只活一两道，滑过的路上留下一串小珠，慢慢干掉。
        let duration = 3.4
        let current = Int(t / runnerGap)
        for k in (current - 2)...current {
            let begin = Double(k) * runnerGap + runnerGap * 0.6 * unitRandom(k, 11)
            let progress = (t - begin) / duration
            guard progress > 0, progress < 1.6 else { continue }
            let x0 = (0.06 + 0.88 * unitRandom(k, 12)) * size.width
            let wobble = 5 + 4 * unitRandom(k, 13)
            func point(_ p: Double) -> CGPoint {
                CGPoint(x: x0 + wobble * sin(p * 9 + Double(k)),
                        // 越滑越快，像真的水。
                        y: (pow(p, 1.5) * 1.1 - 0.05) * size.height)
            }
            // 身后的痕：按滑过的时间淡。
            var trail = 0.0
            while trail < min(progress, 1) {
                let age = (progress - trail) * duration
                let alpha = max(0, 0.9 - age * 0.38)
                if alpha > 0.03 {
                    let spot = point(trail)
                    let radius = 1.1 + 1.3 * unitRandom(k &+ Int(trail * 97), 14)
                    drawDrop(&context, x: spot.x, y: spot.y, radius: radius, alpha: alpha, dark: dark)
                }
                trail += 0.055
            }
            // 滑着的珠子本体：比停着的大，微微拉长。
            if progress < 1 {
                let head = point(progress)
                var drop = context
                drop.translateBy(x: head.x, y: head.y)
                drop.scaleBy(x: 1, y: 1.35)
                drawDrop(&drop, x: 0, y: 0, radius: 3.2, alpha: 1, dark: dark)
            }
        }
    }

    /// 一颗水珠：边缘深、中心几乎透明（光从水珠边上折过去），左上一点高光。
    /// 画成实心圆就成灰尘了。
    private func drawDrop(_ context: inout GraphicsContext, x: Double, y: Double,
                          radius: Double, alpha: Double, dark: Bool) {
        let edge = dark ? Color.white : Color(red: 0.35, green: 0.39, blue: 0.49)
        let stops: [Gradient.Stop] = [
            .init(color: edge.opacity(0), location: 0),
            .init(color: edge.opacity(dark ? 0.13 : 0.2), location: 0.8),
            .init(color: edge.opacity(dark ? 0.34 : 0.52), location: 1),
        ]
        let bounds = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        context.opacity = alpha
        context.fill(Path(ellipseIn: bounds),
                     with: .radialGradient(Gradient(stops: stops),
                                           center: CGPoint(x: x, y: y),
                                           startRadius: radius * 0.45, endRadius: radius))
        let shine = radius * 0.26
        context.fill(Path(ellipseIn: CGRect(x: x - radius * 0.38 - shine,
                                            y: y - radius * 0.38 - shine,
                                            width: shine * 2, height: shine * 2)),
                     with: .color(.white.opacity(dark ? 0.5 : 0.85)))
        context.opacity = 1
    }
}

// MARK: - 落雪

/// 两层雪花慢慢飘下来：远的一层小、糊、慢，近的一层大、清楚、快一点，偶尔左右摇。
private struct SnowFall: View {
    let level: Int
    let frozen: Bool
    @Environment(\.colorScheme) private var scheme

    private var farCount: Int { [20, 30, 44][level] }
    private var nearCount: Int { [12, 18, 28][level] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: frozen)) { timeline in
            let t = frozen ? 1234.5 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 360_000)
            Canvas { context, size in
                let dark = scheme == .dark
                var far = context
                far.addFilter(.blur(radius: 1.4))
                drawFlakes(&far, size: size, t: t, count: farCount, seedSalt: 100,
                           radius: 1.6...2.6, speed: 11...19, alpha: dark ? 0.5 : 0.7, dark: dark)
                drawFlakes(&context, size: size, t: t, count: nearCount, seedSalt: 200,
                           radius: 2.8...4.6, speed: 24...40, alpha: dark ? 0.9 : 1.0, dark: dark)
            }
        }
        .drawingGroup()
    }

    private func drawFlakes(_ context: inout GraphicsContext, size: CGSize, t: Double,
                            count: Int, seedSalt: Int, radius: ClosedRange<Double>,
                            speed: ClosedRange<Double>, alpha: Double, dark: Bool) {
        // 底色是浅粉白的，纯白雪花看不见：浅色时垫一圈冷灰的柔影。
        if !dark {
            context.addFilter(.shadow(color: Color(red: 0.46, green: 0.53, blue: 0.66),
                                      radius: 2.5))
        }
        for index in 0..<count {
            let seed = index &+ seedSalt
            let r = radius.lowerBound + (radius.upperBound - radius.lowerBound) * unitRandom(seed, 21)
            let v = speed.lowerBound + (speed.upperBound - speed.lowerBound) * unitRandom(seed, 22)
            let sway = 10 + 18 * unitRandom(seed, 23)
            let phase = unitRandom(seed, 24) * 2 * .pi
            let x = unitRandom(seed, 25) * size.width
                + sway * sin(t * (0.35 + 0.3 * unitRandom(seed, 26)) + phase)
            let fall = (unitRandom(seed, 27) * (size.height + 24) + t * v)
                .truncatingRemainder(dividingBy: size.height + 24) - 12
            let bounds = CGRect(x: x - r, y: fall - r, width: r * 2, height: r * 2)
            context.opacity = alpha
            context.fill(Path(ellipseIn: bounds), with: .color(.white))
            context.opacity = 1
        }
    }
}
