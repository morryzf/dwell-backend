import Foundation
import SwiftUI

/// 记忆面板的状态。接口和网页的记忆控制台是同一套：
/// /api/chats/{id}/memory-cards（分页、搜索、筛选）、memory-card-drafts（待确认）、
/// long-context（摘要）、memory-shared / memory-cards/injection（两个开关）。
@MainActor
final class MemoryStore: ObservableObject {
    enum Tab: String, CaseIterable { case cards, review, summary, settings }

    let chatID: String
    private let api = API.shared
    private static let pageSize = 30

    @Published var tab: Tab = .cards
    @Published var labels = MemoryLabels()

    // 记忆卡
    @Published var cards: [MemoryCard] = []
    @Published var total = 0
    @Published var activeCount = 0
    @Published var archivedCount = 0
    @Published var query = ""
    @Published var filter = "all"
    @Published var topic = ""
    @Published var lastInjection: MemoryInjection?
    @Published var loadingCards = false

    // 待确认
    @Published var drafts: [MemoryCard] = []
    /// 重新分类 / 拆分建议对照的原卡。
    @Published var draftTargets: [String: MemoryCard] = [:]
    @Published var cardState = MemoryCardState()

    // 摘要和设置
    @Published var summary = MemorySummary()
    @Published var injectionEnabled = false
    @Published var sharedEnabled = false
    @Published var longContextModel = MemoryModelSetting()
    @Published var embeddingModel = MemoryModelSetting()

    /// 操作完给一句话（「已共享给 ChatGPT」「没有归档：……」）。
    @Published var toast = ""

    private var pollTask: Task<Void, Never>?

    init(chatID: String) {
        self.chatID = chatID
    }

    private var base: String { "api/chats/\(chatID)" }

    // MARK: - 拉数据

    func loadAll() async {
        await loadCards(reset: true)
        await loadSummary()
        await loadModels()
        _ = try? await api.request("POST", "api/memory/badge/seen", body: ["chat_id": chatID])
    }

    func loadCards(reset: Bool) async {
        if loadingCards { return }
        loadingCards = true
        defer { loadingCards = false }
        let offset = reset ? 0 : cards.count
        do {
            let json = try await api.request("GET", "\(base)/memory-cards", query: [
                "limit": String(Self.pageSize), "offset": String(offset),
                "q": query.trimmingCharacters(in: .whitespaces), "filter": filter, "topic": topic,
            ])
            let page = (json["items"] as? [[String: Any]] ?? []).map(MemoryCard.init(json:))
            cards = reset ? page : cards + page
            total = json["total"] as? Int ?? cards.count
            let counts = json["counts"] as? [String: Any] ?? [:]
            activeCount = counts["active"] as? Int ?? 0
            archivedCount = counts["archived"] as? Int ?? 0
            labels = MemoryLabels(json: json["taxonomy"] as? [String: Any])
            drafts = (json["drafts"] as? [[String: Any]] ?? []).map(MemoryCard.init(json:))
            let targets = (json["draft_targets"] as? [[String: Any]] ?? []).map(MemoryCard.init(json:))
            draftTargets = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            cardState = MemoryCardState(json: json["state"] as? [String: Any])
            injectionEnabled = json["injection_enabled"] as? Bool ?? false
            sharedEnabled = json["shared_enabled"] as? Bool ?? false
            lastInjection = MemoryInjection(json: json["last_injection"] as? [String: Any])
            pollIfBusy()
        } catch {
            say(error)
        }
    }

    var hasMoreCards: Bool { cards.count < total }

    func loadSummary() async {
        do {
            summary = MemorySummary(json: try await api.request("GET", "\(base)/long-context"))
            pollIfBusy()
        } catch { say(error) }
    }

    func loadModels() async {
        if let json = try? await api.request("GET", "api/long-context-model") {
            longContextModel = MemoryModelSetting(json: json)
        }
        if let json = try? await api.request("GET", "api/embedding-model") {
            embeddingModel = MemoryModelSetting(json: json)
        }
    }

