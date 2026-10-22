import Foundation
import MemosCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The files a batch fetched, offered to ONE share sheet together.
public struct FetchedBatch: Identifiable, Equatable, Sendable {
    /// Local `file:` URLs, in selection order — the same promise `FetchedFile` makes about one.
    public let files: [URL]

    public var id: String { files.map(\.absoluteString).joined(separator: "\n") }
}

/// Select mode's Share (MEMNG-588): the SHARED copy of every chosen file — a picture's mobile tier,
/// a clip's mp4, never an original (MEMNG-874) — fetched one after the other, then handed to one
/// share sheet.
///
/// `MediaSaveFlow` generalised from one file to several, and it keeps each of its rules: a second
/// tap while a batch is in flight is refused rather than joined, nothing is offered that is not
/// held first (`FetchedFileHold`), and the sheet is bound to the offer so a failure cannot raise
/// an empty one.
///
/// What a batch adds is its length. It can be on the wire for minutes, so it is fenced ONCE, by
/// the session generation it started under, checked after every file: when somebody else signs in
/// halfway through, the files already fetched are the previous account's and are thrown away, and
/// no further file is asked for. The download lane fences each request on its own as well
/// (`SessionStore.download`); this is the fence around the batch, which no single request can see.
///
/// The download and the generation read are passed in, as `MediaSaveFlow`'s download is: the
/// fetch needs the session's credential and this layer has no session.
@MainActor
@Observable
public final class MediaBatchShareFlow {
    /// A batch is running — the spinner on the share button, and the guard against a second one.
    public private(set) var isSharing = false
    /// The files, once every one of them is here. The share sheet is presented on this alone.
    public private(set) var offered: FetchedBatch?
    /// Why the last batch did not produce files, or nil.
    public private(set) var lastError: String?

    /// Every file this flow OFFERED and has not let go of, as `MediaSaveFlow` keeps its one.
    private let held: FetchedFileHold
    /// How a file this flow will never offer is thrown away — the hold's own removal, so a file
    /// dropped mid-batch goes the same coordinated way as one released later.
    private let remove: @Sendable ([URL]) -> Void
    /// Which batch is the live one. Moved by every batch that starts and by `abandon`; a batch
    /// whose number is no longer this one owns nothing — not the flag, not the offer, not the
    /// error — and whatever it fetched is thrown away when it next wakes.
    private var batch = 0

    public convenience init() { self.init(remove: FetchedFileHold.removeLater) }

    /// The same flow with the removal handed in, so a test can watch what is thrown away.
    init(remove: @escaping @Sendable ([URL]) -> Void) {
        self.remove = remove
        held = FetchedFileHold(remove: remove)
    }

    /// Fetches the shared copy of every row, one at a time, and offers them all in one sheet.
    ///
    /// - Parameters:
    ///   - rows: the chosen rows, in selection order.
    ///   - generation: the session generation now, or nil when nobody is signed in.
    ///   - download: one file of one attachment. It is always asked for `.shared` — the light copy
    ///     `MemoAttachment.file(_:)` names, never the archive master (MEMNG-874).
    /// - Returns: whether this call ran a batch — false for a tap that arrived while another was
    ///   in flight, and for an empty selection.
    @discardableResult
    public func share(
        _ rows: [LibraryRow],
        generation: @MainActor () -> Int?,
        download: @MainActor (MemoAttachment, AttachmentRendition) async throws -> URL
    ) async -> Bool {
        guard !isSharing, !rows.isEmpty else { return false }
        batch += 1
        let mine = batch
        isSharing = true
        // Only the live batch lowers the flag: an abandoned one waking late must not take it from
        // the batch that replaced it, or a second tap could start a third.
        defer { if batch == mine { isSharing = false } }
        // A new batch is where the last one stops being wanted: offer first, then the files.
        offered = nil
        lastError = nil
        held.release()
        guard let started = generation() else {
            lastError = MediaSaveFlow.message(for: OriginalMediaError.notSignedIn)
            return true
        }
        // Not held yet: nothing is offered before the whole selection is here, and a batch that
        // ends early throws these away itself.
        var files: [URL] = []
        // The names already given out in this batch, lowered — see `unique(_:among:)`.
        var taken: Set<String> = []
        for row in rows {
            let file: URL
            do {
                file = try await download(row.attachment, .shared)
            } catch {
                drop(files)
                // An abandoned batch has nobody left to tell.
                if batch == mine { lastError = MediaSaveFlow.message(for: error) }
                return true
            }
            // Checked between this file's arrival and the next request, with nothing awaited in
            // between, so a batch that was abandoned, or whose session ended, asks for nothing
            // more and offers nothing.
            guard batch == mine else {
                MemosLog.session.info("a share batch outlived select mode; its files are dropped")
                drop(files + [file])
                return true
            }
            guard generation() == started else {
                MemosLog.session.info("a share batch outlived its session; its files are dropped")
                drop(files + [file])
                return true
            }
            let name = Self.unique(Self.named(Self.shareName(for: row), like: file), among: taken)
            let renamed = Self.rename(file, to: name)
            // What the file is now called, which a failed move leaves as the name it arrived with.
            taken.insert(renamed.lastPathComponent.lowercased())
            files.append(renamed)
        }
        // Held BEFORE anything can offer them, as `MediaSaveFlow` holds its one.
        for file in files { held.hold(file) }
        offered = FetchedBatch(files: files)
        return true
    }

