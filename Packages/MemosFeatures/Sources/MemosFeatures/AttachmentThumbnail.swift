import MemosCore
import SwiftUI
import UIKit

/// Which of the four things a tile can be showing. Named separately from the loader so a stalled
/// load can be rendered and asserted without a network.
///
/// `waiting` is the one that was missing, and its absence is what put a row of "!" marks on the
/// first real post: the server derives an attachment's tiers AFTER the memo exists, the tile asked
/// for a picture that was not there yet, the fetch came back with nothing, and a perfectly good
/// photo wore the glyph that means "this file is broken". Waiting and failed are different facts
/// and they now look different.
public enum ThumbnailPhase: Equatable, Sendable {
    case loading
    case loaded
    /// The server has not produced this rendition yet. Nothing is wrong; something is coming.
    case waiting
    case failed
}

/// What a tile does while it waits, and the one thing that changes it.
public enum WaitingTreatment {
    public enum Motion: Equatable, Sendable {
        /// A sheen travelling across the tile.
        case shimmer
        /// The same veil, standing still.
        case still
    }

    /// Reduce Motion means STILL, not "slower": the setting is a request for no movement, and a
    /// gentler animation is still an animation. The waiting is still legible — the veil stays,
    /// it just stops travelling.
    public static func motion(reduceMotion: Bool) -> Motion {
        reduceMotion ? .still : .shimmer
    }
}

/// One attachment in the timeline.
///
/// The photo comes from `MediaImageLoader`, which is the whole point of this view's shape. A
/// `List` builds a fresh `AttachmentThumbnail` every time a row scrolls back, so the tile is asked
/// for its picture again and again — and with `AsyncImage` each of those started at "no image" and
/// flashed the blurhash before the photo reappeared, when it did not go back to the server for it.
/// Here
/// `MediaImageLoader.cached(for:)` is read in `body`, synchronously: a remounted row that has been
/// seen before paints the decoded photo in the very frame it appears in, and never enters
/// `.loading` at all.
///
/// A tile that has NOT been seen keeps the old sequence exactly: blurhash first, photo when it
/// lands. Underneath every tile, always, is the attachment's own BlurHash — the picture's colours,
/// in the picture's shape, not a spinner and not a grey box that reflows the timeline.
///
/// The signature is still enforced here: an entry whose signed URL has lapsed can only be stale,
/// so it is dropped before the fetch — the response bytes and the decoded picture together
/// (`MediaImageLoader.evictLapsedSignature`).
struct AttachmentThumbnail: View {
    let attachment: MemoAttachment
    var tier: MediaTier = .thumb
    /// The shape of the slot and how much of the picture goes in it. The container takes this
    /// shape immediately, from the server's own measurements, so the layout does not jump when
    /// the image lands — and the blurhash underneath gets that identical frame.
    var slot: AttachmentSlot
    /// The corner the tile is cut to. The grid's radius everywhere but the Months mosaic, whose
    /// tiles sit two points apart and take a smaller one (plan decision 9) — which only this clip
    /// can give them, because a wider inner cut is not undone by a narrower one outside it.
    var cornerRadius: CGFloat = DesignTokens.Radius.tile

    /// This tile's own load: what it captured, what it gave up on, and the request it has out.
    @State private var picture = PictureLoad()
    /// Who mints a fresh URL for this picture when the server says its signature expired.
    @Environment(\.signedURLRefresher) private var refresher

    private var url: URL? { MemoPresentation.url(for: attachment, tier: tier) }
    private var key: MediaImageKey { MediaImageLoader.key(for: attachment, tier: tier) }

    /// What a tile paints, given what this instance captured and what the loader still holds.
    ///
    /// The capture has to win, and not merely as an optimisation. `NSCache` may drop an entry at
    /// any moment — a memory warning does not ask which rows are on screen — and a row that is
    /// still mounted gets no second `.task`, because its `id` has not changed. Reading the cache
    /// alone, such a row would fall back to its blurhash and stay there for as long as it lived.
    ///
    /// Pure and static so it can be asserted directly rather than through a hosted view.
    static func painted(
        captured: (key: MediaImageKey, image: UIImage)?,
        for key: MediaImageKey,
        cached: UIImage?
    ) -> UIImage? {
        if let captured, captured.key == key { return captured.image }
        return cached
    }

