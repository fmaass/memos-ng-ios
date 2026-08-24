// swift-tools-version: 6.2
import PackageDescription

// The top layer of the dependency rule (Features -> Core -> API): screens only. It reaches the API
// through MemosCore, never directly, and nothing imports it back.
let package = Package(
    name: "MemosFeatures",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "MemosFeatures", targets: ["MemosFeatures"])
    ],
    dependencies: [
        .package(path: "../MemosCore"),
        .package(path: "../MemosOutbox"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "MemosFeatures",
            dependencies: [
                .product(name: "MemosCore", package: "MemosCore"),
                .product(name: "MemosOutbox", package: "MemosOutbox"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "MemosFeaturesTests",
            dependencies: [
                "MemosFeatures",
                .product(name: "MemosOutbox", package: "MemosOutbox"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
