import AVKit
import MemosCore
import SwiftUI
import UIKit

/// A memo's pictures and videos, full screen: pinch to zoom, drag to move, double tap to go in and
/// out, swipe sideways for the next one, and back down into the tile it came from.
///
/// It is presented as a full-screen cover with the platform ZOOM transition, so the picture grows
/// out of the tile that was tapped and shrinks back into it — including when the shrink is a drag
/// the system is following in real time. That is also why there is no hand-written
/// swipe-to-dismiss gesture here: the transition owns that interaction, and a second recogniser
/// translating the same content would fight it. The close button is the deliberate,
/// always-available way out, and the escape action gives VoiceOver the same door.
///
/// The one thing the transition is asked to stand down for is a magnified picture: while a page
/// holds dismissal, `.interactiveDismissDisabled` is on, so a pinch-out from a zoomed picture
/// only zooms out instead of starting to close the viewer. It is the documented switch for a
/// presentation's interactive dismissal and it costs one line; whether it reaches THIS
/// transition's dismissal is answered on a device, because nothing that runs here can pinch.
///
/// A video is a PAGE of this pager, on the same swipe as the photo beside it. It used to be a
/// second `fullScreenCover` presented OVER the pager, which meant that in a memo with several
/// attachments the first video anybody played was where the swiping stopped: the pager was still
/// down there, under a cover nothing could reach. There is one player and it lives here, because
/// the rule that keeps it to one — built for the page that becomes current, torn down when that
/// page is dismissed or two swipes away — is a rule about the pager, not about a page
/// (`MediaViewerPlayback`).
struct MediaViewerView: View {
    let selection: MediaViewerSelection
    /// Where the pages come from, and whether there are more of them behind the loaded ones. A
    /// memo's viewer is `.fixed`; the library's is `.library`, which is what lets a swipe carry on
    /// past the page the grid had loaded when the file was tapped (MEMNG-189).
    let source: MediaViewerSource
    /// How a page is removed from the server, when this viewer is allowed to remove one at all.
    ///
    /// Passed IN rather than reached for, exactly as the memo delete's request is: the viewer has
    /// no store and no client, and the screen that presented it is the only thing that knows which
    /// memo these pictures hang on. `nil` is a viewer that cannot delete — the media library's —
    /// and it is what makes a control with nothing behind it impossible rather than merely absent.
    let delete: (@MainActor (String) async -> Bool)?
    /// One more thing the presenting screen lets the reader do with the page on screen, or nil —
    /// which is every viewer but a trip's ("Use as Cover", MEMNG-720). Passed in, as `delete` is:
    /// the viewer knows nothing of trips, only that a host handed it an action.
    let hostAction: MediaViewerHostAction?
    /// The pages deleted elsewhere while this viewer is open, handed in by a screen that holds the
    /// pictures Delete took. Each leaves as a page this viewer deleted itself does (`remove`): the
    /// reader moves on to the next page, and the last one closes the viewer. Never merely left out
    /// of the source: the pager keeps a page its source drops (`MediaViewerPager.extended`).
    let gone: Set<MediaPage.ID>
    /// What every page's still is fetched through. The app's own session everywhere but a test
    /// that watches a page's next request go out.
    let transport: any MediaTransport

    @Environment(\.dismiss) private var dismiss
    /// The way out of a tab that cannot open a memo. Optional: a preview or a test host has no
    /// router, and a missing environment value must be a missing action, not a crash.
    @Environment(MemoJump.self) private var jump: MemoJump?
    /// Whose credential the original download presents. Optional for the same reason the router
    /// is: this bundle's tests host the viewer with neither.
    @Environment(SessionStore.self) private var session: SessionStore?
    /// The session's favorites, which the bar's heart reads and writes. Optional for the same
    /// reason: a host without one draws the heart inert.
    @Environment(FavoriteStore.self) private var favorites: FavoriteStore?
    /// Why the last heart tap wrote nothing (somebody else's picture), until the page changes.
    @State private var heartNotice: String?
    /// The place names the Info sheet has looked up, one lookup per file while the viewer is up.
    @State private var places = PlaceNameCache()
    /// The download the menu's slow action starts, and the sheet it ends in.
    @State private var saving = MediaSaveFlow()
    /// The page the pager has settled on — the identity of the page, not an index, because a
    /// paging scroll view tracks identity.
    @State private var currentPage: String?
    /// The pages this viewer has ADOPTED so far. Not what is rendered — `pages` is, and it
    /// reconciles this against the source on every evaluation.
    @State private var shown: [MediaPage]
    /// Which page, if any, is holding the pager still. Paging is off while one is: a sideways drag
    /// inside a zoomed picture is a pan, and a page that turns halfway through examining a photo is
    /// the single most annoying thing a viewer can do. Fingers on the glass are enough — the hold
    /// does not wait for the scale to have changed.
    @State private var pagerHeldBy: String?
    /// Which page, if any, is holding the presentation's interactive dismissal. Narrower than the
    /// pager's hold on purpose: at fitted size a pinch-in is how the viewer is closed.
    @State private var dismissalHeldBy: String?
    /// Everything playback DOES: the policy's answer, the one `AVPlayer`, and the audio session
    /// the sound needs — none of which a view body can be asked about, so none of which is
    /// decided in one (`MediaViewerPlaybackCoordinator`).
    @State private var playback: MediaViewerPlaybackCoordinator
    /// How far the delete conversation has got, and about which page (`AttachmentDeleteFlow`).
    @State private var deletion = AttachmentDeleteFlow()
    /// The pages the server has confirmed gone, from this viewer.
    ///
    /// It has to be kept, not merely removed from `shown`. A memo's source is FIXED and never
    /// shrinks, and `pages` is recomputed from it every evaluation — so a page taken out of `shown`
    /// alone is put straight back by the next one. `MediaViewerPager.visible` is where the two
    /// meet.
    @State private var removed: Set<MediaPage.ID> = []
    /// Whether the chrome — the top row, the date capsule and the bar — is drawn. One tap on the
    /// picture hides all three, the next brings them back (`MediaViewerChrome`).
    @State private var chrome = MediaViewerChrome()
    /// What the Info sheet is open about — the page, and the opening it took — or nil.
    @State private var inspecting: MediaInfoSubject?
    /// The Info sheet's two reads, made only when it opens; one store for this viewer's lifetime,
    /// so a memo looked up once is not looked up again.
    @State private var context: MediaContextStore?

