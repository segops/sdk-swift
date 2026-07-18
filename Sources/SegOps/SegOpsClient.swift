import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public types

/// A single user event in the canonical SegOps schema.
public struct SegOpsEvent: Sendable {
    public let userId: String
    public let eventType: String
    /// ISO-8601 timestamp. Defaults to the current time if nil.
    public let occurredAt: Date?
    public let payload: [String: any Sendable]

    public init(
        userId: String,
        eventType: String,
        occurredAt: Date? = nil,
        payload: [String: any Sendable] = [:]
    ) {
        self.userId = userId
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

/// User identity / trait update.
public struct SegOpsContext: Sendable {
    public let userId: String
    public let traits: [String: any Sendable]

    public init(userId: String, traits: [String: any Sendable]) {
        self.userId = userId
        self.traits = traits
    }
}

/// Identity supplied to the session handshake when authenticating with a public
/// key (pk_…). The id is exchanged for a short-lived session token.
///
/// For logged-in users, sign `userId` on your backend (HMAC-SHA256 over
/// `"\(userId)|\(unixSeconds)"` using the key's HMAC secret) and pass the hex
/// signature as `userIdSig` with the matching `userIdTs`. Keys created with
/// "require signed user_id" reject unsigned identities.
public struct SegOpsUserContext: Sendable {
    /// Authenticated user id. Omit for anonymous visitors.
    public let userId: String?
    /// Stable anonymous/device id for un-authenticated visitors.
    public let anonymousId: String?
    /// Hex HMAC signature of the user id (produced on your backend).
    public let userIdSig: String?
    /// Unix-seconds timestamp paired with `userIdSig`.
    public let userIdTs: Int?

    public init(
        userId: String? = nil,
        anonymousId: String? = nil,
        userIdSig: String? = nil,
        userIdTs: Int? = nil
    ) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.userIdSig = userIdSig
        self.userIdTs = userIdTs
    }
}

/// Configuration for `SegOpsClient`.
public struct SegOpsOptions: Sendable {
    /// Base URL of your SegOps deployment, e.g. "https://api.segops.ai".
    public var apiURL: URL
    /// API key. A public key (pk_…) — safe to embed in a shipped app — drives
    /// the session handshake; provide `userProvider`. A secret key (sk_…)
    /// authenticates directly and must never ship in a client binary.
    public var apiKey: String
    /// Required when `apiKey` is a public key (pk_…): returns the current user
    /// context at mint time. Defaults to an anonymous visitor.
    public var userProvider: (@Sendable () -> SegOpsUserContext)?
    /// Persistence for the SDK-managed anonymous id. Defaults to
    /// `UserDefaultsAnonStore`; supply a Keychain-backed store to survive
    /// reinstalls, or an in-memory store for tests.
    public var anonStore: AnonStore?
    /// Maximum events before an automatic flush. Default: 20.
    public var batchSize: Int
    /// Periodic flush interval. Default: 5 s.
    public var flushInterval: TimeInterval
    /// Error handler called on failed flushes. Default: prints to stderr.
    public var onError: (@Sendable (Error) -> Void)?

    public init(
        apiURL: URL,
        apiKey: String,
        userProvider: (@Sendable () -> SegOpsUserContext)? = nil,
        anonStore: AnonStore? = nil,
        batchSize: Int = 20,
        flushInterval: TimeInterval = 5,
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.userProvider = userProvider
        self.anonStore = anonStore
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.onError = onError
    }
}

// MARK: - Client

/// Thread-safe SegOps event client.
///
/// Public key (recommended for shipped apps):
/// ```swift
/// let client = SegOpsClient(options: .init(
///     apiURL: URL(string: "https://api.segops.ai")!,
///     apiKey: "pk_...",
///     userProvider: { SegOpsUserContext(userId: currentUser.id,
///                                       userIdSig: sig, userIdTs: ts) }
/// ))
///
/// client.track(SegOpsEvent(userId: "u-123", eventType: "page_viewed",
///                           payload: ["path": "/home"]))
/// ```
public final class SegOpsClient: @unchecked Sendable {

    private let options: SegOpsOptions
    private let session: URLSession
    /// Set when authenticating with a public key (pk_…) — drives the handshake.
    /// `var` only so the handshake's user provider can capture `self`; never
    /// reassigned after init.
    private var sessionManager: SessionManager?

    /// Persistence for the SDK-managed anonymous id.
    private let anonStore: AnonStore
    /// Current anonymous id (lock-protected; rotated by `reset()`).
    private var anonId: String
    /// Identity bound via `identify()` / cleared by `reset()`. Once either has
    /// been called, this state supersedes the `userProvider` option.
    private var identity: SegOpsUserContext?
    private var identityIsExplicit = false

