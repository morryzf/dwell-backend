import SwiftUI
import UIKit

// MARK: - 他的读书笔记

struct NookReadingNotes: View {
    let bookID: String
    @State private var items: [NookNote] = []
    @State private var loaded = false
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PaperHeading(title: "Cloudy 的读书笔记", subtitle: "这是读完每一小段留下的正式笔记，你可以进来看。")
                if loaded && items.isEmpty {
                    Text("还没有笔记。Cloudy 第一次读完后会把它留在这里。")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim).padding(.top, 20)
                }
                if !error.isEmpty { Text(error).font(.system(size: 13)).foregroundStyle(MemoryStyle.danger) }
                ForEach(items) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.meta).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                        Text(note.text)
                            .font(.system(size: 15))
                            .lineSpacing(15 * 0.75)
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    }
                    .nookCard()
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .nookPaper()
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let json = try await API.shared.request("GET", "api/nook/reading-notes")
            items = (json["items"] as? [[String: Any]] ?? []).map(NookNote.init(json:)).filter { $0.bookID == bookID }
            loaded = true
        } catch {
            self.error = (error as? APIError)?.message ?? "笔记没拿到"
        }
    }
}

// MARK: - 想和小猫分享的

struct NookShares: View {
    let bookID: String
    @State private var items: [NookNote] = []
    @State private var loaded = false
    @State private var drafts: [String: String] = [:]
    @State private var sending = ""
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                PaperHeading(title: "想和小猫分享的",
                             subtitle: "不是即时聊天。你留话后，他会在下一次安排的书房时间先单独回信，再继续读书。")
                if loaded && items.isEmpty {
                    Text("本子还是空的。等 Cloudy 读到真想告诉你的地方，他会自己写在这里。")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim).lineSpacing(4).padding(.top, 20)
                }
                if !error.isEmpty { Text(error).font(.system(size: 13)).foregroundStyle(MemoryStyle.danger) }
                ForEach(items) { share in card(share) }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .nookPaper()
        .task { await load() }
        .refreshable { await load() }
    }

    private func card(_ share: NookNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(share.meta).font(.system(size: 11.5)).foregroundStyle(Theme.dim).padding(.bottom, 9)
            Text(share.text)
                .font(.system(size: 15.5))
                .lineSpacing(15.5 * 0.75)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            if !share.anchor.isEmpty {
                Text(share.anchor)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.dim)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 11)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.dim).frame(width: 2) }
                    .padding(.vertical, 10)
            }
            ForEach(share.replies) { reply in
                VStack(alignment: .leading, spacing: 3) {
                    Text(reply.text).font(.system(size: 14)).lineSpacing(5).foregroundStyle(Theme.text)
                    Text("\(reply.fromUser ? "小猫" : "Cloudy") · \(reply.ts)").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(reply.fromUser ? MemoryStyle.sage.opacity(0.34) : Theme.text.opacity(0.06)))
                .padding(.leading, reply.fromUser ? 40 : 0)
                .padding(.trailing, reply.fromUser ? 0 : 40)
                .padding(.top, 10)
            }
            NookComposer(text: Binding(get: { drafts[share.id] ?? "" }, set: { drafts[share.id] = $0 }),
                         placeholder: "在这页回他一句…", busy: sending == share.id) {
                Task { await reply(share) }
            }
            .padding(.top, 14)
        }
        .nookCard()
    }

    private func load() async {
        do {
            let json = try await API.shared.request("GET", "api/nook/shares")
            items = (json["items"] as? [[String: Any]] ?? []).map(NookNote.init(json:)).filter { $0.bookID == bookID }
            loaded = true
        } catch {
            self.error = (error as? APIError)?.message ?? "分享本没拿到"
        }
    }

    private func reply(_ share: NookNote) async {
        let text = (drafts[share.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = share.id
        defer { sending = "" }
        do {
            _ = try await API.shared.request("POST", "api/nook/shares/\(share.id)/reply", body: ["text": text])
            drafts[share.id] = ""
            error = ""
            await load()
        } catch {
            self.error = "（这句没有夹进本子）"
        }
    }
}

// MARK: - 翻书

struct NookReader: View {
    let bookID: String
    let startIndex: Int

    @State private var index = 0
    @State private var bookTitle = ""
    @State private var title = ""
    @State private var paragraphs: [String] = []
    @State private var total = 0
    @State private var chapters: [String] = []
    @State private var annotations: [NookNote] = []
    @State private var note = "正在翻开…"
    @State private var showTOC = false
    @State private var anchorSheet: AnchorSheet?
    @State private var flash = ""

    struct AnchorSheet: Identifiable {
        let anchor: String
        var id: String { anchor }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bookTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            if paragraphs.isEmpty {
                Text(note).font(.system(size: 14.5)).foregroundStyle(Theme.dim).padding(.top, 80)
                Spacer()
            } else {
                NookTextView(
                    paragraphs: paragraphs,
                    marks: annotations.map { (anchor: $0.anchor, has: !$0.replies.isEmpty) },
                    resetKey: "\(bookID)-\(index)",
                    onUnderline: { text in Task { await underline(text) } },
                    onWrite: { text in anchorSheet = AnchorSheet(anchor: text) },
                    onTapMark: { anchor in anchorSheet = AnchorSheet(anchor: anchor) }
                )
            }

            HStack(spacing: 10) {
                Button("上一节") { Task { await open(index - 1) } }
                    .disabled(index <= 0)
                Button("下一节") { Task { await open(index + 1) } }
                    .disabled(index + 1 >= total)
            }
            .buttonStyle(NookNavStyle())
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                if !flash.isEmpty {
                    Text(flash).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.chip))
                        .offset(y: -44)
                        .transition(.opacity)
                }
            }
        }
        .nookPaper()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("目录") { showTOC = true }.disabled(chapters.isEmpty)
            }
        }
        .task { await open(startIndex) }
        .sheet(isPresented: $showTOC) { toc }
        .sheet(item: $anchorSheet, onDismiss: { Task { await loadAnnotations() } }) { item in
            NookAnchorSheet(bookID: bookID, chapter: index, anchor: item.anchor,
                            notes: annotations.filter { $0.anchor.trimmingCharacters(in: .whitespacesAndNewlines) == item.anchor })
        }
    }

    private var subtitle: String {
        guard total > 0 else { return " " }
        var text = "\(title.isEmpty ? "第 \(index + 1) 节" : title) · \(index + 1)/\(total)"
        let marked = Set(annotations.map(\.anchor)).count
        if marked > 0 { text += " · 标了 \(marked) 处，点划线的地方看" }
        return text
    }

    private var toc: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters.indices, id: \.self) { i in
                    Button {
                        showTOC = false
                        Task { await open(i) }
                    } label: {
                        Text("\(i + 1). \(chapters[i].isEmpty ? "第 \(i + 1) 节" : chapters[i])")
                            .font(.system(size: 15, weight: i == index ? .semibold : .regular))
                            .foregroundStyle(Theme.text)
                    }
                    .listRowBackground(i == index ? Theme.bubble : Color.clear)
                    .id(i)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(index, anchor: .center) }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("好") { showTOC = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func open(_ target: Int) async {
        guard target >= 0 else { return }
        do {
            let json = try await API.shared.request("GET", "api/nook/chapter/\(bookID)/\(target)")
            index = json["index"] as? Int ?? target
            bookTitle = json["book"] as? String ?? ""
            title = json["title"] as? String ?? ""
            total = json["total"] as? Int ?? 0
            chapters = json["chapters"] as? [String] ?? chapters
            paragraphs = (json["text"] as? String ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            await loadAnnotations()
        } catch {
            note = (error as? APIError)?.message ?? "这一节没翻开"
        }
    }

    private func loadAnnotations() async {
        annotations = ((try? await Nook.array("api/nook/annotations/\(bookID)/\(index)")) ?? []).map(NookNote.init(json:))
    }

    private func underline(_ text: String) async {
        do {
            _ = try await API.shared.request("POST", "api/nook/annotations/\(bookID)/\(index)",
                                             body: ["anchor": text, "note": "", "who": "user"])
            await loadAnnotations()
            show("划好了")
        } catch {
            show("（没划上）")
        }
    }

    private func show(_ text: String) {
        withAnimation { flash = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { flash = "" }
        }
    }
}

private struct NookNavStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.bubble))
            .opacity(enabled ? 1 : 0.32)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// 正文：纸书的字号和行距（17.5 / 2.05 倍、段首空两格）。
