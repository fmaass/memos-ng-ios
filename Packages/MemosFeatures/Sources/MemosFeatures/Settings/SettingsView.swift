import MemosCore
import SwiftUI
import UIKit

/// The Settings destination, as a value the navigation path can hold. Empty because there is only
/// one Settings screen — it is a name for a place, not a payload.
struct SettingsRoute: Hashable {}

/// Settings: the screen that lets the native app stop being a shortcut to the web app.
///
/// Built out of the timeline's own vocabulary rather than a `Form`, and that is a decision rather
/// than an oversight. A grouped `Form` brings iOS's inset-grouped chrome with it — its own
/// separators, its own corner radius, its own idea of a row — and the app already has all three,
/// declared in `DesignTokens` and used by every card on the screen this one is pushed from. Two
/// answers to "what does a section look like" on adjacent screens is the second visual language
/// this app does not have.
///
/// The screen holds no logic worth the name. Every decision on it is a function somewhere else:
/// which sections exist (`SettingsScreen`), what the two visibility rows are
/// (`DefaultVisibilityChoice`), what a stored appearance means (`AppSettings`), what a cache size
/// reads as (`MediaCacheMaintenance`), what a sign-out tap does (`SignOutFlow`), what a build is
/// called (`AboutInfo`).
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    // Optional for the same reason the outbox is on the timeline: a preview or a test host has no
    // settings store, and a missing environment value must not be a crash.
    @Environment(AppSettings.self) private var settings: AppSettings?
    /// Optional for the same reason, and the same object the outbox listens to — see
    /// `Outbox.uploadPreferences`.
    @Environment(UploadSettings.self) private var uploadSettings: UploadSettings?

    /// The one conversation, handed in by the screen that also puts it in the toolbar menu. Two
    /// stages would be two machines and, between them, two revokes — see `SignOutConversation`.
    let signOut: SignOutConversation
    /// Decoded once, by the screen that already needed it for the toolbar. Decoding a few hundred
    /// kilobytes again on push would be paying twice for one picture.
    let avatar: Image?

    @State private var cache = MediaCacheMaintenance.Usage(usedBytes: 0, capacityBytes: 0)
    /// A visibility change in flight. The rows do not move until the server has answered, so this
    /// is what says the tap was heard.
    @State private var savingVisibility = false
    @State private var visibilityFailed = false
    /// The device name being typed, or `nil` when the row is only being read. Held by the screen
    /// rather than by the row, so an answer arriving from the session — which redraws the row —
    /// cannot throw away what somebody is in the middle of typing.
    @State private var tokenDraft: String?
    /// A rename or a renewal is on the wire. One flag for both: they are alternatives, and a
    /// renewal is not something to start twice (see `DeviceTokenSection`).
    @State private var tokenBusy = false
    /// Whether token management is open. A sheet rather than a push, and that is the point rather
    /// than a layout preference: the management grant behind that screen dies with it, so the
    /// screen should read as a session somebody opens and closes — and dismissing a sheet is what
    /// ends it.
    @State private var managingTokens = false

    var body: some View {
        List {
            ForEach(SettingsScreen.sections, id: \.self) { section in
                Section {
                    card(section)
                } header: {
                    // Not every section prints one: the sign-out section's row already says the
                    // word, and a heading over it would say it twice (`SettingsScreen.Section`).
                    if let title = section.title {
                        SectionHeading(title: title)
                    }
                }
            }
        }
        .listStyle(.plain)
        .listRowSpacing(DesignTokens.Space.regular)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Self-sufficient: the timeline reads the account's settings when it opens, but a read
        // that failed there would otherwise leave this screen — the one whose whole job is to show
        // and change them — permanently blank.
        .task { await session.loadSettings() }
        // The phone learns its expiry at the mint and nowhere else, so without this read a
        // reinstalled app cannot say how long this device has left.
        .task { await session.loadDeviceToken() }
        .task { cache = MediaCacheClearing.usage() }
        // Only openable while the app knows which server it is signed in to: the management
        // sign-on is a round trip to that server, and there is nowhere to send it otherwise.
        .sheet(isPresented: $managingTokens) {
            if let baseURL = session.serverBaseURL {
                ManageTokensView(serverBaseURL: baseURL, session: session)
            }
        }
    }

    @ViewBuilder
    private func card(_ section: SettingsScreen.Section) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            switch section {
            case .account: account
            case .defaults: defaults
            case .uploads: uploads
            case .appearance: appearance
            case .storage: storage
            case .about: about
            case .signOut: SignOutSection(conversation: signOut, session: session)
            }
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .cardRow()
    }

    // MARK: - sections

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
        // Below this device's own row, because it is the wider thing: that row is what this phone
        // may do to ITSELF, and this is the account's whole list — which costs a fresh sign-on to
        // reach, because a device token may never mint or revoke a sibling (ADR-0015).
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
            NoticeCard(
                text: "The server did not accept that. The default is unchanged.",
                tone: .error
            )
        }
    }

    @ViewBuilder
    private var uploads: some View {
        UploadsSection(allowsMobileData: mobileData)
    }

    @ViewBuilder
    private var appearance: some View {
        SettingsCaption("System follows the phone, and switches when it does.")
        Picker("Appearance", selection: appearanceChoice) {
            ForEach(AppearancePreference.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var storage: some View {
        SettingsCaption(
            "Photos and videos this phone has downloaded. Clearing them frees space; nothing"
                + " waiting to be posted is touched."
        )
        HStack {
            Text("Media cache")
            Spacer(minLength: DesignTokens.Space.regular)
            Text(MediaCacheMaintenance.summary(cache))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        Divider()
        // The read-back is the point: the number beside it is re-read from the cache that was just
        // emptied, so "Empty" is the cache answering rather than the button congratulating itself.
        Button("Clear cache") {
            MediaCacheClearing.clearDerived()
            cache = MediaCacheClearing.usage()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!MediaCacheMaintenance.isClearable(cache))
    }

    @ViewBuilder
    private var about: some View {
        HStack {
            Text("Version")
            Spacer(minLength: DesignTokens.Space.regular)
            Text(AboutInfo.versionLine(from: .main))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - bindings

    /// Nothing moves until the server has answered, so the checked row is always the account's
    /// real setting rather than the last thing tapped.
    private var defaultVisibility: Binding<MemoVisibility?> {
        Binding(
            get: { DefaultVisibilityChoice.selection(for: session.defaultVisibility) },
            set: { choice in
                guard let choice, choice != session.defaultVisibility else { return }
                Task { await save(choice) }
            }
        )
    }

    /// Written through the store the drain reads, and awaited: the write is what a queued capture
    /// is waiting for, and the drain it starts is what sends it without another tap.
    private var mobileData: Binding<Bool> {
        Binding(
            get: { uploadSettings?.allowsMobileData ?? false },
            set: { value in Task { await uploadSettings?.select(value) } }
        )
    }

    private var appearanceChoice: Binding<AppearancePreference> {
        Binding(
            get: { settings?.appearance ?? .system },
            set: { settings?.select($0) }
        )
    }

    private func save(_ visibility: MemoVisibility) async {
        savingVisibility = true
        visibilityFailed = !(await session.setDefaultVisibility(visibility))
        savingVisibility = false
    }

    /// Both of these say nothing of their own about how it went: the row is drawn from the
    /// session's `deviceToken` and `deviceTokenNotice`, so what is on screen afterwards is what the
    /// server answered rather than what this screen hoped.
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

/// Signing out, at the bottom of the screen and nowhere else.
///
/// MEMNG-185. It sat in the Account section at the TOP and in the toolbar's account menu, so the
/// first thing the screen offered — and one of the two things the menu did — was the one action
/// that ends the session. It is a rare, deliberate act and it now reads as one: last on the
/// screen, a plain word rather than a labelled button, and no heading over it.
///
/// A view of its own, holding the conversation and the session rather than a closure handed down
/// from the screen, and that is the point rather than tidiness: `SettingsView` cannot be hosted in
/// a test (it reads a `SessionStore`, which the Features test bundle cannot construct — see
/// `SettingsRenderTests`), so a row written inline in that body, or one whose action arrived from
/// there, would be the app's ONLY way to sign out with no test able to reach it. Here the tap and
/// what the tap does are both inside something a test can put on a screen and press
/// (`SignOutSectionTests`).
///
/// The red is stated rather than left to the destructive role: these cards are hand-built rather
/// than system list rows, and inside them a button takes the app's accent — the green the whole
/// app is drawn in. The one control here that takes something away must not read like the rest.
struct SignOutSection: View {
    let conversation: SignOutConversation
    let session: any SignOutRevoking

    var body: some View {
        Button(role: .destructive) {
            conversation.send(.requested, to: session)
        } label: {
            Text("Sign out")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The Uploads section's contents, and the only control on this screen that decides whether bytes
/// leave the phone.
///
/// A view of its own rather than a body inside `SettingsView`, and not for tidiness: the screen
/// itself cannot be rendered in a test — it reads a `SessionStore`, and constructing one inlines
/// the API layer the Features test bundle does not link (see `SettingsRenderTests`) — so a switch
/// held only inside that body would be a control no test could see. This one is drawn by
/// `SettingsRenderTests`, twice, and the two pictures have to differ.
///
/// The footer says what stays true with the switch ON, because a row that read as "send
/// everything, always" would be lying about Low Data Mode, which the policy refuses either way.
struct UploadsSection: View {
    @Binding var allowsMobileData: Bool

    var body: some View {
        SettingsCaption(UploadSettings.footer)
        Toggle(UploadSettings.title, isOn: $allowsMobileData)
    }
}

/// The line under a section heading that says what the controls below it will do. Footnote weight
/// and secondary, because it is the explanation and never the control.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The account's picture, or its monogram.
///
/// The monogram is not a placeholder waiting for a picture: an account without an avatar has no
/// picture coming, and an empty grey circle reads as one that failed to load.
///
/// `scale` is a multiple of the shared avatar metric rather than a free size, and it is read
/// through `@ScaledMetric`, so the picture grows with the type size. The toolbar drew one of
/// these too until MEMNG-185 replaced the account anchor with a gear; the metric stays shared
/// because the size of a face is a token, not a number this screen invented.
struct AccountAvatarView: View {
    let image: Image?
    let name: String
    var scale: CGFloat = 1

    @ScaledMetric private var base = DesignTokens.Metric.avatar

    private var side: CGFloat { base * scale }

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Circle()
                    .fill(DesignTokens.accent.opacity(0.15))
                    .overlay {
                        Text(AccountAvatar.initials(for: name))
                            .font(.system(size: side * 0.42, weight: .semibold))
                            .foregroundStyle(DesignTokens.accent)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
