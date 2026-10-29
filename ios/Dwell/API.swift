import CryptoKit
import Foundation

/// 跟 dwell 后端说话的那一层。登录用的是网页同一套：POST /api/login 拿签名 cookie，
/// 之后 URLSession 自己带着（HTTPCookieStorage 会存到磁盘，重开 app 不用重新登录）。
struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
}

final class API {
    static let shared = API()

    private static let baseKey = "dwell.baseURL"

    var baseURL: URL? {
        get { UserDefaults.standard.string(forKey: Self.baseKey).flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: Self.baseKey) }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        // 长轮询最多挂 30 秒，留点余量。
        config.timeoutIntervalForRequest = 45
        return URLSession(configuration: config)
    }()

    /// 用户可能只填 dwell.example.com，补上 https:// 和去掉末尾的斜杠。
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    // MARK: - 底层

    /// remember：GET 回来的原样存一份在手机上，下次打开先拿它摆出来（见 ResponseCache）。
    func request(_ method: String, _ path: String,
                         query: [String: String] = [:],
                         body: [String: Any]? = nil,
                         timeout: TimeInterval? = nil,
                         remember: Bool = false) async throws -> [String: Any] {
        guard let base = baseURL,
              var components = URLComponents(url: base.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw APIError(status: 0, message: "还没填服务器地址")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            // FastAPI 的 HTTPException 把原因放在 detail 里。
            let detail = json["detail"] as? String
            throw APIError(status: status, message: detail ?? "服务器返回了 \(status)")
        }
        if remember && method == "GET" { ResponseCache.save(data, path: path, query: query) }
        return json
    }

    /// 上次存下的那份；没存过是 nil。
    func remembered(_ path: String, query: [String: String] = [:]) -> [String: Any]? {
        ResponseCache.load(path: path, query: query)
    }

    // MARK: - 登录

    func login(user: String, password: String) async throws {
        _ = try await request("POST", "api/login", body: ["user": user, "password": password])
    }

    func logout() async {
        _ = try? await request("POST", "api/logout")
        ResponseCache.clear()
        if let base = baseURL, let cookies = HTTPCookieStorage.shared.cookies(for: base) {
            cookies.forEach(HTTPCookieStorage.shared.deleteCookie)
        }
    }

    func isAuthed() async -> Bool {
        await authState() ?? false
    }

    /// 登着没有：true / false；连不上服务器是 nil（这时候不该把人赶回登录页）。
    func authState() async -> Bool? {
        do {
            let json = try await request("GET", "api/me")
            return json["authed"] as? Bool ?? false
        } catch let error as APIError {
            return error.isUnauthorized ? false : nil
        } catch {
            return nil
        }
    }

    // MARK: - 助手和聊天

    func assistant() async throws -> AssistantInfo {
        AssistantInfo(json: try await request("GET", "api/assistant", remember: true))
    }

    func switchAssistant(_ id: String) async throws -> AssistantInfo {
        AssistantInfo(json: try await request("POST", "api/assistant", body: ["assistant": id]))
    }

    /// scope：live（Recents）/ box（收纳起来的）
    func chats(scope: String = "live") async throws -> [ChatSummary] {
        let json = try await request("GET", "api/chats", query: ["scope": scope], remember: true)
        return Self.chatList(json)
    }

    func rememberedChats(scope: String = "live") -> [ChatSummary]? {
        remembered("api/chats", query: ["scope": scope]).map(Self.chatList)
    }

    private static func chatList(_ json: [String: Any]) -> [ChatSummary] {
        (json["items"] as? [[String: Any]] ?? []).map(ChatSummary.init(json:))
    }

    func switchChat(_ id: String) async throws {
        _ = try await request("POST", "api/chats", body: ["action": "switch", "id": id])
    }

    func renameChat(_ id: String, name: String) async throws {
        _ = try await request("POST", "api/chats", body: ["action": "rename", "id": id, "name": name])
    }

    func archiveChat(_ id: String, archived: Bool) async throws {
        _ = try await request("POST", "api/chats", body: ["action": "archive", "id": id, "archived": archived])
    }

    func deleteChat(_ id: String) async throws {
        _ = try await request("DELETE", "api/chats/\(id)")
    }

    func newChat() async throws {
        _ = try await request("POST", "api/newchat", body: ["arm": true])
    }

    // MARK: - 消息

    /// 最近的一页；传 before 就是比这条更早的一页。
    func messages(chatID: String, limit: Int = 200, before: Int? = nil) async throws -> (msgs: [Message], more: Bool) {
        var query = ["chat_id": chatID, "limit": String(limit)]
        if let before { query["before"] = String(before) }
        // 只存每间聊天最近的那一页（连着里面的照片），往上翻的不存。
        let json = try await request("GET", "api/messages", query: query, remember: before == nil)
        return Self.messagePage(json)
    }

    func rememberedMessages(chatID: String, limit: Int = 200) -> (msgs: [Message], more: Bool)? {
        remembered("api/messages", query: ["chat_id": chatID, "limit": String(limit)]).map(Self.messagePage)
    }

    private static func messagePage(_ json: [String: Any]) -> (msgs: [Message], more: Bool) {
        ((json["msgs"] as? [[String: Any]] ?? []).map(Message.init(json:)), json["more"] as? Bool ?? false)
    }

    func send(text: String, chatID: String, images: [PendingImage] = [], files: [PendingFile] = [],
              voice: Bool? = nil, replyLanguage: String? = nil, memoryCardIDs: [String] = [],
              quoteMessageID: String? = nil) async throws {
        var body: [String: Any] = [
            "text": text,
            "chat_id": chatID,
            "device_time": Self.deviceTime(),
        ]
        // 跟网页一样把页面上看到的开关一起带上：开关刚点完就发，那次保存可能还在路上。
        if let voice { body["voice"] = voice }
        if let replyLanguage { body["reply_language"] = replyLanguage }
        var attachments: [[String: Any]] = images.map {
            ["kind": "image", "media_type": "image/jpeg", "data": $0.data, "preview": $0.preview]
        }
        attachments += files.map(\.payload)
        if !attachments.isEmpty { body["attachments"] = attachments }
        if !memoryCardIDs.isEmpty { body["memory_card_ids"] = memoryCardIDs }
        if let quoteMessageID { body["quote_message_id"] = quoteMessageID }
        _ = try await request("POST", "api/send", body: body)
    }

    /// 拿原始字节（语音）。
    func data(_ path: String, query: [String: String] = [:]) async throws -> Data {
        guard let base = baseURL else { throw APIError(status: 0, message: "还没填服务器地址") }
        var url = base.appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = parts.url ?? url
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError(status: status, message: json?["detail"] as? String ?? "服务器返回了 \(status)")
        }
        return data
    }

    /// multipart/form-data 传一个文件（导入 Kelivo 用）。
    func multipart(_ path: String, field: String, filename: String, data fileData: Data) async throws -> [String: Any] {
        guard let base = baseURL else { throw APIError(status: 0, message: "还没填服务器地址") }
        let boundary = "dwell-" + UUID().uuidString
        var body = Data()
        let safeName = filename.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), json["ok"] as? Bool != false else {
            throw APIError(status: status, message: json["detail"] as? String ?? "服务器返回了 \(status)")
        }
        return json
    }

    /// 大文件分块传：跟网页的 bigUpload 一样，4MB 一块，传完服务器读成文字暂存。
    func upload(fileData: Data, name: String, progress: (Double) -> Void) async throws -> (id: String, truncated: Bool) {
        guard let base = baseURL else { throw APIError(status: 0, message: "还没填服务器地址") }
        let chunk = 4 * 1024 * 1024
        let total = max(1, Int(ceil(Double(fileData.count) / Double(chunk))))
        var uploadID = ""
        var truncated = false
        for index in 0..<total {
            let last = index == total - 1
            var components = URLComponents(url: base.appendingPathComponent("api/upload"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "idx", value: String(index)),
                URLQueryItem(name: "done", value: last ? "1" : "0"),
            ] + (uploadID.isEmpty ? [] : [URLQueryItem(name: "id", value: uploadID)])
            var req = URLRequest(url: components.url!)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            let slice = fileData.subdata(in: (index * chunk)..<min(fileData.count, (index + 1) * chunk))
            let (data, response) = try await session.upload(for: req, from: slice)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(status), json["ok"] as? Bool == true else {
                throw APIError(status: status, message: json["detail"] as? String ?? "第 \(index + 1) 块没传过去")
            }
            uploadID = json["id"] as? String ?? uploadID
            truncated = json["truncated"] as? Bool ?? false
            progress(Double(index + 1) / Double(total))
        }
        return (uploadID, truncated)
    }

    func editMessage(_ id: String, content: String) async throws {
        _ = try await request("PATCH", "api/messages/\(id)", body: ["content": content])
    }

    func deleteMessage(_ id: String) async throws {
        _ = try await request("DELETE", "api/messages/\(id)")
    }

    func regenerate(_ id: String) async throws {
        _ = try await request("POST", "api/messages/\(id)/regenerate")
    }

    func stop() async throws {
        _ = try await request("POST", "api/stop")
    }

    /// 长轮询。服务端会把过大的 since 收敛到当前事件末尾，所以第一次传一个很大的数就是"从现在开始"。
    func poll(chatID: String, since: Int) async throws -> (next: Int, events: [[String: Any]]) {
        let json = try await request("GET", "api/poll",
                                     query: ["chat_id": chatID, "since": String(since), "timeout": "25"],
                                     timeout: 40)
        let next = (json["next"] as? Int) ?? since
        return (next, json["events"] as? [[String: Any]] ?? [])
    }

    /// 跟网页一样，发消息时带上手机此刻的时间，不写进聊天记录。
    private static func deviceTime() -> [String: Any] {
        let now = Date()
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US")
        local.dateStyle = .full
        local.timeStyle = .medium
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "local": local.string(from: now),
            "iso": iso.string(from: now),
            "time_zone": TimeZone.current.identifier,
            "offset_minutes": TimeZone.current.secondsFromGMT(for: now) / 60,
        ]
    }
}

/// 存在手机上的那一份：GET 回来的原样 JSON，一个请求一个文件。打开页面先拿它摆出来，
/// 再去服务器问新的，有新的就换上。放在 Caches 里，系统空间紧时可能清掉，清了也就是下次慢一点；
/// 只在 app 自己的空间里，锁屏时系统加密；退出登录时全删。
enum ResponseCache {
    private static let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("dwell-responses", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(path: String, query: [String: String]) -> URL? {
        let key = path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name + ".json")
    }

    static func save(_ data: Data, path: String, query: [String: String]) {
        guard let url = file(path: path, query: query) else { return }
        // 聊天那一页带着照片，可能有几 MB：放到后台写，不卡界面。
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func load(path: String, query: [String: String]) -> [String: Any]? {
        guard let url = file(path: path, query: query), let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func clear() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