/// 长按选字后菜单里多两项「划线」「写一句」；划过的地方垫一层浅底，点它看那一句的笔记。
struct NookTextView: UIViewRepresentable {
    let paragraphs: [String]
    let marks: [(anchor: String, has: Bool)]
    let resetKey: String
    let onUnderline: (String) -> Void
    let onWrite: (String) -> Void
    let onTapMark: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 18, left: 18, bottom: 40, right: 18)
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        view.linkTextAttributes = [:]
        view.adjustsFontForContentSizeCategory = false
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let signature = resetKey + "|" + marks.map { "\($0.anchor)\($0.has)" }.joined(separator: "\u{1}")
        guard signature != context.coordinator.signature else { return }
        let newPage = !context.coordinator.signature.hasPrefix(resetKey + "|")
        context.coordinator.signature = signature
        let offset = view.contentOffset
        view.attributedText = attributed()
        if newPage {
            view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
        } else {
            view.layoutIfNeeded()
            view.setContentOffset(offset, animated: false)
        }
    }

    private func attributed() -> NSAttributedString {
        let size: CGFloat = 17.5
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = size * 2
        style.minimumLineHeight = size * 2.05
        style.maximumLineHeight = size * 2.05
        style.paragraphSpacing = size * 1.15 - size * 1.05
        let text = UIColor(Theme.text)
        let dim = UIColor(Theme.dim)
        let out = NSMutableAttributedString()
        for (i, paragraph) in paragraphs.enumerated() {
            let piece = NSMutableAttributedString(string: paragraph + (i == paragraphs.count - 1 ? "" : "\n"), attributes: [
                .font: UIFont.systemFont(ofSize: size),
                .foregroundColor: text,
                .paragraphStyle: style,
            ])
            // 跟网页一样：每一段里找划过的句子，重叠的只认先出现的那条。
            var hits: [(NSRange, String, Bool)] = []
            let ns = paragraph as NSString
            for mark in marks {
                let anchor = mark.anchor.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !anchor.isEmpty else { continue }
                let range = ns.range(of: anchor)
                if range.location != NSNotFound { hits.append((range, anchor, mark.has)) }
            }
            var end = 0
            for (range, anchor, has) in hits.sorted(by: { $0.0.location < $1.0.location }) where range.location >= end {
                var attrs: [NSAttributedString.Key: Any] = [
                    .backgroundColor: dim.withAlphaComponent(has ? 0.32 : 0.2),
                    .link: URL(string: "nook://mark?a=" + (anchor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!,
                ]
                if has {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.underlineColor] = dim.withAlphaComponent(0.8)
                }
                piece.addAttributes(attrs, range: range)
                end = range.location + range.length
            }
            out.append(piece)
        }
        return out
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NookTextView?
        var signature = ""

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let picked = (textView.text as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !picked.isEmpty, picked.count <= 280, let parent else {
                return UIMenu(children: suggestedActions)
            }
            let underline = UIAction(title: "划线", image: UIImage(systemName: "highlighter")) { _ in
                textView.selectedRange = NSRange(location: range.location, length: 0)
                parent.onUnderline(picked)
            }
            let write = UIAction(title: "写一句", image: UIImage(systemName: "text.bubble")) { _ in
                textView.selectedRange = NSRange(location: range.location, length: 0)
                parent.onWrite(picked)
            }
            return UIMenu(children: [underline, write] + suggestedActions)
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, url.scheme == "nook" else { return defaultAction }
            let anchor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "a" }?.value ?? ""
            return UIAction { [weak self] _ in self?.parent?.onTapMark(anchor) }
        }
    }
}