    /// 后台在整理（生成草稿、拆卡、压缩摘要）时每隔几秒看一眼，整理完自动刷新。
    private func pollIfBusy() {
        guard cardState.isBusy || summary.isBusy, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                await self.refreshQuietly()
                if !(self.cardState.isBusy || self.summary.isBusy) { break }
            }
            self?.pollTask = nil
        }
    }

    /// 轮询用：只更新状态和列表，不再触发新的轮询。
    private func refreshQuietly() async {
        if let json = try? await api.request("GET", "\(base)/long-context") {
            summary = MemorySummary(json: json)
        }
        let wasBusy = cardState.isBusy
        if let json = try? await api.request("GET", "\(base)/memory-cards", query: ["limit": "1"]) {
            cardState = MemoryCardState(json: json["state"] as? [String: Any])
        }
        // 整理刚结束：整页重拉，新出的待确认才看得见。
        if wasBusy && !cardState.isBusy {
            await loadCards(reset: true)
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 记忆卡

    func add(_ card: MemoryCard) async -> Bool {
        do {
            _ = try await api.request("POST", "\(base)/memory-cards", body: card.payload)
            await loadCards(reset: true)
            return true
        } catch { say(error); return false }
    }

    func save(_ card: MemoryCard) async -> Bool {
        do {
            _ = try await api.request("PUT", "api/chats/\(card.chatID)/memory-cards/\(card.id)", body: card.payload)
            await loadCards(reset: true)
            return true
        } catch { say(error); return false }
    }

    func setStatus(_ card: MemoryCard, _ status: String) async {
        do {
            _ = try await api.request("PUT", "api/chats/\(card.chatID)/memory-cards/\(card.id)", body: ["status": status])
            await loadCards(reset: true)
        } catch { say(error) }
    }

    func archive(_ card: MemoryCard) async {
        do {
            _ = try await api.request("DELETE", "api/chats/\(card.chatID)/memory-cards/\(card.id)")
            cards.removeAll { $0.id == card.id }
            total = max(0, total - 1)
            toast = "已归档，可以在「已归档」里恢复"
        } catch { say(error) }
    }

    func deleteForever(_ card: MemoryCard) async {
        do {
            _ = try await api.request("DELETE", "api/chats/\(card.chatID)/memory-cards/\(card.id)/permanent")
            cards.removeAll { $0.id == card.id }
            total = max(0, total - 1)
        } catch { say(error) }
    }

    func share(_ card: MemoryCard) async {
        do {
            let json = try await api.request("POST", "api/chats/\(card.chatID)/memory-cards/\(card.id)/share")
            toast = "已共享给 " + (json["to_name"] as? String ?? "另一位")
            await loadCards(reset: true)
        } catch { say(error) }
    }

    func splitCard(_ card: MemoryCard) async {
        do {
            let json = try await api.request("POST", "api/chats/\(card.chatID)/memory-cards/\(card.id)/split")
            cardState = MemoryCardState(json: json["state"] as? [String: Any])
            toast = "在拆了，拆好会放进「待确认」"
            pollIfBusy()
        } catch { say(error) }
    }

    // MARK: - 待确认

    func generateDrafts() async {
        do {
            let json = try await api.request("POST", "\(base)/memory-cards/generate")
            cardState = MemoryCardState(json: json["state"] as? [String: Any])
            pollIfBusy()
        } catch { say(error) }
    }

    /// 采用；edited 不为空就是「先修改」之后再采用。
    func accept(_ draft: MemoryCard, edited: MemoryCard? = nil) async -> Bool {
        do {
            _ = try await api.request("POST", "\(base)/memory-card-drafts/\(draft.id)/accept",
                                      body: edited?.payload ?? [:])
            await loadCards(reset: true)
            return true
        } catch { say(error); return false }
    }

    func discard(_ draft: MemoryCard) async {
        do {
            _ = try await api.request("DELETE", "\(base)/memory-card-drafts/\(draft.id)")
            drafts.removeAll { $0.id == draft.id }
        } catch { say(error) }
    }

    func acceptAll() async {
        do {
            let json = try await api.request("POST", "\(base)/memory-card-drafts/accept-all")
            toast = "采用了 \(json["accepted"] as? Int ?? 0) 条"
            await loadCards(reset: true)
        } catch { say(error) }
    }

    func discardAll() async {
        do {
            _ = try await api.request("POST", "\(base)/memory-card-drafts/discard-all")
            await loadCards(reset: true)
        } catch { say(error) }
    }

    func splitDraft(_ draft: MemoryCard) async {
        do {
            let json = try await api.request("POST", "\(base)/memory-card-drafts/\(draft.id)/split")
            cardState = MemoryCardState(json: json["state"] as? [String: Any])
            pollIfBusy()
        } catch { say(error) }
    }

    // MARK: - 原文

    func source(of card: MemoryCard, isDraft: Bool, full: Bool) async -> (messages: [MemorySourceMessage], canExpand: Bool) {
        do {
            let json = try await api.request("GET", "api/chats/\(isDraft ? chatID : card.chatID)/memory-source", query: [
                "kind": isDraft ? "draft" : "card", "id": card.id, "full": full ? "true" : "false",
            ])
            let messages = (json["messages"] as? [[String: Any]] ?? []).map(MemorySourceMessage.init(json:))
            return (messages, json["can_expand"] as? Bool ?? false)
        } catch {
            say(error)
            return ([], false)
        }
    }

    // MARK: - 摘要

    func generateSummary() async {
        do {
            summary = MemorySummary(json: try await api.request("POST", "\(base)/long-context", body: [:]))
            pollIfBusy()
        } catch { say(error) }
    }

    func saveSummary(_ text: String, acceptDraft: Bool) async {
        do {
            summary = MemorySummary(json: try await api.request("PUT", "\(base)/long-context", body: [
                "overview": text, "accept_draft": acceptDraft,
            ]))
            toast = acceptDraft ? "摘要已采用" : "摘要已保存"
        } catch { say(error) }
    }

    func discardSummaryDraft() async {
        do {
            summary = MemorySummary(json: try await api.request("DELETE", "\(base)/long-context/draft"))
        } catch { say(error) }
    }

    // MARK: - 设置

    func setInjection(_ on: Bool) async {
        do {
            let json = try await api.request("PUT", "\(base)/memory-cards/injection", body: ["enabled": on])
            injectionEnabled = json["enabled"] as? Bool ?? on
        } catch { say(error) }
    }

    func setShared(_ on: Bool) async {
        do {
            let json = try await api.request("PUT", "\(base)/memory-shared", body: ["enabled": on])
            sharedEnabled = json["enabled"] as? Bool ?? on
            await loadCards(reset: true)
            await loadSummary()
        } catch { say(error) }
    }

    func setLongContextModel(_ choice: MemoryModelChoice) async {
        do {
            _ = try await api.request("POST", "api/long-context-model", body: [
                "provider_id": choice.providerID, "model_id": choice.modelID,
            ])
            await loadModels()
        } catch { say(error) }
    }

    func setEmbeddingModel(_ choice: MemoryModelChoice?) async {
        do {
            _ = try await api.request("POST", "api/embedding-model", body: [
                "provider_id": choice?.providerID ?? "", "model_id": choice?.modelID ?? "",
            ])
            await loadModels()
        } catch { say(error) }
    }

    private func say(_ error: Error) {
        toast = error.localizedDescription
    }
}
