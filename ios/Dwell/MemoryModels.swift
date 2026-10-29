import Foundation

/// 记忆卡的词表。顺序跟后端（app/main.py 的 MEMORY_CARD_*）一致，界面按这个顺序列；
/// 显示用的中文名以后端发来的 taxonomy 为准，这里只是兜底。
struct MemoryChoice: Identifiable, Hashable {
    let key: String
    let label: String
    var id: String { key }
    init(_ key: String, _ label: String) { self.key = key; self.label = label }
}

enum MemoryTaxonomy {
    static let types: [MemoryChoice] = [
        .init("stable_fact", "稳定事实"), .init("preference", "偏好"), .init("recent_event", "近期事件"),
        .init("open_thread", "进行中事项"), .init("plan", "计划"), .init("quote", "原话"),
    ]
    static let topics: [MemoryChoice] = [
        .init("identity", "身份信息"), .init("personality", "性格与习惯"), .init("about_me", "关于我"),
        .init("daily_life", "日常生活"), .init("place", "地点"), .init("food", "饮食"), .init("books", "书与阅读"),
        .init("work_creativity", "工作与创作"), .init("schedule", "日程"), .init("relationship", "关系与互动"),
        .init("health_safety", "健康与安全"), .init("entertainment", "娱乐"), .init("family_friends", "人际关系"),
        .init("nsfw", "亲密内容"), .init("other", "其他"),
    ]
    static let importance: [MemoryChoice] = [.init("high", "固定保留"), .init("normal", "普通"), .init("low", "可淡出")]
    static let retention: [MemoryChoice] = [
        .init("long_term", "长期有效"), .init("time_bound", "截至某日"), .init("fading", "可随时间淡出"),
    ]
    /// 搜索框左边那个筛选。
    static let filters: [MemoryChoice] = [
        .init("all", "全部"), .init("active", "可被挑选"), .init("hidden", "已隐藏"), .init("high", "固定保留"), .init("archived", "已归档"),
    ]
}

/// 后端发来的 taxonomy：{types:{key:label}, topics:{...}, ...}
struct MemoryLabels {
    var types: [String: String] = [:]
    var topics: [String: String] = [:]
    var importance: [String: String] = [:]
    var retention: [String: String] = [:]

    init(json: [String: Any]? = nil) {
        types = json?["types"] as? [String: String] ?? [:]
        topics = json?["topics"] as? [String: String] ?? [:]
        importance = json?["importance"] as? [String: String] ?? [:]
        retention = json?["retention"] as? [String: String] ?? [:]
    }

    private static func lookup(_ key: String, _ table: [String: String], _ fallback: [MemoryChoice]) -> String {
        table[key] ?? fallback.first { $0.key == key }?.label ?? key
    }
    func type(_ key: String) -> String { Self.lookup(key, types, MemoryTaxonomy.types) }
    func topic(_ key: String) -> String { Self.lookup(key, topics, MemoryTaxonomy.topics) }
    func importance(_ key: String) -> String { Self.lookup(key, importance, MemoryTaxonomy.importance) }
    func retention(_ key: String) -> String { Self.lookup(key, retention, MemoryTaxonomy.retention) }
}

/// 主卡时间线上的一步。
struct TimelineNode: Identifiable, Equatable {
    let id = UUID()
    var date: String
    var text: String

    /// 「10月13日」；不是今年的带上年份。
    var label: String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return "" }
        let year = Calendar.current.component(.year, from: Date())
        return (parts[0] == year ? "" : "\(parts[0])年") + "\(parts[1])月\(parts[2])日"
    }

    static func == (a: TimelineNode, b: TimelineNode) -> Bool { a.date == b.date && a.text == b.text }
}

