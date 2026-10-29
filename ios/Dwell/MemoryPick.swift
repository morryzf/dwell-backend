import SwiftUI

/// 发消息前亲手挑记忆卡：搜一搜、按事件筛，点一下勾上。挑好的跟着下一条消息走，
/// 那一轮他只看到这几张，不再自动找。
struct MemoryPickSheet: View {
    @EnvironmentObject private var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var memory: MemoryStore
    @State private var searchTask: Task<Void, Never>?
    @State private var full = false

    init(chatID: String) {
        _memory = StateObject(wrappedValue: MemoryStore(chatID: chatID))
    }

    /// 胶囊上那几个字：有事件名就写事件，没有就取正文开头。
    static func shortLabel(_ card: MemoryCard) -> String {
        if !card.thread.isEmpty { return (card.isMain ? "主卡 · " : "") + card.thread }
        let text = card.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 10 ? String(text.prefix(10)) + "…" : text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    filters
                    if memory.cards.isEmpty && !memory.loadingCards {
                        Text(memory.query.isEmpty ? "还没有记忆卡" : "没有找到")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(memory.cards) { card in
                        row(card)
                            .onAppear {
                                if card.id == memory.cards.last?.id, memory.hasMoreCards {
                                    Task { await memory.loadCards(reset: false) }
                                }
                            }
                    }
                    if memory.loadingCards {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PaperBackground())
            .navigationTitle("带记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chat.pickedCards.isEmpty ? "完成" : "带上 \(chat.pickedCards.count) 张") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if full {
                    Text("最多带 \(ChatStore.maxPicks) 张")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.chipText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.chip))
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .tint(Theme.text)
        }
        .task {
            // 只挑还在用的卡：归档的不列。
            memory.filter = "all"
            // 随消息带的只认记忆卡，书签先不列。
            memory.kind = "cards"
            await memory.loadCards(reset: true)
        }
        .onChange(of: memory.query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await memory.loadCards(reset: true)
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("搜记忆卡", text: $memory.query)
                    .font(.system(size: 15))
                    .submitLabel(.search)
                if !memory.query.isEmpty {
                    Button { memory.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MemoryStyle.field))
            if !memory.threads.isEmpty {
                Menu {
                    Button("全部事件") { pickThread("") }
                    ForEach(memory.threads, id: \.name) { thread in
                        Button("\(thread.name)（\(thread.count)）") { pickThread(thread.name) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(memory.thread.isEmpty ? "全部事件" : memory.thread)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(MemoryStyle.tag))
                    .overlay(Capsule().stroke(MemoryStyle.border, lineWidth: 1))
                }
            }
        }
        .padding(.top, 6)
    }

    private func pickThread(_ name: String) {
        memory.thread = name
        Task { await memory.loadCards(reset: true) }
    }

    private func row(_ card: MemoryCard) -> some View {
        let on = chat.isPicked(card)
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                let ok = chat.togglePick(card)
                full = !ok
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.content)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if !card.thread.isEmpty {
                        Text((card.isMain ? "主卡 · " : "副卡 · ") + card.thread)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.dim)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? Theme.send : Theme.dim.opacity(0.5))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(on ? Theme.accent.opacity(0.16) : MemoryStyle.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(on ? Theme.accent.opacity(0.5) : MemoryStyle.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "不带这张" : "带上这张")
    }
}

/// 我那条消息下面的一行淡字：「🗒️ 带了 2 张记忆 ›」，点开看是哪几张。
struct MemoryPicksNote: View {
    let picks: [MemoryPick]
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Text("🗒️ 带了 \(picks.count) 张记忆 ›")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim.opacity(0.8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .popover(isPresented: $open) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(picks) { pick in
                        VStack(alignment: .leading, spacing: 4) {
                            if pick.missing {
                                Text("这张卡已经删掉了")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Theme.dim)
                            } else {
                                Text(pick.content)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Theme.text)
                                if !pick.thread.isEmpty {
                                    Text((pick.isMain ? "主卡 · " : "副卡 · ") + pick.thread)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.dim)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if pick.id != picks.last?.id { Divider() }
                    }
                }
                .padding(14)
            }
            .frame(width: 300)
            .frame(maxHeight: 380)
            .presentationCompactAdaptation(.popover)
        }
    }
}
