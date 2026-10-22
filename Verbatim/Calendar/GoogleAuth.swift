import AppKit
import CryptoKit
import Foundation
import Network
import Observation

/// The user's own "Desktop app" OAuth client from Google Cloud Console.
nonisolated struct GoogleOAuthClient: Equatable, Sendable {
    var id: String
    var secret: String

    /// The JSON Google Cloud Console offers for download:
    /// {"installed": {"client_id": "…", "client_secret": "…", …}}.
    static func parse(json data: Data) -> GoogleOAuthClient? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = (root["installed"] ?? root["web"]) as? [String: Any],
              let id = body["client_id"] as? String, let secret = body["client_secret"] as? String,
              !id.trimmed.isEmpty, !secret.trimmed.isEmpty else { return nil }
        return GoogleOAuthClient(id: id.trimmed, secret: secret.trimmed)
    }
}

nonisolated enum GoogleAuthError: LocalizedError, Equatable {
    case noClient, cancelled, stateMismatch, denied(String), noCode, noRefreshToken
    case calendarNotGranted, signedOut, expired, server(String)

    var errorDescription: String? {
        switch self {
        case .noClient: "Import your Google OAuth client first (Settings → Calendar → Import JSON). Creating it in Google Cloud Console is a one-time, 10-minute setup; the steps are listed there."
        case .cancelled: "Sign-in was cancelled."
        case .stateMismatch: "The sign-in response didn't match this request. Try again."
        case let .denied(reason): reason == "access_denied" ? "Google sign-in was declined." : "Google sign-in failed: \(reason)"
        case .noCode, .noRefreshToken: "Google didn't return a sign-in token. Try again."
        case .calendarNotGranted: "Calendar access wasn't granted. Sign in again and keep the calendar box checked."
        case .signedOut: "Not signed in to Google."
        case .expired: "Google sign-in expired or was revoked. Sign in again."
        case let .server(message): "Google: \(message)"
        }
    }
}

/// Google sign-in for an installed app (RFC 8252): the system browser, a
/// one-shot listener on 127.0.0.1 for the redirect, and PKCE. Only the
/// refresh token is kept (with the other secrets); access tokens stay in
/// memory and are renewed when they expire.
@Observable
final class GoogleAuth {
    enum State: Equatable {
        case signedOut, signingIn
        case signedIn(email: String)
    }

    nonisolated static let calendarScope = "https://www.googleapis.com/auth/calendar.events.readonly"
    nonisolated static let scopes = ["openid", "email", calendarScope]
    nonisolated static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    nonisolated static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    nonisolated static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Where the client and tokens live; tests pass an in-memory store.
    nonisolated struct Storage: Sendable {
        var get: @Sendable (String) -> String?
        var set: @Sendable (String?, String) -> Void
        static let secrets = Storage(get: { Keychain.get($0) }, set: { _ = Keychain.set($0, for: $1) })
    }

    private(set) var state: State = .signedOut
    private(set) var hasClient = false
    var lastError: String?

    private let storage: Storage
    private let openURL: (URL) -> Void
    private var token: (value: String, expires: Date)?
    private var renewing: Task<String, Error>?
    private var receiver: LoopbackReceiver?

    init(storage: Storage = .secrets, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.storage = storage
        self.openURL = openURL
        hasClient = client != nil
        if storage.get(SecretKey.googleRefreshToken) != nil {
            state = .signedIn(email: storage.get(SecretKey.googleEmail) ?? "")
        }
    }

    var isSignedIn: Bool { if case .signedIn = state { true } else { false } }

    var client: GoogleOAuthClient? {
        guard let id = storage.get(SecretKey.googleClientID), let secret = storage.get(SecretKey.googleClientSecret) else { return nil }
        return GoogleOAuthClient(id: id, secret: secret)
    }

    func setClient(_ client: GoogleOAuthClient?) {
        storage.set(client?.id.trimmed, SecretKey.googleClientID)
        storage.set(client?.secret.trimmed, SecretKey.googleClientSecret)
        hasClient = self.client != nil
    }