/// 一张记忆卡，或者一条待确认（两者字段几乎一样，待确认多了 action / target_card_id）。
struct MemoryCard: Identifiable, Equatable {
    let id: String
    /// 卡真正归哪间聊天。互通开着时列的是整个公共池，编辑、归档要发给这间。
    let chatID: String
    let chatName: String
    var content: String
    var memoryType: String
    var topics: [String]
    var importance: String
    var retention: String
    var validUntil: String?
    var status: String
    let undated: Bool
    let sourceStart: Int
    let sourceEnd: Int
    let sourceRowids: [Int]
    let sharedFrom: String?
    let sharedCount: Int
    /// 属于哪件事（「追音音」）；同一件事的主卡和细节卡挂同一个名字。空＝不属于哪件持续的事。
    var thread: String
    /// 在这件事里的身份：main（主卡，一件事只有一张）/ detail（副卡）/ 空（不属于任何事件）。
    var threadRole: String
    /// 主卡的时间线：一个节点是某一天这件事往前走的一步，按日子排。别的卡是空的。
    var timeline: [TimelineNode]
    /// 「给主卡加一步」那条待确认：这一步发生在哪天。
    let nodeDate: String
    /// 待确认专用：create / update（重新分类）/ split（拆分）/ replace（更新旧卡）/ revise（补全）
    let action: String
    let targetCardID: String?
    let updated: Date
    /// card（记忆卡）或 bookmark（她在聊天里圈的几句原话）。
    let kind: String
    /// 书签：模型写的「这段在讲什么」，她可以改；还在写的时候 labelState 是 pending。
    let label: String
    let labelState: String
    /// 书签：她写的「为什么记」。
    let why: String
    /// 书签：圈起来的原话（副本）。
    let lines: [BookmarkLine]

