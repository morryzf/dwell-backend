import SwiftUI

/// 「Journal」，先只搬「最喜欢的话」：聊天里摘下来的话，每句下面可以写为什么喜欢。
/// 心事簿、悄悄话、夜记这些还在网页里，页底有个入口。
struct JournalPage: View {
    @EnvironmentObject private var store: ChatStore

    struct Quote: Identifiable, Equatable {
        let id: String
        let date: String
        let quote: String
        var note: String

        init(json: [String: Any]) {
            id = json["id"] as? String ?? UUID().uuidString
            date = json["date"] as? String ?? ""
            quote = (json["quote"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "“”\""))
            // 老的摘录有的把「Cloudy 说 / 我说」记在这里，那不是她写的话。
            let raw = (json["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            note = raw == "Cloudy 说" || raw == "我说" ? "" : raw
        }
    }

    @State private var quotes: [Quote] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var editingID: String?
    @State private var noteDraft = ""
    @State private var deleting: Quote?
    @State private var showWeb = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        PageScaffold(title: "Journal", subtitle: "最喜欢的话 · \(quotes.count) 句") {
            Text("在聊天里点开一条回复，「⋯」→「摘进最喜欢的话」，那一轮的完整回复就收到这里。每句下面可以写写为什么喜欢。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .lineSpacing(3)
                .padding(.top, 6)

            VStack(spacing: 14) {
                ForEach(quotes) { item in card(item) }
            }
            .padding(.top, 18)

            if loaded && quotes.isEmpty {
                Text(failed ? "摘录暂时没拿到，下拉再试一次" : "还没摘下来的话")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }

            Button { showWeb = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("心事簿、悄悄话、夜记还在网页里")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
            }
            .buttonStyle(.plain)
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showWeb) {
            if let base = API.shared.baseURL {
                SafariView(url: base).ignoresSafeArea()
            }
        }
        .confirmationDialog("删掉这句摘录？", isPresented: Binding(get: { deleting != nil },
                                                                set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let deleting { Task { await remove(deleting) } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func card(_ item: Quote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "quote.opening")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(item.date.replacingOccurrences(of: "-", with: " · "))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                Spacer()
                Menu {
                    Button { startEditing(item) } label: {
                        Label(item.note.isEmpty ? "写为什么喜欢" : "改一改", systemImage: "pencil")
                    }
                    Button { UIPasteboard.general.string = item.quote } label: {
                        Label("拷贝这句", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) { deleting = item } label: {
                        Label("删除摘录", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
            }
            Text(item.quote)
                .font(.system(size: 15.5, design: .serif))
                .lineSpacing(6)
                .foregroundStyle(Theme.bubbleText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if editingID == item.id {
                VStack(alignment: .trailing, spacing: 8) {
                    TextField("为什么喜欢这句…", text: $noteDraft, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(2...10)
                        .focused($noteFocused)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background.opacity(0.6)))
                    HStack(spacing: 14) {
                        Button("取消") { editingID = nil }
                            .foregroundStyle(Theme.dim)
                        Button("保存") { Task { await saveNote(item) } }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                    }
                    .font(.system(size: 14))
                    .buttonStyle(.plain)
                }
            } else if !item.note.isEmpty {
                // 她写的「为什么喜欢」：一道竖线隔开，像在页边写的批注。
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(Theme.accent.opacity(0.5)).frame(width: 2.5)
                    Text(item.note)
                        .font(.system(size: 13.5))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { startEditing(item) }
            } else {
                Button { startEditing(item) } label: {
                    Label("写为什么喜欢", systemImage: "pencil.line")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
        .shadow(color: Theme.bubbleShadow, radius: 10, y: 6)
    }

    private func startEditing(_ item: Quote) {
        noteDraft = item.note
        withAnimation(.easeOut(duration: 0.2)) { editingID = item.id }
        noteFocused = true
    }

    private func load() async {
        // 先摆上次存下的，服务器那份回来再换上。
        if !loaded, let json = API.shared.remembered("api/quotes") {
            quotes = (json["items"] as? [[String: Any]] ?? []).map(Quote.init(json:))
            loaded = true
        }
        do {
            let json = try await API.shared.request("GET", "api/quotes", remember: true)
            quotes = (json["items"] as? [[String: Any]] ?? []).map(Quote.init(json:))
            failed = false
        } catch {
            // 手里有存着的就接着看，不说拿不到。
            failed = quotes.isEmpty
        }
        loaded = true
    }

    private func saveNote(_ item: Quote) async {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await API.shared.request("PATCH", "api/quotes/\(item.id)", body: ["note": text])
            if let index = quotes.firstIndex(where: { $0.id == item.id }) { quotes[index].note = text }
            withAnimation(.easeOut(duration: 0.2)) { editingID = nil }
        } catch {
            store.flash("没保存上，再试一次")
        }
    }

    private func remove(_ item: Quote) async {
        do {
            _ = try await API.shared.request("DELETE", "api/quotes/\(item.id)")
            withAnimation(.easeOut(duration: 0.25)) { quotes.removeAll { $0.id == item.id } }
        } catch {
            store.flash("这句没删掉")
        }
    }
}
