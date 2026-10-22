import Foundation
import MapKit
import MemosCore
import SwiftUI

/// What the Info sheet says about one page, row by row.
///
/// **Taken** reads the capture fields ALONE — the attachment's, else the file record's
/// (`AttachmentFacts`). A display date (`MediaPage.takenAt`, the memo's date) is never one: a
/// picture the camera did not date says so, whatever date the capsule shows for it.
///
/// **File** reads the file record first and the attachment where the record is silent: the
/// record is the server's own measurement of the stored file, the page only what its list said.
/// Nothing here fetches a file to measure it: size, dimensions and filename are the record's.
///
/// **Where** and **Camera** come from the record alone and are absent, never empty, when it has
/// nothing to say (MEMNG-869).
enum MediaInfoRows {
    /// The sheet's sections, top to bottom.
    enum Section: Equatable, CaseIterable {
        case taken
        case memo
        case location
        case file
        case camera
    }

    nonisolated struct Location: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    /// Up to three lines, each absent when the record has none of its fields.
    struct Camera: Equatable {
        /// Make and model: "Apple iPhone 16 Pro".
        let device: String?
        /// Lens, focal length and aperture: "iPhone 16 Pro back camera · 6.8 mm · ƒ1.8".
        let lens: String?
        /// ISO · focal · bias · ƒ · shutter: "ISO 80 · 6.8 mm · 0 ev · ƒ1.8 · 1/60 s".
        let exposure: String?
    }

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
        var filename: String? = nil
        var addedBy: String? = nil
    }

    /// Which sections the sheet shows. Taken and File always; Memo when there is a memo card;
    /// Where when the record has a location; Camera when it has a camera line to show.
    static func sections(
        memo: MemoCard?, location: Location?, camera: Camera?
    ) -> [Section] {
        var shown: [Section] = [.taken]
        if memo != nil { shown.append(.memo) }
        if location != nil { shown.append(.location) }
        shown.append(.file)
        if camera != nil { shown.append(.camera) }
        return shown
    }

    static func location(_ facts: AttachmentFacts?) -> Location? {
        guard let latitude = facts?.latitude, let longitude = facts?.longitude else { return nil }
        return Location(latitude: latitude, longitude: longitude)
    }

    /// The Camera rows, or nil when the record carries no camera or none of its lines has a field.
    static func camera(_ camera: CameraFacts?) -> Camera? {
        guard let camera else { return nil }
        let device = joined([camera.make, camera.model], " ")
        let lens = joined(
            [camera.lensModel, camera.focalLength.map(focal), camera.fNumber.map(aperture)])
        let exposure = joined([
            camera.iso.map { "ISO \($0)" }, camera.focalLength.map(focal),
            camera.exposureBias.map(bias), camera.fNumber.map(aperture),
            camera.exposureTime.map(shutter),
        ])
        guard device != nil || lens != nil || exposure != nil else { return nil }
        return Camera(device: device, lens: lens, exposure: exposure)
    }

    /// An exposure time as a photographer reads it: a fraction under a second (`1/60 s`), whole
    /// or decimal seconds from one up (`2 s`, `2.5 s`).
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0 s" }
        if seconds < 1 { return "1/\(Int((1 / seconds).rounded())) s" }
        return "\(trimmed(seconds)) s"
    }

    /// Exposure bias to a tenth of a stop: `0 ev`, `-0.3 ev`, `0.7 ev`.
    static func bias(_ ev: Double) -> String {
        let tenths = (ev * 10).rounded() / 10
        return "\(trimmed(tenths == 0 ? 0 : tenths)) ev"
    }

    static func aperture(_ f: Double) -> String { "ƒ\(trimmed(f))" }

    static func focal(_ millimetres: Double) -> String { "\(trimmed(millimetres)) mm" }

    /// Where the Taken date came from, in words: the camera's own clock, or the upload.
    static func takenSource(_ source: String?) -> String {
        switch source?.lowercased() {
        case nil, "upload", "uploaded", "mtime", "file": "from the upload"
        default: "from the photo's clock"
        }
    }

    /// A number with at most one decimal and no trailing zero: 2 → "2", 1.8 → "1.8".
    private static func trimmed(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        if tenths == tenths.rounded() { return String(Int(tenths)) }
        return String(format: "%.1f", tenths)
    }

    private static func joined(_ parts: [String?], _ separator: String = " · ") -> String? {
        let present = parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: separator)
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
        let width = facts?.width ?? attachment.width
        let height = facts?.height ?? attachment.height
        let dimensions = width.flatMap { w in height.map { h in "\(w) × \(h)" } }
        let seconds = facts?.duration ?? attachment.duration
        let duration = seconds.map {
            Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
        }
        let size = facts.map {
            ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)
        }
        return File(
            type: facts?.mime ?? attachment.mime, dimensions: dimensions, duration: duration,
            size: size, filename: facts?.filename, addedBy: facts?.addedBy)
    }
}

/// What the viewer presents the Info sheet over: the page, the store, and the opening taken for
/// this presentation. Identified by the opening, so each presentation is its own sheet.
struct MediaInfoSubject: Identifiable {
    let page: MediaPage
    let store: MediaContextStore
    let opening: MediaContextStore.Opening
    var id: MediaContextStore.Opening { opening }
}

