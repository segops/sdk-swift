import XCTest
@testable import SegOps

/// In-memory anonymous-id store for deterministic, side-effect-free tests.
final class MemoryAnonStore: AnonStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ id: String) { lock.lock(); value = id; lock.unlock() }
    func clear() { lock.lock(); value = nil; lock.unlock() }
}

final class SegOpsClientTests: XCTestCase {
    func testPublicKeyEnablesSessionHandshake() {
        // A pk_ key constructs a client without throwing; sk_ does too.
        _ = SegOpsClient(options: .init(
            apiURL: URL(string: "https://api.segops.ai")!,
            apiKey: "pk_test",
            userProvider: { SegOpsUserContext(userId: "u1", userIdSig: "deadbeef", userIdTs: 1) }
        ))
        _ = SegOpsClient(options: .init(
            apiURL: URL(string: "https://api.segops.ai")!,
            apiKey: "sk_test"
        ))
    }

    func testUserContextDefaults() {
        let ctx = SegOpsUserContext(anonymousId: "anon")
        XCTAssertNil(ctx.userId)
        XCTAssertEqual(ctx.anonymousId, "anon")
    }

    // MARK: - Anonymous id

    func testGetOrCreateAnonIdCreatesAndPersists() {
        let store = MemoryAnonStore()
        let id = getOrCreateAnonId(store)
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(store.get(), id)
    }

    func testGetOrCreateAnonIdIsStable() {
        let store = MemoryAnonStore()
        let first = getOrCreateAnonId(store)
        let second = getOrCreateAnonId(store)
        XCTAssertEqual(first, second)
    }

    func testRotateProducesDifferentPersistedId() {
        let store = MemoryAnonStore()
        let original = getOrCreateAnonId(store)
        let rotated = rotateAnonId(store)
        XCTAssertNotEqual(rotated, original)
        XCTAssertEqual(store.get(), rotated)
    }

    func testRotateWorksWhenNothingStored() {
        let store = MemoryAnonStore()
        let rotated = rotateAnonId(store)
        XCTAssertFalse(rotated.isEmpty)
        XCTAssertEqual(store.get(), rotated)
    }

    // MARK: - Client identity

    func testClientExposesPersistedAnonId() {
        let store = MemoryAnonStore("fixed-anon")
        let client = SegOpsClient(options: .init(
            apiURL: URL(string: "https://api.segops.ai")!,
            apiKey: "sk_test",
            anonStore: store
        ))
        XCTAssertEqual(client.anonymousId, "fixed-anon")
    }

    func testResetRotatesAnonId() {
        let store = MemoryAnonStore("first")
        let client = SegOpsClient(options: .init(
            apiURL: URL(string: "https://api.segops.ai")!,
            apiKey: "sk_test",
            anonStore: store
        ))
        XCTAssertEqual(client.anonymousId, "first")
        client.reset()
        XCTAssertNotEqual(client.anonymousId, "first")
        XCTAssertEqual(client.anonymousId, store.get())
    }

    func testIdentifyKeepsAnonIdStable() {
        let store = MemoryAnonStore("keep-me")
        let client = SegOpsClient(options: .init(
            apiURL: URL(string: "https://api.segops.ai")!,
            apiKey: "pk_test",
            anonStore: store
        ))
        client.identify(userId: "user-42", userIdSig: "deadbeef", userIdTs: 1)
        // Binding an identity must not rotate the anon id — reconciliation needs
        // the pre-login id to stay attached.
        XCTAssertEqual(client.anonymousId, "keep-me")
    }
}
