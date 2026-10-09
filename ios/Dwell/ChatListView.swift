import SwiftUI

struct ChatListView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var chats: [ChatSummary] = []
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(chats) { chat in
                    Button {
                        Task {
                            await store.switchChat(chat.id)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(chat.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if chat.id == store.chatID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            if !chat.preview.isEmpty {
                                Text(chat.preview)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.dim)
                                    .lineLimit(2)
                            }
                            Text(chat.last, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(Theme.dim)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .navigationTitle(store.assistant?.name ?? "聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            chats = try await API.shared.chats()
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