    /// Select mode ended — closed, left for Years or Months, the account changed, the Library went
    /// away. The running batch, if any, stops being the live one: it asks for no further file,
    /// throws away what it fetched when its current download returns, and never offers anything,
    /// so opening select mode again cannot bring back a sheet over a selection that was left.
    /// The flag is lowered at once, so a new Share is not refused by a batch nobody wants.
    public func abandon() {
        batch += 1
        isSharing = false
        offered = nil
        lastError = nil
    }

    private func drop(_ files: [URL]) {
        guard !files.isEmpty else { return }
        remove(files)
    }

    /// The share sheet has gone: the files stop being offered, and stay held (see
    /// `MediaSaveFlow.finish` for why a dismissal does not delete them).
    public func finish() {
        offered = nil
    }

    public func dismissError() {
        lastError = nil
    }

    /// What a chosen file is called in the share sheet: the name it was uploaded under, which is
    /// what a person recognises, with every path separator made harmless. The uid and the
    /// original's extension only when the list carries no name, or none that survives.
    static func shareName(for row: LibraryRow) -> String {
        let cleaned = sanitise(row.filename)
        if !cleaned.isEmpty { return cleaned }
        return OriginalMedia.filename(uid: row.attachment.uid, mime: row.attachment.mime)
    }

    /// `name` under the extension of the file that ARRIVED, when that is a different type: the
    /// shared copy of `IMG_1.PNG` is a JPEG, and a `.PNG` on it would tell Messages and Mail the
    /// wrong thing (MEMNG-836). A name already of that type (`.jpg` for a `.jpeg`) is left alone,
    /// and so is every name when the arrived file carries no extension. Only a suffix the system
    /// knows as a type is replaced: the `.v2` of `beach.v2` is part of the name, not its type.
    static func named(_ name: String, like file: URL) -> String {
        let arrived = file.pathExtension
        guard !arrived.isEmpty, let type = UTType(filenameExtension: arrived) else { return name }
        let current = (name as NSString).pathExtension
        // Lowered: a camera writes `IMG_1.PNG`, and the type of a suffix does not depend on case.
        let currentType = current.isEmpty ? nil : UTType(filenameExtension: current.lowercased())
        if currentType == type { return name }
        let isAType = currentType.map { !$0.isDynamic } ?? false
        let stem = isAType ? (name as NSString).deletingPathExtension : name
        return "\(stem).\(arrived)"
    }

    /// `name`, or the first `stem-2.ext`, `stem-3.ext`, … that no earlier file of the batch holds.
    /// The JPEG copies of `IMG_1.PNG` and `IMG_1.HEIC` are both `IMG_1.jpeg`, and a share target
    /// handed two files of one name keeps one or overwrites it (MEMNG-836). Compared without case:
    /// the Files app and most share targets do. The suffix follows selection order, so the same
    /// selection is always offered under the same names.
    static func unique(_ name: String, among taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        let suffix = (name as NSString).pathExtension
        let stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        // `taken.count + 1` candidates cannot all be taken, so the loop always returns.
        for number in 2...(taken.count + 2) {
            let candidate = suffix.isEmpty ? "\(stem)-\(number)" : "\(stem)-\(number).\(suffix)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return name
    }

    /// A name that cannot leave the directory it is put in: `/`, `\` and `:` (the separator HFS
    /// paths still honour) become `_`, control characters go, and a name that is nothing but dots
    /// is no name at all.
    static func sanitise(_ name: String) -> String {
        let separators: Set<Character> = ["/", "\\", ":"]
        var mapped = ""
        for character in name {
            if separators.contains(character) {
                mapped.append("_")
            } else if !character.unicodeScalars.contains(where: Self.isControl) {
                mapped.append(character)
            }
        }
        mapped = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
        return mapped.allSatisfy { $0 == "." } ? "" : mapped
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
    }

    /// Moves a fetched file to `name` INSIDE the enclosure the fetch made for it, so what a discard
    /// removes (`OriginalMedia.discard`, the enclosure) is still exactly this file's. A move that
    /// fails leaves the file under the name it arrived with: a worse name, not a lost file.
    static func rename(_ file: URL, to name: String) -> URL {
        guard name != file.lastPathComponent else { return file }
        let target = file.deletingLastPathComponent().appending(path: name)
        do {
            try FileManager.default.moveItem(at: file, to: target)
            return target
        } catch {
            return file
        }
    }
}

/// The system share sheet over several files — `ShareSheet`, for a batch.
struct BatchShareSheet: UIViewControllerRepresentable {
    let files: [URL]

    /// What the activity controller is handed: the files and nothing else (MEMNG-207).
    static func activityItems(for files: [URL]) -> [URL] { files }

    /// Called once the share has COMPLETED; see `ShareSheet.controller(items:onComplete:)`.
    var onComplete: @MainActor @Sendable () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        ShareSheet.controller(items: Self.activityItems(for: files), onComplete: onComplete)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// The sheet a batch ends in, and the reason when it does not. The wait itself is the share
    /// button's spinner (`LibrarySelectToolbar`), so there is no overlay here.
    func sharingFiles(_ flow: MediaBatchShareFlow) -> some View {
        self
            .sheet(
                item: Binding(get: { flow.offered }, set: { if $0 == nil { flow.finish() } })
            ) { batch in
                BatchShareSheet(files: batch.files, onComplete: { flow.finish() })
            }
            .alert(
                "Could not download",
                isPresented: Binding(
                    get: { flow.lastError != nil },
                    set: { if !$0 { flow.dismissError() } }
                )
            ) {
                Button("OK", role: .cancel) { flow.dismissError() }
            } message: {
                Text(flow.lastError ?? MediaSaveFlow.fallbackMessage)
            }
    }
}
