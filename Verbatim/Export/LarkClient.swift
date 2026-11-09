import Foundation

/// Lark (international) or Feishu (China). Same API, different hosts.
nonisolated enum LarkRegion: String, Codable, CaseIterable, Sendable, Identifiable {
    case lark
    case feishu

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lark: "Lark (larksuite.com)"
        case .feishu: "飞书 Feishu (feishu.cn)"
        }
    }

    var apiBase: URL {
        switch self {
        case .lark: URL(string: "https://open.larksuite.com/open-apis/")!
        case .feishu: URL(string: "https://open.feishu.cn/open-apis/")!
        }
    }

    /// Where a doc opens when the API doesn't return its own link.
    var webBase: String {
        switch self {
        case .lark: "https://www.larksuite.com"
        case .feishu: "https://www.feishu.cn"
        }
    }

    var consoleURL: URL {
        switch self {
        case .lark: URL(string: "https://open.larksuite.com/app")!
        case .feishu: URL(string: "https://open.feishu.cn/app")!
        }
    }
}

nonisolated enum LarkError: LocalizedError {
    case missingCredentials
    case noDestination
    case badCredentials(String)
    case missingScope(String)
    case forbidden(String)
    case api(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Add your Lark app ID and secret in Settings → Lark."
        case .noDestination:
            "Add your Lark email (or a folder link) in Settings → Lark, so the doc ends up somewhere you can see it."
        case let .badCredentials(message):
            "Lark rejected the app ID or secret (\(message)). Copy them again from the app's Credentials page in the developer console."
        case let .missingScope(message):
            "The Lark app is missing a permission (\(message)). In the developer console add docx:document and drive:drive under Permissions, then publish a new version of the app."
        case let .forbidden(message):
            "Lark refused access (\(message)). If you set a folder, share it with the app first, or leave the folder empty."
        case let .api(code, message):
            "Lark error \(code): \(message)"
        case .invalidResponse:
            "Unexpected response from Lark."
        }
    }
}

/// Thin Lark / Feishu Open Platform client. Signs in as a custom app
/// (app ID + secret → tenant access token) and retries rate limits.
nonisolated struct LarkClient: Sendable {
    let region: LarkRegion
    let appID: String
    let appSecret: String

    /// A tenant access token for the app (valid about two hours).
    func tenantToken() async throws -> String {
        let json = try await send("POST", "auth/v3/tenant_access_token/internal",
                                  body: ["app_id": appID.trimmed, "app_secret": appSecret.trimmed], token: nil)
        guard let token = json["tenant_access_token"] as? String, !token.isEmpty else { throw LarkError.invalidResponse }
        return token
    }

    /// The `data` object of a successful call.
    func call(_ method: String, _ path: String, body: [String: Any]? = nil, token: String) async throws -> [String: Any] {
        let json = try await send(method, path, body: body, token: token)
        return json["data"] as? [String: Any] ?? [:]
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: region.apiBase)!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        request.timeoutInterval = 60

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LarkError.invalidResponse }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = json["code"] as? Int ?? (http.statusCode == 200 ? 0 : -1)
            let message = json["msg"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)

            if (200..<300).contains(http.statusCode), code == 0 { return json }
            if Self.isRetryable(status: http.statusCode, code: code), attempt < 6 {
                let retryAfter = Double(http.value(forHTTPHeaderField: "x-ogw-ratelimit-reset") ?? "")
                    ?? Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
                    ?? pow(2, Double(attempt - 1))
                try await Task.sleep(for: .seconds(min(max(retryAfter, 0.5), 30)))
                continue
            }
            Log.lark.error("Lark \(method) \(path) failed \(http.statusCode) code \(code): \(message)")
            throw Self.error(status: http.statusCode, code: code, message: message)
        }
    }

    static func isRetryable(status: Int, code: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(status) || code == 99991400
    }

    static func error(status: Int, code: Int, message: String) -> LarkError {
        switch code {
        case 10003, 10014, 99991661, 99991663, 99991664, 99991668:
            return .badCredentials(message)
        case 99991672, 99991679:
            return .missingScope(message)
        default:
            if status == 401 { return .badCredentials(message) }
            if status == 403 { return .forbidden(message) }
            return .api(code, message)
        }
    }

    // MARK: Helpers

    /// The folder token inside whatever the user pasted: a bare token or a
    /// link such as https://xxx.feishu.cn/drive/folder/<token>?from=...
    static func folderToken(_ raw: String) -> String {
        let text = raw.trimmed
        guard !text.isEmpty else { return "" }
        let path = text.split(separator: "?", maxSplits: 1).first.map(String.init) ?? text
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Checks the credentials and, when set, that the app can see the folder.
    /// Returns a short line for Settings.
    func check(folder: String) async throws -> String {
        let token = try await tenantToken()
        let folderToken = Self.folderToken(folder)
        guard !folderToken.isEmpty else { return "Signed in as the app." }
        let data = try await call("GET", "drive/explorer/v2/folder/\(folderToken)/meta", token: token)
        let name = (data["name"] as? String)?.trimmed ?? ""
        return name.isEmpty ? "Signed in. Folder found." : "Signed in. Folder \u{201C}\(name)\u{201D} found."
    }
}
