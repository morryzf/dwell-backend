import SwiftUI

/// 「摘要」页：长期摘要的状态、正文、生成；有待确认的新摘要时可以采用或丢弃。
struct MemorySummaryPanel: View {
    @ObservedObject var store: MemoryStore

    @State private var editing = false
    @State private var draftText = ""

    private var summary: MemorySummary { store.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("状态") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusLine)
                        .foregroundStyle(summary.status == "error" ? MemoryStyle.danger : Theme.text)
                    Text("原消息 \(summary.messageCount) 条 · 已压缩 \(summary.segmentCount) 段 · 最近 \(summary.tailMessages) 条保留原文")
                        .foregroundStyle(Theme.dim)
                    Text("正式摘要最近保存：" + (summary.generatedAt > 0
                        ? Date(timeIntervalSince1970: TimeInterval(summary.generatedAt)).formatted(date: .abbreviated, time: .shortened)
                        : "还未生成"))
                        .foregroundStyle(Theme.dim)
                }
                .font(.system(size: 14))
            }

            if summary.hasDraft {
                section("新摘要（待确认）") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $draftText)
                            .font(.system(size: 15))
                            .frame(minHeight: 220)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
                        HStack(spacing: 10) {
                            Button("采用") { Task { await store.saveSummary(draftText, acceptDraft: true) } }
                                .buttonStyle(MemoryButtonStyle(kind: .primary))
                            Button("丢弃") { Task { await store.discardSummaryDraft() } }
                                .buttonStyle(MemoryButtonStyle(kind: .danger))
                        }
                    }
                }
                .onAppear { draftText = summary.draftOverview }
                .onChange(of: summary.draftOverview) { _, text in draftText = text }
            }

            section("正式摘要") {
                VStack(alignment: .leading, spacing: 12) {
                    if editing {
                        TextEditor(text: $draftText)
                            .font(.system(size: 15))
                            .frame(minHeight: 260)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
                        HStack(spacing: 10) {
                            Button("保存") {
                                Task {
                                    await store.saveSummary(draftText, acceptDraft: false)
                                    editing = false
                                }
                            }
                            .buttonStyle(MemoryButtonStyle(kind: .primary))
                            Button("取消") { editing = false }
                                .buttonStyle(MemoryButtonStyle(kind: .quiet))
                        }
                    } else if !summary.overview.isEmpty {
                        Text(summary.overview)
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.bubbleText)
                            .textSelection(.enabled)
                        Button("编辑") {
                            draftText = summary.overview
                            editing = true
                        }
                        .buttonStyle(MemoryButtonStyle(kind: .normal))
                    } else if !summary.sharedOverview.isEmpty {
                        Text("互通开着，现在用的是「\(summary.sharedFrom)」的公共摘要：")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.dim)
                        Text(summary.sharedOverview)
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.bubbleText)
                            .textSelection(.enabled)
                    } else {
                        Text("还没有正式摘要。摘要只在你点击时生成。")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }

            Button {
                Task { await store.generateSummary() }
            } label: {
                HStack(spacing: 8) {
                    if summary.isBusy { ProgressView().tint(.white).controlSize(.small) }
                    Text(summary.isBusy ? "正在生成…" : "生成摘要")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MemoryButtonStyle(kind: .primary, large: true))
            .disabled(summary.isBusy || summary.hasDraft)
        }
    }

    private var statusLine: String {
        switch summary.status {
        case "queued", "running": return "正在整理摘要…"
        case "error": return "上次生成失败：" + summary.error
        default:
            if summary.hasDraft { return "有一份新摘要等你确认。" }
            return summary.overview.isEmpty ? "还没有正式摘要。摘要只在你点击时生成。" : "摘要已就绪。"
        }
    }
}

/// 「设置」页：两个开关和两个模型。
struct MemorySettingsPanel: View {
    @ObservedObject var store: MemoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("记忆互通") {
                Toggle(isOn: Binding(get: { store.sharedEnabled },
                                     set: { on in Task { await store.setShared(on) } })) {
                    Text("和其他窗口共用同一套记忆卡与摘要。关掉之后，这个窗口只看自己的，自己的也不外流。")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                }
                .tint(Theme.send)
            }
            section("按需记忆") {
                Toggle(isOn: Binding(get: { store.injectionEnabled },
                                     set: { on in Task { await store.setInjection(on) } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("每次回复只挑最多 5 条真正相关的卡片；不相关时一条也不会带入。")
                        Text("每累计 50 条旧消息会自动生成待确认记忆卡。")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dim)
                }
                .tint(Theme.send)
            }
            section("整理所用模型") {
                modelMenu(
                    note: "用来压缩长期摘要、生成记忆卡草稿。",
                    setting: store.longContextModel,
                    choices: store.longContextModel.items,
                    empty: "还没有可选模型。先在网页的设置里为供应商添加模型。",
                    allowNone: false
                ) { choice in
                    if let choice { Task { await store.setLongContextModel(choice) } }
                }
            }
            section("向量检索模型") {
                modelMenu(
                    note: "用于记忆卡的语义检索。设置后新采用或编辑的记忆卡会自动生成向量。",
                    setting: store.embeddingModel,
                    // 跟网页一样，这里只列「常用」里的模型。
                    choices: store.embeddingModel.items.filter(\.favorite),
                    empty: "还没有常用模型。先在网页的设置里把模型加入常用。",
                    allowNone: true
                ) { choice in
                    Task { await store.setEmbeddingModel(choice) }
                }
            }
        }
    }

    private func modelMenu(note: String, setting: MemoryModelSetting, choices: [MemoryModelChoice],
                           empty: String, allowNone: Bool,
                           pick: @escaping (MemoryModelChoice?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note).font(.system(size: 14)).foregroundStyle(Theme.dim)
            if choices.isEmpty {
                Text(empty).font(.system(size: 13.5)).foregroundStyle(Theme.dim)
            } else {
                Menu {
                    if allowNone {
                        Button("不使用") { pick(nil) }
                    }
                    ForEach(choices) { choice in
                        Button {
                            pick(choice)
                        } label: {
                            if choice.providerID == setting.providerID && choice.modelID == setting.modelID {
                                Label("\(choice.providerName) · \(choice.modelID)", systemImage: "checkmark")
                            } else {
                                Text("\(choice.providerName) · \(choice.modelID)")
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(setting.label).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                    }
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
                }
            }
        }
    }
}

/// 设置页和摘要页里那种带标题的白卡片。
private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.text)
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MemoryStyle.card))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
}
