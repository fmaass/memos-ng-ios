import MemosCore
import SwiftUI

/// The account, on a sheet over the Timeline — what the Settings screen did that the phone's
/// Settings app cannot: who is signed in and where, this phone's token, the account's default
/// visibility, and signing out. Appearance and uploads went to the Settings app, the cache to the
/// Library's menu (chrome trim, owner 2026-10-10: "i think we can get rid of the gear in the app
/// altogether").
///
/// A sheet rather than a pushed screen: nothing here is a place in the Timeline's stack, and the
/// sheet is dismissed back to exactly the scroll position it was opened over.
///
/// The sign-out questions are asked from THIS view while it is up. An alert attached under a
/// presented sheet does not appear, so the level underneath mutes its own while the sheet is open
/// and the one conversation — the Timeline's, handed in — is asked here; a revoke still
/// outstanding when the sheet goes answers on the Timeline instead (`accountSheet`).
struct AccountSheet: View {
    @Environment(SessionStore.self) private var session
    // Optional: guest mode is composed by the app; without it the sheet offers no trip pass.
    @Environment(GuestSessionStore.self) private var guest: GuestSessionStore?
    @Environment(\.dismiss) private var dismiss

    let signOut: SignOutConversation
    let avatar: Image?

    @State private var savingVisibility = false
    @State private var visibilityFailed = false
    @State private var tokenDraft: String?
    @State private var tokenBusy = false
    @State private var managingTokens = false

    /// Where the two preferences that left the app are now.
    static let footer = "Appearance and uploads: Settings app › memos"
    static let refusedVisibility = "The server did not accept that. The default is unchanged."
    /// This build, as `2.2.3 (45)`: the line at the foot of the sheet that opens What's new.
    static let versionLine = AboutInfo.versionLine(from: .main)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    card { account }
                }
                Section {
                    card { defaults }
                } header: {
                    SectionHeading(title: "Defaults")
                }
                // A household member can be a guest on somebody else's trip too: the pass is kept
                // apart from the account above (its own credential, its own queue), and this is
                // where it is joined, looked at and left.
                if let guest {
                    Section {
                        card {
                            NavigationLink {
                                TripPassView(guest: guest)
                            } label: {
                                Label(
                                    TripPassPresentation.entryTitle(for: guest.state),
                                    systemImage: "qrcode.viewfinder"
                                )
                            }
                        }
                    } header: {
                        SectionHeading(title: "Trip")
                    }
                }
                Section {
                    card { SignOutSection(conversation: signOut, session: session) }
                } footer: {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
                        SettingsCaption(Self.footer)
                        // A caption that happens to open something, not a control (MEMNG-497):
                        // the plain style keeps it reading as the build's version line.
                        NavigationLink {
                            WhatsNewView(running: Self.versionLine)
                        } label: {
                            SettingsCaption(Self.versionLine)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, DesignTokens.Space.roomy)
                }
            }
            .listStyle(.plain)
            .listRowSpacing(DesignTokens.Space.regular)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await session.loadSettings() }
            .task { await session.loadDeviceToken() }
            // On the list, not on the stack the alerts below hang from: two presentations on one
            // view is how one of them silently stops appearing.
            .sheet(isPresented: $managingTokens) {
                if let baseURL = session.serverBaseURL {
                    ManageTokensView(
                        serverBaseURL: baseURL,
                        session: session,
                        appAccountName: session.state.user?.name ?? ""
                    )
                    .id(session.state.user?.subject)
                }
            }
        }
        .signOutAlerts(signOut, session: session)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            content()
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .cardRow()
    }

    @ViewBuilder
    private var account: some View {
        HStack(spacing: DesignTokens.Space.regular) {
            AccountAvatarView(image: avatar, name: session.state.user?.name ?? "", scale: 1.6)
            VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                Text(SignOutFlow.accountHeading(name: session.state.user?.name))
                    .font(.headline)
                Text(AboutInfo.serverLine(for: session.serverBaseURL))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        Divider()
        DeviceTokenSection(
            token: session.deviceToken,
            notice: session.deviceTokenNotice,
            now: .now,
            isBusy: tokenBusy,
            draft: $tokenDraft,
            rename: { name in Task { await renameToken(to: name) } },
            renew: { Task { await renewToken() } }
        )
        Divider()
        ManageTokensRow(open: { managingTokens = true })
    }

    @ViewBuilder
    private var defaults: some View {
        SettingsCaption("Who sees a new memo when you do not say otherwise.")
        Picker("Default visibility", selection: defaultVisibility) {
            ForEach(DefaultVisibilityChoice.offered, id: \.self) { option in
                Text(option.label).tag(MemoVisibility?.some(option))
            }
        }
        .pickerStyle(.segmented)
        .disabled(savingVisibility)
        if savingVisibility {
            ProgressView().controlSize(.small)
        }
        if let notice = DefaultVisibilityChoice.notice(for: session.defaultVisibility) {
            NoticeCard(text: notice, tone: .warning)
        }
        if visibilityFailed {
            NoticeCard(text: Self.refusedVisibility, tone: .error)
        }
    }

    private var defaultVisibility: Binding<MemoVisibility?> {
        Binding(
            get: { DefaultVisibilityChoice.selection(for: session.defaultVisibility) },
            set: { choice in
                guard let choice, choice != session.defaultVisibility else { return }
                Task { await save(choice) }
            }
        )
    }

    // The busy flags are what the controls show; the store's own slot is what keeps a second
    // write off the wire (`SessionStore.setDefaultVisibility`, `renameDeviceToken`).
    private func save(_ visibility: MemoVisibility) async {
        savingVisibility = true
        visibilityFailed = !(await session.setDefaultVisibility(visibility))
        savingVisibility = false
    }

    private func renameToken(to name: String) async {
        tokenBusy = true
        await session.renameDeviceToken(to: name)
        tokenBusy = false
    }

    private func renewToken() async {
        tokenBusy = true
        await session.renewDeviceToken()
        tokenBusy = false
    }
}

extension View {
    /// The account sheet, and the sign-out alerts of the level it is presented from, as ONE
    /// modifier, because the two are one decision: while the sheet is up its own stack asks the
    /// conversation and this level is muted; once it is down this level asks again — so a revoke
    /// that fails after the sheet was dismissed is still explained (`AccountSheetSignOutTests`).
    ///
    /// The session is read from the environment and handed into the sheet explicitly, so the
    /// sheet's content never depends on what a presentation inherits.
    func accountSheet(
        isPresented: Binding<Bool>, signOut: SignOutConversation, avatar: Image?
    ) -> some View {
        modifier(
            AccountSheetPresentation(isPresented: isPresented, signOut: signOut, avatar: avatar)
        )
    }
}

private struct AccountSheetPresentation: ViewModifier {
    @Environment(SessionStore.self) private var session
    @Environment(GuestSessionStore.self) private var guest: GuestSessionStore?
    @Binding var isPresented: Bool
    let signOut: SignOutConversation
    let avatar: Image?

    func body(content: Content) -> some View {
        content
            .signOutAlerts(signOut, session: session, muted: isPresented)
            .sheet(isPresented: $isPresented) {
                AccountSheet(signOut: signOut, avatar: avatar)
                    .environment(session)
                    .environment(guest)
            }
    }
}
