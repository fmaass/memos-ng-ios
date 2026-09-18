import Foundation
import Testing

/// What the SHIPPED privacy manifests declare about the required-reason APIs this code reaches.
///
/// Read out of the BUILT bundles rather than out of the repository, because a manifest is a claim
/// about a binary and nothing else in the build has an opinion on whether it is true: a store that
/// starts keeping a setting in `UserDefaults` compiles, links and ships beside a manifest that says
/// the app has none — which is exactly what happened here. `Bundle.main` is the app, because
/// every test bundle in this project is hosted in it, and the extension's own manifest travels
/// inside that app under `PlugIns`.
@Suite("Privacy manifests")
struct PrivacyManifestTests {
    private static let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"

    /// Both domains this code writes through: the process's own defaults (`CA92.1`) and the app
    /// group's suite the outbox keeps the mobile-data choice in (`1C8F.1`).
    private static let userDefaultsReasons: Set<String> = ["CA92.1", "1C8F.1"]

    private func declaredReasons(inBundleAt bundle: URL, category: String) throws -> Set<String> {
        let manifest = bundle.appending(path: "PrivacyInfo.xcprivacy")
        let data = try #require(
            try? Data(contentsOf: manifest), "no PrivacyInfo.xcprivacy at \(manifest.path)"
        )
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let declared = (plist as? [String: Any])?["NSPrivacyAccessedAPITypes"]
        let types = try #require(declared as? [[String: Any]])
        let entry = types.first { $0["NSPrivacyAccessedAPIType"] as? String == category }
        let reasons = try #require(
            entry?["NSPrivacyAccessedAPITypeReasons"] as? [String],
            "\(category) is not declared in \(manifest.path)"
        )
        return Set(reasons)
    }

    @Test("the app declares the user defaults its settings and its fetch generation live in")
    func appDeclaresUserDefaults() throws {
        let reasons = try declaredReasons(
            inBundleAt: Bundle.main.bundleURL, category: Self.userDefaults
        )
        #expect(reasons == Self.userDefaultsReasons)
    }

    /// The extension never asks for a preference itself, but MemosOutbox — where the only use of
    /// the API in this repository lives — is linked into the `.appex`, and Apple reads each
    /// bundle's manifest against the executable that bundle carries.
    @Test("the share extension declares the user defaults the outbox linked into it reaches")
    func shareExtensionDeclaresUserDefaults() throws {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        let appex = plugIns.appending(path: "MemosShare.appex")
        let reasons = try declaredReasons(inBundleAt: appex, category: Self.userDefaults)
        #expect(reasons == Self.userDefaultsReasons)
    }
}