/// 「这一句」：划过的那句话、她和他在页边说过的话，下面一个输入框。
struct NookAnchorSheet: View {
    let bookID: String
    let chapter: Int
    let anchor: String
    let notes: [NookNote]

    @Environment(\.dismiss) private var dismiss
    @State private var items: [NookNote] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(anchor)
                        .font(.system(size: 14.5))
                        .lineSpacing(6)
                        .foregroundStyle(Theme.dim)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.bubbleBorder).frame(width: 3) }
                    ForEach(items) { note in
                        if !note.text.isEmpty { bubble(note.text, user: note.who == "user", ts: note.ts) }
                        ForEach(note.replies) { reply in bubble(reply.text, user: reply.fromUser, ts: reply.ts) }
                    }
                    if !error.isEmpty { Text(error).font(.system(size: 13)).foregroundStyle(MemoryStyle.danger) }
                    NookComposer(text: $draft, placeholder: items.contains { !$0.text.isEmpty || !$0.replies.isEmpty } ? "再说一句…" : "想说点什么",
                                 busy: busy) {
                        Task { await send() }
                    }
                }
                .padding(20)
            }
            .background(PaperBackground().ignoresSafeArea())
            .navigationTitle("这一句")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } }
            }
            .onAppear { items = notes }
        }
        .presentationDetents([.medium, .large])
    }

    private func bubble(_ text: String, user: Bool, ts: String) -> some View {
        VStack(alignment: user ? .trailing : .leading, spacing: 5) {
            Text(text)
                .font(.system(size: 15.5))
                .lineSpacing(6)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, user ? 16 : 0)
                .padding(.vertical, user ? 10 : 0)
                .background {
                    if user { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble) }
                }
            Text(ts).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
        .padding(user ? .leading : .trailing, 40)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            if let first = items.first {
                _ = try await API.shared.request("POST", "api/nook/annotations/\(bookID)/\(chapter)/\(first.id)/reply",
                                                 body: ["text": text, "who": "user"])
            } else {
                _ = try await API.shared.request("POST", "api/nook/annotations/\(bookID)/\(chapter)",
                                                 body: ["anchor": anchor, "note": text, "who": "user"])
            }
            draft = ""
            error = ""
            let all = (try? await Nook.array("api/nook/annotations/\(bookID)/\(chapter)")) ?? []
            items = all.map(NookNote.init(json:)).filter { $0.anchor.trimmingCharacters(in: .whitespacesAndNewlines) == anchor }
        } catch {
            self.error = (error as? APIError)?.message ?? "没写上，再试一次"
        }
    }
}

// MARK: - 小零件

/// 跟聊天输入框一样：一块圆角玻璃、透明的输入、一颗粉色的圆按钮。
struct NookComposer: View {
    @Binding var text: String
    let placeholder: String
    let busy: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .padding(.vertical, 6)
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
            .accessibilityLabel("送出")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.composer))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.composerBorder, lineWidth: 1))
    }
}

struct PaperHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, design: .serif)).foregroundStyle(Theme.text)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.dim).lineSpacing(3)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

extension View {
    func nookCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bubble))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
    }
}
