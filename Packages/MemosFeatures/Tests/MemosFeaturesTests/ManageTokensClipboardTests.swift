import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import MemosFeatures

/// What Copy actually writes, read back from the write itself.
///
/// The system pasteboard is shared with everything else on the phone and its contents are not a
/// thing a test may assert on — so the write is handed in, and what is checked here is the item and
/// the options the app would give `UIPasteboard`: the two halves of "this token does not stay on
/// the clipboard, and it still reaches the Mac it was copied for".
@MainActor
@Suite("Copying a new token's text")
struct ManageTokensClipboardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a copied token is written with a deadline on it")
    func copyCarriesAnExpiry() throws {
        var written: ([[String: Any]], [UIPasteboard.OptionsKey: Any])?

        ManageTokensClipboard.copy(current: { "memos_pat_brand_new" }, now: now) {
            written = ($0, $1)
        }

        let (items, options) = try #require(written)
        #expect(items.count == 1)
        #expect(items.first?[UTType.utf8PlainText.identifier] as? String == "memos_pat_brand_new")
        let expires = try #require(
            options[UIPasteboard.OptionsKey.expirationDate] as? Date,
            "the token was put on the clipboard with nothing to take it off again"
        )
        #expect(expires == now.addingTimeInterval(ManageTokensClipboard.lifetime))
    }

    /// The other half of the same decision, and the one a well-meaning hardening would undo: a
    /// clipboard that stops at the phone sends somebody back to reading a secret off the screen and
    /// typing it in somewhere else.
    @Test("a copied token is not kept to this device")
    func copyIsNotLocalOnly() {
        var options: [UIPasteboard.OptionsKey: Any]?

        ManageTokensClipboard.copy(current: { "memos_pat_brand_new" }, now: now) { options = $1 }

        #expect(!(options?.keys.contains(UIPasteboard.OptionsKey.localOnly) ?? true))
    }

    /// The panel is still on screen, with this action live, at the instant the identity that minted
    /// the token goes — and what the press reads is what decides. A read that answers nothing must
    /// leave the clipboard as it was rather than writing a string from before.
    @Test("a secret that can no longer be read is not written at all")
    func nothingIsWrittenWhenTheSecretCannotBeRead() {
        var writes = 0

        ManageTokensClipboard.copy(current: { nil }, now: now) { _, _ in writes += 1 }

        #expect(writes == 0, "a token nobody may read any more was put on the clipboard")
    }
}
