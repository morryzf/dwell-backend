import SwiftUI
import UIKit

/// 网页版的那套皮。数值都是从网页的计算样式里量出来的（iPhone 宽度、默认主题），
/// 半透明 + 毛玻璃的地方折算成了叠在底色上的实色，看起来一样，滚动时也不费电。
enum Theme {
    // 纸和墨
    static let background = Color(light: 0xFCF9FA, dark: 0x393538)
    static let text = Color(light: 0x575156, dark: 0xFFF9FB)
    static let bubbleText = Color(light: 0x514A4F, dark: 0xF7EDF2)
    static let dim = Color(light: 0x948A91, dark: 0xD1C3C9)

    // 气泡：两边同一种，粉一点的毛玻璃
    static let bubble = Color(light: 0xF9F1F4, dark: 0x473C42)
    static let bubbleBorder = Color(light: .clear, dark: Color(red: 242/255, green: 201/255, blue: 220/255).opacity(0.18))
    static let bubbleShadow = Color(red: 72/255, green: 54/255, blue: 64/255).opacity(0.075)

    // thinking / 工具的小胶囊
    static let chip = Color(light: 0xF8EEF2, dark: 0x42393E)
    static let chipText = Color(light: 0x60585E, dark: 0xEFE4E9)
    static let chipBorder = Color(light: Color.white.opacity(0.27), dark: Color(red: 242/255, green: 201/255, blue: 220/255).opacity(0.13))

    // 顶栏和输入框
    static let header = Color(light: 0xFFFDFD, dark: 0x4A4448)
    static let headerShadow = Color(red: 87/255, green: 68/255, blue: 76/255).opacity(0.06)
    static let composer = Color(light: 0xFEFBFC, dark: 0x4D464B)
    static let composerBorder = Color(light: .clear, dark: Color(red: 1, green: 235/255, blue: 244/255).opacity(0.2))
    static let composerShadow = Color(light: Color(red: 86/255, green: 58/255, blue: 71/255).opacity(0.07),
                                      dark: Color.black.opacity(0.19))
    static let roundButton = Color(light: Color.white.opacity(0.25), dark: Color(red: 1, green: 235/255, blue: 244/255).opacity(0.12))
    // 输入框那排按钮的玻璃边：0.5 的细边，左上和右下各一道高光（网页的 --rim-*）。
    static let rimBase = Color(light: Color(red: 150/255, green: 110/255, blue: 128/255).opacity(0.2),
                               dark: Color(red: 1, green: 235/255, blue: 244/255).opacity(0.13))
    static let rimHi = Color(light: Color.white.opacity(0.8), dark: Color(red: 1, green: 240/255, blue: 247/255).opacity(0.54))
    static let rimLo = Color(light: Color.white.opacity(0.75), dark: Color(red: 1, green: 240/255, blue: 247/255).opacity(0.5))

    // 有身份的颜色：标题两边的花、发送键
    static let accent = Color(light: 0xD9A7B7, dark: 0xD9A7B7)
    static let send = Color(light: 0xDEAABD, dark: 0xA88699)
    static let sendShadow = Color(light: Color(red: 181/255, green: 111/255, blue: 136/255).opacity(0.22),
                                  dark: Color.black.opacity(0.25))

    /// 气泡里的字：14.5pt，行高 1.55。
    static let bubbleFont = Font.system(size: 14.5)
    static let bubbleLineSpacing: CGFloat = 5
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(light: Color(hex: light), dark: Color(hex: dark))
    }

    init(light: Color, dark: Color) {
        let lightUI = UIColor(light)
        let darkUI = UIColor(dark)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkUI : lightUI })
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 网页的底：浅色是方格纸（14pt 的点 + 32pt 的粉格线），深色是稀一点的点阵加顶上一团粉光。
struct PaperBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            if scheme == .dark {
                drawDark(context, size)
            } else {
                drawLight(context, size)
            }
        }
        .background(Theme.background)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func drawLight(_ context: GraphicsContext, _ size: CGSize) {
        let line = Color(red: 217/255, green: 167/255, blue: 183/255).opacity(0.1)
        var grid = Path()
        var x: CGFloat = 0
        while x <= size.width {
            grid.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
            x += 32
        }
        var y: CGFloat = 0
        while y <= size.height {
            grid.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
            y += 32
        }
        context.fill(grid, with: .color(line))
        drawDots(context, size, step: 14, color: Color(red: 148/255, green: 138/255, blue: 145/255).opacity(0.2))
    }

    private func drawDark(_ context: GraphicsContext, _ size: CGSize) {
        let glowCenter = CGPoint(x: size.width / 2, y: -size.height * 0.18)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [Color(red: 231/255, green: 167/255, blue: 191/255).opacity(0.09), .clear]),
                center: glowCenter, startRadius: 0, endRadius: max(size.width, size.height) * 0.58
            )
        )
        drawDots(context, size, step: 19, color: Color(red: 238/255, green: 209/255, blue: 220/255).opacity(0.18))
    }

    private func drawDots(_ context: GraphicsContext, _ size: CGSize, step: CGFloat, color: Color) {
        var dots = Path()
        var y: CGFloat = 1
        while y <= size.height {
            var x: CGFloat = 1
            while x <= size.width {
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                x += step
            }
            y += step
        }
        context.fill(dots, with: .color(color))
    }
}

/// 网页上那种圆形小按钮。开着的时候（on）图标变粉，外面一圈淡粉的细边。
struct RoundIcon: View {
    let systemName: String
    var size: CGFloat = 32
    var on = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(on ? Theme.accent : Theme.text)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.roundButton))
            .glassRim(Circle())
            .overlay(Circle().stroke(Theme.accent.opacity(on ? 0.42 : 0), lineWidth: 1))
            .shadow(color: Theme.composerShadow, radius: 9, y: 6)
    }
}

extension View {
    /// 网页 .ctlrow 按钮的那圈玻璃边。浅色模式下白按钮落在白输入框上，全靠它看出轮廓。
    func glassRim<S: InsettableShape>(_ shape: S) -> some View {
        self
            .overlay(shape.strokeBorder(Theme.rimBase, lineWidth: 0.5))
            .overlay(shape.strokeBorder(LinearGradient(stops: [
                .init(color: Theme.rimHi, location: 0), .init(color: .clear, location: 0.3),
                .init(color: .clear, location: 0.64), .init(color: Theme.rimLo, location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
    }
}
