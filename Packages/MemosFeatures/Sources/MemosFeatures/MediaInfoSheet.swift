import Foundation
import MemosCore
import SwiftUI

/// What the Info sheet says about one page, row by row.
///
/// **Taken** reads the capture fields ALONE — the attachment's, else the file record's
/// (`AttachmentFacts`). A display date (`MediaPage.takenAt`, the memo's date) is never one: a
/// picture the camera did not date says so, whatever date the capsule shows for it.
///
/// **File** reads the attachment and the file record. Nothing here fetches a file to measure it.
enum MediaInfoRows {
    enum Taken: Equatable {
        case captured(Date, source: String?)
        case noCaptureData
    }

    struct MemoCard: Equatable {
        let excerpt: String
        let tags: [String]
        let visibility: MemoVisibility
        /// Whether the card offers Show memo: a memo looked up by uid can be opened; the memo the
        /// viewer was opened from is the screen behind it.
        let showable: Bool
        let uid: String
    }

    struct File: Equatable {
        let type: String
        let dimensions: String?
        let duration: String?
        let size: String?
    }

    static func taken(
        _ attachment: MemoAttachment, facts: AttachmentFacts?, timeZone: TimeZone = .current
    ) -> Taken {
        let civil = attachment.captureCivil ?? facts?.captureCivil
        let source = attachment.captureSource ?? facts?.captureSource
        if let civil, let date = MediaViewerContext.civilDate(civil, in: timeZone) {
            return .captured(date, source: source)
        }
        if let instant = attachment.captureInstant ?? facts?.captureInstant {
            return .captured(instant, source: source)
        }
        return .noCaptureData
    }

    static func memoCard(_ link: MediaViewerContext.MemoLink, looked found: Memo?) -> MemoCard? {
        switch link {
        case .orphan: return nil
        case .carried(let memo): return card(memo, showable: false)
        case .lookup: return found.map { card($0, showable: true) }
        }
    }

    private static func card(_ memo: Memo, showable: Bool) -> MemoCard {
        let text = stripTagOnlyLines(memo.content).trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoCard(
            excerpt: String(text.prefix(140)), tags: memo.tags, visibility: memo.visibility,
            showable: showable, uid: memo.uid)
    }

    static func file(_ attachment: MemoAttachment, facts: AttachmentFacts?) -> File {
        let width = attachment.width ?? facts?.width
        let height = attachment.height ?? facts?.height
        let dimensions = width.flatMap { w in height.map { h in "\(w) × \(h)" } }
        let seconds = attachment.duration ?? facts?.duration
        let duration = seconds.map {
            Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
        }
        let size = facts.map {
            ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)
        }
        return File(
            type: facts?.mime ?? attachment.mime, dimensions: dimensions, duration: duration,
            size: size)
    }
}

/// The Info sheet: Taken, Memo and File, from what the page carries and the two reads the sheet
/// makes when it opens (`MediaContextStore`) — never before.
struct MediaInfoSheet: View {
    let page: MediaPage
    let context: MediaViewerContext
    let store: MediaContextStore?
    var showMemo: (String) -> Void = { _ in }

    var body: some View {
        let facts = store?.facts(of: page.attachment.uid)
        NavigationStack {
            List {
                Section("Taken") { takenRow(MediaInfoRows.taken(page.attachment, facts: facts)) }
                if let card = MediaInfoRows.memoCard(context.memo, looked: lookedUp) {
                    Section("Memo") { memoRows(card) }
                }
                Section("File") { fileRows(MediaInfoRows.file(page.attachment, facts: facts)) }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var lookedUp: Memo? {
        guard case .lookup(let uid) = context.memo else { return nil }
        return store?.memo(uid)
    }

    @ViewBuilder
    private func takenRow(_ taken: MediaInfoRows.Taken) -> some View {
        switch taken {
        case .captured(let date, let source):
            LabeledContent("Taken", value: date.formatted(date: .abbreviated, time: .shortened))
            if let source { LabeledContent("Source", value: source) }
        case .noCaptureData:
            Text("No capture data").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func memoRows(_ card: MediaInfoRows.MemoCard) -> some View {
        if !card.excerpt.isEmpty { Text(card.excerpt).lineLimit(4) }
        if !card.tags.isEmpty {
            Text(card.tags.map { "#\($0)" }.joined(separator: " ")).foregroundStyle(.secondary)
        }
        LabeledContent("Visibility", value: card.visibility.label)
        if card.showable {
            Button("Show memo") { showMemo(card.uid) }
        }
    }

    @ViewBuilder
    private func fileRows(_ file: MediaInfoRows.File) -> some View {
        LabeledContent("Type", value: file.type)
        if let dimensions = file.dimensions { LabeledContent("Dimensions", value: dimensions) }
        if let duration = file.duration { LabeledContent("Duration", value: duration) }
        if let size = file.size { LabeledContent("Size", value: size) }
    }

    /// What opening the sheet reads: the page's memo by uid when the source did not carry it, and
    /// the file's own record. The ONLY place either read starts.
    static func opened(
        _ page: MediaPage,
        context: MediaViewerContext,
        store: MediaContextStore,
        handle: SessionHandle?,
        baseURL: URL?
    ) async {
        guard let handle, let baseURL else { return }
        if case .lookup(let uid) = context.memo {
            await store.loadMemo(uid: uid, using: handle, baseURL: baseURL)
        }
        await store.loadFacts(uid: page.attachment.uid, using: handle, baseURL: baseURL)
    }
}
