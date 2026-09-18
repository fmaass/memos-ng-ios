import MapKit
import MemosCore
import UIKit

/// What a pin and a cluster have in common: one photograph, one count, and the rule for painting
/// a picture that arrives after the view has been handed somebody else's.
///
/// UIKit all the way down. A SwiftUI view hosted inside an annotation view brings a whole hosting
/// controller per pin onto a surface that recycles its views by the dozen.
class PlaceAnnotationView: MKAnnotationView {
    /// The side of the square photograph a pin wears.
    private static let side: CGFloat = 52

    private let photo = UIImageView()
    private let badge = UILabel()
    /// Which image this view last ASKED for. The one thing a late answer is judged against.
    private var requested: MediaImageKey?
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

        badge.frame = CGRect(x: Self.side - 26, y: -6, width: 26, height: 18)
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
        photo.image = nil
        badge.isHidden = true
    }

    /// Read what this view stands for out of its annotation and paint it. Overridden by each
    /// subclass; called again by the sink when the pin behind a live view changed.
    func configure() {}

    /// What the view is showing, for the assertions a headless run can make about it.
    var shownImage: UIImage? { photo.image }
    var badgeText: String? { badge.isHidden ? nil : badge.text }

    /// One photograph and one count, with the two fences a recycled view needs.
    func show(photoFor uid: String, at url: URL?, badge text: String?) {
        badge.text = text
        badge.isHidden = text == nil

        let key = MediaImageKey(uid: uid, tier: MediaTier.thumb.rawValue)
        requested = key

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
        loading = Task { [weak self] in
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
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlacePinView is built in code, never from a nib")
    }

    override func configure() {
        clusteringIdentifier = Self.clusterGroup
        guard let place = annotation as? PlaceAnnotation else { return }
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
        show(
            photoFor: lead.spec.uid,
            at: lead.leadThumbnailURL,
            badge: PlacesPresentation.clusterBadge(for: members)
        )
    }
}
