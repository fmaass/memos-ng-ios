import MemosCore
import SwiftUI
import UIKit

/// The management screen as the app puts it on a phone: the store, the browser sheet, and the two
/// moments the grant has to die.
///
/// It is deliberately thin, and everything it does that could be wrong lives somewhere a test can
/// reach — the states in `ManageTokensStore`, the drawing in `ManageTokensScreen`. What is left
/// here is the wiring this layer cannot have both ways: this view holds a `ManageTokensStore`,
/// which inlines the API layer the Features test bundle does not link, so it cannot be hosted in
/// a test at all (the same reason `SettingsView` cannot).
///
/// The grant lives for exactly as long as this view does. It goes when the sheet is dismissed and
/// when the app is backgrounded, and it was never written anywhere that could outlive either.
/// Backgrounding is read as `.background` rather than "anything but active" on purpose: a system
/// alert makes a scene inactive, and the Local Network prompt is raised by the very sign-on this
/// screen is in the middle of — throwing that away would make the first management session on a
/// fresh install impossible to complete.
struct ManageTokensView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var store: ManageTokensStore
    /// This screen's own browser presenter, not the sign-in screen's: each of them owns one
    /// attempt at a time, and sharing one would let a sign-in and a step-up cancel each other.
    @State private var presenter = SafariLoginPresenter()
    @State private var draft = ""

    init(configuration: ServerConfiguration) {
        _store = State(initialValue: ManageTokensStore(configuration: configuration))
    }

    var body: some View {
        NavigationStack {
            ManageTokensScreen(
                state: store.state,
                minted: store.minted,
                secretLost: store.mintedSecretLost,
                notice: store.notice,
                isBusy: store.isBusy,
                now: .now,
                draft: $draft,
                signOn: { Task { await signOn() } },
                create: { name in Task { await create(name) } },
                revoke: { id in Task { await store.revoke(id) } },
                copySecret: { UIPasteboard.general.string = $0 },
                dismissSecret: { store.dismissMinted() }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityLabel("Close token management")
                }
            }
        }
        .onDisappear { store.forget() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.forget() }
        }
    }

    private func signOn() async {
        let signedOn = await store.authenticate(
            deviceName: UIDevice.current.name,
            presenter: presenter
        )
        // The presenter's own machine has to be told how the attempt it opened ended, or the next
        // tap finds it still exchanging and opens nothing.
        presenter.exchangeFinished(succeeded: signedOn)
    }

    private func create(_ name: String) async {
        // The field is emptied only by a create the server accepted, so a refused name is still
        // there to be corrected rather than retyped.
        if await store.create(name: name) { draft = "" }
    }
}
