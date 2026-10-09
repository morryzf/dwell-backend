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

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
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
        tools = (json["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
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
    }

    var isLocal: Bool { id.hasPrefix("local-") }

    /// 画成几个气泡。
    var bubbles: [String] {
        // 只发了图时后端存的是这句占位，图本身已经画出来了，就不再重复。
        if !images.isEmpty && text == "（发来了一张图片）" { return [] }
        let parts = segments.isEmpty ? [text] : segments
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 什么都没有的空占位（比如回复还没开始写的那条），不画。
    var isEmpty: Bool { bubbles.isEmpty && images.isEmpty }
}
