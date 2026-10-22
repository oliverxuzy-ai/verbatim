import Foundation

nonisolated enum NotionError: LocalizedError {
    case missingToken
    case unauthorized
    case notFound(String)
    case api(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Add a Notion token in Settings → Notion."
        case .unauthorized:
            "Notion rejected the token. Create a new one at notion.so/developers and paste it in Settings."
        case let .notFound(what):
            "Notion can't find \(what). If you use an integration token, open the database in Notion → ••• → Connections and add your integration. A personal access token works without sharing."
        case let .api(code, message):
            "Notion error \(code): \(message)"
        case .invalidResponse:
            "Unexpected response from Notion."
        }
    }
}

/// Thin Notion REST client (API version 2026-03-11) with rate-limit retries.
nonisolated struct NotionClient: Sendable {
    let token: String
    static let version = "2026-03-11"
    private static let base = URL(string: "https://api.notion.com/v1/")!

    func get(_ path: String) async throws -> [String: Any] {
        try await send("GET", path, body: nil)
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await send("POST", path, body: body)
    }

    func patch(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await send("PATCH", path, body: body)
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.base)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        request.timeoutInterval = 60

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            switch http.statusCode {
            case 200..<300:
                return json
            case let code where [429, 500, 502, 503, 504].contains(code) && attempt < 6:
                let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt - 1))
                try await Task.sleep(for: .seconds(min(retryAfter, 30)))
                continue
            case 401:
                throw NotionError.unauthorized
            default:
                let message = json["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
                if http.statusCode == 404 || (json["code"] as? String) == "object_not_found" {
                    throw NotionError.notFound(message)
                }
                Log.notion.error("Notion \(method) \(path) failed \(http.statusCode): \(message)")
                throw NotionError.api(http.statusCode, message)
            }
        }
    }

    // MARK: Helpers

    /// The 32-hex Notion ID inside whatever the user pasted: a bare ID (with
    /// or without dashes), a collection:// URL, or a page/database link such
    /// as https://app.notion.com/p/<id>?v=<view>. The view ID in the query
    /// string is ignored.
    static func normalizedID(_ raw: String) -> String {
        let text = raw.trimmed
        // Drop the query string (it carries the view ID, not the database).
        let candidate = text.split(separator: "?", maxSplits: 1).first.map(String.init) ?? text
        let hex = candidate.replacingOccurrences(of: "-", with: "")
        let matches = hex.matches(of: /[0-9a-fA-F]{32}/).map { String($0.output) }
        guard let id = matches.last?.lowercased() else { return text }
        let parts = [id.prefix(8), id.dropFirst(8).prefix(4), id.dropFirst(12).prefix(4), id.dropFirst(16).prefix(4), id.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    /// Data source schema: property name → (id, type). Accepts a database
    /// ID (or link) too and resolves its first data source.
    func dataSourceSchema(_ raw: String) async throws -> (dataSourceID: String, properties: [String: String]) {
        let id = Self.normalizedID(raw)
        do {
            let ds = try await get("data_sources/\(id)")
            return (ds["id"] as? String ?? id, Self.propertyTypes(ds))
        } catch NotionError.unauthorized {
            throw NotionError.unauthorized
        } catch {
            // Probably a database ID (or link): resolve its first data source.
            let db = try await get("databases/\(id)")
            guard let sources = db["data_sources"] as? [[String: Any]], let first = sources.first?["id"] as? String else {
                throw NotionError.notFound("the database \(id)")
            }
            let ds = try await get("data_sources/\(first)")
            return (first, Self.propertyTypes(ds))
        }
    }

    /// Name of a data source (or database) for display in Settings.
    func dataSourceTitle(_ id: String) async throws -> String {
        let ds = try await get("data_sources/\(id)")
        let parts = ds["title"] as? [[String: Any]] ?? []
        let title = parts.compactMap { $0["plain_text"] as? String }.joined().trimmed
        return title.isEmpty ? "Untitled" : title
    }

    private static func propertyTypes(_ object: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in object["properties"] as? [String: Any] ?? [:] {
            if let type = (value as? [String: Any])?["type"] as? String { out[name] = type }
        }
        return out
    }

    /// Workspace members with emails (for the people property).
    func workspaceMembers() async -> [(id: String, email: String, name: String)] {
        var members: [(String, String, String)] = []
        var cursor: String?
        repeat {
            let path = "users?page_size=100" + (cursor.map { "&start_cursor=\($0)" } ?? "")
            guard let page = try? await get(path) else { break }
            for user in page["results"] as? [[String: Any]] ?? [] {
                guard user["type"] as? String == "person",
                      let id = user["id"] as? String,
                      let email = (user["person"] as? [String: Any])?["email"] as? String else { continue }
                members.append((id, email.lowercased(), user["name"] as? String ?? ""))
            }
            cursor = (page["has_more"] as? Bool == true) ? page["next_cursor"] as? String : nil
        } while cursor != nil
        return members
    }
}
