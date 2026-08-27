import Foundation

/// The one player the media viewer owns, and what opening it, swiping it, tapping it and leaving
/// it do to that player.
///
/// A video is a PAGE of the pager now, not a screen presented over it, so "which video is
/// playing" became a property of where the pager has settled — and a rule about a player's
/// LIFETIME ("built when its page becomes current, gone when its page is two swipes away") is
/// only worth anything if it can be asserted. It is decided here rather than inside the view
/// body so that assertion needs no simulator, no `AVPlayer` and no sleep: the view's whole job is
/// to make the real player match what these functions return.
///
/// The two lifetime rules the type exists to state:
///
/// - **One player.** `Player` is a single optional value, not a collection. Visiting five clips
///   in a memo leaves one player behind, not five.
/// - **Paused near, gone far.** Swiping off a playing video pauses it and keeps it, so swiping
///   straight back resumes where it stopped instead of starting the download again. Swiping
///   further than `retainedDistance` throws it away, because a player nobody can reach in one
///   gesture is just memory holding a signed URL open.
public enum MediaViewerPlayback {
    /// The single player: which page it belongs to, what it plays, and whether it is running.
    ///
    /// A paused player still EXISTS — that is the difference between the pause a swipe to the
    /// neighbouring page causes and the teardown a swipe past it causes, and the reason a swipe
    /// back resumes rather than restarts.
    public struct Player: Equatable, Sendable {
        /// The id of the page it belongs to.
        public let page: String
        /// The streamable rendition it was built for — never the original (ADR-0008).
        public let url: URL
        public var isPlaying: Bool

        public init(page: String, url: URL, isPlaying: Bool) {
            self.page = page
            self.url = url
            self.isPlaying = isPlaying
        }
    }

    /// The four things that can happen to the viewer's playback.
    public enum Event: Equatable, Sendable {
        /// The viewer appeared, on the page that was tapped.
        case opened
        /// The pager settled on a DIFFERENT page than the one it was on. The view sends this from
        /// a change of its scroll position, so it never arrives for a page that was already
        /// current — which is why arriving back at the player's own page means "swiped back".
        case paged(to: String)
        /// The play control on a video page was tapped.
        case played(page: String)
        /// The viewer is going away.
        case dismissed
    }

    /// How many pages away a paused player is still kept. One: the page next door is one swipe
    /// back, and the pager itself only keeps its neighbours built.
    public static let retainedDistance = 1

    /// The player the viewer should be holding after `event`.
    ///
    /// `nil` means no player at all: not a paused one, not a muted one — nothing, so the stream
    /// stops being read and the memory goes back.
    public static func player(
        after event: Event,
        player current: Player?,
        in selection: MediaViewerSelection
    ) -> Player? {
        switch event {
        case .opened:
            // The entry page plays the moment it appears when the thing that was tapped was a
            // video: a tap on a video means play it, and a poster with a play button on it
            // asking for a second tap is the defect this behaviour replaced.
            return started(selection.startPage)

        case .played(let id):
            guard let page = selection.pages.first(where: { $0.id == id }) else { return current }
            // A new page's player REPLACES whatever was there, which is what keeps it to one.
            return started(page) ?? current

        case .paged(let to):
            guard let current else { return nil }
            if current.page == to {
                // Swiped back onto it. It kept its position while it was paused, so this is a
                // resume, not a restart.
                return Player(page: current.page, url: current.url, isPlaying: true)
            }
            guard let arriving = selection.pages.firstIndex(where: { $0.id == to }),
                let leaving = selection.pages.firstIndex(where: { $0.id == current.page })
            else { return nil }
            // Off-screen audio is the thing nobody wants: a video the pager has left is silent
            // before it is anything else.
            guard abs(arriving - leaving) <= retainedDistance else { return nil }
            return Player(page: current.page, url: current.url, isPlaying: false)

        case .dismissed:
            return nil
        }
    }

