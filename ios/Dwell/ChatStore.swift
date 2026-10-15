import Foundation
import SwiftUI

/// 聊天页的全部状态。实时部分走后端的 /api/poll 长轮询，跟网页同一套事件：
/// - echo：自己刚发的那条落库了
/// - stream_event：回复一个字一个字地来（text_delta）
/// - assistant_split：开了分条时，一段说完了
/// - assistant_reset：这次回复作废重来（比如答错语言被打回）
/// - system/regenerating：某条回复要重新生成，先把旧的几条撤掉
/// - result：这一轮结束。这时以数据库为准把整页重拉一次，前面拼出来的都只是临时的。
@MainActor
final class ChatStore: ObservableObject {
    enum Phase { case checking, needsLogin, ready }

    @Published var phase: Phase = .checking
    @Published var assistant: AssistantInfo?
    /// 当前这间聊天的名字，顶栏标题用；没起名时显示助手的名字（跟网页一样）。
    @Published var chatName = ""
    /// 记忆面板里有几条新的待确认（三个点上那颗粉点）。
    @Published var memoryUnseen = 0
    /// 按需记忆开没开（菜单里那个开关）。
    @Published var memoryInjection = false

    // 输入框那一排按钮的状态，都按聊天存在服务器上（见 ChatControls.swift）。
    @Published var voiceMode = false
    @Published var replyLanguage = "auto"
    @Published var instructionCount = 0
    @Published var toolsEnabled = false
    @Published var model = ChatModelState()
    /// 刚说完、该自动念一遍的那条语音回复。
    /// 点通知进来要直接打开的侧栏页面（比如书房），聊天页看到就打开。
    @Published var openPage: String?
    @Published var autoplayVoiceID: String?
    @Published var messages: [Message] = []
    /// 我刚发出去的那条：浮上来一下。
    @Published private(set) var entering: Set<String> = []

    /// 正在打的这段里已经说完的几句（后面空了一行的）。像人发消息：凑够一个气泡才冒出来，
    /// 最后那句还在打，就先只给三个点。
    var streamParagraphs: [String] { Array(Self.paragraphs(streamingText).dropLast()) }

    // MARK: 一个一个冒

    /// 他的气泡一次只冒一个，两个之间至少隔这么久。回得快的时候几句一起到，也排着队一句一句出来。
    static let revealGap: TimeInterval = 1.5
    /// 他的消息还没冒完的：id → 已经露出几个气泡。不在这里的就是全露了。
    @Published private(set) var shown: [String: Int] = [:]
    /// 正在打的这段里已经露出的几句。
    @Published private(set) var streamShown = 0
    /// 每冒一个就加一，聊天页跟着滚到底。
    @Published private(set) var revealTick = 0
    private var revealTask: Task<Void, Never>?
    private var lastReveal = Date.distantPast

    /// 正在打的这段里露出来的那几句。
    var streamVisible: [String] { Array(streamParagraphs.prefix(streamShown)) }
    /// 还有气泡排着队没冒出来：三个点要一直在。
    var revealing: Bool { !shown.isEmpty || streamShown < streamParagraphs.count }
    /// 正在流进来、还没说完的那一段。
    @Published var streamingText = ""
    /// 正在流进来的思考过程。
    @Published var streamingThinking = ""
    /// 更早还有没有消息；有的话顶上显示「更早的消息」。
    @Published var hasMore = false
    @Published var loadingOlder = false
    @Published var isReplying = false
    /// 输入框上方那一行小字：在用工具、出错了之类。正常时为空。
    @Published var status = ""

    private let api = API.shared
    private var pollTask: Task<Void, Never>?
    private var polledChatID = ""
    /// messages 现在装的是哪间聊天的。
    private var loadedChatID = ""

    var chatID: String { assistant?.chatID ?? "" }

    // MARK: - 进门

    func start() async {
        guard api.baseURL != nil else { phase = .needsLogin; return }
        if await api.isAuthed() {
            phase = .ready
            await refresh()
        } else {
            phase = .needsLogin
        }
    }

    func login(server: String, user: String, password: String) async throws {
        guard let url = API.normalize(server) else {
            throw APIError(status: 0, message: "服务器地址看起来不对")
        }
        api.baseURL = url
        try await api.login(user: user, password: password)
        phase = .ready
        await refresh()
    }

    func logout() async {
        stopPolling()
        await api.logout()
        messages = []
        loadedChatID = ""
        assistant = nil
        phase = .needsLogin
    }

    // MARK: - 拉数据

