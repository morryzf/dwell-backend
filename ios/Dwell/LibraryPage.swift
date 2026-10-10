import SwiftUI
import UniformTypeIdentifiers

/// 「书房」，照网页的 #nookSheet：一间暗红的屋子，两层书架、每层四本；
/// 右上的怀表是阅读安排，左下的「收藏」是暂时不放在架子上的书。
/// 点书进详情，再从详情去翻书、看他的读书笔记、看分享本。
enum NookRoute: Hashable {
    case book(String)
    case collection
    case settings
    case notes(String)
    case shares(String)
    case chapter(String, Int)
}

struct LibraryPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [NookRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            NookShelf(path: $path)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel("关闭书房")
                    }
                }
                .navigationDestination(for: NookRoute.self) { route in
                    switch route {
                    case .book(let id): NookBookDetail(bookID: id, path: $path)
                    case .collection: NookCollection(path: $path)
                    case .settings: NookSettings()
                    case .notes(let id): NookReadingNotes(bookID: id)
                    case .shares(let id): NookShares(bookID: id)
                    case .chapter(let id, let index): NookReader(bookID: id, startIndex: index)
                    }
                }
        }
        .tint(NookStyle.ink)
    }
}

/// 屋子里的页面都用这一套：暗红背景、透明的导航栏、浅色的字。
private struct NookRoom: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(NookRoomBackground())
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .tint(NookStyle.ink)
            .environment(\.colorScheme, .dark)
    }
}

/// 读书笔记、分享本、翻书这几页回到家里那张方格纸上，跟网页一样。
private struct NookPaper: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(PaperBackground().ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.text)
    }
}

extension View {
    func nookRoom() -> some View { modifier(NookRoom()) }
    func nookPaper() -> some View { modifier(NookPaper()) }
}

// MARK: - 书架

private struct NookShelf: View {
    @Binding var path: [NookRoute]

    @State private var books: [NookBook] = []
    @State private var loaded = false
    @State private var note = "正在开门…"
    @State private var uploading = ""
    @State private var picking = false

    private var shelf: [NookBook] { Array(books.filter { !$0.collected }.prefix(8)) }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    if loaded && uploading.isEmpty {
                        cabinet
                            .frame(width: geo.size.width * 0.86)
                            .padding(.top, 40)
                    } else {
                        Text(uploading.isEmpty ? note : "正在把《\(uploading)》放上书架…")
                            .font(.system(size: 14.5))
                            .foregroundStyle(NookStyle.inkDim)
                            .padding(.top, 120)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                // 怀表：阅读安排藏在这里。
                Button { path.append(.settings) } label: {
                    Image("StudyWatch")
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(192, max(88, geo.size.width * 0.205)))
                        .shadow(color: .black.opacity(0.32), radius: 3.5, y: 5)
                        .opacity(0.72)
                }
                .buttonStyle(PressScale())
                .padding(.trailing, min(56, max(22, geo.size.width * 0.06)))
                .padding(.top, 4)
                .accessibilityLabel("打开阅读安排、模型和摘要来源")
            }
        }
        .nookRoom()
        .task { await load() }
        .refreshable { await load() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data]) { result in
            if case .success(let url) = result { Task { await upload(url) } }
        }
    }

    private var cabinet: some View {
        VStack(spacing: 20) {
            ForEach(0..<2, id: \.self) { tier in
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach(0..<4, id: \.self) { slot in
                            self.slot(tier * 4 + slot)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 16)
                    // 木板：上亮下暗，底下一道影子。
                    LinearGradient(stops: [
                        .init(color: Color(red: 0.29, green: 0.106, blue: 0.125), location: 0),
                        .init(color: Color(red: 0.102, green: 0.035, blue: 0.047), location: 0.32),
                        .init(color: Color(red: 0.035, green: 0.016, blue: 0.02), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: 11)
                    .shadow(color: .black.opacity(0.5), radius: 6.5, y: 8)
                }
            }
            HStack {
                Button { path.append(.collection) } label: {
                    Text("收藏")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(1.4)
                        .foregroundStyle(Color(red: 0.91, green: 0.843, blue: 0.812).opacity(0.62))
                        .frame(width: 72, height: 42)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2,
                                                   bottomTrailingRadius: 6, topTrailingRadius: 6)
                                .fill(NookStyle.keepsake)
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color(red: 0.867, green: 0.776, blue: 0.722).opacity(0.24))
                                .frame(height: 1).padding(.horizontal, 8).padding(.bottom, 5)
                        }
                        .overlay(
                            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2,
                                                   bottomTrailingRadius: 6, topTrailingRadius: 6)
                                .stroke(Color(red: 0.788, green: 0.651, blue: 0.592).opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 7, x: 4, y: 7)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("收藏的书")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func slot(_ index: Int) -> some View {
        if index < shelf.count {
            let book = shelf[index]
            Button { path.append(.book(book.id)) } label: {
                NookCover(book: book)
            }
            .buttonStyle(PressScale())
        } else {
            let upload = index == shelf.count
            Button { picking = true } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: 0.012, green: 0.004, blue: 0.008).opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(NookStyle.ink.opacity(upload ? 0.18 : 0.09), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .overlay {
                        if upload {
                            Image(systemName: "plus").font(.system(size: 17)).foregroundStyle(NookStyle.ink.opacity(0.4))
                        }
                    }
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .disabled(!upload)
            .accessibilityLabel(upload ? "放一本 EPUB 进来" : "空位")
        }
    }

    private func load() async {
        do {
            books = try await Nook.books()
            loaded = true
        } catch {
            note = "书房那头没应声"
        }
    }

    private func upload(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            note = "这本书读不出来"
            return
        }
        let name = url.lastPathComponent
        uploading = (name as NSString).deletingPathExtension
        do {
            _ = try await API.shared.multipart("api/nook/books", field: "file", filename: name, data: data)
            uploading = ""
            await load()
        } catch {
            uploading = ""
            loaded = false
            note = "（\((error as? APIError)?.message ?? "没有放进去")）"
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await load()
        }
    }
}

