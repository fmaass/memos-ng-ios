import Foundation
import MemosCore
import SwiftUI
import UIKit

// The decisions the Settings screen and the account menu read. Pure functions over the account's
// settings, each one tested directly; the screens above them stay thin enough to be obvious.

/// Which default visibilities the Settings screen offers, and what to say about one it does not.
enum DefaultVisibilityChoice {
    /// Public and Private. Two states, by decision rather than by omission.
    ///
    /// The server's enum has three and the web app offers all three — the middle one, PROTECTED,
    /// being the household. The native app offers two because that is the model it was asked for:
    /// settled 2026-08-25, no household tier here, and the ticket that would have introduced one
    /// is cancelled. So this list is not a stub waiting to grow; adding to it would be reopening a
    /// closed question.
    ///
    /// PROTECTED is still READ, because the web app can still set it and a screen that silently
    /// showed such an account as Private would be lying about who can see their memos — see
    /// `selection` and `notice` below.
    ///
    /// Ordered the way the account is most likely to want them — public is the household norm,
    /// which is also why the globe carries no word beside it anywhere else in the app.
    static let offered: [MemoVisibility] = [.public, .private]

    /// Which offered row is checked, given what the account is actually set to. `nil` means the
    /// account holds a value this screen does not offer, and nothing is checked — inventing a
    /// checkmark there would be the screen claiming a setting it is not showing.
    static func selection(for accountDefault: MemoVisibility?) -> MemoVisibility? {
        guard let accountDefault, offered.contains(accountDefault) else { return nil }
        return accountDefault
    }

    /// What the screen says when the account's default is one it does not offer — which can only
    /// be PROTECTED, set from the web app. `nil` the rest of the time, which is nearly always.
    static func notice(for accountDefault: MemoVisibility?) -> String? {
        guard let accountDefault, !offered.contains(accountDefault) else { return nil }
        return "This account's default is \(accountDefault.label), which this app cannot set yet."
            + " Choosing here replaces it."
    }
}

/// The account's picture, and what stands in when there is none.
enum AccountAvatar {
    /// The bytes behind the stored value, or `nil` when there is no picture to draw.
    ///
    /// The server stores an avatar as a `data:image/…;base64,…` URL and validates that shape on
    /// the way in, so that is the only shape decoded here. A value in any other form is one of the
    /// bare paths carried over by the migration from old memos: this app has no route that serves
    /// those, and guessing one would produce a broken image rather than an honest monogram.
    static func imageData(from value: String?) -> Data? {
        guard let value, value.hasPrefix("data:image/") else { return nil }
        guard let separator = value.range(of: ";base64,") else { return nil }
        let payload = value[separator.upperBound...]
        return Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters)
    }

    /// The account's picture, decoded off the main actor.
    ///
    /// Through the same decoder every photo in the app goes through: an avatar is a data URL of a
    /// few hundred kilobytes, which is small for a picture and far too much to decode on the frame
    /// that opens a screen. `nil` means there is nothing to draw and the monogram stands in.
    static func image(from value: String?) async -> Image? {
        guard let data = imageData(from: value) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            MediaImageDecoder.decode(data)
        }.value
        return decoded.map(Image.init(uiImage:))
    }

    /// The monogram shown when there is no picture: one letter, or two when the name has two parts.
    ///
    /// A name that is only whitespace, or empty, still has to draw something — a blank circle
    /// reads as a failed image rather than as an account without a photo.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let letters = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first }
            .map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// What the About section can say about this build, kept apart from the bundle it reads.
///
/// The split is not ceremony: inside a package `Bundle.main` is the APP at runtime and the test
/// RUNNER under test, so a function that reached for it directly could only be tested against
/// whatever the runner happened to declare. The decision is here and the reading is one line.
enum AboutInfo {
    /// `1.2 (34)`, or as much of it as the bundle actually declares.
    static func versionLine(shortVersion: String?, build: String?) -> String {
        guard let shortVersion, !shortVersion.isEmpty else { return "Unknown" }
        guard let build, !build.isEmpty else { return shortVersion }
        return "\(shortVersion) (\(build))"
    }

    static func versionLine(from bundle: Bundle) -> String {
        versionLine(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// The server, as the host alone. The scheme is always `https` (`ServerConfiguration` refuses
    /// anything else) so printing it would only add width, and the host is what someone checking
    /// which server this is actually reads.
    static func serverLine(for baseURL: URL?) -> String {
        baseURL?.host() ?? "Not signed in"
    }
}

/// Emptying the derived media cache — BOTH halves of it, which is the whole reason this exists.
///
/// There are two caches behind a photo and clearing one of them looks exactly like clearing both
/// until the timeline is scrolled: the `URLCache` holds the bytes across launches, and
/// `MediaImageLoader.store` holds the DECODED images for this launch. A Clear button that emptied
/// only the first would report a smaller number and still paint every picture that was on screen,
/// out of memory, with nothing to re-fetch.
///
/// It reaches neither the outbox's queued captures nor its quarantine, and it cannot: both are
/// files in the app group container, and nothing here can name a file (see `DerivedMediaCache`).
enum MediaCacheClearing {
    static func clearDerived(
        cache: any DerivedMediaCache = MediaSession.shared.cache,
        decoded: MediaImageStore = MediaImageLoader.store
    ) {
        MediaCacheMaintenance.clear(cache)
        decoded.purge()
    }

    static func usage(
        of cache: any DerivedMediaCache = MediaSession.shared.cache
    ) -> MediaCacheMaintenance.Usage {
        MediaCacheMaintenance.usage(of: cache)
    }
}

/// What the account menu holds, in order.
///
/// A list rather than a view body, because the ORDER carries a safety property that a view body
/// would only imply. A menu opens with its first row directly under the anchor that opened it, and
/// when that row was the destructive one a second tap on the anchor — the ordinary human reflex
/// when a tap seems not to have registered — revoked a live credential (MEMNG-119). The heading
/// takes that position. It is not decoration: it is what stands between the anchor and the
/// destructive row, and `AccountMenuTests` holds it there.
///
/// There is deliberately no appearance row. Appearance is a setting, it lives on the Settings
/// screen with the other settings, and a menu that offered a second way to change one of them
/// would be two answers to the same question.
enum AccountMenu {
    enum Row: Equatable, Hashable {
        /// Who this device is signed in as. Never actionable — see above.
        case heading(String)
        case settings
        case signOut

        /// Whether choosing this row would take something away. Only one row ever can.
        var isDestructive: Bool {
            if case .signOut = self { return true }
            return false
        }
    }

    static func rows(name: String?) -> [Row] {
        [.heading(SignOutFlow.accountHeading(name: name)), .settings, .signOut]
    }
}

/// The Settings screen's sections, in the order they are read.
///
/// An explicit list rather than whatever the view body happens to contain, so that "these six and
/// no others" is a thing a test can hold. Tokens and notifications are coming and are NOT here:
/// a section rendered as a disabled row or a "coming soon" line is a promise the app has not kept,
/// and it costs a reader a tap to find that out. They arrive when they work.
enum SettingsScreen {
    enum Section: String, CaseIterable, Equatable {
        case account
        case defaults
        /// Where a capture may go, which is a decision about behaviour rather than about looks —
        /// so it sits with the other decision about what a new memo does, not after Appearance.
        case uploads
        case appearance
        case storage
        case about

        var title: String {
            switch self {
            case .account: "Account"
            case .defaults: "Defaults"
            case .uploads: "Uploads"
            case .appearance: "Appearance"
            case .storage: "Storage"
            case .about: "About"
            }
        }
    }

    static let sections: [Section] = Section.allCases
}