    private var queue: [SegOpsEvent] = []
    private let lock = NSLock()
    private var timer: Timer?

    public init(options: SegOpsOptions) {
        self.options = options
        self.session = URLSession(configuration: .ephemeral)

        let store = options.anonStore ?? UserDefaultsAnonStore()
        self.anonStore = store
        self.anonId = getOrCreateAnonId(store)
        self.identity = nil
        self.sessionManager = nil

        if options.apiKey.hasPrefix("pk_") {
            // Always attach the SDK-managed anon id (plus any signed identity)
            // so the mint can reconcile anon→identified server-side.
            self.sessionManager = SessionManager(
                apiURL: options.apiURL,
                apiKey: options.apiKey,
                userProvider: { [weak self] in
                    self?.userForMint() ?? SegOpsUserContext()
                },
                session: self.session
            )
        }

        let interval = options.flushInterval
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(
                withTimeInterval: interval,
                repeats: true
            ) { [weak self] _ in
                self?.flush()
            }
        }

        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
        #endif
    }

    deinit {
        timer?.invalidate()
        flush()
    }

    // MARK: Public API

    /// Enqueue a user event. Flushes automatically when batchSize is reached.
    public func track(_ event: SegOpsEvent) {
        lock.lock()
        queue.append(event)
        let shouldFlush = queue.count >= options.batchSize
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// Record user trait updates as a `context_identified` event.
    public func identify(_ context: SegOpsContext) {
        track(SegOpsEvent(
            userId: context.userId,
            eventType: "context_identified",
            payload: context.traits
        ))
    }

    /// Bind the current visitor to a logged-in identity (call after login).
    ///
    /// The id is attached — alongside the SDK-managed anonymous id — to the next
    /// `pk_` session mint and to subsequent events, so the server reconciles the
    /// pre-login anonymous trail onto this user. The session token is re-minted
    /// transparently. Sign `userId` on your backend and pass the hex signature
    /// as `userIdSig` with the matching `userIdTs` for keys that require it.
    ///
    /// Pass `traits` to also record a `context_identified` event in one call.
    public func identify(
        userId: String,
        userIdSig: String? = nil,
        userIdTs: Int? = nil,
        traits: [String: any Sendable]? = nil
    ) {
        lock.lock()
        identityIsExplicit = true
        identity = SegOpsUserContext(
            userId: userId,
            anonymousId: anonId,
            userIdSig: userIdSig,
            userIdTs: userIdTs
        )
        lock.unlock()
        sessionManager?.invalidate() // re-mint so the new identity reconciles
        if let traits {
            identify(SegOpsContext(userId: userId, traits: traits))
        }
    }

    /// Clear the identified user and **rotate the anonymous id** (call on logout)
    /// so the next person on a shared device never inherits this user's trail.
    /// The session token is re-minted on the next event.
    public func reset() {
        lock.lock()
        identityIsExplicit = true
        identity = nil
        anonId = rotateAnonId(anonStore)
        lock.unlock()
        sessionManager?.invalidate()
    }

    /// The current SDK-managed anonymous id. Useful as the `userId` on events for
    /// visitors who have not logged in yet.
    public var anonymousId: String {
        lock.lock(); defer { lock.unlock() }
        return anonId
    }

    /// Flush all buffered events immediately (fire-and-forget).
    public func flush() {
        lock.lock()
        guard !queue.isEmpty else { lock.unlock(); return }
        let batch = queue
        queue.removeAll()
        lock.unlock()
        sendBatch(batch)
    }

    // MARK: - Internal

    /// Identity sent to the session mint: the explicit `identify()`/`reset()`
    /// state once set, otherwise the `userProvider` option, always carrying the
    /// SDK-managed anonymous id.
    private func userForMint() -> SegOpsUserContext {
        lock.lock()
        let explicit = identityIsExplicit
        let bound = identity
        let anon = anonId
        lock.unlock()

        let base: SegOpsUserContext
        if explicit {
            base = bound ?? SegOpsUserContext()
        } else if let provider = options.userProvider {
            base = provider()
        } else {
            base = SegOpsUserContext()
        }
        return SegOpsUserContext(
            userId: base.userId,
            anonymousId: base.anonymousId ?? anon,
            userIdSig: base.userIdSig,
            userIdTs: base.userIdTs
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func sendBatch(_ events: [SegOpsEvent]) {
        let anon = anonymousId
        var payload: [[String: Any]] = []
        for e in events {
            let ts = e.occurredAt.map { Self.iso8601.string(from: $0) }
                     ?? Self.iso8601.string(from: Date())
            payload.append([
                "user_id": e.userId,
                "anonymous_id": anon,
                "event_type": e.eventType,
                "occurred_at": ts,
                "payload": e.payload,
            ])
        }

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: ["events": payload])
        } catch {
            handleError(error)
            return
        }

        let url = options.apiURL.appendingPathComponent("api/ingestion/track/batch/")

        guard let sm = sessionManager else {
            perform(url: url, body: bodyData, auth: "ApiKey \(options.apiKey)", allowReauth: false)
            return
        }
        sm.validToken { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleError(error)
            case .success(let token):
                self.perform(url: url, body: bodyData, auth: "Bearer \(token)", allowReauth: true)
            }
        }
    }

