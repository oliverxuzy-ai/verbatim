import Foundation
import Testing
@testable import Verbatim

/// In-memory stand-in for secrets.json.
nonisolated func memoryStorage(_ initial: [String: String] = [:]) -> GoogleAuth.Storage {
    let box = Locked(initial)
    return GoogleAuth.Storage(get: { key in box.current[key] }, set: { value, key in box.withLock { $0[key] = value } })
}

/// A JWT whose payload carries `email` (Google signs it; the app only reads it).
nonisolated func idToken(email: String) -> String {
    let payload = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: ["email": email, "sub": "123"]))
    return "eyJhbGciOiJSUzI1NiJ9.\(payload).c2lnbmF0dXJl"
}

nonisolated let sampleEvents = """
{"items": [
  {"id": "m1", "status": "confirmed", "summary": "Alex / Kevin chat",
   "start": {"dateTime": "2026-10-16T10:00:00-07:00"}, "end": {"dateTime": "2026-10-16T10:30:00-07:00"},
   "hangoutLink": "https://meet.google.com/toi-urdu-giy",
   "organizer": {"email": "kevin@example.org", "displayName": "Kevin Walsh"},
   "attendees": [
     {"email": "kevin@example.org", "displayName": "Kevin Walsh", "organizer": true, "responseStatus": "accepted"},
     {"email": "alex@example.net", "self": true, "responseStatus": "accepted"},
     {"email": "grant.ellis@example.org", "responseStatus": "needsAction"},
     {"email": "c_188@resource.calendar.google.com", "displayName": "Room 4", "resource": true, "responseStatus": "accepted"}]},
  {"id": "m2", "summary": "Declined sync", "start": {"dateTime": "2026-10-16T11:00:00Z"}, "end": {"dateTime": "2026-10-16T11:30:00Z"},
   "attendees": [{"email": "me@x.com", "self": true, "responseStatus": "declined"}, {"email": "a@x.com"}]},
  {"id": "m3", "summary": "Offsite", "start": {"date": "2026-10-17"}, "end": {"date": "2026-10-18"}},
  {"id": "m4", "eventType": "workingLocation", "summary": "Home",
   "start": {"dateTime": "2026-10-16T09:00:00Z"}, "end": {"dateTime": "2026-10-16T17:00:00Z"}},
  {"id": "m5", "status": "cancelled", "summary": "Cancelled",
   "start": {"dateTime": "2026-10-16T12:00:00Z"}, "end": {"dateTime": "2026-10-16T12:30:00Z"}},
  {"id": "m6", "summary": "Vendor call", "location": "https://us02web.zoom.us/j/123456789",
   "start": {"dateTime": "2026-10-16T13:00:00.000Z"}, "end": {"dateTime": "2026-10-16T13:30:00.000Z"},
   "organizer": {"email": "me@x.com", "self": true}},
  {"id": "m7", "start": {"dateTime": "2026-10-16T14:00:00Z"}, "end": {"dateTime": "2026-10-16T14:15:00Z"},
   "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:+1-555"},
                                      {"entryPointType": "video", "uri": "https://teams.microsoft.com/l/meetup-join/abc"}]}}
]}
"""