/// 按下去缩一点（网页的 :active scale(.97)）。
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - 一本书

private struct NookBookDetail: View {
    let bookID: String
    @Binding var path: [NookRoute]

    @State private var book: NookBook?
    @State private var note = "正在抽出这本书…"
    @State private var confirmDelete = false
    @State private var error = ""

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                if let book {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .bottom, spacing: geo.size.width <= 420 ? 16 : 20) {
                            NookCover(book: book, detail: true)
                                .frame(width: geo.size.width <= 420 ? 92 : 112)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(book.displayTitle)
                                    .font(.custom(NookStyle.serif, size: min(36, max(24, geo.size.width * 0.06))))
                                    .foregroundStyle(NookStyle.title)
                                Text(book.author.isEmpty ? "作者不详" : book.author)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(NookStyle.inkDim)
                                    .padding(.top, 8)
                                Text(book.progressText)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(NookStyle.ink.opacity(0.68))
                                    .padding(.top, 16)
                                GeometryReader { bar in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(NookStyle.ink.opacity(0.1))
                                        Capsule().fill(NookStyle.progress).frame(width: bar.size.width * book.progress)
                                    }
                                }
                                .frame(height: 4)
                                .padding(.top, 10)
                            }
                        }
                        .padding(.top, 18)
                        .padding(.bottom, 22)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                            Button("翻开这本书") { path.append(.chapter(book.id, book.currentChapter)) }
                                .buttonStyle(NookButtonStyle(primary: true))
                            Button("他的读书笔记") { path.append(.notes(book.id)) }
                                .buttonStyle(NookButtonStyle())
                            Button("这本书的分享本") { path.append(.shares(book.id)) }
                                .buttonStyle(NookButtonStyle())
                            Button(book.collected ? "放回书架" : "收进收藏") { Task { await collect(!book.collected) } }
                                .buttonStyle(NookButtonStyle())
                        }
                        Button("把这本书和它的笔记移出书房") { confirmDelete = true }
                            .buttonStyle(NookButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.top, 18)
                        if !error.isEmpty {
                            Text(error).font(.system(size: 13)).foregroundStyle(NookStyle.inkDim).padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, 32)
                } else {
                    Text(note).font(.system(size: 14.5)).foregroundStyle(NookStyle.inkDim).padding(.top, 120)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .nookRoom()
        .task { await load() }
        .confirmationDialog("把《\(book?.displayTitle ?? "")》和它的笔记一起移出书房吗？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移出书房", role: .destructive) { Task { await remove() } }
        }
    }

    private func load() async {
        do {
            book = try await Nook.books().first { $0.id == bookID }
            if book == nil { note = "这本书一时找不到" }
        } catch {
            note = "这本书一时找不到"
        }
    }

    private func collect(_ on: Bool) async {
        do {
            _ = try await API.shared.request("POST", "api/nook/books/\(bookID)/collection", body: ["collected": on])
            path = []
        } catch {
            self.error = "（\((error as? APIError)?.message ?? "没放成")）"
        }
    }

    private func remove() async {
        do {
            _ = try await API.shared.request("DELETE", "api/nook/books/\(bookID)")
            NookCovers.shared.forget(bookID)
            path = []
        } catch {
            self.error = "（没有移走）"
        }
    }
}