    init(
        selection: MediaViewerSelection,
        source: MediaViewerSource,
        delete: (@MainActor (String) async -> Bool)? = nil,
        hostAction: MediaViewerHostAction? = nil,
        gone: Set<MediaPage.ID> = [],
        transport: any MediaTransport = MediaSession.shared
    ) {
        self.selection = selection
        self.source = source
        self.delete = delete
        self.hostAction = hostAction
        self.gone = gone
        self.transport = transport
        _currentPage = State(initialValue: selection.startPage.id)
        _shown = State(initialValue: selection.pages)
        _playback = State(initialValue: MediaViewerPlaybackCoordinator(selection: selection))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            pager
        }
        .overlay(alignment: .top) { topRow }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                failureNotice
                bar
            }
        }
        .sheet(item: $inspecting) { subject in
            infoSheet(for: subject)
        }
        // Another account — or none — while the viewer is up: the Info sheet's memo and record
        // were read as the one before. The store also refuses a handle of another generation on
        // its own (`MediaContextStore.adopt`); this is the viewer's notice of the same change.
        .onChange(of: session?.snapshotIdentity) { _, _ in context?.sessionIdentityChanged() }
        // The question lives HERE, on the cover, and not on the screen that presented it: an alert
        // attached under a full-screen presentation never appears at all. An alert rather than a
        // confirmation dialog for the reason `ComposeView.deleteRow` records — the dialog put its
        // Cancel neither on screen nor in the accessibility tree.
        .alert(
            asked.map { AttachmentDeleteFlow.question(for: $0.attachment) } ?? "",
            isPresented: askingDelete,
            presenting: asked
        ) { page in
            Button(AttachmentDeleteFlow.title(for: page.attachment), role: .destructive) {
                send(.confirmed)
            }
            Button("Cancel", role: .cancel) { send(.cancelled) }
        } message: { _ in
            Text(AttachmentDeleteFlow.explanation)
        }
        .fetchingFile(saving)
        // The platform's own switch for a presentation's interactive dismissal, asked here so all
        // five presentation sites get it without being touched. The close button and the escape
        // action call `dismiss()` and are unaffected.
        .interactiveDismissDisabled(MediaViewerPager.stands(dismissalHeldBy, among: pages))
        .statusBarHidden()
        // Two-finger scrub, the system-wide "get me out of here" — the same door as the button.
        .accessibilityAction(.escape) { dismiss() }
        // A tapped video is playing before the zoom transition has finished growing out of its
        // tile. A poster with a play button on it, waiting for a second tap, is what this
        // replaced.
        .onAppear { playback.advance(.opened) }
        .onChange(of: currentPage) { _, settled in
            guard let settled else { return }
            heartNotice = nil
            favorites?.dismissNotice()
            playback.advance(.paged(to: settled))
            Task { await advance(to: settled) }
        }
        // The pages the grid had already loaded by the time this cover drew its first frame. A
        // page that arrived between the tap and this moment is in `source.pages` but was never an
        // `onChange`, because it landed BEFORE the modifier had a baseline to compare against — it
        // simply became the baseline. `pages` reconciles on every evaluation so the frame is right
        // whichever way that race went; this is what carries the same answer into the two places
        // that keep state rather than read it (MEMNG-189, review round 1).
        .onAppear { adoptFromSource() }
        // The library grows under an open viewer, and this is where the growth is taken in. The
        // value is READ here, which is what subscribes this view to the store behind a `.library`
        // source; what to do with a source that is no longer the same list at all is
        // `MediaViewerPager.extended`'s decision, not this line's.
        // Only adoption. Reading THROUGH pages that hold nothing to show is the paging seam's
        // job, not this view's: a page of documents changes nothing here, so no modifier on this
        // screen could observe it (`MediaViewerSource.loadMore`).
        .onChange(of: source.pages) { _, _ in adoptFromSource() }
        // A page deleted elsewhere, from the first frame on.
        .onChange(of: gone, initial: true) { _, now in drop(now) }
        // The way out is not only the close button: the zoom transition dismisses on a drag, and
        // a video that went on playing behind a dismissed viewer would be a voice in an empty
        // room. Every exit lands here.
        .onDisappear { playback.advance(.dismissed) }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages) { page in
                    MediaViewerPage(
                        page: page,
                        // Only the page that set a hold may clear it: the page being swiped away
                        // from reports its release after the page arriving has taken its own.
                        onHoldsChange: { holds in
                            if holds.pager {
                                pagerHeldBy = page.id
                            } else if pagerHeldBy == page.id {
                                pagerHeldBy = nil
                            }
                            if holds.dismissal {
                                dismissalHeldBy = page.id
                            } else if dismissalHeldBy == page.id {
                                dismissalHeldBy = nil
                            }
                        },
                        // Handed to exactly one page: the one the single player belongs to. Every
                        // other page gets `nil` and draws its poster.
                        player: playback.player(for: page.id),
                        play: { playback.advance(.played(page: page.id)) },
                        onTap: { withAnimation(.easeInOut(duration: 0.2)) { chrome.tapped() } },
                        transport: transport
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(page.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentPage)
        .scrollIndicators(.hidden)
        .scrollDisabled(MediaViewerPager.stands(pagerHeldBy, among: pages))
        .ignoresSafeArea()
    }

    private var currentContext: MediaViewerContext? {
        pages.first { $0.id == currentPage }.map {
            MediaViewerContext.resolve($0, carried: source.carriedMemo)
        }
    }

    /// Close on the left, the page's date in the middle, ⋯ on the right. The side slots take the
    /// same width, so the capsule keeps the middle whichever of them is drawn.
    private var topRow: some View {
        let shown = chrome.shown
        return HStack(spacing: DesignTokens.Space.snug) {
            MediaViewerCloseButton { dismiss() }
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let date = currentContext?.date {
                    // The date is the Info sheet's first row, so a tap on it opens the sheet.
                    MediaViewerDateCapsule(date: date)
                        .contentShape(Capsule())
                        .onTapGesture { openCurrentInfo() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { openCurrentInfo() }
                }
            }
            .opacity(shown.contains(.dateCapsule) ? 1 : 0)
            actions
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
        .opacity(shown.contains(.topRow) ? 1 : 0)
        .allowsHitTesting(shown.contains(.topRow))
        .accessibilityHidden(!shown.contains(.topRow))
    }

    @ViewBuilder
    private var bar: some View {
        let shown = chrome.shown.contains(.bar)
        if let page = pages.first(where: { $0.id == currentPage }) {
            MediaViewerBar(
                attachment: page.attachment,
                binShown: MediaViewerBar.binShown(
                    deletable: selection.deletable, canDelete: delete != nil),
                // The share flow the ⋯ menu's Share row ran, moved here unchanged.
                share: { Task { await fetch(page.attachment, .shared) } },
                info: { openInfo(page) },
                delete: { send(.tapped(page.attachment.uid)) },
                favorites: favorites,
                handle: session?.activeHandle,
                baseURL: session?.serverBaseURL,
                notice: { heartNotice = $0 }
            )
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
        }
    }

    private func openCurrentInfo() {
        guard let page = pages.first(where: { $0.id == currentPage }) else { return }
        openInfo(page)
    }

    private func openInfo(_ page: MediaPage) {
        let store: MediaContextStore
        if let context {
            store = context
        } else if let session {
            store = MediaContextStore(
                onUnauthorized: { [session] refusal in await session.handle(refusal) })
            store.reports(to: session)
            if let favorites { store.follow(favorites) }
        } else {
            store = MediaContextStore()
        }
        context = store
        inspecting = MediaInfoSubject(page: page, store: store, opening: store.open(page.id))
    }

    /// The sheet for ONE subject: its opening travels inside the value the sheet was presented
    /// over, so the reads, the rows and the cleanup all name that opening — never whichever one
    /// the viewer holds by the time a dismissed sheet's `onDisappear` runs.
    private func infoSheet(for subject: MediaInfoSubject) -> some View {
        MediaInfoSheet(
            page: subject.page,
            context: MediaViewerContext.resolve(subject.page, carried: source.carriedMemo),
            store: subject.store,
            opening: subject.opening,
            handle: session?.activeHandle,
            baseURL: session?.serverBaseURL,
            places: places,
            showMemo: { uid in
                inspecting = nil
                dismiss()
                jump?.request(uid)
            }
        )
    }

    /// What can be done with the file on screen — the same actions its tile offers under a long
    /// press, in a place nobody has to know a gesture to find. A context menu must never be the
    /// only way to reach an action, and full screen is where the tile is no longer on screen at
    /// all.
    ///
    /// It is `MediaTileMenu`'s list less Share (`viewerActions`), which moved to the bar below, so
    /// the two surfaces still cannot offer different things about one file. A memo's own page
    /// offers no "Show Memo": its attachments carry no owner on purpose, because the only memo it
    /// could take anybody to is the one directly behind this cover.
    @ViewBuilder
    private var actions: some View {
        let page = pages.first { $0.id == currentPage }
        HStack(spacing: 0) {
            MediaViewerActions(
                control: page.map { MediaTileMenu.viewerControl(for: $0.attachment) } ?? .hidden,
                showMemo: { uid in
                    // Out of the cover FIRST: the jump changes tabs, and a full-screen cover
                    // presented by the tab being left would be a black screen over the memo.
                    dismiss()
                    jump?.request(uid)
                },
                fetch: { attachment, rendition in
                    Task { await fetch(attachment, rendition) }
                },
                // Handed to the menu here and never to `MediaTileMenu`'s list: only the host that
                // injected it offers it, so a library tile never grows a trip's row (MEMNG-768).
                host: hostAction.flatMap { action in
                    page.map { page in
                        MediaViewerHostItem(action: action, attachment: page.attachment) {
                            dismiss()
                        }
                    }
                }
            )
        }
    }

    /// What a refused delete says, on the one screen with nowhere else to say it.
    ///
    /// The detail view behind this cover has a notice of its own, but it is a DIFFERENT flow's and
    /// it is behind a full-screen cover nobody can see past — so a delete refused from in here
    /// used to fail in silence, the picture simply staying where it was. It is the same card the
    /// timeline shows a failure in, so one refusal does not look like two different things, and
    /// the next question clears it (`AttachmentDeleteFlow` settles `lastError` on every `tapped`).
    @ViewBuilder
    private var failureNotice: some View {
        if let failure = deletion.lastError {
            NoticeCard(text: failure, tone: .error)
                .padding(DesignTokens.Space.roomy)
        } else if let favorite = favorites?.notice {
            NoticeCard(text: favorite, tone: .error)
                .padding(DesignTokens.Space.roomy)
        } else if let heartNotice {
            NoticeCard(text: heartNotice, tone: .warning)
                .padding(DesignTokens.Space.roomy)
        }
    }

    /// The page a question is open about, or nil.
    private var asked: MediaPage? {
        guard let uid = deletion.asking else { return nil }
        return pages.first { $0.id == uid }
    }

    /// What the alert binds to. Only dismissal comes back through it — the question is opened by
    /// the button, never by an assignment from outside, the same discipline `MemoEditFlow.sheet` is
    /// built on.
    private var askingDelete: Binding<Bool> {
        Binding(get: { asked != nil }, set: { if !$0 { send(.cancelled) } })
    }

    /// Every event goes through the flow, and the STATE MOVES HERE — synchronously, before any
    /// task exists.
    ///
    /// The alert's dismissal binding fires in the same turn as the button that dismissed it, so a
    /// confirmation and a cancellation both wrapped in tasks would be two pieces of work with no
    /// order between them, and the cancellation winning would silently swallow a Delete somebody
    /// pressed. Claimed first, the confirmation is already at `deleting` when the dismissal lands.
    /// Only the REQUEST needs a task — and none at all on a viewer that was handed no way to
    /// delete.
    private func send(_ event: AttachmentDeleteFlow.Event) {
        guard let delete else { return }
        // Read from the claim rather than before it: the stage now names the page the request is
        // for, and by the time the answer is back it is `idle` again and says nothing.
        guard deletion.claim(event), let target = deletion.deleting else { return }
        Task {
            let gone = await deletion.perform(delete: delete)
            guard gone else { return }
            remove(target)
        }
    }

    /// The page is gone from the server; take it off the screen, and keep it off.
    private func remove(_ id: MediaPage.ID) {
        removed.insert(id)
        let outcome = MediaViewerPager.removing(id, from: shown, current: currentPage ?? id)
        shown = outcome.pages
        // Nothing left to look at. An empty pager is a black screen with a close button on it, so
        // the viewer closes itself instead.
        guard let next = outcome.current else {
            dismiss()
            return
        }
        currentPage = next
        playback.adopt(pages: shown, startingAt: next)
    }

    /// Takes the pages deleted elsewhere off the screen, each the way `remove` takes one.
    private func drop(_ gone: Set<MediaPage.ID>) {
        for id in shown.map(\.id) where gone.contains(id) && !removed.contains(id) {
            remove(id)
            if shown.isEmpty { return }
        }
    }

    /// Fetches the named file of the picture or clip on screen and offers it to the share sheet.
    ///
    /// The session is what holds the credential; without one there is nothing to present, which is
    /// the same refusal `SessionStore.download` makes for a session that has ended.
    private func fetch(_ attachment: MemoAttachment, _ rendition: AttachmentRendition) async {
        await saving.save(attachment) { [session] attachment in
            guard let session else { throw OriginalMediaError.notSignedIn }
            return try await session.download(attachment, rendition)
        }
    }

    /// The next page, when the reader is close enough to the end of the loaded ones to need it.
    /// Both halves of that decision belong to the source, so a swipe in the middle of a loaded run
    /// and a swipe arriving while a page is already in flight both cost nothing.
    private func advance(to id: String) async {
        await source.loadMore(nearingPageWithID: id)
    }

    /// What is rendered: everything adopted so far, reconciled against what the source holds NOW.
    ///
    /// Computed rather than stored so there is no first-frame gap to lose a page into — see
    /// `onAppear` above. `MediaViewerPager.extended` is what decides whether the source is this
    /// list grown longer or a different list altogether.
    private var pages: [MediaPage] {
        MediaViewerPager.visible(shown: shown, source: source.pages, removed: removed)
    }

    /// Locks the reconciled list in, and tells playback about it — the two pieces of state that
    /// cannot be recomputed per frame. Idempotent, so running it on appear AND on every change is
    /// exactly as correct as running it once.
    private func adoptFromSource() {
        shown = pages
        // The player belongs to a page of THIS list; a video on a page that has just arrived has
        // to be one the playback rules can find.
        playback.adopt(pages: shown, startingAt: selection.startPage.id)
    }
}

/// The viewer's control over the file on screen, in whichever shape its actions call for.
///
/// A view of its own rather than a branch written into the viewer's body, for the reason every
/// other seam in this file exists: what it draws is decided by `MediaTileMenu.control(of:)` and
/// what a press DOES is `MediaTileActionItem.tapped()`, so both halves can be asserted without a
/// full-screen cover, a pager and a player standing behind them.
///
/// A single action is drawn as itself — its own icon, one tap — because a three-dots menu fronting
/// one row is an indirection that buys nothing (MEMNG-213). Two or more keep the menu. The
/// full-screen viewer's own top row hands it a `.menu` for any rows at all
/// (`MediaTileMenu.viewerControl`), so there it is always ⋯.
///
/// Both shapes press the SAME row. That is what keeps the one-download-at-a-time guard and the
/// session's own fence behind Share on one path: the direct button is different chrome around the
/// dispatch the menu row already had, not a second way to start a download.
struct MediaViewerActions: View {
    let control: MediaActionControl
    let showMemo: (String) -> Void
    /// Defaulted for the same reason the row's is: a surface that cannot download still builds the
    /// control rather than being handed a different one.
    var fetch: (MemoAttachment, AttachmentRendition) -> Void = { _, _ in }
    /// The presenting screen's own row, drawn LAST in the menu, or nil — every viewer but a trip's
    /// (MEMNG-768). It is appended here rather than to `MediaTileMenu`'s list, which the library
    /// tiles share.
    var host: MediaViewerHostItem? = nil

    var body: some View {
        switch Self.shape(control, hosted: host != nil) {
        case .hidden:
            EmptyView()
        case .direct(let action):
            // Labelled with the action's own name, not "More": the glyph now says which action it
            // is, and VoiceOver has to say the same thing.
            Button {
                row(action).tapped()
            } label: {
                glyph(action.symbol)
            }
            .accessibilityLabel(action.title)
        case .menu(let actions):
            Menu {
                ForEach(actions) { action in
                    row(action)
                }
                if let host { host }
            } label: {
                glyph("ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    /// The shape drawn: the shared rule's, unless the host handed in a row — then always the menu,
    /// because that row makes two or more. A `.menu` here may hold one shared action or none; the
    /// host's row is the rest of it. Without a host the shared rule stands untouched, so the
    /// one-action button of MEMNG-213 is what every other viewer still draws.
    static func shape(_ control: MediaActionControl, hosted: Bool) -> MediaActionControl {
        guard hosted else { return control }
        switch control {
        case .hidden: return .menu([])
        case .direct(let action): return .menu([action])
        case .menu: return control
        }
    }

    /// The row, whichever shape it ends up drawn in — a menu item, or the button itself.
    private func row(_ action: MediaTileAction) -> MediaTileActionItem {
        MediaTileActionItem(action: action, showMemo: showMemo, fetch: fetch)
    }

    /// The overlay's one glyph, so the direct button and the menu are the same target in the same
    /// corner of the same picture.
    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: MediaViewerBar.circleSide, height: MediaViewerBar.circleSide)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// One row of the actions menu, on the tile and in the viewer alike.
///
/// A view of its own because the two surfaces must offer the same thing built the same way: a
/// second copy written inline in a second body is how "Share" ends up sharing a different URL in
/// one of them.
struct MediaTileActionItem: View {
    let action: MediaTileAction
    let showMemo: (String) -> Void
    /// What the two slow ones do: fetch the named file and offer it. Defaulted so a surface that
    /// cannot download — a preview, a fitting test — still builds the row rather than being handed
    /// a different menu.
    var fetch: (MemoAttachment, AttachmentRendition) -> Void = { _, _ in }

    /// Everything a tap on this row does — the button's whole action, and the only thing it does.
    ///
    /// It is a method rather than three closures written into three branches of `body`, and the
    /// reason is that a `Button`'s action is unreachable from a test: SwiftUI hands out no way to
    /// invoke one, and the probe this bundle has reads accessibility LABELS, which are identical
    /// whatever the control turns out to be. Written inline, the one thing that decides whether a
    /// recipient is handed a file or a link — which rendition each row asks for — was asserted by
    /// nothing at all, and the row could go back to being a share-link control over `webURL` with
    /// every test still green (MEMNG-207, review round 1).
    func tapped() {
        switch action {
        case .showMemo(let uid): showMemo(uid)
        // Neither of these is SwiftUI's built-in share-link control, and it is the same reason for
        // both: that control hands over a value it is already holding, and neither of these files
        // is on the phone until somebody has waited for it. It is what the Share row used to be,
        // which is exactly how the value it was holding came to be a URL.
        case .share(let attachment): fetch(attachment, .shared)
        case .saveOriginal(let attachment): fetch(attachment, .original)
        }
    }

    /// One button, whatever the row is. There is no per-case branch here on purpose: a branch is
    /// where a row that hands over a URL grew last time, and where the next one would.
    var body: some View {
        Button {
            tapped()
        } label: {
            Label(action.title, systemImage: action.symbol)
        }
    }
}

/// An action a screen adds to the viewers it presents, on the page on screen (MEMNG-720).
///
/// The viewer draws it and calls it; what it means is the host's. A trip's screen is the one host
/// that hands one in ("Use as Cover"); every other presenter passes nil, so the control does not
/// exist there rather than existing and doing nothing.
struct MediaViewerHostAction {
    let title: String
    let symbol: String
    let perform: @MainActor (MemoAttachment) -> Void
}

/// The host's action as the viewer's menu row, over the page that was on screen (MEMNG-768).
///
/// Its own view with its own `tapped()` for the reason `MediaTileActionItem` has one: a menu row's
/// action is unreachable from a test, and a menu cannot be opened in one at all.
struct MediaViewerHostItem: View {
    let action: MediaViewerHostAction
    let attachment: MemoAttachment
    /// Closes the viewer: what the action changed is the screen underneath's to show (a trip's
    /// hero, its card).
    let done: () -> Void

    func tapped() {
        action.perform(attachment)
        done()
    }

    var body: some View {
        Button {
            tapped()
        } label: {
            Label(action.title, systemImage: action.symbol)
        }
    }
}

/// The deliberate way out of a full-screen black surface.
///
/// Its own view so its size can be asserted: the drag that dismisses is a gesture nobody is told
/// about, so the button beside it has to stay a real target — at least the 44 points the HIG asks
/// for, at every text size.
struct MediaViewerCloseButton: View {
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: MediaViewerBar.circleSide, height: MediaViewerBar.circleSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Close")
    }
}

/// One page of the viewer, full screen: a zoomable picture, or a video.
///
/// Every proposal a gesture makes goes through `MediaZoom` before it reaches the screen, so the
/// limits are the ones a test asserts rather than whatever the gesture happened to report. The
/// blurhash is underneath from the first frame — the 2048 px rendition is a real download, and
/// the picture's own colours in the picture's own frame is what fills that second.
///
/// Zooming is a PICTURE's gesture. A video page shows its poster until it has a player and the
/// player after that, and neither is pinched: a magnified video frame is nothing anybody asked
/// for, and a pinch that has to be arbitrated against the transport controls underneath it is a
/// swipe that stops working.
struct MediaViewerPage: View {
    let page: MediaPage
    /// What this page denies the surfaces around it while it is being pinched or is magnified —
    /// the pager above it and the presentation's interactive dismissal (`MediaZoom.holds`).
    let onHoldsChange: (MediaZoom.Holds) -> Void
    /// The viewer's one player, handed over only while it belongs to THIS page. `nil` on every
    /// other page — including a video page that has not been asked to play — and the reason a
    /// page cannot create, duplicate or outlive a player.
    let player: AVPlayer?
    /// Ask the viewer for this page's video.
    let play: () -> Void
    /// One tap on the page: what shows and hides the viewer's chrome. Declared after the double
    /// tap on a picture, so a double tap zooms and never toggles; a drag is neither.
    var onTap: () -> Void = {}
    /// The cache the lapsed-signature eviction below names.
    ///
    /// Injectable for one reason, and it is a testing one: the default is a process-wide
    /// singleton every other test in the bundle shares, so watching an eviction in it made the
    /// assertion depend on three things that have nothing to do with the rule — which cache the
    /// composition root won at launch, what else was touching the singleton in parallel, and
    /// whether the image load raced the task. A page handed its own cache can be watched
    /// directly. Production passes nothing and gets `MediaSession.shared.cache`, which is the
    /// cache the image fetches actually go through; evicting out of any other one is a no-op
    /// that reads like an eviction.
    var cache: URLCache = MediaSession.shared.cache
    /// What the still is fetched through, and the other half of the pair above: this session's
    /// `urlCache` IS `cache`, which is what makes the eviction mean something. Both defaults are
    /// asserted against each other by identity in `MediaViewerLoadingTests` — the fetch and the
    /// eviction have to name ONE `URLCache` object, and stating it twice is not the same as
    /// proving it. Injectable for the same reason the cache is: a page handed a scripted
    /// transport can be watched fetching, which is how "the still goes through here" is a test
    /// rather than a comment.
    var transport: any MediaTransport = MediaSession.shared

    @State private var transform = MediaZoom.Transform.identity
    /// The pinch under the fingers right now, or none. It carries where the pinch STARTED as well
    /// as how far it has come, because the point the fingers landed on is the point that has to
    /// stay still, and the gesture reports that point in the space it is attached to — the
    /// viewport-sized frame below.
    @GestureState private var pinch: MediaZoom.Pinch?
    @GestureState private var pan: CGSize = .zero
    /// This page's own load — the same value a timeline tile holds, and for the same reasons:
    /// `NSCache` may drop an entry under a view that is still on screen, a page that has been
    /// swiped on must not wear the previous picture's failure, and a picture nobody answered about
    /// is worth asking for again.
    @State private var picture = PictureLoad()
    /// Who mints a fresh URL for this page's still when the server says its signature expired.
    @Environment(\.signedURLRefresher) private var refresher

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size

            ZStack {
                switch page.kind {
                case .image:
                    picture(in: viewport)
                case .video:
                    video(in: viewport)
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            // A rotation or a size-class change re-fits the picture under a transform that was
            // clamped against the OLD geometry. Only the drawn offset is corrected below; the
            // stored one has to be brought across too, or the next pan spends itself absorbing
            // the stale delta before the picture moves.
            .onChange(of: viewport, initial: false) { _, changed in
                transform = MediaZoom.renormalized(
                    transform,
                    fitted: MediaZoom.fittedSize(aspectRatio: page.aspectRatio, in: changed),
                    viewport: changed
                )
            }
        }
        // Reported from the LIVE state, not the committed one: a hold that only began at a
        // gesture's end would arrive after the page it was meant to hold had already turned.
        .onChange(of: MediaZoom.holds(transform, pinch: pinch), initial: false) { _, holds in
            onHoldsChange(holds)
        }
    }

    @ViewBuilder
    private func picture(in viewport: CGSize) -> some View {
        let fitted = MediaZoom.fittedSize(aspectRatio: page.aspectRatio, in: viewport)
        // Both gestures and the committed transform meet in ONE function, so what is drawn while
        // fingers are down is the same arithmetic the commits are tested against; the view adds
        // nothing of its own to its answer.
        let drawn = MediaZoom.live(
            transform,
            pinch: pinch,
            pannedBy: pan,
            fitted: fitted,
            viewport: viewport
        )

        still
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(CGFloat(drawn.scale))
            .offset(drawn.offset)
            .frame(width: viewport.width, height: viewport.height)
            .contentShape(.rect)
            // The pan is only live while there is something to pan: at rest it would
            // swallow the sideways drag that turns the page.
            .gesture(
                panGesture(fitted: fitted, viewport: viewport),
                including: transform.isZoomed ? .all : .none
            )
            // Attached OUTSIDE the pan and simultaneously, so pinching still works while a
            // magnified picture is being moved.
            .simultaneousGesture(magnifyGesture(fitted: fitted, viewport: viewport))
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { transform = MediaZoom.doubleTapped(transform) }
            }
            .onTapGesture(count: 1) { onTap() }
    }

    /// A video page: the player when this page holds it, its poster and a play button before that.
    ///
    /// The poster is drawn at the video's own proportions, exactly like a picture, so the page
    /// does not change shape at the moment playback starts.
    @ViewBuilder
    private func video(in viewport: CGSize) -> some View {
        if let player {
            // `.contain`, never a collapsing `accessibilityElement()`: AVKit vends its own play,
            // pause and scrubber, and collapsing the player into one labelled element would take
            // every one of them out of the tree — while no label at all left the page nameless to
            // VoiceOver the moment playback started. A labelled CONTAINER keeps both.
            VideoPlayerLayer(player: player)
                .frame(width: viewport.width, height: viewport.height)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(page.accessibilityLabel)
                .contentShape(.rect)
                .onTapGesture { onTap() }
        } else {
            let fitted = MediaZoom.fittedSize(aspectRatio: page.aspectRatio, in: viewport)
            ZStack {
                still
                    .frame(width: fitted.width, height: fitted.height)
                    .frame(width: viewport.width, height: viewport.height)
                playControl
            }
            .contentShape(.rect)
            .onTapGesture { onTap() }
        }
    }

    /// The picture, over its own colours.
    ///
    /// It goes through `MediaImageLoader` — the same loader, store and key a timeline tile uses —
    /// and through the transport THIS page holds, whose cache is the one `loadStill` evicts from.
    /// `AsyncImage` stood here before, and it fetches through `URLSession.shared`: a session
    /// whose cache the app cannot guarantee it won the race to install, so the eviction beside it
    /// was reaching into a cache the fetches never consulted, and a signed URL that had lapsed
    /// could be re-served out of the one they did.
    ///
    /// The task hangs off the stack rather than off the picture: the picture is a conditional
    /// that starts out as nothing at all, and a load that only runs once something is already
    /// drawn never runs.
    private var still: some View {
        ZStack {
            BlurHashBackdrop(blurhash: page.blurhash)
            if page.stillURL != nil {
                stillPicture
            }
        }
        .task(id: PictureTrigger(url: page.stillURL, attempt: picture.attempt)) {
            await loadStill()
        }
        // The same read a tile takes of the same signal: a still nobody answered about is asked
        // for again, and one already on screen is left alone.
        .onChange(of: MediaRetrySignal.shared.publications) { _, _ in
            picture.askAgain(showing: painted != nil)
        }
        .accessibilityElement()
        .accessibilityLabel(page.accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    /// What is painted over the blurhash: the decoded picture, the failure glyph, or — while it
    /// is still coming — nothing, because the blurhash IS the loading state and a spinner over it
    /// would only hide it.
    @ViewBuilder
    private var stillPicture: some View {
        if let painted {
            AspectPinnedLayer { Image(uiImage: painted).resizable().scaledToFit() }
        } else if picture.failedKey == page.stillKey {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
    }

    /// Read synchronously in `body`, exactly as a tile does: a picture already decoded is painted
    /// in the frame the page appears in, without passing through the blurhash first.
    private var painted: UIImage? {
        AttachmentThumbnail.painted(
            captured: picture.captured,
            for: page.stillKey,
            cached: MediaImageLoader.cachedUIImage(for: page.stillKey)
        )
    }

    /// The full-screen rendition: dropped from both caches if its signature has lapsed, then
    /// fetched once and decoded once through the page's own transport.
    private func loadStill() async {
        // Claimed before anything is awaited and released however this leaves — see the tile's
        // load for what the claim is for.
        let serial = picture.claim()
        defer { picture.release(serial) }
        guard let url = page.stillURL else { return }
        // Captured before the await: the pager can hand this view a different page while the
        // fetch is in flight, and the answer belongs to the key it was asked for.
        let requested = page.stillKey
        // The signature can lapse while a cached copy is still on disk; re-serving it would hide
        // the moment it stopped verifying (SignedMediaURL / LSN-0062). This drops it out of the
        // cache the fetch below actually reads, which is the whole point of `transport` and
        // `cache` being one pair — and out of the decoded store, which `stillPicture` reads
        // synchronously and would otherwise paint from in the very next frame.
        MediaImageLoader.evictLapsedSignature(url: url, key: requested, cache: cache)
        // Already decoded — `body` has painted it in this very frame. Taken into this view's own
        // state anyway: that is what keeps it painted if the cache is emptied under a page that
        // stays on screen.
        if let hit = MediaImageLoader.cachedUIImage(for: requested) {
            picture.painted(hit, for: requested)
            return
        }

        let generation = MediaImageLoader.store.generation
        let answer = await MediaImageLoader.answer(
            for: requested,
            url: url,
            transport: transport,
            refresher: refresher
        )
        // The same fence the loader applies to its cache, applied to the screen: an answer about
        // the account that was signed in when this started must not be painted for the one signed
        // in now — not even as a failure.
        guard generation == MediaImageLoader.store.generation else { return }
        // The same read a tile takes of the same handoff: a signal that arrived while this fetch
        // was out is answered by how the fetch ended.
        if picture.settle(answer, for: requested, serial: serial).asksAgain {
            picture.askAgain(showing: painted != nil)
        }
    }

    /// A real control rather than a tap on the poster, so it is reachable with VoiceOver.
    ///
    /// It is what a video page reached by SWIPING waits for. Nothing starts playing because
    /// somebody swiped past it — only the video that was TAPPED, back on the memo, is already
    /// running when the viewer opens.
    @ViewBuilder
    private var playControl: some View {
        if page.playbackURL != nil {
            Button(action: play) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 8)
            }
            .accessibilityLabel("Play video")
        }
    }

    private func magnifyGesture(fitted: CGSize, viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = MediaZoom.Pinch(
                    magnification: Double(value.magnification),
                    anchor: value.startLocation
                )
            }
            .onEnded { value in
                transform = MediaZoom.settled(
                    transform,
                    magnifiedBy: Double(value.magnification),
                    anchoredAt: value.startLocation,
                    fitted: fitted,
                    viewport: viewport
                )
            }
    }

    private func panGesture(fitted: CGSize, viewport: CGSize) -> some Gesture {
        DragGesture()
            .updating($pan) { value, state, _ in
                state = value.translation
            }
            // A pinch may still be under the fingers when the drag ends, and its arithmetic
            // multiplies whatever this stores — which is why the pinch goes in with the
            // translation rather than being ignored here.
            .onEnded { value in
                transform = MediaZoom.panned(
                    transform,
                    by: value.translation,
                    underPinch: pinch,
                    fitted: fitted,
                    viewport: viewport
                )
            }
    }
}

extension View {
    /// The tile a full-screen picture grows out of, when the surface has a namespace to match in.
    ///
    /// Optional because a card can be rendered without one — a preview, a fitting test — and a
    /// missing namespace must be a missing animation, not a missing photo.
    @ViewBuilder
    func mediaTransitionSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// The presentation half of the same transition.
    @ViewBuilder
    func mediaZoomTransition(sourceID: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}
