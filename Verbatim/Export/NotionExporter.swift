import Foundation

/// Writes a recording into the Meeting Transcripts database: properties the
/// app knows (title, date, duration, attendees, link, status), two empty
/// sections for the user (摘要, 讨论要点), and the full transcript inside the
/// "逐字稿 Transcript" toggle.
nonisolated struct NotionExporter: Sendable {
    let client: NotionClient
    let dataSourceID: String
    let sourceOption: String

    /// Property names in the user's database. Matched by name first, then by
    /// type, and silently skipped when absent so schema edits never break export.
    enum Prop {
        static let title = "会议标题"
        static let date = "会议日期"
        static let duration = "时长（分钟）"
        static let external = "外部参会人"
        static let members = "参会人（工作区成员）"
        static let source = "来源"
        static let status = "整理状态"
        static let link = "录音 / 会议链接"
    }

    func export(_ recording: Recording) async throws -> URL {
        let (dsID, schema) = try await client.dataSourceSchema(dataSourceID)
        let members = schema[Prop.members] == "people" ? await client.workspaceMembers() : []
        let properties = Self.properties(for: recording, schema: schema, members: members, sourceOption: sourceOption)

        let page = try await client.post("pages", [
            "parent": ["type": "data_source_id", "data_source_id": dsID],
            "properties": properties,
            "children": Self.skeleton(for: recording),
        ])
        guard let pageID = page["id"] as? String else { throw NotionError.invalidResponse }

        let toggle = try await client.patch("blocks/\(pageID)/children", [
            "children": [Self.transcriptToggle()],
        ])
        guard let toggleID = (toggle["results"] as? [[String: Any]])?.first?["id"] as? String else {
            throw NotionError.invalidResponse
        }

        let blocks = Self.transcriptBlocks(for: recording)
        for start in stride(from: 0, to: blocks.count, by: 100) {
            let chunk = Array(blocks[start..<min(start + 100, blocks.count)])
            _ = try await client.patch("blocks/\(toggleID)/children", ["children": chunk])
        }

        if let url = (page["url"] as? String).flatMap(URL.init(string:)) { return url }
        return URL(string: "https://www.notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))")!
    }

    // MARK: Properties

    static func properties(
        for recording: Recording,
        schema: [String: String],
        members: [(id: String, email: String, name: String)],
        sourceOption: String
    ) -> [String: Any] {
        var props: [String: Any] = [:]
        func name(_ preferred: String, type: String) -> String? {
            if schema[preferred] == type { return preferred }
            return nil
        }

        let titleProp = name(Prop.title, type: "title") ?? schema.first { $0.value == "title" }?.key
        if let titleProp { props[titleProp] = ["title": richText(recording.meeting.title)] }

        if let dateProp = name(Prop.date, type: "date") {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            iso.timeZone = .current
            var date: [String: Any] = ["start": iso.string(from: recording.startedAt)]
            if let end = recording.endedAt { date["end"] = iso.string(from: end) }
            props[dateProp] = ["date": date]
        }
        if let p = name(Prop.duration, type: "number") {
            props[p] = ["number": max(1, Int((recording.duration / 60).rounded()))]
        }
        if let p = name(Prop.status, type: "status") {
            props[p] = ["status": ["name": "待整理"]]
        }
        if let p = name(Prop.source, type: "select"), !sourceOption.trimmed.isEmpty {
            props[p] = ["select": ["name": sourceOption.trimmed]]
        }
        if let p = name(Prop.link, type: "url"), let link = recording.meeting.conferenceURL?.absoluteString {
            props[p] = ["url": link]
        }

        // Attendees: workspace members go to the people property, everyone
        // else (by name) to the external text property. Speakers the user
        // named but who were not on the invite count as attendees too.
        let memberByEmail = Dictionary(members.map { ($0.email, $0.id) }, uniquingKeysWith: { a, _ in a })
        var memberIDs: [String] = []
        var externalNames: [String] = []
        for a in recording.meeting.attendees {
            if let email = a.email?.lowercased(), let id = memberByEmail[email] {
                if !memberIDs.contains(id) { memberIDs.append(id) }
            } else if !a.isSelf {
                externalNames.append(a.displayName)
            }
        }
        for s in recording.speakers where !s.isMe && s.isConfirmed {
            let known = recording.meeting.attendees.contains { (a: Attendee) -> Bool in
                if a.displayName == s.name { return true }
                if let email = a.email, email == s.email { return true }
                return false
            }
            if !known, !externalNames.contains(s.name) { externalNames.append(s.name) }
        }
        if let p = name(Prop.members, type: "people"), !memberIDs.isEmpty {
            props[p] = ["people": memberIDs.map { ["object": "user", "id": $0] }]
        }
        if let p = name(Prop.external, type: "rich_text"), !externalNames.isEmpty {
            props[p] = ["rich_text": richText(externalNames.joined(separator: ", "))]
        }
        return props
    }

    // MARK: Blocks

    /// Only the two sections the user fills in by hand; the transcript
    /// toggle is appended after these.
    static func skeleton(for recording: Recording) -> [[String: Any]] {
        [
            heading("摘要"),
            emptyParagraph(),
            heading("讨论要点"),
            ["object": "block", "type": "bulleted_list_item", "bulleted_list_item": ["rich_text": []]],
        ]
    }

    static func emptyParagraph() -> [String: Any] {
        ["object": "block", "type": "paragraph", "paragraph": ["rich_text": []]]
    }

    static func transcriptToggle() -> [String: Any] {
        ["object": "block", "type": "heading_2", "heading_2": [
            "rich_text": richText("逐字稿 Transcript"),
            "is_toggleable": true,
        ]]
    }

    /// One paragraph per speaker turn: "[00:12:34] Name: text".
    static func transcriptBlocks(for recording: Recording) -> [[String: Any]] {
        recording.visibleSegments.map { segment in
            var rich: [[String: Any]] = [
                ["type": "text", "text": ["content": "[\(segment.start.clockString)] "],
                 "annotations": ["color": "gray"]],
                ["type": "text", "text": ["content": "\(recording.speakerName(segment.speakerID)): "],
                 "annotations": ["bold": true]],
            ]
            rich += richText(segment.text)
            return ["object": "block", "type": "paragraph", "paragraph": ["rich_text": Array(rich.prefix(100))]]
        }
    }

    static func heading(_ text: String) -> [String: Any] {
        ["object": "block", "type": "heading_2", "heading_2": ["rich_text": richText(text)]]
    }

    /// Notion caps each text object at 2000 characters.
    static func richText(_ text: String) -> [[String: Any]] {
        chunks(text, size: 1900).map { ["type": "text", "text": ["content": $0]] }
    }

    static func chunks(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var cut = rest.index(rest.startIndex, offsetBy: size, limitedBy: rest.endIndex) ?? rest.endIndex
            if cut != rest.endIndex, let space = rest[..<cut].lastIndex(where: { $0 == " " || $0 == "。" || $0 == "，" }),
               rest.distance(from: rest.startIndex, to: space) > size / 2 {
                cut = rest.index(after: space)
            }
            out.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        return out
    }
}

/// Plain-text and Markdown renderings for copy / file export.
nonisolated enum TranscriptFormatter {
    static func plainText(_ recording: Recording) -> String {
        var lines = [recording.meeting.title, headerLine(recording), ""]
        for s in recording.visibleSegments {
            lines.append("[\(s.start.clockString)] \(recording.speakerName(s.speakerID)): \(s.text)")
        }
        return lines.joined(separator: "\n")
    }

    static func markdown(_ recording: Recording) -> String {
        var lines = ["# \(recording.meeting.title)", "", "_\(headerLine(recording))_", ""]
        for s in recording.visibleSegments {
            lines.append("`\(s.start.clockString)` **\(recording.speakerName(s.speakerID))**: \(s.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func headerLine(_ recording: Recording) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(f.string(from: recording.startedAt)) · \(recording.duration.shortClockString)"
    }
}
