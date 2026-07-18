import Foundation

/// SDK-managed anonymous id.
///
/// A stable id is generated once and persisted (UserDefaults by default; supply
/// a Keychain-backed `AnonStore` to survive reinstalls). It is attached to every
/// event and to the `pk_` session mint so the server can reconcile pre-login
/// activity once the visitor identifies, and is **rotated on `reset()`** (logout)
/// so a shared device never inherits the previous user's anonymous trail.

/// Storage key used by the default `UserDefaultsAnonStore`.
public let segOpsAnonStorageKey = "segops_anon_id"

/// Pluggable persistence for the anonymous id — defaults to `UserDefaults`,
/// injectable for tests or a Keychain-backed implementation.
public protocol AnonStore: Sendable {
    func get() -> String?
    func set(_ id: String)
    func clear()
}

/// Default store. Persists the anonymous id in `UserDefaults`, which survives app
/// launches and is cleared on uninstall. For an id that survives reinstalls,
/// provide a Keychain-backed `AnonStore` via `SegOpsOptions.anonStore`.
public struct UserDefaultsAnonStore: AnonStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = segOpsAnonStorageKey) {
        self.defaults = defaults
        self.key = key
    }

    public func get() -> String? { defaults.string(forKey: key) }
    public func set(_ id: String) { defaults.set(id, forKey: key) }
    public func clear() { defaults.removeObject(forKey: key) }
}

func generateAnonId() -> String {
    UUID().uuidString.lowercased()
}

/// Return the persisted anonymous id, creating and storing one if absent.
public func getOrCreateAnonId(_ store: AnonStore) -> String {
    if let existing = store.get(), !existing.isEmpty { return existing }
    let id = generateAnonId()
    store.set(id)
    return id
}

/// Discard the current anonymous id and persist a fresh one. Returns the new id.
public func rotateAnonId(_ store: AnonStore) -> String {
    store.clear()
    let id = generateAnonId()
    store.set(id)
    return id
}
