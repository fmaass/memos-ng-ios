import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A `UserDefaults` of its own per test. The shared domain is the device's real settings, and a
/// suite that wrote into it would change the app's appearance on whatever machine ran the gate.
private func scratchDefaults() -> (defaults: UserDefaults, name: String) {
    let name = "memosng.settings.tests.\(UUID().uuidString)"
    return (defaults: UserDefaults(suiteName: name)!, name: name)
}

private func forgetting(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
}

@MainActor
@Suite("The appearance choice, and that it survives a launch")
struct AppSettingsTests {
    /// The default is System, and it is a CHOICE — a phone that switches at sunset is what most
    /// people want, and a fresh install must not be pinned to Light by accident.
    @Test("a store with nothing written reads as System")
    func emptyIsSystem() {
        let (defaults, name) = scratchDefaults()
        defer { forgetting(name) }
        #expect(AppSettings(defaults: defaults).appearance == .system)
    }

    /// The property that makes it a SETTING rather than a toggle: a second store over the same
    /// storage — which is what the next launch is — reads back what the first one chose. Remove
    /// the write from `select` and this goes red.
    @Test("a choice is still there for the next launch")
    func choiceSurvivesTheStore() {
        let (defaults, name) = scratchDefaults()
        defer { forgetting(name) }
        for choice in AppearancePreference.allCases {
            AppSettings(defaults: defaults).select(choice)
            #expect(AppSettings(defaults: defaults).appearance == choice)
        }
    }

    @Test("choosing changes the store it was chosen on")
    func choosingChangesTheStore() {
        let (defaults, name) = scratchDefaults()
        defer { forgetting(name) }
        let settings = AppSettings(defaults: defaults)

        settings.select(.dark)

        #expect(settings.appearance == .dark)
        #expect(defaults.string(forKey: AppSettings.appearanceKey) == "dark")
    }

    /// One case per input CATEGORY. A settings key is read on every launch forever, and the only
    /// safe reading of a value this version cannot understand is the default — never a crash, and
    /// never a silent Light.
    @Test("every shape a stored value can have resolves to something")
    func storedValuesAllResolve() {
        #expect(AppSettings.appearance(fromStored: nil) == .system)
        #expect(AppSettings.appearance(fromStored: "") == .system)
        #expect(AppSettings.appearance(fromStored: "sepia") == .system)
        #expect(AppSettings.appearance(fromStored: "Dark") == .system)
        #expect(AppSettings.appearance(fromStored: "system") == .system)
        #expect(AppSettings.appearance(fromStored: "light") == .light)
        #expect(AppSettings.appearance(fromStored: "dark") == .dark)
    }

    /// `nil` is the opinion "follow the device", which is exactly what `preferredColorScheme(nil)`
    /// means — so System must map to nil and the other two must not.
    @Test("each choice names the scheme SwiftUI is given")
    func schemesAreNamed() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }
}

@MainActor
@Suite("The default a new memo gets")
struct DefaultVisibilityChoiceTests {
    /// Two states, settled 2026-08-25. This is here so that adding a third has to be a deliberate
    /// act with a red test in front of it, rather than a line someone appends.
    @Test("exactly two states are offered, public first")
    func twoStatesOnly() {
        #expect(DefaultVisibilityChoice.offered == [.public, .private])
    }

    /// One case per input category, the account's third state included: a screen that showed a
    /// PROTECTED account as Private would be lying about who can read their memos.
    @Test("only an offered default is checked")
    func selectionCoversEveryState() {
        #expect(DefaultVisibilityChoice.selection(for: .public) == .public)
        #expect(DefaultVisibilityChoice.selection(for: .private) == .private)
        #expect(DefaultVisibilityChoice.selection(for: .protected) == nil)
        #expect(DefaultVisibilityChoice.selection(for: nil) == nil)
    }

    @Test("the state this app does not offer is explained rather than hidden")
    func noticeOnlyForTheUnofferedState() throws {
        #expect(DefaultVisibilityChoice.notice(for: .public) == nil)
        #expect(DefaultVisibilityChoice.notice(for: .private) == nil)
        #expect(DefaultVisibilityChoice.notice(for: nil) == nil)
        let notice = try #require(DefaultVisibilityChoice.notice(for: .protected))
        #expect(notice.contains("Protected"))
    }

    /// The round trip the section exists for, over the function the compose sheet actually reads.
    ///
    /// `SessionStore.setDefaultVisibility` is what puts the choice into `defaultVisibility` (that
    /// half is asserted against a real transport in `SessionDefaultVisibilityTests`); this is the
    /// other half — an untouched compose sheet, whose `selection` is nil because nobody has
    /// overridden anything, resolves to exactly the account default and nothing else. Break the
    /// `accountDefault` argument in `ComposeView` and this stops describing the app.
    @Test("an untouched compose sheet gets exactly the chosen default")
    func theDefaultReachesTheNextCompose() {
        for chosen in DefaultVisibilityChoice.offered {
            #expect(
                VisibilityChoice.resolved(selection: nil, accountDefault: chosen) == chosen
            )
            #expect(
                VisibilityChoice.accessibilityLabel(selection: nil, accountDefault: chosen)
                    == "Visibility: \(chosen.label), the account default"
            )
        }
    }

    /// And an explicit choice on the sheet still wins over the default — otherwise "apply the
    /// default" would have quietly become "ignore the person".
    @Test("choosing on the sheet still overrides the default")
    func anExplicitChoiceWins() {
        #expect(
            VisibilityChoice.resolved(selection: .private, accountDefault: .public) == .private
        )
    }
}

