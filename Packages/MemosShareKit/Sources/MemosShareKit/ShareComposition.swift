import Foundation
import MemosOutbox

/// What a share becomes as words, and when it may be posted at all.
///
/// Pure by design: this is the part of the extension worth testing, and it is tested directly
/// rather than through a view that a share-sheet host would have to be standing up.
public enum ShareComposition {
    /// The memo's text: what the person typed, then whatever came with the share that is worth
    /// keeping as words.
    ///
    /// A browser hands over the page's title as text AND its address as a link, so both are kept,
    /// in that order — but never twice: a title someone has already pasted into the note, or an
    /// address the note already quotes, is not repeated underneath it.
    public static func content(note: String, items: [SharedItem]) -> String {
        var blocks: [String] = []
        let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { blocks.append(typed) }
        for item in items {
            switch item {
            case .file:
                continue
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !blocks.contains(where: { $0.contains(trimmed) }) else {
                    continue
                }
                blocks.append(trimmed)
            case .link(let url):
                let address = url.absoluteString
                guard !blocks.contains(where: { $0.contains(address) }) else { continue }
                blocks.append(address)
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A share may be posted when it has files or words, and never while one of its items could
    /// not be read: posting now would silently leave a photo behind, which is the failure someone
    /// only discovers weeks later.
    ///
    /// A trip takes photos and videos and nothing else: a share for a guest's pass with no file in
    /// it has nothing the door can receive, and its words alone would be dropped on the way.
    public static func canPost(
        for kind: CredentialKind,
        note: String,
        items: [SharedItem],
        failed: Int,
        isBusy: Bool
    ) -> Bool {
        guard failed == 0, !isBusy else { return false }
        if items.contains(where: \.isFile) { return true }
        guard kind != .guest else { return false }
        return !content(note: note, items: items).isEmpty
    }

    /// What the sheet says about what it is holding — and, when something could not be read, what
    /// it says instead. A file that failed is never dropped quietly.
    public static func summary(items: [SharedItem], failed: Int) -> String? {
        if failed > 0 {
            let total = items.count + failed
            return "\(failed) of \(total) could not be read. Share them again."
        }
        let files = items.filter(\.isFile).count
        guard files > 0 else { return nil }
        return files == 1 ? "1 file attached" : "\(files) files attached"
    }
}