    /// Read in `body`, and synchronous on both paths. The cache lookup is what makes a scroll-back
    /// free; the capture is what keeps it painted afterwards.
    private var image: Image? {
        Self.painted(
            captured: picture.captured,
            for: key,
            cached: MediaImageLoader.cachedUIImage(for: key)
        )
        .map(Image.init(uiImage:))
    }

    private var phase: ThumbnailPhase {
        Self.phase(
            readiness: attachment.readiness,
            hasImage: image != nil,
            hasURL: url != nil,
            loadFailed: picture.failedKey == key
        )
    }

    /// The three-way projection, as a function of what the SERVER said and what this instance
    /// managed to load. Pure, so each of the three can be asserted distinctly instead of being
    /// inferred from a rendered tile.
    ///
    /// The server's word comes first, and only `failed` produces the failure glyph. An attachment
    /// the server is still working on waits — even though its derived-tier URL is already in the
    /// payload and a fetch for it would 404, which is precisely the trap the old two-way version
    /// fell into. A picture that somehow arrived anyway is shown rather than covered up.
    ///
    /// A `ready` attachment whose fetch comes back with nothing is still a failure: the tiers are
    /// supposed to exist, so something IS wrong with this one.
    static func phase(
        readiness: AttachmentReadiness,
        hasImage: Bool,
        hasURL: Bool,
        loadFailed: Bool
    ) -> ThumbnailPhase {
        switch readiness {
        case .failed:
            return .failed
        case .waiting:
            return hasImage ? .loaded : .waiting
        case .ready:
            if hasImage { return .loaded }
            if !hasURL || loadFailed { return .failed }
            return .loading
        }
    }

    var body: some View {
        Color.clear
            .aspectRatio(slot.aspectRatio, contentMode: .fit)
            .overlay {
                ThumbnailContent(
                    attachment: attachment,
                    phase: phase,
                    image: image,
                    contentMode: slot.contentMode
                )
            }
            .task(
                id: PictureTrigger(
                    url: url,
                    readiness: attachment.readiness,
                    attempt: picture.attempt
                )
            ) { await load() }
            // Something happened that could change the answer. Whether it changes anything for
            // THIS tile is the tile's own to say, and it is the only one that can: the list it
            // sits in has no idea which of its pictures arrived.
            .onChange(of: MediaRetrySignal.shared.publications) { _, _ in
                picture.askAgain(showing: image != nil)
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private func load() async {
        // Claimed before anything is awaited and released however this leaves, so a signal that
        // arrives while this fetch is out is refused rather than answered with a second request —
        // and a load that returns without fetching anything leaves nothing claimed behind it.
        let serial = picture.claim()
        defer { picture.release(serial) }
        // Nothing to fetch while the server is still deriving it, and nothing to fetch for a file
        // it gave up on. Asking anyway is what turned a pending photo into a failure glyph.
        guard attachment.readiness == .ready, let url else { return }
        // Captured before the await: the view can be handed a different attachment while the
        // fetch is in flight, and the answer belongs to the key it was asked for.
        let requested = key
        // A lapsed signature is dropped from BOTH layers — the response bytes and the decoded
        // picture — because either one alone would paint a frame the URL can no longer authorise.
        MediaImageLoader.evictLapsedSignature(url: url, key: requested)
        // Already decoded — `body` has painted it in this very frame, and there is nothing to
        // fetch. It is still taken INTO this view's own state: the frame is already right, and
        // this is what keeps it right if the cache is emptied under a row that stays mounted.
        if let hit = MediaImageLoader.cachedUIImage(for: requested) {
            picture.painted(hit, for: requested)
            return
        }

        let generation = MediaImageLoader.store.generation
        let answer = await MediaImageLoader.answer(for: requested, url: url, refresher: refresher)
        // The same fence the loader applies to its cache, applied to the screen: an answer about
        // the account that was signed in when this started must not be painted for the one signed
        // in now. Nothing is assigned at all — not even a failure, which would put a warning
        // triangle on a tile whose memo is already being replaced.
        guard generation == MediaImageLoader.store.generation else { return }
        // A signal that arrived while this fetch was out is answered by how the fetch ENDED, not
        // by the moment it arrived in: what was refused then is asked for now, once, by the load
        // that held the claim.
        if picture.settle(answer, for: requested, serial: serial).asksAgain {
            picture.askAgain(showing: image != nil)
        }
    }
}

/// A layer pinned to the slot it was given, however it draws inside it.
///
/// `scaledToFill` reports the oversized dimensions it drew, not the space it was offered: a 4:3
/// image asked to fill a 120x160 slot answers 213x160. Two such layers in one `ZStack` therefore
/// grow the stack to the larger of them and centre each inside it — so a blurhash (always 4:3
/// from a 32x24 decode) and a photo of some other shape ended up centred in different boxes, and
/// the blur sat visibly beside the picture it was supposed to be under.
///
/// `Color.clear` accepts whatever it is offered and reports exactly that, so putting the filled
/// content in its overlay keeps the reported size equal to the slot. Every layer of a tile goes
/// through here, which is what pins them all to one frame.
struct AspectPinnedLayer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Color.clear
            .overlay { content }
            .clipped()
    }
}

