// swift-tools-version: 6.2
import PackageDescription

// The durability layer: a capture lives here until the server has confirmed it, so this package
// answers to the file system and the standard library and to nothing else. It has no package
// dependencies on purpose — the on-disk format of a queued capture is decided here, not derived
// from a generated schema that a re-sync can change under it.
//
// That is also what licenses the hand-rolled wire types in `OutboxWire`. A hand-rolled wire type
// is allowed only where the generated one is UNREACHABLE from the layer that needs it, and here
// exactly one ground carries it: this dependency rule. Taking no package dependencies means the
// generated client cannot be imported from this layer at all. The shape of the calls is not a
// second ground, and preference is never one. The licence is conditional on the vendored-document
// contract test, which must pin every semantic those mirrors consume.
let package = Package(
    name: "MemosOutbox",
    // macOS is declared as well as iOS so this layer can be built with SwiftPM directly — that is
    // how the gate proves it compiles with -warnings-as-errors.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MemosOutbox", targets: ["MemosOutbox"])
    ],
    targets: [
        .target(
            name: "MemosOutbox",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemosOutboxTests",
            dependencies: ["MemosOutbox"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
