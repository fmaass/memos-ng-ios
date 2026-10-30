import CoreImage
import CoreImage.CIFilterBuiltins
import MemosCore
import SwiftUI
import UIKit

/// Where the Guests sheet opens: on its list, or straight on Invite Guests.
enum TripGuestsEntry: String, Identifiable {
    case guests, invite

    var id: String { rawValue }
}

/// A trip's guests (Trip Pass): Invite Guests, the passes with their devices, and the Guest Uploads
/// inbox, in one sheet over the trip screen and one `TripGuestStore` that dies with it.
struct TripGuestsSheet: View {
    let trip: Trip
    let entry: TripGuestsEntry
    let access: () -> CollectionsAccess?
    /// Told after a moderation reached the server: the trip's own grid still holds what it read
    /// before, and a hidden or removed picture must leave it.
    var onModerated: @MainActor () -> Void = {}

    @Environment(SessionStore.self) private var session: SessionStore?
    @Environment(\.dismiss) private var dismiss
    @State private var store: TripGuestStore?
    @State private var path: [TripGuestsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let store {
                    TripGuestsList(trip: trip, store: store, access: access)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Guests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: TripGuestsRoute.self) { route in
                if let store {
                    switch route {
                    case .invite: InviteGuestsForm(trip: trip, store: store, access: access)
                    case .uploads:
                        GuestUploadsInbox(store: store, access: access, onModerated: onModerated)
                    }
                }
            }
        }
        .onAppear {
            guard store == nil else { return }
            let made = TripGuestStore(
                collectionUid: trip.uid,
                onUnauthorized: { [session] refusal in
                    guard let session else { return .superseded }
                    return await session.handle(refusal)
                })
            if let session { made.reports(to: session) }
            store = made
            if entry == .invite { path = [.invite] }
        }
        .onDisappear { store?.dismissIssued() }
    }
}

enum TripGuestsRoute: Hashable {
    case invite, uploads
}

/// The passes of the trip, each with its devices, and the ways into Invite and the inbox.
struct TripGuestsList: View {
    let trip: Trip
    let store: TripGuestStore
    let access: () -> CollectionsAccess?

