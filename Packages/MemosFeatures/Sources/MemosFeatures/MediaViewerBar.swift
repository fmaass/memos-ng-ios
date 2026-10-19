import MemosCore
import SwiftUI

/// The opened-picture viewer's bottom bar: Share on the left, the heart and Info in one capsule
/// in the middle, the bin on the right.
///
/// An overlay at the bottom of the viewer, never a safe-area bar: it floats over the picture and
/// takes no room from it. The bin follows today's rule exactly — the viewer was opened deletable
/// and was handed a delete — and when it is absent its slot stays, so the capsule keeps the
/// middle. The heart is drawn and does nothing yet (Favorites and Info 1/4), dimmed so it does not
/// read as a control that is broken.
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
                shareButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                capsule
                Group {
                    if binShown { binButton }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
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

    private var capsule: some View {
        HStack(spacing: 0) {
            Button(action: {}) {
                glyph("heart")
                    .opacity(Self.heartOpacity)
                    .frame(width: Self.itemWidth, height: Self.capsuleHeight)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("Favorite")
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
