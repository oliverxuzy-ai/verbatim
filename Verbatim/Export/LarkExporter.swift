import Foundation

/// Writes a recording into a new Lark / Feishu doc: a header line (date,
/// duration, attendees, meeting link), two empty sections for the user
/// (摘要, 讨论要点), and the full transcript, one paragraph per turn.
///
/// The doc is created by the app (tenant token). So the user can find it,
/// it goes into the folder they chose (shared with the app), and/or its
/// ownership is handed to their Lark account by email, which also moves it
/// into their own space.
nonisolated struct LarkExporter: Sendable {
    let client: LarkClient
    /// Folder link or token. Empty: the app's own space.
    var folder: String = ""
    /// The user's Lark login email. The doc's owner becomes this account.
    var ownerEmail: String = ""
    /// Pause between block writes: Lark allows about 3 edits per second per doc.
    var writeSpacing: Duration = .milliseconds(350)

    struct Result: Sendable {
        let url: URL
        /// Set when the doc was made but couldn't be handed to the user.
        let warning: String?
    }

    /// Lark accepts at most 50 blocks per "create children" call.
    static let batchSize = 50

    func export(_ recording: Recording) async throws -> Result {
        let folderToken = LarkClient.folderToken(folder)
        let email = ownerEmail.trimmed
        guard !folderToken.isEmpty || !email.isEmpty else { throw LarkError.noDestination }

        let token = try await client.tenantToken()
        var body: [String: Any] = ["title": String(recording.meeting.title.prefix(800))]
        if !folderToken.isEmpty { body["folder_token"] = folderToken }
        let created = try await client.call("POST", "docx/v1/documents", body: body, token: token)
        guard let documentID = (created["document"] as? [String: Any])?["document_id"] as? String else {
            throw LarkError.invalidResponse
        }

        let blocks = Self.blocks(for: recording)
        for start in stride(from: 0, to: blocks.count, by: Self.batchSize) {
            if start > 0 { try await Task.sleep(for: writeSpacing) }
            let chunk = Array(blocks[start..<min(start + Self.batchSize, blocks.count)])
            _ = try await client.call(
                "POST", "docx/v1/documents/\(documentID)/blocks/\(documentID)/children?document_revision_id=-1",
                body: ["children": chunk, "index": -1], token: token
            )
        }

        var warning: String?
        if !email.isEmpty {
            warning = await handOver(documentID, to: email, token: token)
        }
        let url = await documentURL(documentID, token: token)
        return Result(url: url, warning: warning)
    }

    /// Makes the user the owner (moving the doc into their space). If Lark
    /// refuses, adds them as a full-access collaborator instead. Returns a
    /// warning when neither worked.
    func handOver(_ documentID: String, to email: String, token: String) async -> String? {
        do {
            _ = try await client.call(
                "POST", "drive/v1/permissions/\(documentID)/members/transfer_owner?type=docx&need_notification=false&remove_old_owner=false&stay_put=false",
                body: ["member_type": "email", "member_id": email], token: token
            )
            return nil
        } catch {
            Log.lark.error("Transfer owner failed: \(error.localizedDescription)")
        }
        do {
            _ = try await client.call(
                "POST", "drive/v1/permissions/\(documentID)/members?type=docx&need_notification=false",
                body: ["member_type": "email", "member_id": email, "perm": "full_access"], token: token
            )
            return nil
        } catch {
            return "The doc was created, but Lark wouldn't share it with \(email): \(error.localizedDescription)"
        }
    }

    /// The doc's link on the user's tenant domain, or a generic one.
    func documentURL(_ documentID: String, token: String) async -> URL {
        let data = try? await client.call("POST", "drive/v1/metas/batch_query", body: [
            "request_docs": [["doc_token": documentID, "doc_type": "docx"]],
            "with_url": true,
        ], token: token)
        if let raw = (data?["metas"] as? [[String: Any]])?.first?["url"] as? String, let url = URL(string: raw) {
            return url
        }
        return URL(string: "\(client.region.webBase)/docx/\(documentID)")!
    }

    // MARK: Blocks

    static func blocks(for recording: Recording) -> [[String: Any]] {
        var out: [[String: Any]] = [header(for: recording)]
        out += [
            heading("摘要"),
            text([run(" ")]),
            heading("讨论要点"),
            ["block_type": 12, "bullet": ["elements": [run(" ")]]],
            ["block_type": 22, "divider": [String: Any]()],
            heading("逐字稿 Transcript"),
        ]
        out += transcriptBlocks(for: recording)
        return out
    }

    /// "Nov 9, 2026 at 10:00 · 42m · Attendees: … · Meeting link", in gray.
    static func header(for recording: Recording) -> [String: Any] {
        var elements = [run(TranscriptFormatter.headerLine(recording), color: gray)]
        let names = attendeeNames(recording)
        if !names.isEmpty {
            elements.append(run(" · " + names.joined(separator: ", "), color: gray))
        }
        if let link = recording.meeting.conferenceURL?.absoluteString {
            elements.append(run(" · ", color: gray))
            elements.append(["text_run": ["content": "Meeting link", "text_element_style": [
                "link": ["url": link.addingPercentEncoding(withAllowedCharacters: urlSafe) ?? link],
            ]]])
        }
        return text(elements)
    }

    /// Invited attendees plus confirmed speakers who weren't on the invite.
    static func attendeeNames(_ recording: Recording) -> [String] {
        var names: [String] = []
        for a in recording.meeting.attendees where !names.contains(a.displayName) {
            names.append(a.displayName)
        }
        for s in recording.speakers where s.isConfirmed && !s.isMe && !names.contains(s.name) {
            names.append(s.name)
        }
        return names
    }

    /// One paragraph per speaker turn: "00:12:34  Name: text".
    static func transcriptBlocks(for recording: Recording) -> [[String: Any]] {
        recording.visibleSegments.map { segment in
            var elements = [
                run("\(segment.start.clockString)  ", color: gray),
                run("\(recording.speakerName(segment.speakerID)): ", bold: true),
            ]
            elements += NotionExporter.chunks(segment.text, size: 1900).map { run($0) }
            return text(elements)
        }
    }

    static let gray = 7
    private static let urlSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func heading(_ content: String) -> [String: Any] {
        ["block_type": 4, "heading2": ["elements": [run(content)]]]
    }

    static func text(_ elements: [[String: Any]]) -> [String: Any] {
        ["block_type": 2, "text": ["elements": elements]]
    }

    static func run(_ content: String, bold: Bool = false, color: Int? = nil) -> [String: Any] {
        var style: [String: Any] = [:]
        if bold { style["bold"] = true }
        if let color { style["text_color"] = color }
        var run: [String: Any] = ["content": content]
        if !style.isEmpty { run["text_element_style"] = style }
        return ["text_run": run]
    }
}
