import Foundation
import MemosCore
import SwiftUI
import UIKit

// The decisions the account sheet and the Library's cache item read. Pure functions over the
// account's settings, each one tested directly; the views above them stay obvious.

/// Which default visibilities the account sheet offers, and what to say about one it does not.
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

/// What can be said about this build — the Settings app's Version row (`SettingsBundleSync`) —
/// kept apart from the bundle it reads.
///
/// The split is not ceremony: `Bundle.main` is the hosted APP in this project's test bundles as
/// well as at runtime (`PrivacyManifestTests` reads the built manifests through it), so a function
/// that reached for it directly could only be tested against whatever this one build declares.
/// The decision is here, with every case a test can name, and the reading is one line.
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

/// What changed in each build, as the What's new screen shows it: the sections of the ONE notes
/// file the TestFlight cut also sends as "What to Test" (`Resources/ReleaseNotes.md`, MEMNG-497).
///
/// A section is a `## <version> (<build>)` heading and the Markdown under it, read the way the
/// cut's loader reads it (`fastlane/lib/release_notes.rb`): a level-1 or level-2 heading outside a
/// code fence ends a section, a deeper heading belongs to it, and a heading inside a fence is
/// text. The heading is the very line `AboutInfo.versionLine` writes for that build, which is what
/// lets the running build find its own section.
enum ReleaseNotes {
    struct Section: Equatable {
        /// `2.2.3 (45)`: the heading, without its `## `.
        let version: String
        /// The Markdown under the heading, blank lines at either end dropped.
        let body: String
    }

    /// Every section, in file order. Text before the first section is the file's own preamble
    /// and belongs to none.
    static func sections(markdown: String) -> [Section] {
        var found: [Section] = []
        var heading: String?
        var lines: [Substring] = []
        // The open fence's character and run length: CommonMark closes a fence only on a line
        // that is nothing but the SAME character, at least as many times.
        var fence: (mark: Character, count: Int)?

        func close() {
            if let heading {
                let body = lines.joined(separator: "\n")
                found.append(
                    Section(
                        version: heading,
                        body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            heading = nil
            lines = []
        }

        // `isNewline` rather than "\n": a CRLF file's "\r\n" is ONE Character to Swift.
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if fence == nil, let level = headingLevel(line), level <= 2 {
                close()
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level == 2, !title.isEmpty { heading = title }
                continue
            }
            let indented = line.drop(while: { $0 == " " || $0 == "\t" })
            if let open = fence {
                let run = indented.prefix(while: { $0 == open.mark }).count
                let rest = indented.dropFirst(run)
                if run >= open.count, rest.allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
            } else if let mark = indented.first, mark == "`" || mark == "~" {
                let run = indented.prefix(while: { $0 == mark }).count
                if run >= 3 { fence = (mark, run) }
            }
            if heading != nil { lines.append(line) }
        }
        close()
        return found
    }

    /// The running build's section first, every other one after it in file order. A build the
    /// file does not name — a local build, `Unknown` — leaves the order as written: nothing is
    /// dropped and nothing is invented.
    static func ordered(_ sections: [Section], running: String) -> [Section] {
        guard let index = sections.firstIndex(where: { $0.version == running }) else {
            return sections
        }
        var rest = sections
        let current = rest.remove(at: index)
        return [current] + rest
    }

    /// The notes this build was made with, read once. An unreadable file is no sections, which
    /// the screen says, rather than a crash on the way to a courtesy.
    static let bundled: [Section] = {
        guard let url = Bundle.module.url(forResource: "ReleaseNotes", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return sections(markdown: text)
    }()

    /// `#` → 1, `##` → 2, and so on, when the line is an ATX heading: the hashes at the start of
    /// the line followed by a space, a tab or nothing.
    private static func headingLevel(_ line: Substring) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes > 0 else { return nil }
        let after = line.dropFirst(hashes).first
        return after == nil || after == " " || after == "\t" ? hashes : nil
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
