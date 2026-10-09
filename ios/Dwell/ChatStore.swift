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
    @Published var messages: [Message] = []
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
            chatName = (try? await api.chats())?.first { $0.id == chatID }?.name ?? ""
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
        loadedChatID = chat
        messages = older + fresh
        streamingText = ""
        streamingThinking = ""
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

    func send(_ raw: String, images: [PendingImage] = []) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty, !chatID.isEmpty else { return }
        // 先在本地放一条，echo 回来再换成真的。
        messages.append(Message(id: "local-\(UUID().uuidString)", kind: .me, text: text,
                                images: images.map(\.previewDataURL)))
        isReplying = true
        status = ""
        do {
            try await api.send(text: text, chatID: chatID, images: images)
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
            try await reloadMessages()
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
                messages.append(Message(id: id, kind: .gu, text: text))
            }
            streamingText = ""
            streamingThinking = ""

        case "system" where (event["subtype"] as? String) == "regenerating":
            let ids = Set((event["message_ids"] as? [String] ?? []) + [event["message_id"] as? String ?? ""])
            messages.removeAll { ids.contains($0.id) }
            streamingText = ""
            streamingThinking = ""
            isReplying = true

        case "assistant_reset":
            streamingText = ""

        case "tool_call":
            let tool = event["tool"] as? [String: Any]
            let name = tool?["name"] as? String ?? ""
            status = name.isEmpty ? "在用工具…" : "在用 \(name)…"

        case "result":
            isReplying = false
            status = (event["is_error"] as? Bool) == true ? "这次回复出错了" : ""
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
        status = error.localizedDescription
    }
}