    init(json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        chatID = json["chat_id"] as? String ?? ""
        chatName = json["chat_name"] as? String ?? ""
        content = json["content"] as? String ?? ""
        memoryType = json["memory_type"] as? String ?? "stable_fact"
        topics = json["topics"] as? [String] ?? []
        importance = json["importance"] as? String ?? "normal"
        retention = json["retention"] as? String ?? "long_term"
        validUntil = (json["valid_until"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        status = json["status"] as? String ?? "active"
        undated = (json["undated"] as? Int ?? 0) != 0 || (json["undated"] as? Bool ?? false)
        sourceStart = json["source_start_rowid"] as? Int ?? 0
        sourceEnd = json["source_end_rowid"] as? Int ?? 0
        sourceRowids = json["source_rowids"] as? [Int] ?? []
        sharedFrom = (json["shared_from"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        sharedCount = json["shared_count"] as? Int ?? 0
        thread = json["thread"] as? String ?? ""
        threadRole = json["thread_role"] as? String ?? ""
        timeline = (json["timeline"] as? [[String: Any]] ?? []).map {
            TimelineNode(date: $0["date"] as? String ?? "", text: $0["text"] as? String ?? "")
        }
        nodeDate = json["node_date"] as? String ?? ""
        action = json["action"] as? String ?? "create"
        targetCardID = json["target_card_id"] as? String
        updated = Date(timeIntervalSince1970: TimeInterval(json["updated"] as? Int ?? json["made"] as? Int ?? 0))
        kind = json["kind"] as? String ?? "card"
        label = json["label"] as? String ?? ""
        labelState = json["label_state"] as? String ?? ""
        why = json["why"] as? String ?? ""
        lines = (json["lines"] as? [[String: Any]] ?? []).map(BookmarkLine.init(json:))
    }

    var isBookmark: Bool { kind == "bookmark" }

    var isHidden: Bool { status == "hidden" }
    var isMain: Bool { !thread.isEmpty && threadRole == "main" }
    var isArchived: Bool { status == "archived" }
    var hasSource: Bool { sourceEnd > 0 }

    /// 跟网页的 memorySource 一样的说法。
    var sourceLabel: String {
        if undated { return "手动添加" }
        if sourceStart == 0 && sourceEnd == 0 { return "来自摘要分段" }
        return "看原文"
    }

    /// 提交给后端的那几个字段。
    var payload: [String: Any] {
        [
            "content": content, "memory_type": memoryType, "topics": topics,
            "importance": importance, "retention": retention,
            "valid_until": retention == "time_bound" ? (validUntil ?? "") : "",
            "thread": thread.trimmingCharacters(in: .whitespacesAndNewlines),
            "thread_role": thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : threadRole,
        ]
    }

    /// 新卡的默认值，跟网页添加表单一样。
    static func blank(chatID: String) -> MemoryCard {
        MemoryCard(json: [
            "id": "new", "chat_id": chatID, "content": "", "memory_type": "stable_fact",
            "topics": [String](), "importance": "normal", "retention": "long_term", "undated": 1,
        ])
    }
}

struct MemoryCardState {
    var status = "idle"
    var error = ""
    var note = ""
    var draftCount = 0
    var cardCount = 0

    init(json: [String: Any]? = nil) {
        status = json?["status"] as? String ?? "idle"
        error = json?["error"] as? String ?? ""
        note = json?["note"] as? String ?? ""
        draftCount = json?["draft_count"] as? Int ?? 0
        cardCount = json?["card_count"] as? Int ?? 0
    }

    var isBusy: Bool { status == "queued" || status == "running" }
}

/// 摘要那一页。
struct MemorySummary {
    var status = "idle"
    var error = ""
    var overview = ""
    var generatedAt = 0
    var messageCount = 0
    var segmentCount = 0
    var tailMessages = 80
    var hasDraft = false
    var draftOverview = ""
    /// 互通开着、模型实际读的是别的窗口的公共摘要时，显示那份。
    var sharedOverview = ""
    var sharedFrom = ""
    /// 正式摘要的历史：每次被生成的新版、手动编辑或换回旧版替掉之前，都留一份。
    var versions: [Version] = []

    struct Version: Identifiable {
        let id: String
        let overview: String
        let reason: String
        let made: Int
    }

    init(json: [String: Any]? = nil) {
        status = json?["status"] as? String ?? "idle"
        error = json?["error"] as? String ?? ""
        overview = json?["overview"] as? String ?? ""
        generatedAt = json?["generated_at"] as? Int ?? 0
        messageCount = json?["message_count"] as? Int ?? 0
        segmentCount = json?["segment_count"] as? Int ?? 0
        tailMessages = json?["tail_messages"] as? Int ?? 80
        hasDraft = json?["has_draft"] as? Bool ?? false
        draftOverview = json?["draft_overview"] as? String ?? ""
        let shared = json?["shared_overview"] as? [String: Any] ?? [:]
        sharedOverview = shared["overview"] as? String ?? ""
        sharedFrom = shared["chat_name"] as? String ?? ""
        versions = (json?["versions"] as? [[String: Any]] ?? []).map {
            Version(id: $0["id"] as? String ?? UUID().uuidString, overview: $0["overview"] as? String ?? "",
                    reason: $0["reason"] as? String ?? "", made: $0["made"] as? Int ?? 0)
        }
    }

    var isBusy: Bool { status == "queued" || status == "running" }
}

/// 设置页里能选的模型。
struct MemoryModelChoice: Identifiable, Hashable {
    let providerID: String
    let modelID: String
    let providerName: String
    let favorite: Bool
    var id: String { providerID + "\u{1}" + modelID }

    init(json: [String: Any]) {
        providerID = json["provider_id"] as? String ?? ""
        modelID = json["model_id"] as? String ?? ""
        providerName = json["provider_name"] as? String ?? ""
        favorite = (json["favorite"] as? Int ?? 0) != 0 || (json["favorite"] as? Bool ?? false)
    }
}

struct MemoryModelSetting {
    var providerID = ""
    var modelID = ""
    var providerName = ""
    var items: [MemoryModelChoice] = []

    init(json: [String: Any]? = nil) {
        providerID = json?["provider_id"] as? String ?? ""
        modelID = json?["model_id"] as? String ?? ""
        providerName = json?["provider_name"] as? String ?? ""
        items = (json?["items"] as? [[String: Any]] ?? []).map(MemoryModelChoice.init(json:))
    }

    var label: String {
        modelID.isEmpty ? "未选择" : (providerName.isEmpty ? modelID : "\(providerName) · \(modelID)")
    }
}

/// 「看原文」里的一条消息。
struct MemorySourceMessage: Identifiable {
    let id: Int
    let role: String
    let content: String
    let made: Date
    let cited: Bool

    init(json: [String: Any]) {
        id = json["rowid"] as? Int ?? 0
        role = json["role"] as? String ?? ""
        content = json["content"] as? String ?? ""
        made = Date(timeIntervalSince1970: TimeInterval(json["made"] as? Int ?? 0))
        cited = json["cited"] as? Bool ?? false
    }
}

struct MemoryInjection {
    var usedAt = Date()
    var items: [MemoryCard] = []

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        items = (json["items"] as? [[String: Any]] ?? []).map(MemoryCard.init(json:))
        if items.isEmpty { return nil }
        usedAt = Date(timeIntervalSince1970: TimeInterval(json["used_at"] as? Int ?? 0))
    }
}

/// 书签里的一句原话：谁说的、什么时候、说了什么，还记着是哪条消息。
struct BookmarkLine: Identifiable, Equatable {
    let messageID: String
    let role: String
    let content: String
    let made: Date
    var id: String { messageID }

    init(json: [String: Any]) {
        messageID = json["message_id"] as? String ?? UUID().uuidString
        role = json["role"] as? String ?? "user"
        content = json["content"] as? String ?? ""
        made = Date(timeIntervalSince1970: TimeInterval(json["made"] as? Int ?? 0))
    }
}
