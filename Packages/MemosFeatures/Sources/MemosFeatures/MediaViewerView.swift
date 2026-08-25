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
/// A video is a PAGE of this pager, on the same swipe as the photo beside it. It used to be a
/// second `fullScreenCover` presented OVER the pager, which meant that in a memo with several
/// attachments the first video anybody played was where the swiping stopped: the pager was still
/// down there, under a cover nothing could reach. There is one player and it lives here, because
/// the rule that keeps it to one — built for the page that becomes current, torn down when that
/// page is dismissed or two swipes away — is a rule about the pager, not about a page
/// (`MediaViewerPlayback`).
struct MediaViewerView: View {
    let selection: MediaViewerSelection

    @Environment(\.dismiss) private var dismiss
    /// The page the pager has settled on — the identity of the page, not an index, because a
    /// paging scroll view tracks identity.
    @State private var currentPage: String?
    /// Which page, if any, is magnified. Paging is off while one is: a sideways drag inside a
    /// zoomed picture is a pan, and a page that turns halfway through examining a photo is the
    /// single most annoying thing a viewer can do.
    @State private var zoomedPage: String?
    /// What the player SHOULD be. Decided by `MediaViewerPlayback` from what the pager did, never
    /// in a view body — see `advance(_:)`.
    @State private var playback: MediaViewerPlayback.Player?
    /// The player itself, and there is only ever this one.
    @State private var player: AVPlayer?

    init(selection: MediaViewerSelection) {
        self.selection = selection
        _currentPage = State(initialValue: selection.startPage.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            pager
            closeButton
        }
        .overlay(alignment: .top) { counter }
        .statusBarHidden()
        // Two-finger scrub, the system-wide "get me out of here" — the same door as the button.
        .accessibilityAction(.escape) { dismiss() }
        // A tapped video is playing before the zoom transition has finished growing out of its
        // tile. A poster with a play button on it, waiting for a second tap, is what this
        // replaced.
        .onAppear { advance(.opened) }
        .onChange(of: currentPage) { _, settled in
            guard let settled else { return }
            advance(.paged(to: settled))
        }
        // The way out is not only the close button: the zoom transition dismisses on a drag, and
        // a video that went on playing behind a dismissed viewer would be a voice in an empty
        // room. Every exit lands here.
        .onDisappear { advance(.dismissed) }
    }