struct GoogleCalendarTests {
    @Test func pkceMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count >= 43 && verifier.count <= 128)
        #expect(verifier != PKCE.makeVerifier())
    }

    @Test func authorizationURLAsksForOfflineReadOnlyCalendar() throws {
        let url = GoogleAuth.authorizationURL(client: GoogleOAuthClient(id: "cid.apps.googleusercontent.com", secret: "s"),
                                              redirect: "http://127.0.0.1:5555", challenge: "abc", state: "xyz")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["client_id"] == "cid.apps.googleusercontent.com")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555")
        #expect(items["code_challenge_method"] == "S256" && items["code_challenge"] == "abc" && items["state"] == "xyz")
        #expect(items["access_type"] == "offline" && items["response_type"] == "code")
        #expect(items["scope"]?.contains("calendar.events.readonly") == true)
        #expect(items["scope"]?.contains("calendar ") == false) // never the full read/write scope
    }

    @Test func clientJSONFromGoogleCloudConsoleImports() {
        let downloaded = #"{"installed":{"client_id":"123-abc.apps.googleusercontent.com","project_id":"verbatim","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","client_secret":"GOCSPX-xyz","redirect_uris":["http://localhost"]}}"#
        #expect(GoogleOAuthClient.parse(json: Data(downloaded.utf8)) == GoogleOAuthClient(id: "123-abc.apps.googleusercontent.com", secret: "GOCSPX-xyz"))
        #expect(GoogleOAuthClient.parse(json: Data(#"{"type":"service_account"}"#.utf8)) == nil)
    }

    @Test func idTokenEmailIsRead() {
        #expect(GoogleAuth.emailFromIDToken(idToken(email: "alex@example.net")) == "alex@example.net")
        #expect(GoogleAuth.emailFromIDToken("not-a-jwt") == nil)
    }

    @Test func eventsBecomeMeetings() throws {
        let page = try GoogleCalendarAPI.parse(Data(sampleEvents.utf8))
        #expect(page.meetings.map(\.calendarEventID) == ["m1", "m6", "m7"]) // declined, all-day, working location, cancelled dropped
        let chat = page.meetings[0]
        #expect(chat.title == "Alex / Kevin chat")
        #expect(chat.attendees.map(\.displayName) == ["Kevin Walsh", "Alex", "Grant Ellis"]) // room left out, names from emails
        #expect(chat.attendees.first { $0.isSelf }?.email == "alex@example.net")
        #expect(chat.attendees.first { $0.isOrganizer }?.displayName == "Kevin Walsh")
        #expect(chat.conferenceProvider == .googleMeet)
        #expect(chat.scheduledStart == ISO8601DateFormatter().date(from: "2026-10-16T17:00:00Z"))
        let vendor = page.meetings[1]
        #expect(vendor.conferenceProvider == .zoom)
        #expect(vendor.attendees.count == 1 && vendor.attendees[0].isSelf && vendor.attendees[0].isOrganizer)
        #expect(vendor.scheduledEnd != nil) // fractional seconds parse
        #expect(page.meetings[2].title == "Untitled event")
        #expect(page.meetings[2].conferenceProvider == .teams)
    }

    @Test func loopbackReceiverAnswersTheBrowser() async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        #expect(receiver.port > 0)
        let favicon = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.port)/favicon.ico")!)
        #expect((favicon.1 as? HTTPURLResponse)?.statusCode == 404)
        let (page, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.port)/?state=s1&code=4%2F0Ab&scope=email")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("connected to Google Calendar"))
        let query = try await receiver.redirect(timeout: 5)
        #expect(query["code"] == "4/0Ab" && query["state"] == "s1")
    }

    @Test func receiverCanBeCancelled() async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        receiver.fail(GoogleAuthError.cancelled)
        await #expect(throws: GoogleAuthError.cancelled) { try await receiver.redirect(timeout: 5) }
    }
}

/// Network flows share the global URL stub, so they run inside the
/// serialized NetworkFlowTests suite.
extension NetworkFlowTests {
    static let client = GoogleOAuthClient(id: "cid.apps.googleusercontent.com", secret: "GOCSPX-test")

    /// Plays the browser: follows Google's redirect back to the app.
    static func browser(code: String = "auth-code", error: String? = nil) -> (URL) -> Void {
        { url in
            let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var back = URLComponents(string: items["redirect_uri"]!)!
            back.queryItems = [URLQueryItem(name: "state", value: items["state"])] + (error.map { [URLQueryItem(name: "error", value: $0)] } ?? [URLQueryItem(name: "code", value: code)])
            Task.detached { _ = try? await URLSession.shared.data(from: back.url!) }
        }
    }

