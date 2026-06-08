# SegOps Swift SDK

Behavioral segmentation SDK for Apple platforms (iOS 16+, macOS 13+, watchOS 9+, tvOS 16+).

## Install

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/segops/sdk-swift.git", from: "0.1.0"),
]
```

## Usage

### Public key (`pk_…`) — recommended for shipped apps

A public key is safe to embed in a binary. The SDK exchanges it for a short-lived
session token via the handshake. Bind events to a logged-in user by signing the
user id on your backend and returning it from `userProvider`.

```swift
import SegOps

let client = SegOpsClient(options: .init(
    apiURL: URL(string: "https://api.segops.ai")!,
    apiKey: "pk_...",
    userProvider: {
        SegOpsUserContext(userId: currentUser.id,
                          userIdSig: signed.sig,   // from your backend
                          userIdTs: signed.ts)
    }
))

client.track(SegOpsEvent(userId: currentUser.id, eventType: "page_viewed",
                         payload: ["path": "/home"]))
```

Enable **"require signed user_id"** on the public key so the server rejects
unsigned or forged identities. Keys used by mobile apps should have an **empty
origin allowlist** (mobile clients send no `Origin` header).

### Secret key (`sk_…`) — server-side only

```swift
let client = SegOpsClient(options: .init(
    apiURL: URL(string: "https://api.segops.ai")!,
    apiKey: "sk_..."
))
```

Never ship a secret key in a client binary.

## License

MIT
