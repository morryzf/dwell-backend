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

/// 天气叠层：铺在聊天背景上、蕾丝和气泡下面。雪在这里画；
/// 雨不在这层——它是对背景做折射的 Metal shader（RainGlass），得贴在背景自己身上。
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

// MARK: - 雨打在玻璃上（Metal 折射）

/// 挂在聊天背景上的雨：每颗水珠里是被折射的壁纸——缩小、倒置、更亮，
/// 不是画上去的圈。思路来自 codrops/RainEffect，珠子全在 shader 里现场算。
/// 下雨下雷雨时才开 shader；天气换了用自己记的时间戳慢慢淡进淡出。
struct RainGlass: ViewModifier {
    let weather: WeatherNow
    var paused = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// 雨开始 / 停止的时刻：淡入淡出按它算，不靠 SwiftUI 的 transition（shader 不吃那个）。
    @State private var turned = Date.distantPast

    // 「雨的手感」四个滑杆（设置 → 聊天背景），默认 1。
    @AppStorage("rainDensity") private var tuneDensity = 1.0
    @AppStorage("rainSize") private var tuneSize = 1.0
    @AppStorage("rainRefract") private var tuneRefract = 1.0
    @AppStorage("rainShine") private var tuneShine = 1.0

    private var raining: Bool { weather.kind == .rain || weather.kind == .storm }
    private var level: Double { raining ? (weather.kind == .storm ? 2 : Double(weather.level)) : 0 }

    func body(content: Content) -> some View {
        let frozen = paused || reduceMotion || scenePhase != .active
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: frozen || !raining)) { timeline in
            let now = timeline.date
            let t = frozen ? 1234.5 : now.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 36_000)
            // 1.8 秒淡进来；停了淡出去。减弱动态效果时直接到位。
            let ramp = reduceMotion ? 1.0 : min(1, max(0, now.timeIntervalSince(turned) / 1.8))
            let fade = raining ? ramp : 1 - ramp
            content.layerEffect(
                ShaderLibrary.rainOnGlass(
                    .boundingRect,
                    .float(Float(t)),
                    .float(Float(level)),
                    .float(scheme == .dark ? 1 : 0),
                    .float(Float(fade)),
                    .float4(tuneDensity, tuneSize, tuneRefract, tuneShine)
                ),
                maxSampleOffset: CGSize(width: 120, height: 120),
                isEnabled: fade > 0.001
            )
        }
        .onChange(of: raining) { _, _ in turned = Date() }
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

// MARK: - 雨的手感

/// 「雨的手感」：四个滑杆直接喂给 shader，一格糊化给背景。只存在这台手机上。
/// 开着「大雨」预览调，回聊天页就能看出差别。
struct RainTuneView: View {
    @AppStorage("weatherPreview") private var weatherPreview = ""
    @AppStorage("rainDensity") private var density = 1.0
    @AppStorage("rainSize") private var size = 1.0
    @AppStorage("rainRefract") private var refract = 1.0
    @AppStorage("rainShine") private var shine = 1.0
    @AppStorage("rainBlur") private var blur = 3.0

    var body: some View {
        List {
            if weatherPreview.isEmpty {
                Section {
                    Button("先把预览开成「大雨」") { weatherPreview = "rain:heavy" }
                } footer: {
                    Text("不开预览的话，只有真下雨时才看得到调的结果。")
                }
            }
            Section("水珠") {
                row("密度", $density, 0.3...2.0, "多少颗")
                row("大小", $size, 0.5...1.8, "每颗有多大")
            }
            Section("光") {
                row("折射", $refract, 0.2...2.5, "透过水珠看到的背景扭多远")
                row("高光", $shine, 0.0...2.5, "珠子左上那一点亮")
                row("背景糊化", $blur, 0.0...8.0, "下雨时背景糊几档")
            }
            Section {
                Button("恢复默认") {
                    density = 1; size = 1; refract = 1; shine = 1; blur = 3
                }
            } footer: {
                Text("调完记得把预览换回「跟着真实天气」。这些只存在这台手机上。")
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("雨的手感")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.send)
    }

    private func row(_ name: String, _ value: Binding<Double>,
                     _ range: ClosedRange<Double>, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
            Slider(value: value, in: range)
            Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
        }
        .padding(.vertical, 2)
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