    /// POST the batch. On a 401 in session mode, re-mint once and retry.
    private func perform(url: URL, body: Data, auth: String, allowReauth: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            if let error {
                self.handleError(error)
                return
            }
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 401, allowReauth, let sm = self.sessionManager {
                sm.invalidate()
                sm.validToken { result in
                    switch result {
                    case .failure(let error):
                        self.handleError(error)
                    case .success(let token):
                        self.perform(url: url, body: body, auth: "Bearer \(token)", allowReauth: false)
                    }
                }
                return
            }
            if http.statusCode >= 300 {
                self.handleError(SegOpsError.httpError(http.statusCode))
            }
        }.resume()
    }

    private func handleError(_ error: Error) {
        if let handler = options.onError {
            handler(error)
        } else {
            fputs("[SegOps] error: \(error)\n", stderr)
        }
    }
}

// MARK: - Session handshake

/// Mints and caches short-lived session JWTs from a public key. A single token
/// is reused until it nears expiry, then transparently re-minted. Concurrent
/// callers share one in-flight mint.
final class SessionManager: @unchecked Sendable {

    private struct MintResponse: Decodable {
        let token: String
        let expires_at: String
    }

    private let apiURL: URL
    private let apiKey: String
    private let userProvider: @Sendable () -> SegOpsUserContext
    private let session: URLSession

    private let lock = NSLock()
    private var token: String?
    private var expiresAtMs: Double = 0
    private var minting = false
    private var waiters: [(Result<String, Error>) -> Void] = []

    /// Refresh 60 s before expiry.
    private let refreshSkewMs: Double = 60_000

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(
        apiURL: URL,
        apiKey: String,
        userProvider: @escaping @Sendable () -> SegOpsUserContext,
        session: URLSession
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.userProvider = userProvider
        self.session = session
    }

    func validToken(_ completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        if let token, nowMs() < expiresAtMs - refreshSkewMs {
            lock.unlock()
            completion(.success(token))
            return
        }
        waiters.append(completion)
        if minting {
            lock.unlock()
            return
        }
        minting = true
        lock.unlock()
        mint()
    }

    /// Drop the cached token so the next call re-mints (e.g. after a 401).
    func invalidate() {
        lock.lock()
        token = nil
        expiresAtMs = 0
        lock.unlock()
    }

    private func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private func mint() {
        let u = userProvider()
        var body: [String: Any] = [:]
        if let v = u.userId { body["user_id"] = v }
        if let v = u.anonymousId { body["anonymous_id"] = v }
        if let v = u.userIdSig { body["user_id_sig"] = v }
        if let v = u.userIdTs { body["user_id_ts"] = v }

        let url = apiURL.appendingPathComponent("api/auth/session/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            finish(.failure(error))
            return
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let data else {
                self.finish(.failure(SegOpsError.httpError(code)))
                return
            }
            do {
                let parsed = try JSONDecoder().decode(MintResponse.self, from: data)
                let expMs = Self.iso8601.date(from: parsed.expires_at)
                    .map { $0.timeIntervalSince1970 * 1000 } ?? 0
                self.lock.lock()
                self.token = parsed.token
                self.expiresAtMs = expMs
                self.lock.unlock()
                self.finish(.success(parsed.token))
            } catch {
                self.finish(.failure(error))
            }
        }.resume()
    }

    /// Resolve every queued waiter and clear the in-flight flag.
    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        minting = false
        lock.unlock()
        for waiter in pending {
            waiter(result)
        }
    }
}

// MARK: - Errors

public enum SegOpsError: LocalizedError {
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code): return "SegOps: HTTP \(code)"
        }
    }
}