    /// A page's player, if that page is a video with something to stream.
    ///
    /// A video whose derived rendition the server has not produced is a poster and nothing else,
    /// so it never becomes a player — there is no URL to build one from.
    private static func started(_ page: MediaPage) -> Player? {
        guard page.kind == .video, let url = page.playbackURL else { return nil }
        return Player(page: page.id, url: url, isPlaying: true)
    }

    // MARK: - the audio session

    /// What a change of player asks of the device's audio session.
    ///
    /// A decision about the TRANSITION rather than about the state, because that is what the
    /// system's session is: taking it is an event other apps hear ("something deliberate is
    /// playing, stop your podcast"), and taking it again while already holding it is that event
    /// sent twice. So a video that keeps playing while the pager moves under it asks for nothing,
    /// and a player that was already paused releases nothing.
    public enum SessionCommand: Equatable, Sendable {
        /// Take the session for deliberate playback. The claim is what makes a video audible with
        /// the ringer switch off — without it the silent switch silences it (MEMNG-183).
        case claim
        /// Give it back, so whatever was playing before the viewer opened can carry on.
        case release
    }

    /// What the audio session must do about the player going from `current` to `next` — `nil` for
    /// the transitions that ask nothing of it.
    public static func sessionCommand(from current: Player?, to next: Player?) -> SessionCommand? {
        switch (current?.isPlaying ?? false, next?.isPlaying ?? false) {
        case (false, true):
            return .claim
        case (true, false):
            return .release
        default:
            return nil
        }
    }

    /// A call, an alarm, or another app taking the audio session away and giving it back.
    public enum Interruption: Equatable, Sendable {
        case began
        /// `shouldResume` is the system's own hint that the app whose sound was interrupted may
        /// start again. Without it, resuming is the app talking over whatever took its place.
        case ended(shouldResume: Bool)
    }

    /// The player an interruption leaves behind, and whether its end may start it again.
    public struct Interrupted: Equatable, Sendable {
        public var player: Player?
        /// Whether the player this interruption paused was RUNNING when it arrived. It is the one
        /// piece of memory the decision needs: a player already paused on the page next door must
        /// not start talking because somebody else's phone call ended.
        public var resumable: Bool

        public init(player: Player?, resumable: Bool) {
            self.player = player
            self.resumable = resumable
        }
    }

    /// The player after an interruption. Pure, so "what comes back after a call" is an assertion
    /// rather than something only a real phone can be made to demonstrate.
    public static func interrupted(
        _ event: Interruption,
        player current: Player?,
        resumable: Bool
    ) -> Interrupted {
        switch event {
        case .began:
            // Paused, never torn down: the interruption is not the pager leaving, and the position
            // the call interrupted is the position it resumes at.
            guard let current else { return Interrupted(player: nil, resumable: false) }
            return Interrupted(
                player: Player(page: current.page, url: current.url, isPlaying: false),
                resumable: current.isPlaying
            )
        case .ended(let shouldResume):
            guard shouldResume, resumable, let current else {
                return Interrupted(player: current, resumable: false)
            }
            return Interrupted(
                player: Player(page: current.page, url: current.url, isPlaying: true),
                resumable: false
            )
        }
    }

    // MARK: - looping the short ones

    /// The length above which a video plays once and stops (MEMNG-184).
    ///
    /// Two minutes is the line between the two things a video in a memo is. A few seconds of a cat
    /// or a whiteboard is watched the way a Live Photo is — several times over, and the restart
    /// nobody has to reach for is the whole affordance. A clip past this is something somebody sat
    /// through: replaying it silently from the top is a surprise, and on a phone it is also a
    /// download and a radio nobody asked to keep running.
    public static let autoLoopMaximumDuration: Duration = .seconds(120)

    /// Whether a clip of this length restarts itself when it reaches its end.
    ///
    /// An unknown length never loops. A duration arrives late and may never arrive at all —
    /// a live stream's is indefinite — and "I do not know how long this is" must not become "loop
    /// it forever" (`nil` is what `duration(of:)` returns for an indefinite or invalid time).
    public static func shouldLoop(duration: Duration?) -> Bool {
        guard let duration, duration > .zero else { return false }
        return duration <= autoLoopMaximumDuration
    }
}
