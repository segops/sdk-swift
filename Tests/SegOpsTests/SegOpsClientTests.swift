import XCTest
@testable import SegOps

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
}
