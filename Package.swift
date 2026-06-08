// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SegOps",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "SegOps", targets: ["SegOps"]),
    ],
    targets: [
        .target(
            name: "SegOps",
            path: "Sources/SegOps"
        ),
        .testTarget(
            name: "SegOpsTests",
            dependencies: ["SegOps"],
            path: "Tests/SegOpsTests"
        ),
    ]
)
