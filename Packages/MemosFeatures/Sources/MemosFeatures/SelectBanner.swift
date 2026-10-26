import Observation

/// The ONE result banner of a select-mode screen (MEMNG-788): what the latest run said, whichever
/// flow ran it — a delete, or a memo action. A flow publishes into it when its run has something to
/// say, and the newest publication is the one shown, so an earlier delete's sentence never hides a
/// later "N of M changed" or "Another change is still running", and a dismissal clears only what
/// was on screen. A flow that retires its own sentence (select mode ended, a new question) takes it
/// down only while it is still the one shown: a newer sentence of the other flow stays up.
@MainActor
@Observable
public final class SelectBanner {
    /// Which flow a sentence came from.
    public enum Source: Equatable, Sendable {
        case delete
        case action
    }

    /// What the banner shows, or nil.
    public private(set) var message: String?
    /// Who said it.
    public private(set) var source: Source?

    public init() {}

    /// `text` replaces whatever is up: it is the latest outcome.
    public func publish(_ text: String, from source: Source) {
        message = text
        self.source = source
    }

    /// `source`'s sentence comes down — and only that one: another flow's newer sentence stays.
    public func retire(_ source: Source) {
        guard self.source == source else { return }
        message = nil
        self.source = nil
    }

    /// The banner was read or timed out.
    public func dismiss() {
        message = nil
        source = nil
    }
}

/// A select-mode screen's two result-speaking flows, built around one banner so neither can speak
/// past the other. Held in one `@State` because the flows need the banner at their birth.
@MainActor
final class SelectResults {
    let banner = SelectBanner()
    let deleting: LibraryDeleteFlow
    let acting: MemoActionFlow
    /// Add to Album (MEMNG-805), whose sentence is an action's.
    let albums: AlbumAddFlow

    init() {
        deleting = LibraryDeleteFlow(banner: banner)
        acting = MemoActionFlow(banner: banner)
        albums = AlbumAddFlow(banner: banner)
    }
}
