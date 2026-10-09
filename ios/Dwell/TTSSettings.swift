import AVFoundation
import SwiftUI

/// 「语音服务」：照网页的 #ttsSheet。两位助手各选各的音色和朗读方式；音色库和 ElevenLabs 连接两位共用。
struct TTSSettings: View {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let voiceID: String
        let previewURL: String

        init(json: [String: Any]) {
            id = json["id"] as? String ?? json["voice_id"] as? String ?? UUID().uuidString
            name = json["name"] as? String ?? ""
            voiceID = json["voice_id"] as? String ?? ""
            previewURL = json["preview_url"] as? String ?? ""
        }

        var payload: [String: Any] {
            ["id": id, "name": name, "voice_id": voiceID, "preview_url": previewURL]
        }
    }

    struct CatalogModel: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @EnvironmentObject private var store: ChatStore
    @State private var assistant = "cloudy"
    @State private var voices: [Voice] = []
    @State private var activeVoiceID = ""
    @State private var modelID = ""
    @State private var modelName = ""
    @State private var readMode = "plain"
    @State private var autoPlay = false
    @State private var hasKey = false
    @State private var name = "ElevenLabs"
    @State private var baseURL = "https://api.elevenlabs.io"
    @State private var token = ""
    @State private var models: [CatalogModel] = []
    @State private var catalogVoices: [Voice] = []
    @State private var showVoiceCatalog = false
    @State private var cacheText = ""
    @State private var message = ""
    @StateObject private var preview = PreviewPlayer()

    private var assistantName: String {
        store.assistant?.all.first { $0.id == assistant }?.name ?? (assistant == "chatgpt" ? "ChatGPT" : "Cloudy")
    }

    private var activeVoice: Voice? { voices.first { $0.id == activeVoiceID } }

    var body: some View {
        List {
            Section {
                Picker("助手", selection: $assistant) {
                    ForEach(store.assistant?.all ?? []) { item in Text(item.name).tag(item.id) }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                HStack(spacing: 14) {
                    Button {
                        if let voice = activeVoice { preview.toggle(voice.previewURL) }
                    } label: {
                        Image(systemName: preview.playingURL == activeVoice?.previewURL && preview.playingURL != nil
                              ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.dim)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.roundButton))
                    }
                    .buttonStyle(.plain)
                    .disabled(activeVoice?.previewURL.isEmpty ?? true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(assistantName) 的声音").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        Text(activeVoice?.name ?? "先在音色库里添加一个音色").font(.system(size: 16))
                        if activeVoice == nil {
                            Text("还没有选音色，语音回复先用不了了").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        }
                    }
                    .foregroundStyle(Theme.text)
                }
            }
            .listRowBackground(Theme.accent.opacity(0.22))

            Section("朗读") {
                if models.isEmpty {
                    HStack {
                        Text("语音模型")
                        Spacer()
                        Text(modelName.isEmpty ? modelID : modelName).foregroundStyle(Theme.dim)
                    }
                } else {
                    Picker("语音模型", selection: $modelID) {
                        ForEach(models) { model in Text(model.name).tag(model.id) }
                    }
                    .onChange(of: modelID) { _, id in
                        modelName = models.first { $0.id == id }?.name ?? id
                    }
                }
                Picker("朗读范围", selection: $readMode) {
                    Text("仅正体").tag("plain")
                    Text("含斜体").tag("plain_and_italic")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $autoPlay) {
                    VStack(alignment: .leading) {
                        Text("自动朗读")
                        Text("回复完就播").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                    }
                }
                .tint(Theme.send)
                Button("保存 \(assistantName) 的朗读设置") { Task { await saveProfile() } }
                    .font(.system(size: 15, weight: .semibold))
            }

            Section("音色库 · 两位共用") {
                ForEach(voices) { voice in
                    Button {
                        activeVoiceID = voice.id
                        Task { await saveProfile() }
                    } label: {
                        HStack {
                            Text(voice.name).foregroundStyle(Theme.text)
                            Spacer()
                            if voice.id == activeVoiceID {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .swipeActions {
                        Button("移除", role: .destructive) {
                            voices.removeAll { $0.id == voice.id }
                            Task { await saveVoices() }
                        }
                    }
                }
                Button {
                    Task { await loadCatalog() }
                    showVoiceCatalog = true
                } label: {
                    Label("从 ElevenLabs 添加音色", systemImage: "plus")
                        .foregroundStyle(Theme.send)
                }
                .disabled(!hasKey)
            }

            Section {
                TextField("名称", text: $name)
                SecureField(hasKey ? "API Key 已保存 · 不换就留空" : "输入 ElevenLabs API Key", text: $token)
                TextField("API 基址", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存连接") { Task { await saveConnection() } }
                    .font(.system(size: 15, weight: .semibold))
            } header: {
                HStack {
                    Text("连接 · 两位共用")
                    Spacer()
                    Text(hasKey ? "● 已连接" : "● 需要 API Key")
                        .foregroundStyle(hasKey ? MemoryStyle.sage : Theme.dim)
                }
            } footer: {
                Text("API Key 经服务器加密后保存，之后只能看到「已保存」。")
            }

            Section {
                HStack {
                    Text("语音缓存")
                    Spacer()
                    Text(cacheText).foregroundStyle(Theme.dim)
                }
                Button("清空缓存", role: .destructive) {
                    Task {
                        _ = try? await API.shared.request("DELETE", "api/tts/cache")
                        await loadCache()
                    }
                }
            } footer: {
                if !message.isEmpty { Text(message) }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("语音服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { assistant = store.assistant?.id ?? "cloudy" }
        .task(id: assistant) { await load() }
        .onDisappear { preview.stop() }
        .sheet(isPresented: $showVoiceCatalog) {
            VoiceCatalogSheet(voices: catalogVoices, have: Set(voices.map(\.voiceID)), preview: preview) { picked in
                voices.append(picked)
                Task { await saveVoices() }
            }
        }
    }

    // MARK: - 读写

    private func load() async {
        guard let json = try? await API.shared.request("GET", "api/tts/config", query: ["assistant": assistant]) else { return }
        voices = (json["voices"] as? [[String: Any]] ?? []).map(Voice.init(json:))
        activeVoiceID = json["active_voice_id"] as? String ?? ""
        modelID = json["model_id"] as? String ?? ""
        modelName = json["model_name"] as? String ?? modelID
        readMode = json["read_mode"] as? String ?? "plain"
        autoPlay = json["auto_play"] as? Bool ?? false
        hasKey = json["has_key"] as? Bool ?? false
        name = json["name"] as? String ?? "ElevenLabs"
        baseURL = json["base_url"] as? String ?? "https://api.elevenlabs.io"
        await loadCache()
        if hasKey && models.isEmpty { await loadCatalog() }
    }

    private func loadCatalog() async {
        guard let json = try? await API.shared.request("GET", "api/tts/catalog") else { return }
        models = (json["models"] as? [[String: Any]] ?? []).map {
            CatalogModel(id: $0["model_id"] as? String ?? "", name: $0["name"] as? String ?? "")
        }
        // 当前选的模型不在目录里（比如手填过）也要留着，不然 Picker 会是空的。
        if !modelID.isEmpty && !models.contains(where: { $0.id == modelID }) {
            models.insert(CatalogModel(id: modelID, name: modelName.isEmpty ? modelID : modelName), at: 0)
        }
        catalogVoices = (json["voices"] as? [[String: Any]] ?? []).map(Voice.init(json:))
    }

    private func loadCache() async {
        guard let json = try? await API.shared.request("GET", "api/tts/cache") else { return }
        let bytes = json["bytes"] as? Int ?? 0
        let files = json["files"] as? Int ?? 0
        cacheText = "\(files) 条 · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func post(_ body: [String: Any], done: String) async {
        do {
            var payload = body
            payload["assistant"] = assistant
            let json = try await API.shared.request("POST", "api/tts/config", body: payload)
            hasKey = json["has_key"] as? Bool ?? hasKey
            voices = (json["voices"] as? [[String: Any]] ?? []).map(Voice.init(json:))
            activeVoiceID = json["active_voice_id"] as? String ?? activeVoiceID
            message = done
        } catch {
            message = "没存上：" + error.localizedDescription
        }
    }

    private func saveProfile() async {
        await post([
            "active_voice_id": activeVoiceID, "model_id": modelID, "model_name": modelName,
            "read_mode": readMode, "auto_play": autoPlay,
        ], done: "\(assistantName) 的朗读设置存好了")
    }

    private func saveVoices() async {
        await post(["voices": voices.map(\.payload)], done: "音色库存好了")
    }

    private func saveConnection() async {
        var body: [String: Any] = ["name": name, "base_url": baseURL]
        let next = token.trimmingCharacters(in: .whitespaces)
        if !next.isEmpty { body["token"] = next }
        await post(body, done: "连接存好了")
        token = ""
        if hasKey { await loadCatalog() }
    }
}

/// 从 ElevenLabs 的音色目录里挑一个加进音色库，可以先试听。
private struct VoiceCatalogSheet: View {
    let voices: [TTSSettings.Voice]
    let have: Set<String>
    @ObservedObject var preview: PreviewPlayer
    let onPick: (TTSSettings.Voice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if voices.isEmpty {
                    Text("正在读取 ElevenLabs 的音色…").foregroundStyle(Theme.dim)
                }
                ForEach(voices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { voice in
                    HStack {
                        Button {
                            preview.toggle(voice.previewURL)
                        } label: {
                            Image(systemName: preview.playingURL == voice.previewURL ? "pause.fill" : "play.fill")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 30)
                        }
                        .buttonStyle(.borderless)
                        .disabled(voice.previewURL.isEmpty)
                        Text(voice.name).foregroundStyle(Theme.text)
                        Spacer()
                        if have.contains(voice.voiceID) {
                            Text("已添加").foregroundStyle(Theme.dim)
                        } else {
                            Button("添加") {
                                onPick(voice)
                                dismiss()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.send)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索音色")
            .modifier(SheetListStyle())
            .navigationTitle("从 ElevenLabs 添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .tint(Theme.text)
        }
    }
}

/// 试听 ElevenLabs 给的 preview_url（公开地址，直接流式播）。
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var playingURL: String?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ urlString: String) {
        if playingURL == urlString {
            stop()
            return
        }
        stop()
        guard let url = URL(string: urlString) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        self.player = player
        playingURL = urlString
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playingURL = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
