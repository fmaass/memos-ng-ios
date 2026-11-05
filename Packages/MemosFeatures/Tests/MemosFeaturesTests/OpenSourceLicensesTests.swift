import Foundation
import Testing

@testable import MemosFeatures

/// The Licenses sheet's list (MEMNG-1128): the bundled file decodes, every entry can be shown, and
/// it names exactly the packages the tracked `Package.resolved` pins — so a dependency added or
/// bumped without the file being rewritten fails here rather than shipping an untrue list.
@Suite("Open-source licenses")
struct OpenSourceLicensesTests {
    /// The pins in `Package.resolved` on the day the file was written.
    private static let pinnedPackages = 13

    @Test("the bundled list decodes, one entry per pinned package")
    func bundledListDecodes() {
        #expect(OpenSourceLicenses.bundled.count == Self.pinnedPackages)
    }

    @Test("every entry has a name, a version, a licence and a repository to open")
    func everyEntryIsShowable() {
        #expect(!OpenSourceLicenses.bundled.isEmpty, "control: the file was bundled")
        for package in OpenSourceLicenses.bundled {
            #expect(!package.name.isEmpty)
            #expect(!package.version.isEmpty, "\(package.name) has no version")
            #expect(!package.license.isEmpty, "\(package.name) has no licence")
            #expect(package.repository.scheme == "https", "\(package.name): \(package.repository)")
        }
    }

    @Test("the list names exactly the packages Package.resolved pins, at their versions")
    func listMatchesThePins() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MemosFeaturesTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MemosFeatures
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // the repository
        let data = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let resolved = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try #require(resolved["pins"] as? [[String: Any]])
        #expect(pins.count == Self.pinnedPackages, "control: the pins were read")

        var pinned: [String: String] = [:]
        for pin in pins {
            let identity = try #require(pin["identity"] as? String)
            let state = try #require(pin["state"] as? [String: Any])
            let version = try #require(state["version"] as? String, "\(identity): no version")
            pinned[identity] = version
        }
        let listed = Dictionary(
            uniqueKeysWithValues: OpenSourceLicenses.bundled.map {
                ($0.repository.lastPathComponent.lowercased(), $0.version)
            }
        )
        #expect(listed == pinned)
    }

    @Test("an entry without a licence is refused, not shown blank")
    func incompleteEntryIsRefused() {
        let incomplete = Data(#"{"packages":[{"name":"x","version":"1.0.0"}]}"#.utf8)
        #expect(throws: DecodingError.self) { try OpenSourceLicenses.decode(incomplete) }
    }
}