/// The Info sheet: Taken, Memo and File, from what the page carries and the two reads the sheet
/// makes when it opens (`MediaContextStore`) — never before.
///
/// It holds its OWN opening, immutably, from the moment it is built: what it reads, what it shows
/// and what it gives back when it goes are all that one, so a sheet dismissed after another has
/// opened ends only itself (`disappeared()`).
struct MediaInfoSheet: View {
    let page: MediaPage
    let context: MediaViewerContext
    let store: MediaContextStore
    /// This time the sheet is open; its file record is read for it and shown only under it.
    let opening: MediaContextStore.Opening
    var handle: SessionHandle? = nil
    var baseURL: URL? = nil
    /// The place names the viewer has looked up, one lookup per file.
    var places: PlaceNameCache? = nil
    var showMemo: (String) -> Void = { _ in }

    var body: some View {
        let facts = store.facts(for: opening)
        let card = MediaInfoRows.memoCard(context.memo, looked: lookedUp)
        let location = MediaInfoRows.location(facts)
        let camera = MediaInfoRows.camera(facts?.camera)
        NavigationStack {
            List {
                ForEach(
                    MediaInfoRows.sections(memo: card, location: location, camera: camera),
                    id: \.self
                ) { section in
                    switch section {
                    case .taken:
                        Section("Taken") {
                            takenRow(MediaInfoRows.taken(page.attachment, facts: facts))
                        }
                    case .memo:
                        if let card { Section("Memo") { memoRows(card) } }
                    case .location:
                        if let location { Section("Where") { whereRows(location) } }
                    case .file:
                        Section("File") {
                            fileRows(MediaInfoRows.file(page.attachment, facts: facts))
                        }
                    case .camera:
                        if let camera { Section("Camera") { cameraRows(camera) } }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task { await appeared() }
        // Every way the sheet goes — a swipe, Show memo, the cover itself — ends ITS opening, so
        // a record still in the air for it lands nowhere.
        .onDisappear { disappeared() }
    }

    /// The sheet is on screen: this opening's reads.
    func appeared() async {
        await Self.opened(opening, context: context, store: store, handle: handle, baseURL: baseURL)
        if let location = MediaInfoRows.location(store.facts(for: opening)) {
            await places?.lookUp(page.attachment.uid, at: location)
        }
    }

    /// The sheet has gone: this opening, and no other, ends.
    func disappeared() { store.close(opening) }

    private var lookedUp: Memo? {
        guard case .lookup(let uid) = context.memo else { return nil }
        return store.memo(uid)
    }

    @ViewBuilder
    private func takenRow(_ taken: MediaInfoRows.Taken) -> some View {
        switch taken {
        case .captured(let date, let source):
            let zone = TimeZone.current.abbreviation(for: date) ?? TimeZone.current.identifier
            LabeledContent(
                "Taken", value: date.formatted(date: .abbreviated, time: .shortened) + " " + zone)
            Text(MediaInfoRows.takenSource(source)).foregroundStyle(.secondary)
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
        if let filename = file.filename { LabeledContent("Filename", value: filename) }
        if let addedBy = file.addedBy { LabeledContent("Added by", value: addedBy) }
    }

    @ViewBuilder
    private func whereRows(_ location: MediaInfoRows.Location) -> some View {
        let coordinate = CLLocationCoordinate2D(
            latitude: location.latitude, longitude: location.longitude)
        Map(
            initialPosition: .region(
                MKCoordinateRegion(
                    center: coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)),
            interactionModes: []
        ) {
            Marker("", coordinate: coordinate)
        }
        .frame(height: 160)
        .listRowInsets(EdgeInsets())
        if let name = places?.name(for: page.attachment.uid) {
            Text(name)
        }
    }

    @ViewBuilder
    private func cameraRows(_ camera: MediaInfoRows.Camera) -> some View {
        if let device = camera.device { Text(device) }
        if let lens = camera.lens { Text(lens).foregroundStyle(.secondary) }
        if let exposure = camera.exposure { Text(exposure).foregroundStyle(.secondary) }
    }

    /// What one opening of the sheet reads: the page's memo by uid when the source did not carry
    /// it, and the file's own record for this opening. The ONLY place either read starts. The
    /// record is not asked for once the opening has closed — the store refuses an opening that is
    /// not the live one, so a sheet dismissed while its memo was in the air sends nothing more.
    static func opened(
        _ opening: MediaContextStore.Opening,
        context: MediaViewerContext,
        store: MediaContextStore,
        handle: SessionHandle?,
        baseURL: URL?
    ) async {
        guard let handle, let baseURL else { return }
        if case .lookup(let uid) = context.memo {
            await store.loadMemo(uid: uid, using: handle, baseURL: baseURL)
        }
        await store.loadFacts(for: opening, using: handle)
    }
}

/// The place names of the files the viewer has shown Info for: ONE reverse lookup per file for
/// the viewer's lifetime, whatever its answer, so paging back and forth never asks twice.
@Observable
final class PlaceNameCache {
    typealias Lookup = @MainActor (MediaInfoRows.Location) async -> String?

    private(set) var names: [String: String] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let lookup: Lookup

    init(lookup: @escaping Lookup = PlaceNameCache.reverseGeocode) {
        self.lookup = lookup
    }

    func name(for uid: String) -> String? { names[uid] }

    func lookUp(_ uid: String, at location: MediaInfoRows.Location) async {
        guard asked.insert(uid).inserted else { return }
        if let name = await lookup(location) { names[uid] = name }
    }

    /// Off the main actor: the request and the items it answers with never cross an isolation
    /// boundary, only the name does.
    nonisolated static func reverseGeocode(_ location: MediaInfoRows.Location) async -> String? {
        let point = CLLocation(latitude: location.latitude, longitude: location.longitude)
        guard let request = MKReverseGeocodingRequest(location: point) else { return nil }
        return try? await request.mapItems.first?.name
    }
}