@MainActor
@Suite("The account's picture")
struct AccountAvatarTests {
    /// Real base64 of real PNG bytes, decoded by the function under test — not a value this file
    /// made up and then recognised.
    @Test("a stored data URL decodes to the bytes it carries")
    func dataURLDecodes() throws {
        let png = MediaFixture.png(.red, side: 4)
        let stored = "data:image/png;base64,\(png.base64EncodedString())"

        let decoded = try #require(AccountAvatar.imageData(from: stored))

        #expect(decoded == png)
        #expect(UIImage(data: decoded) != nil)
    }

    /// One case per category of stored value. The bare path is the one that matters: old memos
    /// migrated avatars as paths, this app has no route that serves them, and guessing one would
    /// paint a broken image where an honest monogram belongs.
    @Test("everything that is not a data URL yields no picture")
    func nonDataURLsYieldNothing() {
        #expect(AccountAvatar.imageData(from: nil) == nil)
        #expect(AccountAvatar.imageData(from: "") == nil)
        #expect(AccountAvatar.imageData(from: "/o/r/avatar.png") == nil)
        #expect(AccountAvatar.imageData(from: "https://example.invalid/a.png") == nil)
        // A data URL that is not base64 — the server never writes one, and it is not decodable.
        #expect(AccountAvatar.imageData(from: "data:image/svg+xml,<svg/>") == nil)
        #expect(AccountAvatar.imageData(from: "data:text/plain;base64,AAAA") == nil)
    }

    @Test("a name always produces something to draw")
    func initialsCoverEveryName() {
        #expect(AccountAvatar.initials(for: "Fabian") == "F")
        #expect(AccountAvatar.initials(for: "Fabian Maass") == "FM")
        #expect(AccountAvatar.initials(for: "ada b lovelace") == "AL")
        #expect(AccountAvatar.initials(for: "laura") == "L")
        #expect(AccountAvatar.initials(for: "") == "?")
        #expect(AccountAvatar.initials(for: "   ") == "?")
    }
}

@MainActor
@Suite("What About can say")
struct AboutInfoTests {
    @Test("the version line says as much as the bundle declares")
    func versionLineCoversEveryBundle() {
        #expect(AboutInfo.versionLine(shortVersion: "1.2", build: "34") == "1.2 (34)")
        #expect(AboutInfo.versionLine(shortVersion: "1.2", build: nil) == "1.2")
        #expect(AboutInfo.versionLine(shortVersion: "1.2", build: "") == "1.2")
        #expect(AboutInfo.versionLine(shortVersion: nil, build: "34") == "Unknown")
        #expect(AboutInfo.versionLine(shortVersion: "", build: "34") == "Unknown")
    }

    @Test("the server is named by host, or said to be absent")
    func serverLineNamesTheHost() throws {
        let url = try #require(URL(string: "https://memos.example.invalid"))
        #expect(AboutInfo.serverLine(for: url) == "memos.example.invalid")
        #expect(AboutInfo.serverLine(for: nil) == "Not signed in")
    }
}

@MainActor
@Suite("Clearing the media cache from Settings")
struct MediaCacheClearingTests {
    /// The defect this exists to prevent: there are TWO caches behind a photo, and emptying only
    /// the `URLCache` looks exactly like emptying both until the timeline is scrolled — every
    /// picture already seen would still paint, out of the decoded store, with nothing to re-fetch.
    @Test("both halves of the cache are emptied, not just the bytes")
    func bothCachesAreEmptied() throws {
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, diskPath: nil)
        let url = try #require(URL(string: "https://memos.example.invalid/api/attachments/x/thumb"))
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )
        )
        let png = MediaFixture.png(.red, side: 4)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: png), for: request
        )

        let decoded = MediaImageStore(countLimit: 8, totalCostLimit: 1 << 20)
        let image = try #require(UIImage(data: png))
        let key = MediaImageKey(uid: "x", tier: "thumb")
        decoded.store(image, forKey: key, generation: decoded.generation)
        #expect(decoded.image(forKey: key) != nil)
        #expect(cache.cachedResponse(for: request) != nil)

        MediaCacheClearing.clearDerived(cache: cache, decoded: decoded)

        #expect(cache.cachedResponse(for: request) == nil)
        #expect(decoded.image(forKey: key) == nil)
    }

    @Test("the size shown is read from the cache it clears")
    func usageComesFromTheSameCache() {
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 4 << 20, diskPath: nil)
        #expect(MediaCacheClearing.usage(of: cache).capacityBytes == cache.diskCapacity)
    }
}
