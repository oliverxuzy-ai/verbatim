import Foundation
import Testing
@testable import Verbatim

/// Intercepts URLSession.shared so the Notion and Anthropic flows can be
/// exercised end to end without real tokens or network.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var responder: (@Sendable (Captured) -> (Int, Data, [String: String]))?
    static let log = Locked<[Captured]>([])

    // The Google sign-in tests talk to a real listener on 127.0.0.1.
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host != "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let captured = Captured(method: request.httpMethod ?? "GET", url: request.url!,
                                headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.log.withLock { $0.append(captured) }
        let (status, data, headers) = Self.responder?(captured) ?? (500, Data(), [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func install(_ responder: @escaping @Sendable (Captured) -> (Int, Data, [String: String])) {
        self.responder = responder
        log.withLock { $0 = [] }
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        responder = nil
    }
}

nonisolated func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
nonisolated func parse(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

@Suite(.serialized)
struct NetworkFlowTests {
    func longRecording(segments: Int) -> Recording {
        var rec = Recording(
            meeting: MeetingInfo(title: "1on1 with Hsiao", attendees: [
                Attendee(name: "Oliver", email: "oliver@example.com", isSelf: true),
                Attendee(name: "Hsiao-Wen Lin", email: "hsiao@example.com"),
            ], conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij")),
            startedAt: Date(timeIntervalSince1970: 1_760_000_000), endedAt: Date(timeIntervalSince1970: 1_760_003_600),
            language: "en-US", engine: "apple", micMode: .solo
        )
        rec.speakers = [
            Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:0", name: "Hsiao-Wen Lin", email: "hsiao@example.com", colorIndex: 1, isConfirmed: true),
        ]
        rec.segments = (0..<segments).map { (i: Int) -> Segment in
            let mine = i % 2 == 0
            let words = String(repeating: "word ", count: i == 7 ? 600 : 5)
            return Segment(channel: mine ? .mic : .system, speakerID: mine ? "me" : "system:0",
                           start: Double(i * 10), end: Double(i * 10 + 8), text: "Line \(i) \(words)", isFinal: true)
        }
        return rec
    }

    @Test func notionExportCreatesPageAndAppendsTranscriptInBatches() async throws {
        let toggleID = "toggle-123"
        let pageID = "page-456"
        let throttled = Locked(false)
        let schema: [String: Any] = [
            "会议标题": ["type": "title"], "会议日期": ["type": "date"], "时长（分钟）": ["type": "number"],
            "外部参会人": ["type": "rich_text"], "参会人（工作区成员）": ["type": "people"], "来源": ["type": "select"],
            "整理状态": ["type": "status"], "录音 / 会议链接": ["type": "url"],
        ]
        let dataSource: Data = json(["id": "ds-1", "properties": schema])
        let users: Data = json(["results": [["type": "person", "id": "user-1", "name": "Oliver", "person": ["email": "oliver@example.com"]]], "has_more": false])
        let created: Data = json(["id": pageID, "url": "https://www.notion.so/Page-\(pageID)"])
        let toggleCreated: Data = json(["results": [["id": toggleID]]])
        let appended: Data = json(["results": [Any]()])
        let responder: @Sendable (StubURLProtocol.Captured) -> (Int, Data, [String: String]) = { req in
            let route = "\(req.method) \(req.url.path)"
            if route == "GET /v1/data_sources/ds-1" { return (200, dataSource, [:]) }
            if route == "GET /v1/users" { return (200, users, [:]) }
            if route == "POST /v1/pages" {
                // First attempt is rate limited; the client must retry.
                let first = throttled.withLock { t -> Bool in defer { t = true }; return !t }
                return first ? (429, json(["message": "slow down"]), ["Retry-After": "0"]) : (200, created, [:])
            }
            if route == "PATCH /v1/blocks/\(pageID)/children" { return (200, toggleCreated, [:]) }
            if route == "PATCH /v1/blocks/\(toggleID)/children" { return (200, appended, [:]) }
            return (404, json(["message": "unexpected \(route)"]), [:])
        }
        StubURLProtocol.install(responder)
        defer { StubURLProtocol.uninstall() }

        let exporter = NotionExporter(client: NotionClient(token: "ntn_test"), dataSourceID: "ds-1", sourceOption: "Verbatim")
        let url = try await exporter.export(longRecording(segments: 250))
        #expect(url.absoluteString.contains(pageID))

        let calls = StubURLProtocol.log.current
        #expect(calls.allSatisfy { $0.headers["Authorization"] == "Bearer ntn_test" && $0.headers["Notion-Version"] == "2026-03-11" })
        let posts = calls.filter { $0.method == "POST" }
        #expect(posts.count == 2) // 429 then success
        let page = parse(posts[1].body)
        #expect((page["parent"] as? [String: String])?["data_source_id"] == "ds-1")
        let props = page["properties"] as? [String: Any] ?? [:]
        #expect(Set(props.keys) == ["会议标题", "会议日期", "时长（分钟）", "外部参会人", "参会人（工作区成员）", "来源", "整理状态", "录音 / 会议链接"])
        let children = page["children"] as? [[String: Any]] ?? []
        #expect(children.count == 4)

        let batches = calls.filter { $0.url.path == "/v1/blocks/\(toggleID)/children" }.map { (parse($0.body)["children"] as? [Any])?.count ?? 0 }
        #expect(batches == [100, 100, 50])
        // The 3000-character line was split under Notion's 2000-char limit.
        let longest = calls.filter { $0.url.path == "/v1/blocks/\(toggleID)/children" }
            .flatMap { (parse($0.body)["children"] as? [[String: Any]]) ?? [] }
            .flatMap { (($0["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]]) ?? [] }
            .compactMap { (($0["text"] as? [String: Any])?["content"] as? String)?.count }
            .max() ?? 0
        #expect(longest <= 2000)
    }

    @Test func notionNotFoundGivesSharingHint() async throws {
        StubURLProtocol.install { _ in (404, json(["code": "object_not_found", "message": "Could not find data source"]), [:]) }
        defer { StubURLProtocol.uninstall() }
        let exporter = NotionExporter(client: NotionClient(token: "secret_test"), dataSourceID: "ds-x", sourceOption: "Verbatim")
        do {
            _ = try await exporter.export(longRecording(segments: 2))
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("Connections"))
        }
    }

    @Test func larkExportCreatesDocWritesBlocksInBatchesAndHandsOver() async throws {
        let docID = "doxcnTest123"
        let throttled = Locked(false)
        let responder: @Sendable (StubURLProtocol.Captured) -> (Int, Data, [String: String]) = { req in
            let route = "\(req.method) \(req.url.path)"
            switch route {
            case "POST /open-apis/auth/v3/tenant_access_token/internal":
                return (200, json(["code": 0, "msg": "ok", "tenant_access_token": "t-test", "expire": 7200]), [:])
            case "POST /open-apis/docx/v1/documents":
                return (200, json(["code": 0, "data": ["document": ["document_id": docID, "revision_id": 1]]]), [:])
            case "POST /open-apis/docx/v1/documents/\(docID)/blocks/\(docID)/children":
                let first = throttled.withLock { t -> Bool in defer { t = true }; return !t }
                return first ? (429, json(["code": 99991400, "msg": "request trigger frequency limit"]), ["x-ogw-ratelimit-reset": "0"])
                    : (200, json(["code": 0, "data": ["children": [Any]()]]), [:])
            case "POST /open-apis/drive/v1/permissions/\(docID)/members/transfer_owner":
                return (200, json(["code": 0, "data": [String: Any]()]), [:])
            case "POST /open-apis/drive/v1/metas/batch_query":
                return (200, json(["code": 0, "data": ["metas": [["doc_token": docID, "url": "https://acme.larksuite.com/docx/\(docID)"]]]]), [:])
            default:
                return (404, json(["code": 404, "msg": "unexpected \(route)"]), [:])
            }
        }
        StubURLProtocol.install(responder)
        defer { StubURLProtocol.uninstall() }

        let client = LarkClient(region: .lark, appID: "cli_test", appSecret: "secret")
        let exporter = LarkExporter(client: client, folder: "https://acme.larksuite.com/drive/folder/fldTest9?from=x",
                                    ownerEmail: "oliver@example.com", writeSpacing: .zero)
        let result = try await exporter.export(longRecording(segments: 250))
        #expect(result.url.absoluteString == "https://acme.larksuite.com/docx/\(docID)")
        #expect(result.warning == nil)

        let calls = StubURLProtocol.log.current
        #expect(calls.allSatisfy { $0.url.host == "open.larksuite.com" })
        let auth = try #require(calls.first)
        #expect(parse(auth.body)["app_id"] as? String == "cli_test")
        #expect(calls.dropFirst().allSatisfy { $0.headers["Authorization"] == "Bearer t-test" })

        let create = try #require(calls.first { $0.url.path == "/open-apis/docx/v1/documents" })
        #expect(parse(create.body)["folder_token"] as? String == "fldTest9")
        #expect(parse(create.body)["title"] as? String == "1on1 with Hsiao")

        let writes = calls.filter { $0.url.path.hasSuffix("/children") }
        #expect(writes.allSatisfy { $0.url.query?.contains("document_revision_id=-1") == true })
        // First write was rate limited and retried; 7 skeleton blocks + 250 turns.
        let sizes = writes.map { (parse($0.body)["children"] as? [Any])?.count ?? 0 }
        #expect(sizes == [50, 50, 50, 50, 50, 50, 7])

        let transfer = try #require(calls.first { $0.url.path.hasSuffix("/transfer_owner") })
        #expect(transfer.url.query?.contains("type=docx") == true)
        #expect(transfer.url.query?.contains("stay_put=false") == true)
        #expect(parse(transfer.body)["member_id"] as? String == "oliver@example.com")
        #expect(parse(transfer.body)["member_type"] as? String == "email")
    }

    @Test func larkFallsBackToSharingWhenOwnershipTransferFails() async throws {
        let docID = "doxcnFallback"
        StubURLProtocol.install { req in
            switch "\(req.method) \(req.url.path)" {
            case "POST /open-apis/auth/v3/tenant_access_token/internal":
                return (200, json(["code": 0, "tenant_access_token": "t-test"]), [:])
            case "POST /open-apis/docx/v1/documents":
                return (200, json(["code": 0, "data": ["document": ["document_id": docID]]]), [:])
            case "POST /open-apis/drive/v1/permissions/\(docID)/members/transfer_owner":
                return (400, json(["code": 1063001, "msg": "invalid parameter"]), [:])
            case "POST /open-apis/drive/v1/permissions/\(docID)/members":
                return (200, json(["code": 0, "data": ["member": [String: Any]()]]), [:])
            case "POST /open-apis/drive/v1/metas/batch_query":
                return (400, json(["code": 99991672, "msg": "no scope"]), [:])
            default:
                return (200, json(["code": 0, "data": [String: Any]()]), [:])
            }
        }
        defer { StubURLProtocol.uninstall() }

        let client = LarkClient(region: .feishu, appID: "cli_test", appSecret: "secret")
        let exporter = LarkExporter(client: client, ownerEmail: "oliver@example.com", writeSpacing: .zero)
        let result = try await exporter.export(longRecording(segments: 3))
        #expect(result.warning == nil)
        // No URL from the API: the generic Feishu link.
        #expect(result.url.absoluteString == "https://www.feishu.cn/docx/\(docID)")

        let calls = StubURLProtocol.log.current
        #expect(calls.allSatisfy { $0.url.host == "open.feishu.cn" })
        #expect(parse(try #require(calls.first { $0.url.path == "/open-apis/docx/v1/documents" }).body)["folder_token"] == nil)
        let share = try #require(calls.first { $0.url.path == "/open-apis/drive/v1/permissions/\(docID)/members" })
        #expect(parse(share.body)["perm"] as? String == "full_access")
    }

    @Test func larkNeedsSomewhereToPutTheDoc() async throws {
        StubURLProtocol.install { _ in (500, Data(), [:]) }
        defer { StubURLProtocol.uninstall() }
        let exporter = LarkExporter(client: LarkClient(region: .lark, appID: "cli_test", appSecret: "secret"))
        do {
            _ = try await exporter.export(longRecording(segments: 2))
            Issue.record("expected an error")
        } catch LarkError.noDestination {
            #expect(StubURLProtocol.log.current.isEmpty)
        }
    }

    @Test func claudeNamingSendsStructuredRequestAndParsesReply() async throws {
        StubURLProtocol.install { req in
            let reply: [String: Any] = [
                "speakers": [["label": "system:1", "name": "Ananya Iyer", "confidence": 0.86, "evidence": "[00:00:05] Ananya, want to start?"]],
            ]
            let text = String(decoding: json(reply), as: UTF8.self)
            return (200, json([
                "stop_reason": "end_turn",
                "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
            ]), [:])
        }
        defer { StubURLProtocol.uninstall() }
        var rec = Recording(meeting: MeetingInfo(title: "Kickoff", attendees: [
            Attendee(name: "Me", isSelf: true), Attendee(name: "Ananya Iyer"), Attendee(name: "Hsiao-Wen Lin"),
        ]), startedAt: .now, endedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        rec.speakers = [Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true),
                        Speaker(id: "system:1", name: "Speaker 1", colorIndex: 1)]
        rec.segments = [Segment(channel: .mic, speakerID: "me", start: 5, end: 7, text: "Ananya, want to start?", isFinal: true),
                        Segment(channel: .system, speakerID: "system:1", start: 8, end: 10, text: "Sure.", isFinal: true)]
        let out = try await LLMSpeakerNamer.suggest(for: rec, apiKey: "sk-ant-test", myName: "Me")
        #expect(out.map(\.name) == ["Ananya Iyer"])

        let call = try #require(StubURLProtocol.log.current.first)
        #expect(call.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(call.headers["x-api-key"] == "sk-ant-test")
        #expect(call.headers["anthropic-version"] == "2023-06-01")
        #expect(call.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        let body = parse(call.body)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
    }

    @Test func claudeRefusalYieldsNoNames() async throws {
        StubURLProtocol.install { _ in (200, json(["stop_reason": "refusal", "content": []]), [:]) }
        defer { StubURLProtocol.uninstall() }
        var rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: .now, endedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        rec.speakers = [Speaker(id: "system:1", name: "Speaker 1", colorIndex: 1)]
        rec.segments = [Segment(channel: .system, speakerID: "system:1", start: 0, end: 2, text: "Hello", isFinal: true)]
        #expect(try await LLMSpeakerNamer.suggest(for: rec, apiKey: "k", myName: "Me").isEmpty)
    }
}
