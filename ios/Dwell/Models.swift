import Foundation

/// 后端的 JSON 字段多而且一直在长，这里只取聊天页用得到的几个，其余的不管。
/// 用手写的 init(json:) 而不是 Codable：后端多一个字段、少一个字段都不会让整页解不出来。

struct AssistantInfo {
    let id: String
    let name: String
    let chatID: String
    let all: [AssistantChoice]

    init(json: [String: Any]) {
        id = json["assistant"] as? String ?? ""
        name = json["name"] as? String ?? ""
        chatID = json["chat_id"] as? String ?? ""
        all = (json["assistants"] as? [[String: Any]] ?? []).map {
            AssistantChoice(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "")
        }
    }
}

struct AssistantChoice: Identifiable {
    let id: String
    let name: String
}

struct ChatSummary: Identifiable {
    let id: String
    let name: String
    let preview: String
    let last: Date
    let current: Bool
    let archived: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        archived = json["archived"] as? Bool ?? false
        name = json["name"] as? String ?? ""
        preview = json["preview"] as? String ?? ""
        last = Date(timeIntervalSince1970: TimeInterval(json["last"] as? Int ?? 0))
        current = json["current"] as? Bool ?? false
    }

    var title: String { name.isEmpty ? "未命名" : name }
}

struct Message: Identifiable, Equatable {
    enum Kind { case me, gu, system }

    let id: String
    /// 数据库里的 rowid，往前翻页用。本地刚发、还没落库的是 0。
    let seq: Int
    let kind: Kind
    var text: String
    /// 开了「分条」的回复，后端已经切好了，每段一个气泡。
    var segments: [String]
    let at: Date
    let fromHeartbeat: Bool
    /// 缩略图的 data URL。
    var images: [String]
    var thinking: String
    /// 这次回复用过的工具名，只拿来显示一行小字。
    var tools: [String]
    /// 语音回复：画成语音条，文字默认收起。
    var voice: Bool
    /// 这一轮用了多少 token（只记在一轮回复的最后一条上）。
    var usage: MessageUsage
    /// 贴在这条上的一个表情：我的消息上是他贴的，他的消息上是我贴的。没有是空串。
    var reaction: String
    /// 我发这条时亲手挑的记忆卡。那一轮他只看到这几张。
    var memoryPicks: [MemoryPick]

    init(json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        seq = json["seq"] as? Int ?? 0
        switch json["kind"] as? String {
        case "me": kind = .me
        case "gu": kind = .gu
        default: kind = .system
        }
        text = json["text"] as? String ?? ""
        segments = json["segments"] as? [String] ?? []
        at = Date(timeIntervalSince1970: TimeInterval(json["at"] as? Int ?? 0))
        fromHeartbeat = (json["origin"] as? String) == "heartbeat"
        images = json["images"] as? [String] ?? []
        thinking = (json["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 贴表情也是一次工具调用，但它已经画在消息角上了，不再写进「用过的工具」。
        tools = (json["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            .filter { $0 != "React" }
        voice = json["voice"] as? Bool ?? false
        usage = MessageUsage(json: json["usage"] as? [String: Any] ?? [:])
        reaction = json["reaction"] as? String ?? ""
        memoryPicks = (json["memory_picks"] as? [[String: Any]] ?? []).map(MemoryPick.init(json:))
    }

    init(id: String, kind: Kind, text: String, images: [String] = [], at: Date = Date()) {
        self.id = id
        self.seq = 0
        self.kind = kind
        self.text = text
        self.segments = []
        self.at = at
        self.fromHeartbeat = false
        self.images = images
        self.thinking = ""
        self.tools = []
        self.voice = false
        self.usage = MessageUsage(json: [:])
        self.reaction = ""
        self.memoryPicks = []
    }

    var isLocal: Bool { id.hasPrefix("local-") }

    /// 画成几个气泡。
    var bubbles: [String] {
        // 只发了图时后端存的是这句占位，图本身已经画出来了，就不再重复。
        if !images.isEmpty && text == "（发来了一张图片）" { return [] }
        // 我的消息、他主动发来的消息：换一行就是一个新气泡（像一句一句按回车发的）。
        // 只是画法不同，存着的原文不变；带代码块的不拆，免得把代码切碎。
        let byLine = kind == .me || (fromHeartbeat && segments.isEmpty && !text.contains("```"))
        let parts = byLine ? text.components(separatedBy: "\n") : (segments.isEmpty ? [text] : segments)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 什么都没有的空占位（比如回复还没开始写的那条），不画。
    var isEmpty: Bool { bubbles.isEmpty && images.isEmpty }
}

/// 发消息时亲手挑的一张记忆卡，消息下面那行「带了几张记忆」点开看的就是这些。
struct MemoryPick: Identifiable, Equatable {
    let id: String
    let content: String
    let thread: String
    let isMain: Bool
    /// 这张卡后来删掉了。
    let missing: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        content = json["content"] as? String ?? ""
        thread = json["thread"] as? String ?? ""
        isMain = (json["thread_role"] as? String) == "main"
        missing = json["missing"] as? Bool ?? false
    }

    init(card: MemoryCard) {
        id = card.id
        content = card.content
        thread = card.thread
        isMain = card.isMain
        missing = false
    }
}

/// 网页气泡右下角那行「23,726 tokens」，点开是明细。
struct MessageUsage: Equatable {
    var input = 0
    var contextInput = 0
    var output = 0
    var total = 0
    var cached = 0
    var cacheWrite = 0
    var tokensPerSecond = 0.0
    var durationMS = 0
    var cacheCheckpoint = false
    /// 同一轮回复拆成好几条消息时，它们共用这个 id。
    var turnID = ""

    init(json: [String: Any]) {
        func int(_ key: String) -> Int { (json[key] as? NSNumber)?.intValue ?? 0 }
        input = int("input_tokens")
        contextInput = int("context_input_tokens")
        output = int("output_tokens")
        total = int("total_tokens")
        cached = int("cached_tokens")
        cacheWrite = int("cache_write_tokens")
        tokensPerSecond = (json["tokens_per_second"] as? NSNumber)?.doubleValue ?? 0
        durationMS = int("duration_ms")
        cacheCheckpoint = json["cache_checkpoint"] as? Bool ?? false
        turnID = json["tts_turn_id"] as? String ?? ""
    }

    /// 跟网页一样：上下文（没缓存的 + 读缓存 + 写缓存）加上输出。
    var shown: Int {
        let context = contextInput > 0 ? contextInput : input + cached + cacheWrite
        let sum = context + output
        return sum > 0 ? sum : total
    }
}