/// The tile itself, with the load phase handed IN rather than fetched — so what a stalled load
/// looks like can be rendered and asserted without a network.
struct ThumbnailContent: View {
    let attachment: MemoAttachment
    let phase: ThumbnailPhase
    let image: Image?
    /// `fill` crops to the slot, `fit` shows the whole picture inside it. The BACKDROP always
    /// fills whichever way this goes: when a fitted picture does not reach the edges, the blur is
    /// what should be behind it, not a grey bar.
    var contentMode: TileContentMode = .fill

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BlurHashBackdrop(blurhash: attachment.blurhash)
            if phase == .loaded, let image {
                AspectPinnedLayer {
                    if contentMode == .fit {
                        image.resizable().scaledToFit()
                    } else {
                        image.resizable().scaledToFill()
                    }
                }
            }
            // The ONLY place the failure glyph is drawn, and only for an attachment the server
            // actually failed on.
            if phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            // A video whose poster has not been derived yet has nothing to play, so it does not
            // offer to.
            if attachment.isVideo && phase != .failed && phase != .waiting {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
            }
        }
        // An overlay rather than another layer of the stack: a veil must never be able to change
        // the size of the tile it is a veil over.
        .overlay {
            if phase == .waiting {
                WaitingVeil(motion: WaitingTreatment.motion(reduceMotion: reduceMotion))
            }
        }
        .clipped()
    }
}

/// The veil over a tile whose picture the server has not finished making.
///
/// A sheen that travels rather than a spinner: the tile already has the picture's own colours under
/// it (the blurhash), and a spinner on top of that says "loading" where the truth is "being made".
/// The plain fill `BlurHashBackdrop` falls back to is what it covers when there is no hash.
///
/// It never draws the failure glyph, which is the whole point of it existing.
struct WaitingVeil: View {
    let motion: WaitingTreatment.Motion

    @State private var travelling = false

    var body: some View {
        Group {
            switch motion {
            case .still:
                // Reduce Motion: the same brightening, standing still. Something is clearly
                // happening to this tile; nothing on it moves.
                Rectangle().fill(.white.opacity(0.14))
            case .shimmer:
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let band = max(width * 0.5, 32)
                    LinearGradient(
                        colors: [
                            .white.opacity(0), .white.opacity(0.32), .white.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: band)
                    .offset(x: travelling ? width : -band)
                    .animation(
                        .linear(duration: 1.4).repeatForever(autoreverses: false),
                        value: travelling
                    )
                }
                .onAppear { travelling = true }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
