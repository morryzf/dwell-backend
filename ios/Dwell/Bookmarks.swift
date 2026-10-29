import SwiftUI

/// 记忆页里的一个书签：她在聊天里圈的几句原话。上面一行「这段在讲什么」，
/// 下面是原话（谁说的、哪天），再下面是她写的「为什么记」。
struct BookmarkCardView: View {
    let card: MemoryCard
    let assistantName: String
    var onEdit: () -> Void = {}
    var onSource: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var actionsOpen = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("书签", systemImage: "bookmark.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(BookmarkCardView.title(card))
                    .font(.system(size: 14.5, weight: card.labelState == "pending" || card.label.isEmpty ? .regular : .medium))
                    .foregroundStyle(card.label.isEmpty ? Theme.dim : Theme.text)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(line.role == "user" ? "Morry" : assistantName) · \(line.made.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                        Text(line.content)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text)
                            .lineLimit(expanded ? nil : 4)
                    }
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.45)).frame(width: 2.5)
            }
            if card.lines.contains(where: { $0.content.count > 90 }) || card.lines.count > 3 {
                Button(expanded ? "收起" : "展开") {
                    withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.dim)
                .buttonStyle(.plain)
            }
            if !card.why.isEmpty {
                Text("为什么记：" + card.why)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
            HStack {
                Button(action: onSource) {
                    HStack(spacing: 3) {
                        Text("看原文")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { actionsOpen.toggle() }
                } label: {
                    Image(systemName: actionsOpen ? "chevron.up" : "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionsOpen ? "收起操作" : "更多操作")
            }
            if actionsOpen {
                HStack(spacing: 8) {
                    Button("编辑", action: onEdit)
                        .buttonStyle(MemoryButtonStyle(kind: .normal))
                    Button("删除", action: onDelete)
                        .buttonStyle(MemoryButtonStyle(kind: .danger))
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MemoryStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
    }

    /// 概括还在写、没写出来时说什么。
    static func title(_ card: MemoryCard) -> String {
        if !card.label.isEmpty { return card.label }
        return card.labelState == "pending" ? "正在概括…" : "没概括出来，点编辑自己写一句"
    }
}

/// 改书签：概括、为什么记；每句原话旁边一个 ×，去掉就是从书签里拿掉这一句。
struct BookmarkEditor: View {
    let card: MemoryCard
    let assistantName: String
    let onSave: (_ label: String, _ why: String) async -> Void
    let onRemoveLine: (BookmarkLine) async -> Void
    let onCancel: () -> Void
    @State private var label: String
    @State private var why: String
    @State private var saving = false

    init(card: MemoryCard, assistantName: String,
         onSave: @escaping (_ label: String, _ why: String) async -> Void,
         onRemoveLine: @escaping (BookmarkLine) async -> Void,
         onCancel: @escaping () -> Void) {
        self.card = card
        self.assistantName = assistantName
        self.onSave = onSave
        self.onRemoveLine = onRemoveLine
        self.onCancel = onCancel
        _label = State(initialValue: card.label)
        _why = State(initialValue: card.why)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑书签")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            field("这段在讲什么") {
                TextField("一句话就好", text: $label, axis: .vertical)
                    .lineLimit(1...3)
            }
            field("为什么记（可以不写）") {
                TextField("", text: $why, axis: .vertical)
                    .lineLimit(2...6)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("原话")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                ForEach(card.lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.role == "user" ? "Morry" : assistantName)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim)
                            Text(line.content)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        if card.lines.count > 1 {
                            Button {
                                Task { await onRemoveLine(line) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.dim)
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("从书签里去掉这一句")
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button(saving ? "正在保存…" : "保存") {
                    Task {
                        saving = true
                        await onSave(label, why)
                        saving = false
                    }
                }
                .buttonStyle(MemoryButtonStyle(kind: .primary))
                .disabled(saving)
                Button("取消", action: onCancel)
                    .buttonStyle(MemoryButtonStyle(kind: .quiet))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MemoryStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(MemoryStyle.border, lineWidth: 1))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            content()
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MemoryStyle.field))
        }
    }
}

/// 在聊天里勾好几句以后点「收进记忆」：看一眼选了哪几句，想写就写一句为什么记。
struct BookmarkComposeSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let messages: [Message]
    let onDone: () -> Void
    @State private var why = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.kind == .me ? "Morry" : (store.assistant?.name ?? "Cloudy"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.dim)
                                Text(message.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(4)
                            }
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent.opacity(0.45)).frame(width: 2.5)
                    }
                    TextField("为什么记（可以不写）", text: $why, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.system(size: 15))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.field))
                    Text("收好以后，会自动写一句「这段在讲什么」，之后可以在记忆页改。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim)
                }
                .padding(20)
            }
            .background(PaperBackground())
            .navigationTitle("收进记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "正在收…" : "收进记忆") {
                        Task {
                            saving = true
                            let ok = await store.bookmark(messages.map(\.id), why: why)
                            saving = false
                            if ok {
                                dismiss()
                                onDone()
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(saving || messages.isEmpty)
                }
            }
            .tint(Theme.text)
        }
    }
}