    /// 回到前台、切换聊天之后都走这里：问一次后端现在是哪间，再整页重拉。
    /// 网页那边可能在这期间切过聊天，所以不能只信自己记着的 chatID。
    func refresh() async {
        do {
            assistant = try await api.assistant()
            try await reloadMessages()
            startPolling()
            await syncReplying()
            chatName = (try? await api.chats())?.first { $0.id == chatID }?.name ?? ""
            await refreshMemoryBadge()
            await loadControls()
        } catch {
            handle(error)
        }
    }

    /// 重拉最近一页。之前往上翻出来的更早消息留着，不然一轮回复结束，翻好的历史就没了。
    func reloadMessages() async throws {
        guard !chatID.isEmpty else { return }
        let chat = chatID
        let page = try await api.messages(chatID: chat)
        guard chat == chatID else { return }
        let fresh = page.msgs.filter { !$0.isEmpty }
        // rowid 是全库共用的，换了聊天就不能留旧的。
        var older: [Message] = []
        if loadedChatID == chat, let firstSeq = page.msgs.first?.seq {
            older = messages.filter { $0.seq > 0 && $0.seq < firstSeq }
        }
        if older.isEmpty { hasMore = page.more }
        // 同一间聊天里多出来的（比如他主动发的），算刚到的；换聊天、第一次打开就不演了。
        if loadedChatID == chat {
            let known = Set(messages.map(\.id))
            hold(fresh.filter { !known.contains($0.id) && $0.kind == .gu }, carried: streamShown)
        } else {
            shown = [:]
        }
        loadedChatID = chat
        messages = older + fresh
        let ids = Set(messages.map(\.id))
        shown = shown.filter { ids.contains($0.key) }
        streamingText = ""
        streamingThinking = ""
        streamShown = 0
        pump()
    }

