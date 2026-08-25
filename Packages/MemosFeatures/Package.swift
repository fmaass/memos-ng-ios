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
            // The accent lives in an asset catalogue rather than a literal because it has to
            // answer differently in light and dark. It is declared here as well as in the app's
            // own catalogue: the app's copy is what the SYSTEM reads for the global tint, this
            // one is what `Color(_:bundle: .module)` resolves. `DesignTokensTests` asserts the
            // two are the same colour, so the pair cannot drift.
            resources: [
                .process("Resources/DesignTokens.xcassets")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                // Where this layer's warnings become errors. The gate builds every other package
                // with SwiftPM and -warnings-as-errors on the command line; this one has no macOS
                // destination to build for, so it goes through xcodebuild for the simulator — and
                // every knob xcodebuild takes from a command line or an xcconfig reaches the
                // DEPENDENCIES too, which turns somebody else's warning into this gate's failure
                // (measured 2026-08-25: OpenAPIKit unsuppressed, MarkdownUI when scoped to the
                // simulator SDK). Declared on the target instead, it lands on this target only.
                // Debug alone: the gate builds Debug, and a release archive is no place to
                // discover a warning.
                .treatAllWarnings(as: .error, .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "MemosFeaturesTests",
            dependencies: [
                "MemosFeatures",
                .product(name: "MemosOutbox", package: "MemosOutbox"),
                // The parity suite projects what the RENDERER parsed rather than re-parsing the
                // markdown itself, so it builds a `MarkdownContent` and links MarkdownUI directly.
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
