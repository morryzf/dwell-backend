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

/// 网页 backdrop-filter: blur(Npx) 的原生版。
/// 之前试过 UIKit 里可调半径的那种模糊，在新系统上它不报错、但根本不模糊（只剩一层透明的色）。
/// 现在用系统的毛玻璃材质：半径越大换越厚的一档；很小的半径就把最薄那档调淡，模糊也跟着变弱。
struct BackdropBlur: View {
    let radius: Double

    var body: some View {
        if radius <= 0 {
            Color.clear
        } else if radius < 6 {
            Rectangle().fill(.ultraThinMaterial).opacity(radius / 6)
        } else if radius < 16 {
            Rectangle().fill(.ultraThinMaterial)
        } else if radius < 28 {
            Rectangle().fill(.thinMaterial)
        } else {
            Rectangle().fill(.regularMaterial)
        }
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
