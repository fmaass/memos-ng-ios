import MapKit
import MemosCore
import UIKit

/// The geometry a pin and a cluster are drawn with, and what the opening view owes it.
///
/// Written once because the margin follows the drawing: the square stands wholly ABOVE the
/// coordinate it marks and its badge overhangs the top, so a coordinate on the pane's edge is a
/// pin half off the screen — and a photograph of another size would be cut differently.
nonisolated enum PlacePinGeometry {
    /// The side of the square photograph a pin wears.
    static let side: CGFloat = 52
    /// How far the count badge reaches above the square's top edge.
    static let badgeOverhang: CGFloat = 6
    /// The air left around the outermost pins, so the map does not open with a pin touching its
    /// frame.
    static let breathingSpace: CGFloat = side / 2
    /// How much of an axis the fit leaves to the map itself whatever the pins cost, so a pane too
    /// small for the margin shows a smaller margin rather than nothing.
    static let minimumFreeExtent: CGFloat = 40

    /// What the opening fit keeps free on each side of a pane of this size, in points.
    static func openingInsets(in pane: CGSize) -> UIEdgeInsets {
        // Above the coordinate: the whole square and the badge, then the air. Below it: air alone.
        let (top, bottom) = shrunk(
            side + badgeOverhang + breathingSpace,
            breathingSpace,
            toFit: pane.height
        )
        // Centred on the coordinate: half a square on each side, then the air.
        let (left, right) = shrunk(
            side / 2 + breathingSpace,
            side / 2 + breathingSpace,
            toFit: pane.width
        )
        return UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }

    /// Two insets brought within what one axis can spend, in proportion so neither side loses the
    /// margin the other keeps. A pane under `minimumFreeExtent` can spend nothing: insets that met
    /// in the middle would leave the fit inverted, with no rect left to show.
    private static func shrunk(
        _ near: CGFloat,
        _ far: CGFloat,
        toFit extent: CGFloat
    ) -> (CGFloat, CGFloat) {
        let budget = max(0, extent - minimumFreeExtent)
        let asked = near + far
        guard asked > budget else { return (near, far) }
        let scale = budget / asked
        return (near * scale, far * scale)
    }
}

/// What a pin and a cluster have in common: one photograph, one count, and the rule for painting
/// a picture that arrives after the view has been handed somebody else's.
///
/// UIKit all the way down. A SwiftUI view hosted inside an annotation view brings a whole hosting
/// controller per pin onto a surface that recycles its views by the dozen.
class PlaceAnnotationView: MKAnnotationView {
    private static let side = PlacePinGeometry.side

    private let photo = UIImageView()
    private let badge = UILabel()
    /// Which image this view last ASKED for. The one thing a late answer is judged against.
    private var requested: MediaImageKey?
    /// One request this view made: which photograph it is for, and which of this view's requests
    /// it is. The number is what lets the request that ENDS say whether it is still the one out —
    /// the same photograph can be asked for twice by one view, so the key alone cannot.
    private struct Request {
        let key: MediaImageKey
        let serial: Int
    }

    /// The request this view has out right now, if any — cleared by the task that made it, and by
    /// reuse. A map pass arrives whenever the screen is re-evaluated, so the same photograph can
    /// be asked for again while the first request is still unanswered.
    private var inFlight: Request?
    /// How many requests this view has made, which numbers each one.
    private var requestsMade = 0
    /// Exposed so a test can await the fetch this view started rather than sleep for it.
    private(set) var loading: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        centerOffset = CGPoint(x: 0, y: -Self.side / 2)

        photo.frame = bounds
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.backgroundColor = .secondarySystemBackground
        photo.layer.cornerRadius = 8
        photo.layer.borderWidth = 2
        photo.layer.borderColor = UIColor.systemBackground.cgColor
        addSubview(photo)

