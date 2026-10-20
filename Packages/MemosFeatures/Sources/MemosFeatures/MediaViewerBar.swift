import MemosCore
import SwiftUI

/// The opened-picture viewer's bottom bar: Share on the left, the heart and Info in one capsule
/// in the middle, the bin on the right.
///
/// An overlay at the bottom of the viewer, never a safe-area bar: it floats over the picture and
/// takes no room from it. The bin follows today's rule exactly — the viewer was opened deletable
/// and was handed a delete — and when it is absent its slot stays, so the capsule keeps the
/// middle. The heart is the picture's favorite as `FavoriteStore` reports it
/// (`FavoriteHeartPresentation`); with no store to write through it is drawn dimmed and inert.
struct MediaViewerBar: View {
    enum Slot: Equatable {
        case share
        case capsule
        case bin
    }

    let attachment: MemoAttachment
    let binShown: Bool
    var share: () -> Void = {}
    var info: () -> Void = {}
    var delete: () -> Void = {}
    /// The session's favorites, the session they are written under, and where a tap on somebody
    /// else's picture says why it wrote nothing. No store: the heart is drawn and does nothing.
    var favorites: FavoriteStore? = nil
    var handle: SessionHandle? = nil
    var baseURL: URL? = nil
    var notice: (String) -> Void = { _ in }

    static let circleSide: CGFloat = 48
    static let capsuleHeight: CGFloat = 48
    static let itemWidth: CGFloat = 52
    static let gap: CGFloat = 12
    static let sideInset: CGFloat = 20
    static let heartOpacity: Double = 0.4

    /// Today's rule for the bin, unchanged: the viewer was opened deletable AND handed a delete.
    static func binShown(deletable: Bool, canDelete: Bool) -> Bool { deletable && canDelete }

    /// The slots drawn, left to right.
    static func slots(binShown: Bool) -> [Slot] {
        binShown ? [.share, .capsule, .bin] : [.share, .capsule]
    }

    var body: some View {
        GlassEffectContainer(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                // Each side is a row that always exists, so the two take equal shares of the width
                // whether or not the bin is drawn: an empty `if` is no view, and a frame around no
                // view takes no room.
                HStack(spacing: 0) {
                    shareButton
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                capsule
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if binShown { binButton }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Self.sideInset)
        .padding(.bottom, DesignTokens.Space.snug)
    }

    private var shareButton: some View {
        Button(action: share) {
            glyph("square.and.arrow.up")
                .frame(width: Self.circleSide, height: Self.circleSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!MediaTileMenu.canShare(attachment))
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Share")
    }

    /// What the heart shows for `attachment`: its owner's flag, its own tags as the store reports
    /// them (a write in flight or a committed one outranks the copy the page carries), and
    /// whether a write to it has an unknown outcome.
    static func heart(for attachment: MemoAttachment, in favorites: FavoriteStore)
        -> FavoriteHeartPresentation
    {
        FavoriteHeartPresentation(
            mine: attachment.mine == true,
            tags: favorites.tags(for: attachment.uid, shown: attachment.tags),
            pending: favorites.isPending(attachment.uid))
    }

    /// What a tap on the heart does: writes the state it asks for, or says why it wrote nothing.
    /// The store decides whether a write goes on the wire (join, follow-up or no-op), so a second
    /// tap while the first is in the air is the store's question, never this button's.
    @discardableResult
    static func tapHeart(
        _ attachment: MemoAttachment,
        favorites: FavoriteStore,
        handle: SessionHandle?,
        baseURL: URL?,
        notice: (String) -> Void
    ) -> Task<Void, Never>? {
        let heart = heart(for: attachment, in: favorites)
        if let sentence = heart.notice {
            notice(sentence)
            return nil
        }
        guard let target = heart.target, let handle, let baseURL else { return nil }
        return favorites.setFavorite(
            uid: attachment.uid, to: target, shownTags: attachment.tags, using: handle,
            baseURL: baseURL)
    }

    @ViewBuilder
    private var heartButton: some View {
        if let favorites {
            let heart = Self.heart(for: attachment, in: favorites)
            Button {
                Self.tapHeart(
                    attachment, favorites: favorites, handle: handle, baseURL: baseURL,
                    notice: notice)
            } label: {
                glyph(heart.symbolName)
                    .opacity(heart.isDimmed ? Self.heartOpacity : 1)
                    .overlay {
                        if heart.showsProgress { ProgressView().tint(.white) }
                    }
                    .frame(width: Self.itemWidth, height: Self.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Favorite")
            .accessibilityValue(Self.heartValue(heart))
            .accessibilityHint(heart.notice.map { Text($0) } ?? Text(verbatim: ""))
        } else {
            Button(action: {}) {
                glyph("heart")
                    .opacity(Self.heartOpacity)
                    .frame(width: Self.itemWidth, height: Self.capsuleHeight)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("Favorite")
        }
    }

    /// What VoiceOver reads after "Favorite": the state the glyph claims, or that it claims none.
    static func heartValue(_ heart: FavoriteHeartPresentation) -> String {
        switch heart.glyph {
        case .filled: "On"
        case .outline: "Off"
        case .pending: "Confirming"
        }
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            heartButton
            Button(action: info) {
                glyph("info.circle")
                    .frame(width: Self.itemWidth, height: Self.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Info")
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var binButton: some View {
        Button(action: delete) {
            glyph("trash")
                .frame(width: Self.circleSide, height: Self.circleSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(AttachmentDeleteFlow.title(for: attachment))
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.white)
    }
}