    private func markEntering(_ id: String) {
        entering.insert(id)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            entering.remove(id)
        }
    }

    /// 新到的他的消息先藏起来，排队冒。carried：第一条是刚才正在打的那段，打字时已经露出的几句接着露着。
    private func hold(_ fresh: [Message], carried: Int) {
        guard !voiceMode else { return }
        for (index, message) in fresh.enumerated() where !message.voice {
            let visible = index == 0 ? carried : 0
            if visible < message.bubbles.count { shown[message.id] = visible }
        }
    }

    /// 有排队的就一个一个放出来，每个之间隔 revealGap。
    private func pump() {
        guard revealTask == nil, revealing else { return }
        revealTask = Task { [weak self] in
            while let store = self, store.revealing, !Task.isCancelled {
                let wait = store.lastReveal.addingTimeInterval(Self.revealGap).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                self?.revealOne()
            }
            self?.revealTask = nil
        }
    }

    private func revealOne() {
        withAnimation(.spring(duration: 0.42, bounce: 0.18)) {
            // 先把已经存好的消息冒完，再轮到正在打的这段。
            if let message = messages.first(where: { shown[$0.id] != nil }), let count = shown[message.id] {
                shown[message.id] = count + 1 >= message.bubbles.count ? nil : count + 1
            } else if streamShown < streamParagraphs.count {
                streamShown += 1
            } else {
                return
            }
            lastReveal = Date()
            revealTick += 1
        }
    }

    /// 报错、提示这种一行字：过一会儿自己消失，不用等下一条消息才把它冲掉。
    private var statusClear: Task<Void, Never>?

    private func flash(_ text: String, for seconds: Double = 4) {
        status = text
        statusClear?.cancel()
        statusClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, self?.status == text else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.status = "" }
        }
    }

    func refreshMemoryBadge() async {
        guard let json = try? await api.request("GET", "api/memory/badge") else { return }
        memoryUnseen = json["unseen"] as? Int ?? 0
        memoryInjection = json["injection_enabled"] as? Bool ?? false
    }

    func setMemoryInjection(_ on: Bool) async {
        guard !chatID.isEmpty else { return }
        do {
            let json = try await api.request("PUT", "api/chats/\(chatID)/memory-cards/injection", body: ["enabled": on])
            memoryInjection = json["enabled"] as? Bool ?? on
        } catch { handle(error) }
    }

    func loadOlder() async {
        guard hasMore, !loadingOlder, !chatID.isEmpty,
              let oldest = messages.first(where: { $0.seq > 0 })?.seq else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let chat = chatID
            let page = try await api.messages(chatID: chat, limit: 100, before: oldest)
            guard chat == chatID else { return }
            messages = page.msgs.filter { !$0.isEmpty } + messages
            hasMore = page.more
        } catch { handle(error) }
    }

    // MARK: - 发消息

    func send(_ raw: String, images: [PendingImage] = [], files: [PendingFile] = []) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty, !chatID.isEmpty else { return }
        // 先在本地放一条，echo 回来再换成真的。
        let shown = text.isEmpty && images.isEmpty
            ? "（发来了文件：" + files.map(\.name).joined(separator: "、") + "）" : text
        let localID = "local-\(UUID().uuidString)"
        messages.append(Message(id: localID, kind: .me, text: shown, images: images.map(\.previewDataURL)))
        markEntering(localID)
        isReplying = true
        status = ""
        do {
            try await api.send(text: text, chatID: chatID, images: images, files: files,
                               voice: voiceMode, replyLanguage: replyLanguage)
        } catch {
            isReplying = false
            messages.removeAll { $0.isLocal }
            handle(error)
        }
    }

    func regenerate(_ message: Message) async {
        do {
            try await api.regenerate(message.id)
            isReplying = true
        } catch { handle(error) }
    }

    func edit(_ message: Message, to content: String) async {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != message.text else { return }
        do {
            try await api.editMessage(message.id, content: text)
            replaceText(message.id, with: text)
        } catch { handle(error) }
    }

    /// 改完只在原地换掉那一条的字，不整页重读——重读会把往上翻过的记录丢掉，屏幕就跳走了。
    private func replaceText(_ id: String, with text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var message = messages[index]
        message.text = text
        // 原来是分条显示的，按空行重新切一次（跟后端一样的规则）。
        if !message.segments.isEmpty { message.segments = Self.paragraphs(text) }
        messages[index] = message
    }

    /// 一整轮回复：他一次说的话可能拆成了好几条消息（中途分条）。
    /// 先按 tts_turn_id 认；老消息没有的话，就取前后挨着的那几条他的消息。
    func turn(of message: Message) -> [Message] {
        guard message.kind == .gu, let index = messages.firstIndex(where: { $0.id == message.id }) else { return [message] }
        let id = message.usage.turnID
        if !id.isEmpty {
            let same = messages.filter { $0.kind == .gu && $0.usage.turnID == id && !$0.isLocal }
            if same.count > 1 { return same }
        }
        var start = index, end = index
        while start > 0, messages[start - 1].kind == .gu { start -= 1 }
        while end + 1 < messages.count, messages[end + 1].kind == .gu { end += 1 }
        return Array(messages[start...end]).filter { !$0.isLocal }
    }

    /// 改一整轮回复。编辑框里每条消息之间空一行；
    /// 段数跟原来对得上就各改各的，对不上就把全文放进这一轮的最后一条（用量记在它身上），前面几条删掉。
    func editTurn(_ parts: [Message], to content: String) async {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let last = parts.last else { return }
        if parts.count == 1 { return await edit(last, to: text) }
        let chunks = Self.paragraphs(text)
        let counts = parts.map { Self.paragraphs($0.text).count }
        do {
            if chunks.count == counts.reduce(0, +) {
                var cursor = 0
                for (part, count) in zip(parts, counts) {
                    let piece = chunks[cursor..<(cursor + count)].joined(separator: "\n\n")
                    cursor += count
                    if piece != part.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                        try await api.editMessage(part.id, content: piece)
                        replaceText(part.id, with: piece)
                    }
                }
            } else {
                try await api.editMessage(last.id, content: text)
                replaceText(last.id, with: text)
                for part in parts.dropLast() {
                    try await api.deleteMessage(part.id)
                    messages.removeAll { $0.id == part.id }
                }
            }
        } catch { handle(error) }
    }

    private static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 搜索里点开一条

    /// 聊天页看到它就滚过去，然后清掉。
    @Published var jumpTarget: String?

    /// 切到那一间，往上翻到那句为止（最多翻十几页），再让聊天页把它滚到正中。
    func open(chat chatID: String, message messageID: String) async {
        if chatID != self.chatID { await switchChat(chatID) }
        var tries = 0
        while !messages.contains(where: { $0.id == messageID }) && hasMore && tries < 15 {
            await loadOlder()
            tries += 1
        }
        if messages.contains(where: { $0.id == messageID }) { jumpTarget = messageID }
    }

    /// 多选删除：跟网页一样一次发过去。
    func bulkDelete(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await api.request("POST", "api/messages/bulk-delete", body: ["ids": ids])
            let gone = Set(ids)
            messages.removeAll { gone.contains($0.id) }
        } catch { handle(error) }
    }

    func delete(_ message: Message) async {
        do {
            try await api.deleteMessage(message.id)
            messages.removeAll { $0.id == message.id }
        } catch { handle(error) }
    }

    func stop() async {
        try? await api.stop()
    }

    func switchChat(_ id: String) async {
        do {
            try await api.switchChat(id)
            await refresh()
        } catch { handle(error) }
    }

    /// dwell://open?chat=… ——Bark 通知点开时带来的那一间。还没登录好就等一会儿。
    func openLink(_ url: URL) async {
        guard url.scheme == "dwell" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let chat = items.first { $0.name == "chat" }?.value ?? ""
        for _ in 0..<40 where phase != .ready {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if items.contains(where: { $0.name == "study" }) {
            openPage = "Library"
            return
        }
        guard phase == .ready, !chat.isEmpty, chat != chatID else { return }
        await switchChat(chat)
    }

    func newChat() async {
        do {
            try await api.newChat()
            await refresh()
        } catch { handle(error) }
    }

    func switchAssistant(_ id: String) async {
        do {
            // 切换接口的返回里没有「都有哪几位」，切完走一遍 refresh 拿全的。
            _ = try await api.switchAssistant(id)
            await refresh()
        } catch { handle(error) }
    }

    // MARK: - 长轮询

    func startPolling() {
        guard !chatID.isEmpty else { return }
        if pollTask != nil, polledChatID == chatID { return }
        stopPolling()
        let chat = chatID
        polledChatID = chat
        pollTask = Task { [weak self] in
            // 很大的游标 = 从现在开始，不重放旧事件。
            var cursor = 1_000_000_000
            while !Task.isCancelled {
                do {
                    let (next, events) = try await API.shared.poll(chatID: chat, since: cursor)
                    cursor = next
                    for event in events { await self?.apply(event) }
                    // 等了一整轮都没动静、却还显示着「在回」：多半是收尾那一下漏了，问一次后端。
                    if events.isEmpty, self?.isReplying == true { await self?.syncReplying() }
                } catch {
                    if Task.isCancelled { break }
                    if let apiError = error as? APIError, apiError.isUnauthorized {
                        await self?.handle(apiError)
                        break
                    }
                    // 网络抖一下很正常（进电梯、切 Wi-Fi），歇两秒接着等。
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// 回复收尾的那个事件只在长轮询里发一次。app 在后台时轮询是断的，回来再从「现在」接着听，
    /// 那一下就错过了：三个点一直在、发送键一直是「生成中」。所以回到前台、或者久等没动静时，
    /// 直接问后端这间聊天还在不在回。
    func syncReplying() async {
        guard let json = try? await api.request("GET", "api/status") else { return }
        let busy = json["busy"] as? Bool ?? false
        if busy {
            isReplying = true
        } else if isReplying {
            isReplying = false
            status = ""
            try? await reloadMessages()
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        polledChatID = ""
    }

    private func apply(_ event: [String: Any]) async {
        switch event["type"] as? String {
        case "echo":
            messages.removeAll { $0.isLocal }
            let id = event["message_id"] as? String ?? UUID().uuidString
            if !messages.contains(where: { $0.id == id }) {
                let at = Date(timeIntervalSince1970: TimeInterval(event["at"] as? Int ?? 0))
                messages.append(Message(id: id, kind: .me, text: event["text"] as? String ?? "",
                                        images: event["images"] as? [String] ?? [], at: at))
            }
            isReplying = true

        case "stream_event":
            let delta = (event["event"] as? [String: Any])?["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                streamingText += delta?["text"] as? String ?? ""
                status = ""
                pump()
            case "thinking_delta":
                streamingThinking += delta?["thinking"] as? String ?? ""
            default:
                break
            }
            isReplying = true

        case "assistant_split":
            let text = event["text"] as? String ?? streamingText
            let id = event["message_id"] as? String ?? UUID().uuidString
            if !text.isEmpty, !messages.contains(where: { $0.id == id }) {
                // 打字时已经冒出来的那几句接着露着，剩下的排队冒。
                let message = Message(id: id, kind: .gu, text: text)
                hold([message], carried: streamShown)
                messages.append(message)
            }
            streamingText = ""
            streamingThinking = ""
            streamShown = 0
            pump()

        case "system" where (event["subtype"] as? String) == "voice_reply":
            autoplayVoiceID = event["message_id"] as? String

        case "system" where (event["subtype"] as? String) == "regenerating":
            let ids = Set((event["message_ids"] as? [String] ?? []) + [event["message_id"] as? String ?? ""])
            messages.removeAll { ids.contains($0.id) }
            streamingText = ""
            streamShown = 0
            streamingThinking = ""
            isReplying = true

        case "assistant_reset":
            streamingText = ""
            streamShown = 0

        case "tool_call":
            let tool = event["tool"] as? [String: Any]
            let name = tool?["name"] as? String ?? ""
            status = name.isEmpty ? "在用工具…" : "在用 \(name)…"

        case "result":
            isReplying = false
            if (event["is_error"] as? Bool) == true { flash("这次回复出错了", for: 6) } else { status = "" }
            try? await reloadMessages()

        default:
            break
        }
    }

    private func handle(_ error: Error) {
        if let apiError = error as? APIError, apiError.isUnauthorized {
            stopPolling()
            phase = .needsLogin
            return
        }
        flash(error.localizedDescription)
    }
}
