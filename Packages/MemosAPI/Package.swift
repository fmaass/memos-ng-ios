// swift-tools-version: 6.2
import PackageDescription

// The bottom layer of the dependency rule (Features -> Core -> API): this package knows the wire
// format and nothing about the domain, so it must never reference a higher layer.
//
// The rule is checked by grepping THIS FILE for the names of the layers above it, so neither may
// appear here even inside a comment — a check a comment can defeat is not a check.
let package = Package(
    name: "MemosAPI",
    // macOS is declared as well as iOS so these two layers can be built and tested with SwiftPM
    // directly — that is how the gate proves they compile with -warnings-as-errors, which
    // xcodebuild cannot be asked to do for two package targets only. The layer above stays
    // iOS-only: its screens use iOS-only SwiftUI modifiers.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MemosAPI", targets: ["MemosAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "MemosAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            // openapi.json and openapi-generator-config.yaml stay IN the target's sources: they
            // are the plugin's declared inputs, and excluding them makes the plugin report that
            // the target has no document to generate from. The parity fixture is vendored from the
            // same commit and read by the Core test bundle, not by this library.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "MemosAPITests",
            dependencies: ["MemosAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
