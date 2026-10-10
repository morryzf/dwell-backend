import SwiftUI
import UIKit

/// 选好、还没发出去的一张图。跟网页的 shrinkImage 一样：
/// 原图缩到长边 1568 给模型看，另做一张长边 640 的缩略图存进聊天记录。
struct PendingImage: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    /// 给模型的 JPEG，base64。
    let data: String
    /// 存进记录的缩略图，base64。
    let preview: String

    /// 后端单张上限 1,500,000 个 base64 字符。
    private static let maxBase64 = 1_450_000

    init?(imageData: Data) {
        guard let source = UIImage(data: imageData) else { return nil }
        var side: CGFloat = 1568
        var encoded: String?
        var full = source
        // 先降质量，还太大再缩尺寸。照片一般第一轮就够了。
        while encoded == nil && side >= 600 {
            full = Self.resize(source, maxSide: side)
            for quality in [0.85, 0.7, 0.55] {
                if let jpeg = full.jpegData(compressionQuality: quality) {
                    let b64 = jpeg.base64EncodedString()
                    if b64.count <= Self.maxBase64 { encoded = b64; break }
                }
            }
            side *= 0.75
        }
        let thumb = Self.resize(full, maxSide: 640)
        guard let encoded,
              let thumbData = thumb.jpegData(compressionQuality: 0.72) else { return nil }
        self.thumbnail = thumb
        self.data = encoded
        self.preview = thumbData.base64EncodedString()
    }

    var previewDataURL: String { "data:image/jpeg;base64,\(preview)" }

    static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// 聊天记录里的图是 data URL，解码一次就记住，滚动时不反复解。
enum DataURLImage {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ url: String) -> UIImage? {
        let key = url as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct MessageImage: View {
    let url: String
    @State private var showFull = false

    var body: some View {
        if let image = DataURLImage.image(url) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { showFull = true }
                .fullScreenCover(isPresented: $showFull) {
                    FullImageView(image: image)
                }
        }
    }
}

struct FullImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * pinch)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in scale = min(max(scale * value.magnification, 1), 5) }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring) { scale = scale > 1 ? 1 : 2.5 }
                }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
            }
            .padding()
            .accessibilityLabel("关闭")
        }
    }
}

/// 选好、还没发出去的一个文件。跟网页的 takeFiles 一样：
/// 小的纯文本文件读成文字直接带上；别的（PDF、大文件）先分块传上去，服务器读成文字暂存。
struct PendingFile: Identifiable {
    enum Content {
        case text(String)
        case upload(id: String)
    }

    let id = UUID()
    let name: String
    let content: Content

    var payload: [String: Any] {
        switch content {
        case .text(let text): return ["kind": "text", "name": name, "text": text]
        case .upload(let id): return ["kind": "upload", "id": id, "name": name]
        }
    }

    /// 网页 TEXT_EXT 那一串。
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "log", "yaml", "yml", "xml", "html", "htm",
        "css", "js", "ts", "py", "sh", "ini", "conf", "toml", "sql", "srt", "vtt",
    ]

    /// 小于 200KB 的纯文本：直接读成文字。
    static func inlineText(name: String, data: Data) -> PendingFile? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard data.count < 200 * 1024, textExtensions.contains(ext),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return PendingFile(name: name, content: .text(text))
    }
}
