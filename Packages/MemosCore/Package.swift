// swift-tools-version: 6.2
import PackageDescription

// The middle layer of the dependency rule (Features -> Core -> API): domain models, stores and the
// pure functions ported from the SPA. It may depend on the API layer and must never reference the
// Features layer — nothing imports Features.
//
// The rule is checked by grepping THIS FILE for the name of the layer above it, so that name may
// not appear here even inside a comment.
let package = Package(
    name: "MemosCore",
    // macOS is declared as well as iOS so these two layers can be built and tested with SwiftPM
    // directly — that is how the gate proves they compile with -warnings-as-errors, which
    // xcodebuild cannot be asked to do for two package targets only. The layer above stays
    // iOS-only: its screens use iOS-only SwiftUI modifiers.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MemosCore", targets: ["MemosCore"])
    ],
    dependencies: [
        .package(path: "../MemosAPI"),
        // The queue of captures waiting for the server. It depends on nothing, and this layer
        // depends on it only to implement the one protocol it asks for: where the server is, who
        // is signed in, and the bearer token of the moment.
        .package(path: "../MemosOutbox"),
        // Not a layering break: the generated request types ARE OpenAPIRuntime types, and the
        // default arguments Core inlines when it builds one (`Input.Headers.init(accept:)`) are
        // defined in that module, so Core has to link it or the symbols are simply missing.
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
    ],
    targets: [
        .target(
            name: "MemosCore",
            dependencies: [
                .product(name: "MemosAPI", package: "MemosAPI"),
                .product(name: "MemosOutbox", package: "MemosOutbox"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemosCoreTests",
            dependencies: [
                "MemosCore",
                .product(name: "MemosAPI", package: "MemosAPI"),
                .product(name: "MemosOutbox", package: "MemosOutbox"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