// MARK: - 收藏

private struct NookCollection: View {
    @Binding var path: [NookRoute]
    @State private var books: [NookBook] = []
    @State private var loaded = false
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                NookHeading(title: "收藏", subtitle: "暂时不放在书架上的书，内容和笔记都还留着。")
                if loaded && books.isEmpty {
                    NookEmpty(text: "还没有收进收藏的书。")
                }
                ForEach(books) { book in
                    HStack(spacing: 12) {
                        Button { path.append(.book(book.id)) } label: {
                            HStack(spacing: 12) {
                                NookCover(book: book).frame(width: 54)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(book.displayTitle).font(.custom(NookStyle.serif, size: 15)).foregroundStyle(NookStyle.ink)
                                    Text(book.author.isEmpty ? "作者不详" : book.author)
                                        .font(.system(size: 11)).foregroundStyle(NookStyle.ink.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("放回") { Task { await putBack(book) } }
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.851, green: 0.784, blue: 0.753))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(NookStyle.ink.opacity(0.08)))
                            .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.black.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(NookStyle.ink.opacity(0.09), lineWidth: 1))
                }
                if !error.isEmpty {
                    Text(error).font(.system(size: 13)).foregroundStyle(NookStyle.inkDim)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .nookRoom()
        .task { await load() }
    }

    private func load() async {
        books = ((try? await Nook.books()) ?? []).filter(\.collected)
        loaded = true
    }

    private func putBack(_ book: NookBook) async {
        do {
            _ = try await API.shared.request("POST", "api/nook/books/\(book.id)/collection", body: ["collected": false])
            error = ""
            await load()
        } catch {
            self.error = "（\((error as? APIError)?.message ?? "书架放不下了")）"
        }
    }
}

struct NookHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.custom(NookStyle.serif, size: 30)).foregroundStyle(NookStyle.ink)
            Text(subtitle).font(.system(size: 13.5)).foregroundStyle(NookStyle.ink.opacity(0.8)).lineSpacing(3)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

struct NookEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(NookStyle.ink.opacity(0.58))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black.opacity(0.4))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color(red: 0.745, green: 0.537, blue: 0.518).opacity(0.34)).frame(width: 1)
            }
    }
}

// MARK: - 阅读安排（怀表）

private struct NookSettings: View {
    @State private var on = false
    @State private var times: [String] = []
    @State private var tokens = 4000
    @State private var chatID = ""
    @State private var providerID = ""
    @State private var modelID = ""
    @State private var chats: [(id: String, name: String)] = []
    @State private var models: [(provider: String, providerName: String, model: String)] = []
    @State private var hasBooks = false
    @State private var loaded = false
    @State private var message = ""
    @State private var waking = false

