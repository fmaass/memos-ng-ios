import Foundation
import MemosCore

// The decisions a Settings screen will read, and no screen.
//
// The information architecture — what the sections are, where they are reached from, what moves
// out of the timeline's overflow menu — is being drafted before anything is built, so this slice
// is deliberately the part that survives whatever that draft decides: pure functions over the
// account's settings, each one tested directly. Nothing here draws.

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
