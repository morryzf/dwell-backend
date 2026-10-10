import SwiftUI

/// 书房的数据：接口都在 /api/nook/* 下，跟网页同一套。

struct NookBook: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let chapterCount: Int
    let currentChapter: Int
    let currentOffset: Int
    let finished: Bool
    let lastRead: Int
    let collected: Bool
    let hasCover: Bool
    let chapters: [String]

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        title = json["title"] as? String ?? ""
        author = json["author"] as? String ?? ""
        chapterCount = json["chapter_count"] as? Int ?? 0
        currentChapter = json["current_chapter"] as? Int ?? 0
        currentOffset = json["current_offset"] as? Int ?? 0
        finished = Nook.flag(json["finished"])
        lastRead = json["last_read"] as? Int ?? 0
        collected = Nook.flag(json["collected"])
        hasCover = Nook.flag(json["has_cover"])
        chapters = json["chapters"] as? [String] ?? []
    }

    var displayTitle: String { title.isEmpty ? "未命名" : title }
    var started: Bool { lastRead > 0 || currentChapter > 0 || currentOffset > 0 || finished }

    /// 详情页那一行：他读到哪了。
    var progressText: String {
        if finished { return "Cloudy 已经读完了" }
        guard started else { return "Cloudy 还没有开始读" }
        let name = chapters.indices.contains(currentChapter) ? chapters[currentChapter] : ""
        return "Cloudy 读到：" + (name.isEmpty ? "第 \(currentChapter + 1) 节" : name)
    }

    var progress: Double {
        let total = max(chapterCount, chapters.count, 1)
        return started ? min(1, Double(currentChapter + 1) / Double(total)) : 0
    }
}

struct NookReply: Identifiable, Hashable {
    let id: String
    let who: String
    let text: String
    let ts: String

    init(json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        who = json["who"] as? String ?? ""
        text = json["text"] as? String ?? ""
        ts = json["ts"] as? String ?? ""
    }

    var fromUser: Bool { who == "user" }
}

/// 读书笔记、分享本的一页、页边笔记，都是这一种。
struct NookNote: Identifiable, Hashable {
    let id: String
    let bookID: String
    let chapterIndex: Int
    let anchor: String
    let text: String
    let who: String
    let bookTitle: String
    let chapterTitle: String
    let ts: String
    let replies: [NookReply]

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        bookID = json["book_id"] as? String ?? ""
        chapterIndex = json["chapter_idx"] as? Int ?? 0
        anchor = json["anchor"] as? String ?? ""
        // 页边笔记的正文叫 note，别的叫 text。
        text = (json["note"] as? String) ?? (json["text"] as? String) ?? ""
        who = json["who"] as? String ?? ""
        bookTitle = json["book_title"] as? String ?? ""
        chapterTitle = json["chapter_title"] as? String ?? ""
        ts = json["ts"] as? String ?? ""
        replies = (json["replies"] as? [[String: Any]] ?? []).map(NookReply.init(json:))
    }

    var meta: String {
        "《\(bookTitle)》 · \(chapterTitle.isEmpty ? "这一节" : chapterTitle) · \(ts)"
    }
}

enum Nook {
    static func flag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        return (value as? Int ?? 0) != 0
    }

    /// 有几个接口回的是光秃秃的数组。
    static func array(_ path: String) async throws -> [[String: Any]] {
        let data = try await API.shared.data(path)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    static func books() async throws -> [NookBook] {
        let json = try await API.shared.request("GET", "api/nook")
        return (json["books"] as? [[String: Any]] ?? []).map(NookBook.init(json:))
    }
}

/// 封面要带登录的 cookie，所以不用 AsyncImage，自己拿、自己存一份。
@MainActor
final class NookCovers {
    static let shared = NookCovers()
    private var cache: [String: UIImage] = [:]
    private var missing: Set<String> = []

    func image(_ id: String) -> UIImage? { cache[id] }

    func load(_ id: String) async -> UIImage? {
        if let image = cache[id] { return image }
        if missing.contains(id) { return nil }
        guard let data = try? await API.shared.data("api/nook/books/\(id)/cover"),
              let image = UIImage(data: data) else {
            missing.insert(id)
            return nil
        }
        cache[id] = image
        return image
    }

