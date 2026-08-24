// swift-tools-version: 6.2
import PackageDescription

// What the share extension does with what the system hands it, kept out of the extension target
// so it can be tested: a unit-test bundle cannot link an `.appex`, so anything that lives in the
// extension itself is untestable by construction.
//
// It depends on the outbox and on nothing else. That is the same rule the extension is held to —
// an extension may not carry a client, a session or a credential — expressed where the gate's
// dependency check can read it.
let package = Package(
    name: "MemosShareKit",
    // macOS is declared as well as iOS so this layer can be built with SwiftPM directly, the way
    // the layers below it are.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MemosShareKit", targets: ["MemosShareKit"])
    ],
    dependencies: [
        .package(path: "../MemosOutbox")
    ],
    targets: [
        .target(
            name: "MemosShareKit",
            dependencies: [
                .product(name: "MemosOutbox", package: "MemosOutbox")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemosShareKitTests",
            dependencies: [
                "MemosShareKit",
                .product(name: "MemosOutbox", package: "MemosOutbox"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
