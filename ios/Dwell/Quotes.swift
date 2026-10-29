import SwiftUI

/// 气泡上方那一小块引用：不写名字，淡底、左边一道竖线，最多两行（折叠着）。
/// 带图的在左边放一张小缩略图。点一下跳回原消息。
struct QuoteBlock: View {
    let quote: MessageQuote
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                if let image = DataURLImage.image(quote.image) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(quote.preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 7)
            .padding(.leading, 11)
            .padding(.trailing, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chip.opacity(0.85)))
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.5)).frame(width: 2.5).padding(.vertical, 7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("引用：\(quote.preview)")
    }
}

/// 输入框上方那条「正在引用」：一行原话，× 取消。
struct QuotingChip: View {
    let message: Message
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Theme.accent.opacity(0.5)).frame(width: 2.5, height: 18)
            Text(MessageQuote(message: message).preview)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("不引用了")
        }
        .padding(.horizontal, 2)
    }
}

/// 点了引用、原消息离得太远没加载：给那条和前后几条，被引用的那条描边。
struct QuoteContextSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let quote: MessageQuote
    @State private var messages: [MemorySourceMessage] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if loading {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                        } else if messages.isEmpty {
                            // 原消息已经删了：引用里存着的原话还在。
                            Text(quote.preview)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MemoryStyle.banner))
                            Text("原消息已经不在了，这是引用时存下的原话。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.dim)
                        }
                        ForEach(messages) { message in
                            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                                Text(message.made.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.dim)
                                Text(message.content)
                                    .font(Theme.bubbleFont)
                                    .lineSpacing(Theme.bubbleLineSpacing)
                                    .foregroundStyle(Theme.bubbleText)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(message.cited ? Theme.accent : Theme.bubbleBorder, lineWidth: message.cited ? 1.5 : 1)
                                    )
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                            .id(message.id)
                        }
                    }
                    .padding(18)
                }
                .onChange(of: messages.count) { _, _ in
                    if let cited = messages.first(where: \.cited) { proxy.scrollTo(cited.id, anchor: .center) }
                }
            }
            .background(PaperBackground())
            .navigationTitle("引用的那条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .tint(Theme.text)
            .task {
                messages = await store.context(of: quote.messageID)
                loading = false
            }
        }
    }
}
