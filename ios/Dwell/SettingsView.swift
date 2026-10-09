import SwiftUI

/// 设置，照网页的 #settingsSheet 排：账号一组，「家」一组。
/// 网页里只对浏览器有意义的（隐藏 Clawd）没搬；多了一组「这台手机」放日夜模式和退出登录。
struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = Appearance.shared

    @State private var alive = "看看…"
    @State private var ttsStatus = ""
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    row("person", "用户", value: API.shared.baseURL?.host ?? "本机")
                }
                Section("家") {
                    Button {
                        Task { await checkAlive() }
                    } label: {
                        row("waveform.path.ecg", "后端在跑吗", value: alive)
                    }
                    NavigationLink {
                        BackgroundSettings()
                    } label: {
                        row("photo", "聊天背景", value: appearance.background(store.assistant?.id ?? "cloudy") == nil ? "默认" : "已设置")
                    }
                    NavigationLink {
                        GlassSettings()
                    } label: {
                        row("slider.horizontal.3", "玻璃效果", value: "消息")
                    }
                    NavigationLink {
                        TTSSettings()
                    } label: {
                        row("speaker.wave.2", "语音服务", value: ttsStatus)
                    }
                    NavigationLink {
                        ProvidersPage()
                    } label: {
                        row("bolt", "模型供应商")
                    }
                    NavigationLink {
                        MCPServersPage()
                    } label: {
                        row("wrench", "MCP 工具")
                    }
                    NavigationLink {
                        InstructionManager {}
                    } label: {
                        row("square.3.layers.3d", "聊天指令")
                    }
                    NavigationLink {
                        RewriteRulesPage()
                    } label: {
                        row("arrow.clockwise", "重写规则")
                    }
                    NavigationLink {
                        SystemLogPage()
                    } label: {
                        row("doc.text", "系统日志")
                    }
                    NavigationLink {
                        KelivoImportPage()
                    } label: {
                        row("plus", "导入 Kelivo 聊天记录")
                    }
                }
                Section("这台手机") {
                    Picker(selection: $appearance.theme) {
                        Text("跟随系统").tag("auto")
                        Text("日间").tag("light")
                        Text("夜间").tag("dark")
                    } label: {
                        Label("日夜", systemImage: "circle.lefthalf.filled")
                    }
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                Section {
                } footer: {
                    Text("Dwell iOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .frame(maxWidth: .infinity)
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .tint(Theme.text)
            .task {
                await checkAlive()
                await loadTTSStatus()
            }
            .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    dismiss()
                    Task { await store.logout() }
                }
            }
        }
    }

    private func row(_ icon: String, _ title: String, value: String = "") -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 24)
            Text(title)
            Spacer()
            if !value.isEmpty {
                Text(value).foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
        .foregroundStyle(Theme.text)
    }

    private func checkAlive() async {
        alive = "看看…"
        let started = Date()
        do {
            let json = try await API.shared.request("GET", "api/health")
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            alive = (json["ok"] as? Bool) == true ? "在跑 · \(ms)ms" : "不太对"
        } catch {
            alive = "连不上"
        }
    }

    private func loadTTSStatus() async {
        guard let json = try? await API.shared.request("GET", "api/tts/config") else { return }
        let hasKey = json["has_key"] as? Bool ?? false
        let voices = json["voices"] as? [[String: Any]] ?? []
        ttsStatus = !hasKey ? "未设置" : (voices.isEmpty ? "还没有音色" : "已连接")
    }
}
