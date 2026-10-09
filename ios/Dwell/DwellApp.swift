import SwiftUI

@main
struct DwellApp: App {
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    // 切到后台时 iOS 会掐掉网络；回来时重新问一次现在在哪间、补上漏掉的消息。
                    switch phase {
                    case .active where store.phase == .ready:
                        Task { await store.refresh() }
                    case .background:
                        store.stopPolling()
                    default:
                        break
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        switch store.phase {
        case .checking:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        case .needsLogin:
            LoginView()
        case .ready:
            NavigationStack { ChatView() }
        }
    }
}

enum Theme {
    // 跟网页的配色对齐：--bg / --user-bubble / --accent。
    static let background = Color(light: 0xFAF9F5, dark: 0x262624)
    static let userBubble = Color(light: 0xF0EEE6, dark: 0x383836)
    static let dim = Color(light: 0x8A867C, dark: 0xA3A099)
    static let accent = Color(light: 0xD9A7B7, dark: 0xD9A7B7)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}
