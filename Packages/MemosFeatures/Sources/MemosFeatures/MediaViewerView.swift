import MemosCore
import SwiftUI

/// A memo's pictures, full screen: pinch to zoom, drag to move, double tap to go in and out,
/// swipe sideways for the next one, and back down into the tile it came from.
///
/// It is presented as a full-screen cover with the platform ZOOM transition, so the picture grows
/// out of the tile that was tapped and shrinks back into it — including when the shrink is a drag
/// the system is following in real time. That is also why there is no hand-written
/// swipe-to-dismiss gesture here: the transition owns that interaction, and a second recogniser
/// translating the same content would fight it. The close button is the deliberate,
/// always-available way out, and the escape action gives VoiceOver the same door.
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
    @State private var playing: VideoPlayback?

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
        .fullScreenCover(item: $playing) { playback in
            VideoPlayerView(playback: playback)
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
                        play: { url in playing = VideoPlayback(url: url) }
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

/// One picture, full screen and zoomable.
///
/// Every proposal a gesture makes goes through `MediaZoom` before it reaches the screen, so the
/// limits are the ones a test asserts rather than whatever the gesture happened to report. The
/// blurhash is underneath from the first frame — the 2048 px rendition is a real download, and
/// the picture's own colours in the picture's own frame is what fills that second.
struct MediaViewerPage: View {
    let page: MediaPage
    let onZoomChange: (Bool) -> Void
    let play: (URL) -> Void

    @State private var transform = MediaZoom.Transform.identity
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var pan: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
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

            ZStack {
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
                    .onTapGesture {
                        if let url = page.playbackURL { play(url) }
                    }
                playControl
            }
            .frame(width: viewport.width, height: viewport.height)
            // A rotation or a size-class change re-fits the picture under a transform that was
            // clamped against the OLD geometry. Only the drawn offset is corrected above; the
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

    private var still: some View {
        ZStack {
            BlurHashBackdrop(blurhash: page.blurhash)
            if let url = page.stillURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        AspectPinnedLayer { image.resizable().scaledToFit() }
                    case .failure:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    default:
                        // The blurhash IS the loading state. A spinner over it would only hide it.
                        // `default` rather than `.empty`: a phase this SwiftUI has not shipped yet
                        // must read as still loading, never as a warning triangle.
                        EmptyView()
                    }
                }
                .task(id: url) {
                    // The signature can lapse while a cached copy is still on disk; re-serving it
                    // would hide the moment it stopped verifying (SignedMediaURL / LSN-0062).
                    MediaCache.evictExpired(url)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(page.accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    /// A real control rather than a tap on the picture, so it is reachable with VoiceOver — and a
    /// sibling of the zoomable layer rather than a child of it, so the gestures underneath cannot
    /// swallow it.
    @ViewBuilder
    private var playControl: some View {
        if page.kind == .video, let url = page.playbackURL {
            Button {
                play(url)
            } label: {
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