    /// One event in, one desired player out of `MediaViewerPlayback`, and the real `AVPlayer` made
    /// to match it.
    ///
    /// The teardown is the load-bearing half. A player that belongs to a different page than the
    /// one wanted is released rather than paused and kept, and its item is detached first so the
    /// stream stops being read at once — otherwise every clip visited in a long memo leaves an
    /// `AVPlayer` behind, each still holding a signed URL open.
    private func advance(_ event: MediaViewerPlayback.Event) {
        let next = MediaViewerPlayback.player(after: event, player: playback, in: selection)
        if playback?.page != next?.page {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        playback = next
        guard let next else { return }
        let live = player ?? AVPlayer(url: next.url)
        player = live
        if next.isPlaying {
            live.play()
        } else {
            live.pause()
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(selection.pages) { page in
                    MediaViewerPage(
                        page: page,
                        onZoomChange: { zoomed in
                            if zoomed {
                                zoomedPage = page.id
                            } else if zoomedPage == page.id {
                                zoomedPage = nil
                            }
                        },
                        // Handed to exactly one page: the one the single player belongs to. Every
                        // other page gets `nil` and draws its poster.
                        player: playback?.page == page.id ? player : nil,
                        play: { advance(.played(page: page.id)) }
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
        .scrollDisabled(zoomedPage != nil)
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        MediaViewerCloseButton { dismiss() }
    }

    /// Where in the memo this picture is. Hidden from VoiceOver because every page already says
    /// it — "Photo 2 of 5" — and hearing the same count twice is noise.
    @ViewBuilder
    private var counter: some View {
        let page = selection.pages.first { $0.id == currentPage }
        if selection.pages.count > 1, let page {
            Text("\(page.position) of \(page.total)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, DesignTokens.Space.snug)
                .padding(.vertical, DesignTokens.Space.hair)
                .background(.black.opacity(0.35), in: .capsule)
                .padding(.top, DesignTokens.Space.regular)
                .accessibilityHidden(true)
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
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.85))
                .padding()
        }
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
    let onZoomChange: (Bool) -> Void
    /// The viewer's one player, handed over only while it belongs to THIS page. `nil` on every
    /// other page — including a video page that has not been asked to play — and the reason a
    /// page cannot create, duplicate or outlive a player.
    let player: AVPlayer?
    /// Ask the viewer for this page's video.
    let play: () -> Void
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
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var pan: CGSize = .zero
    /// What THIS page loaded, tagged with the key it was loaded for — the same arrangement the
    /// timeline tiles use, and for the same reason: `NSCache` may drop an entry under a view that
    /// is still on screen, and a page reading only the cache would fall back to its blurhash and
    /// stay there.
    @State private var loaded: (key: MediaImageKey, image: UIImage)?
    /// The key whose load came back with nothing. Tagged too, so a page that has been swiped on
    /// does not wear the previous picture's failure.
    @State private var failedKey: MediaImageKey?

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
        .onChange(of: transform.isZoomed, initial: false) { _, zoomed in
            onZoomChange(zoomed)
        }
    }

    @ViewBuilder
    private func picture(in viewport: CGSize) -> some View {
        let fitted = MediaZoom.fittedSize(aspectRatio: page.aspectRatio, in: viewport)
        let scale = MediaZoom.clamped(scale: transform.scale * Double(magnification))
        let offset = MediaZoom.clampedOffset(
            CGSize(
                width: transform.offset.width + pan.width,
                height: transform.offset.height + pan.height
            ),
            scale: scale,
            fitted: fitted,
            viewport: viewport
        )

        still
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(CGFloat(scale))
            .offset(offset)
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
        } else {
            let fitted = MediaZoom.fittedSize(aspectRatio: page.aspectRatio, in: viewport)
            ZStack {
                still
                    .frame(width: fitted.width, height: fitted.height)
                    .frame(width: viewport.width, height: viewport.height)
                playControl
            }
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
        .task(id: page.stillURL) { await loadStill() }
        .accessibilityElement()
        .accessibilityLabel(page.accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    /// What is painted over the blurhash: the decoded picture, the failure glyph, or — while it
    /// is still coming — nothing, because the blurhash IS the loading state and a spinner over it
    /// would only hide it.
    @ViewBuilder
    private var stillPicture: some View {
        let key = page.stillKey
        // Read synchronously in `body`, exactly as a tile does: a picture already decoded is
        // painted in the frame the page appears in, without passing through the blurhash first.
        let painted = AttachmentThumbnail.painted(
            captured: loaded,
            for: key,
            cached: MediaImageLoader.cachedUIImage(for: key)
        )
        if let painted {
            AspectPinnedLayer { Image(uiImage: painted).resizable().scaledToFit() }
        } else if failedKey == key {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
    }

    /// The full-screen rendition: dropped from both caches if its signature has lapsed, then
    /// fetched once and decoded once through the page's own transport.
    private func loadStill() async {
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
            loaded = (requested, hit)
            if failedKey == requested { failedKey = nil }
            return
        }

        let generation = MediaImageLoader.store.generation
        let image = await MediaImageLoader.uiImage(for: requested, url: url, transport: transport)
        // The same fence the loader applies to its cache, applied to the screen: an answer about
        // the account that was signed in when this started must not be painted for the one signed
        // in now — not even as a failure.
        guard generation == MediaImageLoader.store.generation else { return }
        if let image {
            loaded = (requested, image)
            if failedKey == requested { failedKey = nil }
        } else {
            failedKey = requested
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
            .updating($magnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                transform = MediaZoom.settled(
                    transform,
                    magnifiedBy: Double(value.magnification),
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
            .onEnded { value in
                transform = MediaZoom.panned(
                    transform,
                    by: value.translation,
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