    private var ready: Bool { !chatID.isEmpty && !modelID.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NookHeading(title: "阅读安排", subtitle: "藏在书房小物件里的设置。只有你来决定他什么时候读、一次读多少。")
                if loaded { form } else {
                    Text("正在打开…").font(.system(size: 14)).foregroundStyle(NookStyle.inkDim).padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .nookRoom()
        .task { await load() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                field("使用哪段聊天的摘要") {
                    Menu {
                        ForEach(chats, id: \.id) { chat in
                            Button(chat.name) { chatID = chat.id }
                        }
                    } label: {
                        menuLabel(chats.first { $0.id == chatID }?.name ?? (chats.isEmpty ? "还没有聊天" : "请选择聊天"))
                    }
                }
                field("书房使用的模型") {
                    Menu {
                        ForEach(Array(models.enumerated()), id: \.offset) { _, item in
                            Button("\(item.providerName) · \(item.model)") {
                                providerID = item.provider
                                modelID = item.model
                            }
                        }
                    } label: {
                        menuLabel(modelID.isEmpty ? "请选择模型"
                                  : "\(models.first { $0.provider == providerID && $0.model == modelID }?.providerName ?? "") · \(modelID)")
                    }
                }
                field("每天准确在这些时间读") {
                    VStack(spacing: 7) {
                        ForEach(times.indices, id: \.self) { index in
                            HStack(spacing: 7) {
                                DatePicker("", selection: Binding(
                                    get: { times.indices.contains(index) ? HomeClock.hmFormat.date(from: times[index]) ?? Date() : Date() },
                                    set: { if times.indices.contains(index) { times[index] = HomeClock.hm($0) } }
                                ), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .environment(\.timeZone, HomeClock.zone)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    if times.count > 1 { times.remove(at: index) }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(NookStyle.inkDim)
                                        .frame(width: 38, height: 38)
                                        .background(RoundedRectangle(cornerRadius: 9).fill(NookStyle.ink.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .disabled(times.count <= 1)
                                .accessibilityLabel("删掉这个时间")
                            }
                        }
                        Button {
                            times.append("20:00")
                        } label: {
                            Label("再加一次", systemImage: "plus").font(.system(size: 13.5)).foregroundStyle(NookStyle.inkDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(times.count >= 12)
                    }
                }
                field("每次原文最多读取 tokens") {
                    HStack {
                        Text("\(tokens)").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(NookStyle.ink)
                        Spacer()
                        Stepper("tokens", value: $tokens, in: 1000...12000, step: 500).labelsHidden()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(NookStyle.ink.opacity(0.08)))
                }
                Text("有新留言时，会先单独回信，再另起一次阅读。两次使用不同输入。")
                    .font(.system(size: 12)).foregroundStyle(NookStyle.inkDim).lineSpacing(3)
                Button("保存阅读安排") { Task { await save() } }
                    .buttonStyle(NookButtonStyle(primary: true))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(NookStyle.panel))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(NookStyle.line, lineWidth: 1))

            HStack(spacing: 9) {
                Button(on ? "暂停定时阅读" : "打开定时阅读") { Task { await toggle() } }
                    .buttonStyle(NookButtonStyle(primary: !on))
                Button(waking ? "叫他去了…" : "现在读一会儿") { Task { await run() } }
                    .buttonStyle(NookButtonStyle())
                    .disabled(!(hasBooks && ready) || waking)
                    .opacity(hasBooks && ready ? 1 : 0.5)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 13)).foregroundStyle(NookStyle.inkDim)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(NookStyle.inkDim)
            content()
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 14.5)).foregroundStyle(NookStyle.ink).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(NookStyle.inkDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9).fill(NookStyle.ink.opacity(0.08)))
    }

    private func apply(_ json: [String: Any]) {
        on = json["on"] as? Bool ?? false
        times = json["times"] as? [String] ?? ["20:00"]
        if times.isEmpty { times = ["20:00"] }
        tokens = json["reading_tokens"] as? Int ?? 4000
        chatID = json["chat_id"] as? String ?? ""
        providerID = json["model_provider_id"] as? String ?? ""
        modelID = json["model_id"] as? String ?? ""
    }

    private func load() async {
        do {
            apply(try await API.shared.request("GET", "api/nook/settings"))
            let chatJSON = try await API.shared.request("GET", "api/chats", query: ["scope": "live", "assistant": "cloudy"])
            let items = chatJSON["items"] as? [[String: Any]] ?? []
            chats = items.map { (id: $0["id"] as? String ?? "", name: ($0["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "新对话") }
            if chatID.isEmpty { chatID = items.first { ($0["current"] as? Bool) == true }?["id"] as? String ?? "" }
            let catalog = try await API.shared.request("GET", "api/model-catalog")
            let enabled = Set((catalog["providers"] as? [[String: Any]] ?? [])
                .filter { ($0["enabled"] as? Bool) ?? (($0["enabled"] as? Int ?? 1) != 0) }
                .compactMap { $0["id"] as? String })
            models = (catalog["items"] as? [[String: Any]] ?? []).compactMap { item in
                guard let provider = item["provider_id"] as? String, enabled.contains(provider),
                      let model = item["model_id"] as? String else { return nil }
                return (provider: provider, providerName: item["provider_name"] as? String ?? "", model: model)
            }
            hasBooks = ((try? await Nook.books()) ?? []).contains { !$0.collected }
            loaded = true
        } catch {
            message = (error as? APIError)?.message ?? "阅读安排没打开"
        }
    }

    private func save() async {
        do {
            apply(try await API.shared.request("POST", "api/nook/settings", body: [
                "times": times, "reading_tokens": tokens, "chat_id": chatID,
                "model_provider_id": providerID, "model_id": modelID,
            ]))
            message = "阅读安排存好了"
        } catch {
            message = "（\((error as? APIError)?.message ?? "没存上")）"
        }
    }

    private func toggle() async {
        guard ready else {
            message = "（先选择摘要来源和模型，再保存）"
            return
        }
        do {
            apply(try await API.shared.request("POST", "api/nook/settings", body: ["on": !on]))
            message = on ? "定时阅读开了，到点他会自己进书房" : "定时阅读暂停了"
        } catch {
            message = "（\((error as? APIError)?.message ?? "没改成")）"
        }
    }

    private func run() async {
        waking = true
        defer { waking = false }
        do {
            _ = try await API.shared.request("POST", "api/nook/run")
            message = "Cloudy 醒来后会自己进书房。"
        } catch {
            message = "（这次没有叫醒他）"
        }
    }
}
