import SwiftUI

@main
struct DwellApp: App {
    @StateObject private var store = ChatStore()
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                // 日夜：跟随系统 / 常亮 / 常暗，侧边栏底部和设置里都能切。
                .preferredColorScheme(appearance.colorScheme)
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