    @MainActor @Test func googleSignInStoresTheRefreshToken() async throws {
        let tokens = json(["access_token": "ya29.a", "expires_in": 3599, "refresh_token": "1//refresh", "token_type": "Bearer",
                           "scope": "openid https://www.googleapis.com/auth/userinfo.email \(GoogleAuth.calendarScope)",
                           "id_token": idToken(email: "alex@example.net")])
        StubURLProtocol.install { req in req.url.host == "oauth2.googleapis.com" ? (200, tokens, [:]) : (404, Data(), [:]) }
        defer { StubURLProtocol.uninstall() }
        let storage = memoryStorage()
        let auth = GoogleAuth(storage: storage, openURL: Self.browser())
        auth.setClient(Self.client)
        await auth.signIn()
        #expect(auth.state == .signedIn(email: "alex@example.net"))
        #expect(storage.get(SecretKey.googleRefreshToken) == "1//refresh")
        #expect(try await auth.accessToken() == "ya29.a")
        // The token request proves the PKCE verifier and uses the same redirect.
        let form = String(decoding: try #require(StubURLProtocol.log.current.first).body, as: UTF8.self)
        #expect(form.contains("grant_type=authorization_code") && form.contains("code=auth-code") && form.contains("code_verifier="))
        #expect(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A"))
    }

    @MainActor @Test func uncheckedCalendarBoxIsReported() async {
        let tokens = json(["access_token": "a", "expires_in": 3599, "refresh_token": "r", "scope": "openid email"])
        StubURLProtocol.install { _ in (200, tokens, [:]) }
        defer { StubURLProtocol.uninstall() }
        let auth = GoogleAuth(storage: memoryStorage(), openURL: Self.browser())
        auth.setClient(Self.client)
        await auth.signIn()
        #expect(auth.state == .signedOut)
        #expect(auth.lastError == GoogleAuthError.calendarNotGranted.localizedDescription)
    }

    @MainActor @Test func declinedConsentIsReported() async {
        StubURLProtocol.install { _ in (500, Data(), [:]) }
        defer { StubURLProtocol.uninstall() }
        let auth = GoogleAuth(storage: memoryStorage(), openURL: Self.browser(error: "access_denied"))
        auth.setClient(Self.client)
        await auth.signIn()
        #expect(auth.state == .signedOut)
        #expect(auth.lastError == "Google sign-in was declined.")
        #expect(StubURLProtocol.log.current.isEmpty) // no token request
    }

    @MainActor @Test func revokedSignInSignsOut() async {
        StubURLProtocol.install { _ in (400, json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."]), [:]) }
        defer { StubURLProtocol.uninstall() }
        let storage = memoryStorage([SecretKey.googleClientID: Self.client.id, SecretKey.googleClientSecret: Self.client.secret,
                                     SecretKey.googleRefreshToken: "old", SecretKey.googleEmail: "me@x.com"])
        let auth = GoogleAuth(storage: storage)
        #expect(auth.state == .signedIn(email: "me@x.com"))
        await #expect(throws: GoogleAuthError.expired) { try await auth.accessToken() }
        #expect(auth.state == .signedOut)
        #expect(storage.get(SecretKey.googleRefreshToken) == nil)
    }

    @MainActor @Test func calendarPagesAreFollowedWithTheToken() async throws {
        let first = Data(#"{"items":[{"id":"a","summary":"One","start":{"dateTime":"2026-10-16T10:00:00Z"},"end":{"dateTime":"2026-10-16T10:30:00Z"}}],"nextPageToken":"p2"}"#.utf8)
        let second = Data(#"{"items":[{"id":"b","summary":"Two","start":{"dateTime":"2026-10-16T11:00:00Z"},"end":{"dateTime":"2026-10-16T11:30:00Z"}}]}"#.utf8)
        StubURLProtocol.install { req in
            req.url.query?.contains("pageToken=p2") == true ? (200, second, [:]) : (200, first, [:])
        }
        defer { StubURLProtocol.uninstall() }
        let meetings = try await GoogleCalendarAPI.meetings(accessToken: "ya29.t", from: .now, to: .now.addingTimeInterval(3600))
        #expect(meetings.map(\.title) == ["One", "Two"])
        let calls = StubURLProtocol.log.current
        #expect(calls.count == 2 && calls.allSatisfy { $0.headers["Authorization"] == "Bearer ya29.t" })
        #expect(calls[0].url.path == "/calendar/v3/calendars/primary/events")
        #expect(calls[0].url.query?.contains("singleEvents=true") == true)
    }

    @MainActor @Test func calendarServiceListsGoogleMeetings() async throws {
        let tokens = json(["access_token": "ya29.s", "expires_in": 3599, "scope": GoogleAuth.calendarScope])
        StubURLProtocol.install { req in
            req.url.host == "oauth2.googleapis.com" ? (200, tokens, [:]) : (200, Data(sampleEvents.utf8), [:])
        }
        defer { StubURLProtocol.uninstall() }
        let storage = memoryStorage([SecretKey.googleClientID: Self.client.id, SecretKey.googleClientSecret: Self.client.secret,
                                     SecretKey.googleRefreshToken: "r", SecretKey.googleEmail: "alex@example.net"])
        let service = CalendarService(google: GoogleAuth(storage: storage))
        #expect(service.isConnected)
        service.refresh()
        for _ in 0..<50 where service.events.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(service.events.map(\.title) == ["Vendor call", "Untitled event", "Alex / Kevin chat"]) // by start time
        #expect(service.googleError == nil)
        #expect(!service.looksDisconnected)
    }
}
