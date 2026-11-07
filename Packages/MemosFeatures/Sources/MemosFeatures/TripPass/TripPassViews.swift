import Foundation
import MemosCore
import SwiftUI

/// The trip-pass screen wherever it is reached from: the pass this phone holds when it holds one,
/// the way to join a trip when it does not.
struct TripPassView: View {
    let guest: GuestSessionStore

    var body: some View {
        if guest.state.isActive {
            GuestModeView(guest: guest)
        } else {
            TripPassJoinView(guest: guest)
        }
    }
}

/// The trip-pass screen as the sign-in screen presents it: its own stack and a way out.
struct TripPassSheet: View {
    let guest: GuestSessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TripPassView(guest: guest)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(DesignTokens.accent)
    }
}

/// Joining a trip: the name to join under, the live scanner when the phone has one, and a paste
/// field always — a link sent in a chat is a pass too. A refused redeem says why, and "Scan
/// again" gives the scanner a fresh claim.
struct TripPassJoinView: View {
    let guest: GuestSessionStore
    /// Starts as the name typed last time, else empty under its "Your name" placeholder; whatever
    /// it holds when a code is scanned or Join is tapped is the name sent ("Guest" when empty).
    @State private var name: String
    @State private var pasted = ""
    @State private var pasteRefused = false
    @State private var scan = 0

    /// Tall enough to aim at a code held at arm's length, short enough to leave the paste field
    /// on screen above the keyboard.
    static let scannerHeight: CGFloat = 280

    init(guest: GuestSessionStore) {
        self.guest = guest
        _name = State(initialValue: guest.joinFieldName)
    }

    private var isRedeeming: Bool { guest.state == .redeeming }

    private var notice: String? {
        if pasteRefused { return GuestSessionStore.RedeemRefusal.notAPassLink.message }
        return TripPassPresentation.notice(for: guest.state)
    }

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onChange(of: name) { _, typed in
                        let capped = GuestName.capped(typed)
                        if capped != typed { name = capped }
                    }
            } header: {
                Text("Your name")
            } footer: {
                Text("The trip shows it with everything you send.")
            }
            if TripPassScannerView.isAvailable {
                Section {
                    TripPassScannerView { url in join(url) }
                        .id(scan)
                        .frame(height: Self.scannerHeight)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Point the camera at the trip's QR code.")
                }
            }
            Section {
                TextField("Trip pass link", text: $pasted)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Join") { joinPasted() }
                    .disabled(pasted.isEmpty || isRedeeming)
            } header: {
                Text("Or paste the link")
            }
            if isRedeeming {
                Section { ProgressView() }
            }
            if let notice {
                Section {
                    NoticeCard(text: notice, tone: .error)
                    if TripPassScannerView.isAvailable {
                        Button("Scan again") {
                            pasteRefused = false
                            scan += 1
                        }
                    }
                }
            }
        }
        .navigationTitle("Join a trip")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func join(_ url: URL) {
        pasteRefused = false
        let typed = name
        Task { await guest.redeem(passLink: url, typedName: typed) }
    }

    private func joinPasted() {
        guard let url = TripPassPresentation.passLink(fromPasted: pasted) else {
            pasteRefused = true
            return
        }
        join(url)
    }
}

/// Guest mode: which trip this phone sends to and until when, what the door says it has, and the
/// way out.
struct GuestModeView: View {
    let guest: GuestSessionStore

    var body: some View {
        List {
            Section {
                if case .active(let label, let expiresAt) = guest.state {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                        Text(label)
                            .font(.headline)
                        Text("Until \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                GuestNameEditor(guest: guest)
                Text("Share photos and videos to this trip from the Photos app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Trip")
            }
            Section {
                if guest.receipts.isEmpty {
                    Text("Nothing has arrived yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(guest.receipts) { receipt in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                        Text(TripPassPresentation.receiptSummary(receipt))
                        if let completedAt = receipt.completedAt {
                            Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Sent")
            }
            Section {
                Button("Leave trip", role: .destructive) {
                    Task { await guest.leave() }
                }
            } footer: {
                Text(
                    "Anything still waiting to send stays on this phone and is never sent under"
                        + " another pass."
                )
            }
        }
        .navigationTitle("Trip pass")
        .navigationBarTitleDisplayMode(.inline)
        .task { await guest.refreshReceipts() }
        .refreshable { await guest.refreshReceipts() }
    }
}

/// The name the trip credits this phone's pictures to, editable after joining. Saving asks the door
/// (`GuestSessionStore.rename`); the field is locked until the answer, then shows the name the door
/// stored (`GuestNameDraft`). A refusal leaves the stored name as it was and says what to do; the
/// typed text stays so it can be corrected.
struct GuestNameEditor: View {
    let guest: GuestSessionStore
    @State private var draft: GuestNameDraft
    @State private var notice: String?

    init(guest: GuestSessionStore) {
        self.guest = guest
        _draft = State(initialValue: GuestNameDraft(stored: guest.joinedName))
    }

    var body: some View {
        HStack {
            TextField(
                "Your name",
                text: Binding(
                    get: { draft.text },
                    set: { typed in
                        draft.edit(typed)
                        notice = nil
                    })
            )
            .textContentType(.name)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { save() }
            .disabled(!draft.isEditable)
            if draft.isEditable {
                Button("Save") { save() }
                    .disabled(!draft.canSave(stored: guest.joinedName))
            } else {
                ProgressView()
            }
        }
        .onChange(of: guest.joinedName) { _, stored in draft.storedChanged(stored) }
        if let notice {
            NoticeCard(text: notice, tone: .error)
        }
    }

    private func save() {
        guard let typed = draft.beginSave(stored: guest.joinedName) else { return }
        notice = nil
        Task {
            let outcome = await guest.rename(to: typed)
            notice = draft.finish(outcome)
        }
    }
}
