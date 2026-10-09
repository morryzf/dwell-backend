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
