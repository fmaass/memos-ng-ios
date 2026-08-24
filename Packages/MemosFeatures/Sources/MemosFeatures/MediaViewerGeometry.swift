import CoreGraphics
import Foundation

/// The arithmetic of a zoomable picture, with no view attached.
///
/// Pinch, pan and double-tap are three ways of proposing a transform; what makes them behave is
/// what happens to a proposal that is out of bounds. That is the part worth testing, so it lives
/// here: a gesture handler in a view body is where a clamp goes wrong silently — a picture that
/// can be flung off the screen and never comes back reads as a broken viewer, not as a rounding
/// error.
public enum MediaZoom {
    /// Fully zoomed out: the whole picture on screen.
    public static let minimumScale: Double = 1
    /// Far enough in to read the text on a sign, not so far that a 2048 px rendition is mush.
    public static let maximumScale: Double = 6
    /// Where a double tap lands from zoomed out. A single step, not a slow ride.
    public static let doubleTapScale: Double = 2.5

    /// A pinch may propose anything, including a negative number when two fingers cross. What
    /// reaches the transform never leaves the range.
    public static func clamped(scale: Double) -> Double {
        guard scale.isFinite else { return minimumScale }
        return min(max(scale, minimumScale), maximumScale)
    }

    /// Double tap toggles: out goes in, anything already in goes back out. Toggling rather than
    /// stepping is what makes a second double tap always an escape route.
    public static func scale(afterDoubleTapAt current: Double) -> Double {
        isZoomed(current) ? minimumScale : doubleTapScale
    }

    /// Zoomed at all, allowing for the float error a pinch leaves behind. Paging is disabled while
    /// this is true — a horizontal drag inside a magnified picture is a pan, not a page turn.
    public static func isZoomed(_ scale: Double) -> Bool {
        scale > minimumScale + 0.001
    }

    /// The picture's frame inside the screen it is shown on: the whole picture, centred, at its
    /// own proportions. Degenerate inputs (an unmeasured ratio, a zero viewport) get `.zero`
    /// rather than a NaN frame that lays out as nothing and takes the gestures with it.
    public static func fittedSize(aspectRatio: Double, in viewport: CGSize) -> CGSize {
        guard aspectRatio.isFinite, aspectRatio > 0,
            viewport.width > 0, viewport.height > 0
        else { return .zero }
        let viewportRatio = viewport.width / viewport.height
        if viewportRatio > aspectRatio {
            // Taller than the space is wide: the height is what runs out first.
            return CGSize(width: viewport.height * aspectRatio, height: viewport.height)
        }
        return CGSize(width: viewport.width, height: viewport.width / aspectRatio)
    }

    /// How far a magnified picture may be pushed before its edge would leave the screen.
    ///
    /// Zero on an axis the magnified picture does not overflow — which is why a zoomed-out picture
    /// cannot be dragged around at all, and a panorama zoomed in can be moved sideways but not up.
    public static func panLimit(scale: Double, fitted: CGSize, viewport: CGSize) -> CGSize {
        let scaled = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        return CGSize(
            width: max(0, (scaled.width - viewport.width) / 2),
            height: max(0, (scaled.height - viewport.height) / 2)
        )
    }

    /// The offset a drag actually gets, after the limits. A proposal beyond the edge is not
    /// refused, it is trimmed — so a pan that starts legal and overshoots stops at the edge
    /// instead of snapping back to centre.
    public static func clampedOffset(
        _ proposed: CGSize,
        scale: Double,
        fitted: CGSize,
        viewport: CGSize
    ) -> CGSize {
        let limit = panLimit(scale: scale, fitted: fitted, viewport: viewport)
        return CGSize(
            width: min(max(proposed.width, -limit.width), limit.width),
            height: min(max(proposed.height, -limit.height), limit.height)
        )
    }

    /// A committed transform: what the picture keeps when the fingers leave.
    public struct Transform: Equatable, Sendable {
        public var scale: Double
        public var offset: CGSize

        public static let identity = Transform(scale: MediaZoom.minimumScale, offset: .zero)

        public init(scale: Double, offset: CGSize) {
            self.scale = scale
            self.offset = offset
        }

        public var isZoomed: Bool { MediaZoom.isZoomed(scale) }
    }

    /// The transform a pinch leaves behind. The offset is re-clamped against the NEW scale,
    /// because zooming back out shrinks the room a pan was allowed to use — without this, a
    /// picture pinched out after being panned stays stuck off-centre.
    public static func settled(
        _ transform: Transform,
        magnifiedBy magnification: Double,
        fitted: CGSize,
        viewport: CGSize
    ) -> Transform {
        let scale = clamped(scale: transform.scale * magnification)
        return Transform(
            scale: scale,
            offset: clampedOffset(
                transform.offset,
                scale: scale,
                fitted: fitted,
                viewport: viewport
            )
        )
    }

    /// The transform a pan leaves behind.
    public static func panned(
        _ transform: Transform,
        by translation: CGSize,
        fitted: CGSize,
        viewport: CGSize
    ) -> Transform {
        Transform(
            scale: transform.scale,
            offset: clampedOffset(
                CGSize(
                    width: transform.offset.width + translation.width,
                    height: transform.offset.height + translation.height
                ),
                scale: transform.scale,
                fitted: fitted,
                viewport: viewport
            )
        )
    }

    /// The transform re-fitted to a viewport that changed UNDER it — a rotation, a size class,
    /// a split view.
    ///
    /// Clamping only what is drawn is not enough: the stored offset would keep its pre-rotation
    /// value, and the next pan would spend itself absorbing that stale delta before the picture
    /// moved at all — which reads as a picture stuck against an edge it is not against. The
    /// stored value is brought into the new geometry instead, so the next drag starts where the
    /// picture actually is.
    public static func renormalized(
        _ transform: Transform,
        fitted: CGSize,
        viewport: CGSize
    ) -> Transform {
        let scale = clamped(scale: transform.scale)
        return Transform(
            scale: scale,
            offset: clampedOffset(
                transform.offset,
                scale: scale,
                fitted: fitted,
                viewport: viewport
            )
        )
    }

    /// The transform a double tap leaves behind. Zooming out always recentres: the picture is
    /// whole again, so there is nothing left to be off-centre about.
    public static func doubleTapped(_ transform: Transform) -> Transform {
        Transform(scale: scale(afterDoubleTapAt: transform.scale), offset: .zero)
    }
}
