// swift-tools-version: 6.2
import PackageDescription

// The durability layer: a capture lives here until the server has confirmed it, so this package
// answers to the file system and the standard library and to nothing else. It has no package
// dependencies on purpose — the on-disk format of a queued capture is decided here, not derived
// from a generated schema that a re-sync can change under it, and the small set of wire fields it
// consumes are mirrored locally (the chunk PATCH and the offset HEAD cannot be driven from the
// vendored document at all: the raw-bytes body and the Upload-Offset response header are
// unmodelled).
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