    func forget(_ id: String) {
        cache[id] = nil
        missing.remove(id)
    }
}

/// 书房（暗红那间屋子）里的颜色，量自网页的 #nookSheet.room。
enum NookStyle {
    static let ink = Color(red: 0.918, green: 0.875, blue: 0.855)          // #eadfda
    static let inkDim = ink.opacity(0.56)
    static let title = Color(red: 0.941, green: 0.894, blue: 0.875)        // #f0e4df
    static let room = Color(red: 0.102, green: 0.051, blue: 0.063)         // #1a0d10
    static let cover = Color(red: 0.196, green: 0.063, blue: 0.094)        // #321018
    static let coverDetail = Color(red: 0.263, green: 0.082, blue: 0.118)  // #43151e
    static let coverInk = Color(red: 0.933, green: 0.882, blue: 0.843)     // #eee1d7
    static let button = Color(red: 0.153, green: 0.059, blue: 0.078).opacity(0.78)
    static let primary = Color(red: 0.867, green: 0.816, blue: 0.780)      // #ddd0c7
    static let primaryInk = Color(red: 0.129, green: 0.063, blue: 0.078)   // #211014
    static let line = ink.opacity(0.1)
    static let panel = Color(red: 0.051, green: 0.024, blue: 0.031).opacity(0.56)
    static let progress = Color(red: 0.561, green: 0.298, blue: 0.333)     // #8f4c55
    static let keepsake = Color(red: 0.204, green: 0.075, blue: 0.102)     // #34131a
    static let serif = "Songti SC"
}

/// 暗红的书房背景：网页同一张图，顶端对齐，上面压一层暗。
struct NookRoomBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                NookStyle.room
                Image("StudyBackdrop")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                LinearGradient(colors: [Color.black.opacity(0.1), Color.black.opacity(0.34)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.42, green: 0.14, blue: 0.17).opacity(0.18), .clear],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: geo.size.width * 0.75)
            }
        }
        .ignoresSafeArea()
    }
}

/// 书的封面：有图用图，没图就是旧书式的文字封面（衬线字、书名 + 小号作者）。
struct NookCover: View {
    let book: NookBook
    var detail = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            (detail ? NookStyle.coverDetail : NookStyle.cover)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                VStack(spacing: detail ? 10 : 6) {
                    Text(book.displayTitle)
                        .font(.custom(NookStyle.serif, size: detail ? 16 : 12.5))
                        .lineSpacing(2)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.system(size: detail ? 11 : 8, weight: .medium))
                            .tracking(0.6)
                            .foregroundStyle(NookStyle.coverInk.opacity(0.56))
                    }
                }
                .foregroundStyle(NookStyle.coverInk)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, detail ? 12 : 6)
                .padding(.vertical, 9)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: detail ? 3 : 2, bottomLeadingRadius: detail ? 3 : 2,
                                          bottomTrailingRadius: detail ? 6 : 4, topTrailingRadius: detail ? 6 : 4))
        // 书脊：左边一道亮、右边一道暗；左下压一道硬影子，像立在架子上。
        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 2) }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1) }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 4, topTrailingRadius: 4)
                .fill(Color(red: 0.035, green: 0.016, blue: 0.024))
                .offset(x: detail ? -5 : -3, y: detail ? 4 : 2)
        )
        .shadow(color: .black.opacity(detail ? 0.46 : 0.48), radius: detail ? 17 : 6.5, x: detail ? 10 : 4, y: detail ? 18 : 7)
        .task(id: book.id) {
            image = NookCovers.shared.image(book.id)
            if image == nil, book.hasCover { image = await NookCovers.shared.load(book.id) }
        }
        .accessibilityLabel("《\(book.displayTitle)》")
    }
}

/// 书房里的按钮：暗红半透明，主按钮是米色。
struct NookButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(primary ? NookStyle.primaryInk : NookStyle.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(primary ? NookStyle.primary : NookStyle.button))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(primary ? .clear : NookStyle.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
