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
        .init("health_safety", "健康与安全"), .init("entertainment", "娱乐"), .init("family_friends", "家人与朋友"),
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
    /// 待确认专用：create / update（重新分类）/ split（拆分）
    let action: String
    let targetCardID: String?
    let updated: Date

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
        action = json["action"] as? String ?? "create"
        targetCardID = json["target_card_id"] as? String
        updated = Date(timeIntervalSince1970: TimeInterval(json["updated"] as? Int ?? json["made"] as? Int ?? 0))
    }

    var isHidden: Bool { status == "hidden" }
    var isArchived: Bool { status == "archived" }
    var hasSource: Bool { sourceEnd > 0 }

    /// 跟网页的 memorySource 一样的说法。
    var sourceLabel: String {
        if undated { return "来源：手动添加" }
        if sourceStart == 0 && sourceEnd == 0 { return "来源：已有摘要分段" }
        if !sourceRowids.isEmpty { return "来源：已标出原话" }
        return sourceStart == sourceEnd ? "来源：1 条原消息" : "来源：整段原文"
    }

    /// 提交给后端的那几个字段。
    var payload: [String: Any] {
        [
            "content": content, "memory_type": memoryType, "topics": topics,
            "importance": importance, "retention": retention,
            "valid_until": retention == "time_bound" ? (validUntil ?? "") : "",
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
