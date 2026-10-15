import AVFoundation
import Foundation
import SwiftUI

/// 这间聊天在用的模型。/api/model 读写。
struct ChatModelState {
    var providerID = ""
    var modelID = ""
    var effort = "high"
    var showThinking = true
    var promptCacheTTL = "off"

    init(json: [String: Any]? = nil) {
        providerID = json?["provider_id"] as? String ?? ""
        modelID = json?["model"] as? String ?? ""
        effort = json?["effort"] as? String ?? "high"
        showThinking = json?["show_thinking"] as? Bool ?? true
        promptCacheTTL = json?["prompt_cache_ttl"] as? String ?? "off"
    }

    /// 胶囊上的名字。跟网页的 displayName 一个念法：
    /// claude-opus-4-8 → Opus 4.8，gpt-5.6-sol → 5.6 Sol，认不出来就原样。
    var displayName: String { Self.displayName(modelID) }

    static func displayName(_ raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespaces)
        if id.isEmpty { return "…" }
        let leaf = (id.split(separator: "/").last.map(String.init) ?? id)
        let slug = leaf.replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1-$2", options: .regularExpression)
        let oneM = slug.hasSuffix("[1m]")
        if let match = slug.firstMatch(of: #/(?:^|claude-)(fable|opus|sonnet|haiku)-(\d+)(?:-(\d+))?/#) {
            let family = String(match.1).prefix(1).uppercased() + String(match.1).dropFirst()
            var name = "\(family) \(match.2)"
            if let minor = match.3, minor.count <= 2 { name += ".\(minor)" }
            return oneM ? name + " · 1M" : name
        }
        // 中转加的 [J3按量] 这类前缀不要。
        let bare = leaf.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        if let match = bare.firstMatch(of: #/^(?i:gpt)-(\d+(?:\.\d+)?[a-zA-Z]?)(?:-(.+))?$/#) {
            var words = [String(match.1).lowercased()]
            if let tail = match.2 {
                let trimmed = String(tail).replacingOccurrences(
                    of: #"-?(?:\d{4}-\d{2}-\d{2}|\d{8})$"#, with: "", options: .regularExpression)
                words += trimmed.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            }
            return words.joined(separator: " ")
        }
        return id
    }

    struct Effort: Identifiable {
        let id: String
        let name: String
        let desc: String
    }

    static let efforts: [Effort] = [
        Effort(id: "low", name: "Low", desc: "Quick replies to simple questions"),
        Effort(id: "medium", name: "Medium", desc: "Light, casual tasks"),
        Effort(id: "high", name: "High", desc: "Balanced for everyday work"),
        Effort(id: "xhigh", name: "Extra", desc: "Complex, detailed work"),
        Effort(id: "max", name: "Max", desc: "The hardest problems. Takes longest."),
    ]

    var effortName: String { Self.efforts.first { $0.id == effort }?.name ?? "High" }
}

extension ChatStore {
    /// 换了聊天、回到前台时重读一遍输入框那一排的状态。
    func loadControls() async {
        guard !chatID.isEmpty else { return }
        let base = "api/chats/\(chatID)"
        if let json = try? await API.shared.request("GET", "\(base)/voice-mode") {
            voiceMode = json["enabled"] as? Bool ?? false
        }
        if let json = try? await API.shared.request("GET", "\(base)/reply-language") {
            replyLanguage = json["language"] as? String ?? "auto"
        }
        if let json = try? await API.shared.request("GET", "api/model") {
            model = ChatModelState(json: json)
        }
        await refreshInstructionCount()
        await refreshTools()
    }

    func refreshInstructionCount() async {
        guard let json = try? await API.shared.request("GET", "api/instructions/chat") else { return }
        instructionCount = (json["items"] as? [[String: Any]] ?? []).filter { $0["selected"] as? Bool == true }.count
    }

    func refreshTools() async {
        guard let json = try? await API.shared.request("GET", "api/mcp/chat") else { return }
        let count = (json["items"] as? [[String: Any]] ?? []).filter { $0["selected"] as? Bool == true }.count
        toolsEnabled = (json["home_todos_enabled"] as? Bool ?? false) || count > 0
    }

    func setVoiceMode(_ on: Bool) async {
        guard !chatID.isEmpty else { return }
        voiceMode = on   // 先亮，手感即时；失败再退回去
        flash(on ? "语音回复已开启，接下来会用语音回你" : "语音回复已关闭")
        do {
            let json = try await API.shared.request("PUT", "api/chats/\(chatID)/voice-mode", body: ["enabled": on])
            voiceMode = json["enabled"] as? Bool ?? on
        } catch {
            voiceMode = !on
            flash("语音开关没切换：" + error.localizedDescription)
        }
    }

    func setReplyLanguage(_ language: String) async {
        guard !chatID.isEmpty, language != replyLanguage else { return }
        let previous = replyLanguage
        replyLanguage = language
        do {
            let json = try await API.shared.request("PUT", "api/chats/\(chatID)/reply-language", body: ["language": language])
            replyLanguage = json["language"] as? String ?? language
            // 存好了才说：看到这句再发，就不会赶在开关生效之前。
            let name = ["zh": "中文", "en": "English"][replyLanguage]
            flash(name.map { "回复语言已切到\($0)，接下来都用它回你" } ?? "回复语言已改回自动")
        } catch {
            replyLanguage = previous
            flash("回复语言没切换：" + error.localizedDescription)
        }
    }