    // MARK: Sign in / out

    func signIn() async {
        guard let client else { lastError = GoogleAuthError.noClient.localizedDescription; return }
        let previous = state
        state = .signingIn
        lastError = nil
        do {
            let receiver = try await LoopbackReceiver.start()
            self.receiver = receiver
            defer { receiver.stop(); self.receiver = nil }
            let verifier = PKCE.makeVerifier()
            let nonce = UUID().uuidString
            let redirect = "http://127.0.0.1:\(receiver.port)"
            openURL(Self.authorizationURL(client: client, redirect: redirect, challenge: PKCE.challenge(for: verifier), state: nonce))
            let query = try await receiver.redirect(timeout: 300)
            guard query["state"] == nonce else { throw GoogleAuthError.stateMismatch }
            if let error = query["error"] { throw GoogleAuthError.denied(error) }
            guard let code = query["code"] else { throw GoogleAuthError.noCode }
            let tokens = try await Self.exchange(code: code, client: client, redirect: redirect, verifier: verifier)
            guard tokens.scopes.contains(Self.calendarScope) else { throw GoogleAuthError.calendarNotGranted }
            guard let refresh = tokens.refreshToken else { throw GoogleAuthError.noRefreshToken }
            let email = tokens.email ?? ""
            storage.set(refresh, SecretKey.googleRefreshToken)
            storage.set(email, SecretKey.googleEmail)
            token = (tokens.accessToken, tokens.expiry)
            state = .signedIn(email: email)
        } catch {
            state = previous
            lastError = error.localizedDescription
            Log.calendar.error("Google sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Stops waiting for the browser.
    func cancelSignIn() {
        receiver?.fail(GoogleAuthError.cancelled)
    }

    func signOut() async {
        if let refresh = storage.get(SecretKey.googleRefreshToken) {
            _ = try? await Self.post(Self.revokeEndpoint, form: ["token": refresh])
        }
        forget()
    }

    private func forget() {
        storage.set(nil, SecretKey.googleRefreshToken)
        storage.set(nil, SecretKey.googleEmail)
        token = nil
        state = .signedOut
    }

    // MARK: Access tokens

    /// A current access token, renewed from the refresh token when needed.
    func accessToken() async throws -> String {
        if let token, token.expires > .now { return token.value }
        if let renewing { return try await renewing.value }
        guard let client, let refresh = storage.get(SecretKey.googleRefreshToken) else { throw GoogleAuthError.signedOut }
        let task = Task { () throws -> String in
            let tokens = try await Self.renew(refreshToken: refresh, client: client)
            self.token = (tokens.accessToken, tokens.expiry)
            return tokens.accessToken
        }
        renewing = task
        defer { renewing = nil }
        do {
            return try await task.value
        } catch GoogleAuthError.expired {
            forget()
            lastError = GoogleAuthError.expired.localizedDescription
            throw GoogleAuthError.expired
        }
    }

    /// After a 401 the cached token is useless even if not yet expired.
    func discardAccessToken() { token = nil }

    // MARK: Protocol

    nonisolated struct Tokens: Sendable {
        var accessToken: String
        var expiry: Date
        var refreshToken: String?
        var scopes: Set<String>
        var email: String?
    }

    nonisolated static func authorizationURL(client: GoogleOAuthClient, redirect: String, challenge: String, state: String) -> URL {
        var c = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // A refresh token every time, so signing in again always works.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    nonisolated static func exchange(code: String, client: GoogleOAuthClient, redirect: String, verifier: String) async throws -> Tokens {
        try parseTokens(try await post(tokenEndpoint, form: [
            "code": code, "client_id": client.id, "client_secret": client.secret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ]))
    }

    nonisolated static func renew(refreshToken: String, client: GoogleOAuthClient) async throws -> Tokens {
        try parseTokens(try await post(tokenEndpoint, form: [
            "refresh_token": refreshToken, "client_id": client.id, "client_secret": client.secret,
            "grant_type": "refresh_token",
        ]))
    }

    nonisolated static func parseTokens(_ data: Data) throws -> Tokens {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String else { throw GoogleAuthError.noRefreshToken }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let scopes = Set(((json["scope"] as? String) ?? "").split(separator: " ").map(String.init))
        return Tokens(accessToken: access, expiry: Date.now.addingTimeInterval(expiresIn - 60),
                      refreshToken: json["refresh_token"] as? String, scopes: scopes,
                      email: (json["id_token"] as? String).flatMap(emailFromIDToken))
    }

    /// The ID token comes straight from Google's token endpoint over TLS, so
    /// reading its payload without checking the signature is fine (Google's
    /// own guidance); it only labels the account in Settings.
    nonisolated static func emailFromIDToken(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    nonisolated static func post(_ url: URL, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["error"] as? String ?? "HTTP \(status)"
            if code == "invalid_grant" { throw GoogleAuthError.expired }
            throw GoogleAuthError.server((json?["error_description"] as? String) ?? code)
        }
        return data
    }
}

/// PKCE (RFC 7636): the browser leg carries only a hash of a secret that
/// the token request then proves.
nonisolated enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Accepts the one browser redirect Google sends to http://127.0.0.1:<port>
/// after sign-in, answers it with a short page, and hands over the query.
nonisolated final class LoopbackReceiver: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "verbatim.google.loopback")
    private let outcome = Locked<Result<[String: String], Error>?>(nil)
    private let waiter = Locked<CheckedContinuation<[String: String], Error>?>(nil)

    private init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    /// Listens on a free port of 127.0.0.1 (never on the network).
    static func start() async throws -> LoopbackReceiver {
        let receiver = try LoopbackReceiver()
        let listener = receiver.listener
        listener.newConnectionHandler = { [weak receiver] connection in
            if let receiver { receiver.handle(connection) } else { connection.cancel() }
        }
        receiver.port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ r in defer { r = true }; return !r }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case let .failed(error):
                    if resumed.withLock({ r in defer { r = true }; return !r }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: receiver.queue)
        }
        return receiver
    }

    /// The redirect's query items, once the browser arrives.
    func redirect(timeout seconds: Double) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.fail(TimeoutError(seconds: seconds))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            if let done = outcome.current {
                continuation.resume(with: done)
            } else {
                waiter.withLock { $0 = continuation }
                // The redirect may have landed between the check and the store.
                if let done = outcome.current, let w = waiter.withLock({ w in defer { w = nil }; return w }) { w.resume(with: done) }
            }
        }
    }

    func fail(_ error: Error) { finish(.failure(error)) }

    func stop() { listener.cancel() }

    private func finish(_ result: Result<[String: String], Error>) {
        let first = outcome.withLock { o -> Bool in
            guard o == nil else { return false }
            o = result
            return true
        }
        guard first, let w = waiter.withLock({ w in defer { w = nil }; return w }) else { return }
        w.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            guard text.contains("\r\n\r\n") || complete || error != nil else {
                self.receive(on: connection, buffer: buffer)
                return
            }
            self.respond(to: text, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // Browsers also ask for /favicon.ico; only the redirect has a code or error.
        let isRedirect = query["code"] != nil || query["error"] != nil
        let ok = query["code"] != nil
        let page = isRedirect
            ? Self.page(ok ? "Verbatim is connected to Google Calendar." : "Google sign-in didn't finish.",
                        ok ? "You can close this tab and go back to Verbatim." : "Go back to Verbatim and try again.")
            : ""
        let status = isRedirect ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if isRedirect { finish(.success(query)) }
    }

    private static func page(_ title: String, _ detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Verbatim</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;color:#1b1b1b;background:#fafafa;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
        div{max-width:420px}h1{font-size:18px;font-weight:600;margin:0 0 8px}p{color:#666;margin:0}
        @media(prefers-color-scheme:dark){body{background:#141414;color:#e6e6e6}p{color:#999}}</style></head>
        <body><div><h1>\(title)</h1><p>\(detail)</p></div></body></html>
        """
    }
}
