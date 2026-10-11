import SwiftUI
import UIKit

/// 界面玻璃：照网页「玻璃效果」里「界面」那一块（applyInterfaceGlass）。
/// 输入框、左侧边栏、整页弹窗各有一个不透明度和一个模糊强度，浅色深色各一套，只存在这台手机上。
struct GlassValue: Codable, Equatable {
    var opacity: Double
    var blur: Double
}

enum GlassSurface: String, CaseIterable, Identifiable {
    case composer, drawer, pageSheet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .composer: return "输入框"
        case .drawer: return "左侧边栏"
        case .pageSheet: return "整页弹窗"
        }
    }

    /// 网页 INTERFACE_GLASS_DEFAULTS。
    func defaults(_ mode: String) -> GlassValue {
        switch (self, mode) {
        case (.composer, "dark"): return GlassValue(opacity: 58, blur: 34)
        case (.composer, _): return GlassValue(opacity: 47, blur: 34)
        case (.drawer, "dark"): return GlassValue(opacity: 60, blur: 10)
        case (.drawer, _): return GlassValue(opacity: 51, blur: 10)
        case (.pageSheet, "dark"): return GlassValue(opacity: 56, blur: 36)
        case (.pageSheet, _): return GlassValue(opacity: 39, blur: 36)
        }
    }

    /// 玻璃的底色（再乘上不透明度），也是网页的那几个 rgb。
    var tint: Color {
        switch self {
        case .composer, .pageSheet:
            return Color(light: Color(red: 1, green: 253/255, blue: 254/255),
                         dark: self == .composer ? Color(red: 92/255, green: 82/255, blue: 89/255)
                                                 : Color(red: 80/255, green: 72/255, blue: 78/255))
        case .drawer:
            return Color(light: Color(red: 247/255, green: 236/255, blue: 241/255),
                         dark: Color(red: 68/255, green: 61/255, blue: 66/255))
        }
    }
}

extension Appearance {
    func glass(_ surface: GlassSurface, _ mode: String) -> GlassValue {
        interfaceGlass[mode]?[surface.rawValue] ?? surface.defaults(mode)
    }

    func setGlass(_ value: GlassValue, _ surface: GlassSurface, _ mode: String) {
        var all = interfaceGlass
        all[mode, default: [:]][surface.rawValue] = GlassValue(opacity: min(100, max(0, value.opacity.rounded())),
                                                              blur: min(40, max(0, value.blur.rounded())))
        interfaceGlass = all
    }

    func resetGlass(_ surface: GlassSurface, _ mode: String) {
        var all = interfaceGlass
        all[mode]?[surface.rawValue] = nil
        interfaceGlass = all
    }
}

/// 一块按设置走的玻璃：后面的东西先模糊，再盖一层半透明的底色。
struct GlassBackground<S: Shape>: View {
    let surface: GlassSurface
    let shape: S
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let value = appearance.glass(surface, scheme == .dark ? "dark" : "light")
        ZStack {
            if value.blur > 0 { BackdropBlur(radius: value.blur).clipShape(shape) }
            shape.fill(surface.tint.opacity(value.opacity / 100))
        }
    }
}

/// 网页 backdrop-filter: blur(Npx) 的原生版：只模糊、不加系统毛玻璃那层白。
/// 用的是 UIKit 里可调半径的模糊；万一这台系统上没有，就退回系统的超薄材质。
struct BackdropBlur: UIViewRepresentable {
    let radius: Double

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: Self.effect(radius))
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        if context.coordinator.radius != radius {
            context.coordinator.radius = radius
            view.effect = Self.effect(radius)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(radius: radius) }

    final class Coordinator {
        var radius: Double
        init(radius: Double) { self.radius = radius }
    }

    private static func effect(_ radius: Double) -> UIVisualEffect {
        // 每个键都先问一句「你认不认」，系统哪天改了也只会退回材质，不会闪退。
        let keys = ["setBlurRadius:", "setScale:", "setColorTint:", "setColorTintAlpha:"]
        if let type = NSClassFromString("_UICustomBlurEffect") as? UIBlurEffect.Type,
           case let effect = type.init(),
           keys.allSatisfy({ effect.responds(to: NSSelectorFromString($0)) }) {
            effect.setValue(radius, forKey: "blurRadius")
            effect.setValue(1.0, forKey: "scale")
            effect.setValue(UIColor.clear, forKey: "colorTint")
            effect.setValue(0.0, forKey: "colorTintAlpha")
            return effect
        }
        return UIBlurEffect(style: .systemUltraThinMaterial)
    }
}

private struct OnGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var onGlass: Bool {
        get { self[OnGlassKey.self] }
        set { self[OnGlassKey.self] = newValue }
    }
}

extension View {
    /// 整页弹窗（设置、记忆、侧栏里的那几页）：弹窗本身是一块玻璃，里面的方格纸不再铺底色。
    func glassSheet() -> some View {
        self
            .environment(\.onGlass, true)
            .presentationBackground {
                GlassBackground(surface: .pageSheet, shape: Rectangle()).ignoresSafeArea()
            }
    }
}