    /// 改模型设置（模型、用力档、thinking、缓存），返回改完的状态。
    @discardableResult
    func saveModel(_ body: [String: Any]) async -> Bool {
        do {
            let json = try await API.shared.request("POST", "api/model", body: body)
            if let id = json["model"] as? String { model.modelID = id }
            if let id = json["provider_id"] as? String { model.providerID = id }
            if let effort = json["effort"] as? String { model.effort = effort }
            if let show = json["show_thinking"] as? Bool { model.showThinking = show }
            if let ttl = json["prompt_cache_ttl"] as? String { model.promptCacheTTL = ttl }
            return true
        } catch {
            flash("没存上：" + error.localizedDescription)
            return false
        }
    }

    /// 输入框上方那行小字说一句，几秒后自己消失。
    func flash(_ text: String) {
        status = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if status == text { status = "" }
        }
    }
}

/// 语音回复的播放器。全局只有一个声音在响。
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    enum State: Equatable { case idle, loading, playing, paused, error(String) }

    @Published private(set) var currentID: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    /// 播过的语音的真实时长，语音条显示用。
    @Published private(set) var durations: [String: TimeInterval] = [:]
    /// 浮在输入框上面的那个播放器在放哪条；播完也留着，点叉才收起。
    @Published private(set) var panelID: String?
    @Published private(set) var rate: Float = 1
    static let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var cache: [String: Data] = [:]

    func state(for id: String) -> State { currentID == id ? state : .idle }

    /// 气泡下面点「朗读」：弹出播放器并开始放；正在放（或还在准备）这条时再点一下就停。
    func readAloud(_ id: String) {
        if currentID == id {
            close()
            return
        }
        panelID = id
        Task { await play(id) }
    }

    func close() {
        stop()
        panelID = nil
    }

    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        player?.rate = rate
    }

    func seek(_ fraction: Double) {
        guard let player, player.duration > 0 else { return }
        player.currentTime = fraction * player.duration
        elapsed = player.currentTime
        progress = fraction
    }

    func toggle(_ id: String) {
        if currentID == id, player == nil {
            // 还在生成语音：再点一下就是不要了。
            stop()
            return
        }
        if currentID == id, let player {
            if player.isPlaying {
                player.pause()
                state = .paused
                stopTicker()
            } else {
                player.play()
                state = .playing
                startTicker()
            }
            return
        }
        Task { await play(id) }
    }

    func play(_ id: String) async {
        stop()
        currentID = id
        state = .loading
        do {
            let data: Data
            if let hit = cache[id] {
                data = hit
            } else {
                data = try await API.shared.data("api/tts/messages/\(id)")
                cache[id] = data
            }
            guard currentID == id else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            self.player = player
            durations[id] = player.duration
            player.play()
            state = .playing
            startTicker()
        } catch {
            guard currentID == id else { return }
            state = .error(error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        stopTicker()
        currentID = nil
        state = .idle
        progress = 0
        elapsed = 0
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.elapsed = player.currentTime
                self.progress = player.currentTime / player.duration
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTicker()
            self.progress = 0
            self.elapsed = 0
            self.state = .idle
            self.currentID = nil
            self.player = nil
        }
    }
}

/// 点「朗读」后浮在输入框上面的播放器（照网页的 #ttsPlayer）：谁的声音、现在在干什么、
/// 暂停继续、进度可拖、倍速、叉掉。播完不自己消失，想再听一遍点播放就行。
struct VoicePlayerPanel: View {
    @ObservedObject private var voice = VoicePlayer.shared
    let name: String

    var body: some View {
        if let id = voice.panelID {
            let state = voice.state(for: id)
            let duration = voice.durations[id] ?? 0
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button { voice.toggle(id) } label: {
                        Group {
                            if state == .loading {
                                ProgressView().tint(Theme.accent)
                            } else {
                                Image(systemName: state == .playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                    }
                    .accessibilityLabel(state == .playing ? "暂停" : "播放")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(status(state)).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { voice.cycleRate() } label: {
                        Text(rateLabel)
                            .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .frame(minWidth: 40, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("播放速度")
                    Button { voice.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.dim)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭播放器")
                }
                HStack(spacing: 8) {
                    Text(clock(voice.currentID == id ? voice.elapsed : 0))
                    Slider(value: Binding(get: { voice.currentID == id ? voice.progress : 0 },
                                          set: { voice.seek($0) }))
                        .tint(Theme.accent)
                        .disabled(voice.currentID != id || state == .loading)
                    Text(clock(duration))
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(GlassBackground(surface: .composer, shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var rateLabel: String {
        let r = voice.rate
        return (r == r.rounded() ? String(Int(r)) : String(format: "%g", r)) + "×"
    }

    private func status(_ state: VoicePlayer.State) -> String {
        switch state {
        case .loading: return "正在生成或读取语音…"
        case .playing: return "正在朗读这一条"
        case .paused: return "已暂停"
        case .error(let message): return "没能播放：" + message
        case .idle: return "播放完成"
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