    @State private var ending: TripPass?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                NavigationLink(value: TripGuestsRoute.invite) {
                    Label("Invite Guests", systemImage: "qrcode")
                }
                NavigationLink(value: TripGuestsRoute.uploads) {
                    Label("Guest Uploads", systemImage: "tray")
                }
            }
            if let failure = failure ?? store.notice {
                Section { Text(failure).foregroundStyle(.secondary) }
            }
            if let passes = store.passes {
                if passes.isEmpty {
                    Section { Text("No guests are invited to this trip yet.") }
                }
                ForEach(passes) { pass in
                    Section {
                        ForEach(store.devices[pass.uid] ?? []) { device in
                            deviceRow(device, of: pass)
                        }
                        if pass.state == .active {
                            Button("End the Pass", role: .destructive) { ending = pass }
                        }
                    } header: {
                        Text(TripGuestsText.passHeader(pass))
                    }
                    .task(id: pass.version) { await readDevices(of: pass.uid) }
                }
            }
        }
        .disabled(store.isWriting)
        .task { await read() }
        .refreshable { await read() }
        .confirmationDialog(
            ending.map { TripGuestsText.endQuestion(devices: $0.deviceCount) } ?? "",
            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
            titleVisibility: .visible
        ) {
            Button("End the Pass", role: .destructive) {
                if let pass = ending { run { try await store.endPass(pass.uid, using: $0) } }
                ending = nil
            }
            Button("Cancel", role: .cancel) { ending = nil }
        }
    }

    private func deviceRow(_ device: TripPassDevice, of pass: TripPass) -> some View {
        HStack {
            Text(TripGuestsText.deviceLine(device, now: Date()))
                .foregroundStyle(device.revoked ? .secondary : .primary)
            Spacer()
            if !device.revoked && pass.state == .active {
                Button("Revoke", role: .destructive) {
                    run { try await store.revokeDevice(device.uid, of: pass.uid, using: $0) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func read() async {
        guard let access = access() else { return }
        await store.loadPasses(using: access.handle)
    }

    private func readDevices(of uid: String) async {
        guard let access = access() else { return }
        await store.loadDevices(of: uid, using: access.handle)
    }

    private func run(_ write: @escaping @MainActor (SessionHandle) async throws -> Void) {
        guard let access = access() else { return }
        Task {
            do {
                try await write(access.handle)
                failure = nil
            } catch {
                failure = (error as? TripGuestStore.Failure)?.errorDescription
            }
        }
    }
}

/// Invite Guests: the pass's label, scope, expiry and device cap, then — once issued — the QR code
/// and the share row. The guest URL lives in the store's memory only, for as long as this is up.
struct InviteGuestsForm: View {
    let trip: Trip
    let store: TripGuestStore
    let access: () -> CollectionsAccess?

    @State private var draft: TripPassDraft
    @State private var failure: String?
    @State private var sharing = false

    init(trip: Trip, store: TripGuestStore, access: @escaping () -> CollectionsAccess?) {
        self.trip = trip
        self.store = store
        self.access = access
        _draft = State(initialValue: TripPassDraft.opening(for: trip, now: Date()))
    }

    var body: some View {
        Form {
            if let issued = store.issued {
                Section {
                    if let image = PassQRCode.image(for: issued.url) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("QR code for \(issued.pass.label)")
                    }
                    Text("Guests scan this code to add their photos to \(trip.title).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Share Invitation", systemImage: "square.and.arrow.up") {
                        sharing = true
                    }
                }
                .sheet(isPresented: $sharing) {
                    InviteShareSheet(items: InviteShareSheet.items(for: issued))
                }
            } else {
                Section("Pass") {
                    TextField("Label", text: $draft.label)
                    Picker("Guests may", selection: $draft.scope) {
                        Text("Add photos").tag(TripPass.Scope.contribute)
                        Text("Add and see the trip").tag(TripPass.Scope.contributeAndView)
                    }
                    DatePicker(
                        "Expires", selection: $draft.expiresAt, in: Date()...,
                        displayedComponents: .date)
                    Stepper(
                        "Up to \(draft.maxDevices) devices", value: $draft.maxDevices,
                        in: TripPassDraft.deviceRange)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.secondary) }
                }
                Section {
                    Button("Create Invitation") { issue() }
                        .disabled(store.isWriting || !draft.isSendable(at: Date()))
                }
            }
        }
        .navigationTitle("Invite Guests")
    }

    private func issue() {
        guard let access = access() else { return }
        let sent = draft
        Task {
            do {
                try await store.issue(sent, using: access.handle)
                failure = nil
            } catch {
                failure = (error as? TripGuestStore.Failure)?.errorDescription
            }
        }
    }
}

/// The Guest Uploads inbox: every picture the trip's passes brought, to hide, show again or remove.
struct GuestUploadsInbox: View {
    let store: TripGuestStore
    let access: () -> CollectionsAccess?
    let onModerated: @MainActor () -> Void

    @State private var chosen: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var said: String?
    @State private var askingRemove = false

    var body: some View {
        List(selection: $chosen) {
            if let said = said ?? store.notice {
                Text(said).foregroundStyle(.secondary)
            }
            if let rows = store.contributions {
                if rows.isEmpty { Text("No guest has added a photo yet.") }
                ForEach(rows) { row in
                    HStack {
                        thumbnail(row)
                        VStack(alignment: .leading) {
                            Text(row.contributorName ?? "A guest")
                            Text(row.createdAt, style: .relative)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if row.hidden {
                                Text("Hidden").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(row.attachmentUid)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Guest Uploads")
        .task { await read() }
        .refreshable { await read() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editMode.isEditing ? "Done" : "Select") {
                    editMode = editMode.isEditing ? .inactive : .active
                    if !editMode.isEditing { chosen = [] }
                }
            }
            if editMode.isEditing {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Actions", systemImage: "ellipsis") {
                        ForEach(TripGuestsText.devices(in: store.contributions ?? []), id: \.0) {
                            device in
                            Button("Select All from \(device.1)") {
                                chosen = TripGuestsText.uploads(
                                    from: device.0, in: store.contributions ?? [])
                            }
                        }
                        Divider()
                        Button("Hide", systemImage: "eye.slash") { moderate(.hide) }
                        Button("Show Again", systemImage: "eye") { moderate(.unhide) }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            askingRemove = true
                        }
                    }
                    .disabled(store.isWriting)
                }
            }
        }
        .confirmationDialog(
            TripGuestsText.removeQuestion(chosen.count), isPresented: $askingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { moderate(.remove) }
        }
    }

    @ViewBuilder
    private func thumbnail(_ row: TripContribution) -> some View {
        Group {
            if let picture = store.picture(for: row.attachmentUid) {
                AttachmentThumbnail(
                    attachment: picture, tier: .thumb, slot: MemoPresentation.gridSlot)
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
        .opacity(row.hidden ? 0.4 : 1)
        .task(id: row.attachmentUid) {
            guard let access = access() else { return }
            await store.loadPicture(
                row.attachmentUid, using: access.handle, baseURL: access.baseURL)
        }
    }

    private func read() async {
        guard let access = access() else { return }
        await store.loadContributions(using: access.handle)
    }

    private func moderate(_ action: TripModeration) {
        guard let access = access(), !chosen.isEmpty else { return }
        let picked = chosen
        Task {
            do {
                let outcome = try await store.moderate(action, picked, using: access.handle)
                said = TripGuestsText.moderationNote(outcome)
                chosen = []
                if outcome.applied > 0 { onModerated() }
            } catch {
                said = (error as? TripGuestStore.Failure)?.errorDescription
                // A batch can fail after some of its calls were applied.
                onModerated()
            }
        }
    }
}

/// The words of the guest screens, as functions a test can read.
enum TripGuestsText {
    /// "Anna · iPhone app · 412 photos · last seen 2 min ago".
    static func deviceLine(_ device: TripPassDevice, now: Date) -> String {
        var parts = [device.displayName]
        switch device.platform {
        case .app: parts.append("iPhone app")
        case .clip: parts.append("App Clip")
        case .web: parts.append("browser")
        case nil: break
        }
        parts.append(device.uploadsCount == 1 ? "1 photo" : "\(device.uploadsCount) photos")
        if device.revoked {
            parts.append("revoked")
        } else if let seen = device.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append("last seen \(formatter.localizedString(for: seen, relativeTo: now))")
        }
        return parts.joined(separator: " · ")
    }

    static func passHeader(_ pass: TripPass) -> String {
        let state: String =
            switch pass.state {
            case .active: "until \(pass.expiresAt.formatted(date: .abbreviated, time: .omitted))"
            case .expired: "expired"
            case .revoked: "ended"
            }
        return "\(pass.label) · \(state)"
    }

    /// The confirmation names how many devices lose their way in.
    static func endQuestion(devices: Int) -> String {
        switch devices {
        case 0: "End this pass? Nobody has used it yet."
        case 1: "End this pass? The 1 device using it can no longer add photos."
        default: "End this pass? The \(devices) devices using it can no longer add photos."
        }
    }

    static func removeQuestion(_ count: Int) -> String {
        count == 1
            ? "Remove this photo? It is deleted from the server."
            : "Remove these \(count) photos? They are deleted from the server."
    }

    static func moderationNote(_ outcome: TripModerationOutcome) -> String? {
        guard outcome.failed > 0 else { return nil }
        return outcome.failed == 1
            ? "1 photo could not be changed."
            : "\(outcome.failed) photos could not be changed."
    }

    /// Each device that brought something, once, with the name it gave, in the inbox's order.
    static func devices(in rows: [TripContribution]) -> [(String, String)] {
        var seen: Set<String> = []
        var found: [(String, String)] = []
        for row in rows {
            guard let device = row.deviceUid, seen.insert(device).inserted else { continue }
            found.append((device, row.contributorName ?? "A guest"))
        }
        return found
    }

    static func uploads(from device: String, in rows: [TripContribution]) -> Set<String> {
        Set(rows.filter { $0.deviceUid == device }.map(\.attachmentUid))
    }
}

/// The issued pass's guest URL as a QR code, drawn on this phone with CoreImage — the server's own
/// SVG of the same URL has no view to draw it in.
enum PassQRCode {
    static func image(for url: URL, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard
            let output = filter.outputImage?.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale))
        else { return nil }
        guard let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// The system share sheet over an invitation: its guest URL and its QR code, so Messages, AirDrop,
/// Copy and Print all have something to take. Unlike a picture this needs no download first.
struct InviteShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    static func items(for issued: IssuedTripPass) -> [Any] {
        var items: [Any] = [issued.url]
        if let code = PassQRCode.image(for: issued.url) { items.append(code) }
        return items
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