        badge.frame = CGRect(
            x: Self.side - 26,
            y: -PlacePinGeometry.badgeOverhang,
            width: 26,
            height: 18
        )
        badge.textAlignment = .center
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.isHidden = true
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaceAnnotationView is built in code, never from a nib")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
        requested = nil
        inFlight = nil
        photo.image = nil
        badge.isHidden = true
    }

    /// Read what this view stands for out of its annotation and paint it. Overridden by each
    /// subclass; called again by the sink when the pin behind a live view changed.
    func configure() {}

    /// What the view is showing, for the assertions a headless run can make about it.
    var shownImage: UIImage? { photo.image }
    var badgeText: String? { badge.isHidden ? nil : badge.text }

    /// Whether this pin is still owed its photograph: nothing painted and nothing on the wire.
    ///
    /// A fetch that came back with nothing leaves exactly this state and caches nothing, so the
    /// view is the only place that knows the picture is still worth asking for — the pin's place,
    /// its photographs and often its URL are all the same as they were.
    var isAwaitingPhotograph: Bool { photo.image == nil && inFlight == nil }

    /// One photograph and one count, with the two fences a recycled view needs.
    func show(photoFor uid: String, at url: URL?, badge text: String?) {
        badge.text = text
        badge.isHidden = text == nil

        let key = MediaImageKey(uid: uid, tier: MediaTier.thumb.rawValue)
        requested = key

        // A request for this very photograph is already out, and the answer on its way is this
        // call's answer too. Returning here is what keeps a repeated ask off the wire — and what
        // keeps the line below from blanking a pin that is merely waiting.
        if inFlight?.key == key { return }

        // Before the cache is read, and the same one rule the tile applies: a lapsed signature
        // takes the decoded picture with it, or the pin paints a frame this URL can no longer
        // authorise and never asks for the one that would replace it.
        if let url { MediaImageLoader.evictLapsedSignature(url: url, key: key) }

        // The same entry the library's tile fetched, so a photograph seen in the grid costs a pin
        // nothing.
        if let cached = MediaImageLoader.cachedUIImage(for: key) {
            photo.image = cached
            return
        }
        photo.image = nil
        guard let url else { return }

        // Read BEFORE the await and compared after it: an answer about the account that was
        // signed in when this started must not be painted for the one signed in now.
        let generation = MediaImageLoader.store.generation
        requestsMade += 1
        let request = Request(key: key, serial: requestsMade)
        inFlight = request
        loading = Task { [weak self] in
            // Whichever way this task leaves, the request it stands for is over — and only THIS
            // request. A view recycled and handed the same pin again cancels this one and makes
            // another for the same photograph; when the cancelled one ends it must not report the
            // live one finished, or the next map pass sees a pin owed a picture and asks twice.
            defer { if self?.inFlight?.serial == request.serial { self?.inFlight = nil } }
            // The task starts a turn later than the generation was read, and the loader would
            // sample the clock itself: asking it now for a URL the previous account signed files
            // those bytes under THIS account's number, where the refusal below no longer reaches
            // them. So the fence is asked once more before the request exists at all.
            guard MediaImageLoader.store.generation == generation else { return }
            let image = await MediaImageLoader.uiImage(for: key, url: url)
            guard let self else { return }
            guard MediaImageLoader.store.generation == generation else { return }
            // And the fence a recycled view needs on top of it: this view may already be standing
            // for a different pin, and the photograph it asked for is no longer the one to paint.
            guard requested == key else { return }
            // The same photograph can be out twice — a view handed the same pin again cancels the
            // first request and makes another — and then the key says nothing about which of them
            // this is. Only the request still out may paint: the one it replaced can answer with
            // nothing, and its nothing would take down the picture already on screen.
            guard inFlight?.serial == request.serial else { return }
            photo.image = image
        }
    }
}

/// One coordinate's pin.
final class PlacePinView: PlaceAnnotationView {
    /// Set so MAPKIT does the clustering and hands back `MKClusterAnnotation`s — the alternative
    /// is a second clustering rule beside `PlaceClustering`'s, disagreeing with it at some zoom.
    private static let clusterGroup = "places"

    override var annotation: (any MKAnnotation)? {
        didSet { configure() }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = Self.clusterGroup
        // A view built around its annotation configures twice, here and through the property the
        // superclass set. Both are kept: a view built empty is painted only by the property, and
        // the repeat costs nothing — a request for the same photograph is already out and `show`
        // returns on it.
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlacePinView is built in code, never from a nib")
    }

    override func configure() {
        clusteringIdentifier = Self.clusterGroup
        guard let place = annotation as? PlaceAnnotation else { return }
        // Where the view learns what it stands for is the one place it can say it: MapKit's own
        // label is "Map pin", which is true of every pin on the screen.
        accessibilityLabel = PlacesPresentation.spokenLabel(
            photographs: place.pin.spec.count,
            newest: place.pin.leadTakenAt
        )
        show(
            photoFor: place.pin.spec.uid,
            at: place.pin.leadThumbnailURL,
            badge: PlacesPresentation.pinBadge(for: place.pin.spec)
        )
    }
}

/// What several pins become when they are too close together to tell apart.
final class PlaceClusterView: PlaceAnnotationView {
    override var annotation: (any MKAnnotation)? {
        didSet { configure() }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // Deliberately no clustering identifier: a cluster of clusters is not a thing.
        // Configured here as well as through the property, for the reason `PlacePinView` gives.
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaceClusterView is built in code, never from a nib")
    }

    override func configure() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let members = cluster.memberAnnotations.compactMap { ($0 as? PlaceAnnotation)?.pin }
        guard let lead = PlacesPresentation.clusterLead(of: members) else { return }
        // The photographs behind the cluster, which is what its badge counts too — MapKit's own
        // label is the "+n more" it would have drawn, about pins rather than pictures.
        accessibilityLabel = PlacesPresentation.spokenLabel(
            photographs: PlacesPresentation.clusterPhotographs(in: members),
            newest: lead.leadTakenAt
        )
        show(
            photoFor: lead.spec.uid,
            at: lead.leadThumbnailURL,
            badge: PlacesPresentation.clusterBadge(for: members)
        )
    }
}
