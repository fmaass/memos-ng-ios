import AVFoundation
import Foundation
import MemosCore

/// The device's audio session as the viewer needs it.
///
/// One of the two things the viewer has to say to the system to make a video audible — the other
/// is `MediaViewerPlayerCommanding` below — and both are protocols rather than direct calls for
/// the same reason `MediaViewerPlayback` is a pure function: the defects here are in the ORDER and
/// the PAIRING of events. A claim made twice, a release that never happens because a page was torn
/// down instead of paused, a session left held after the viewer closed, a loop that re-takes the
/// session on every lap. None of those can be produced from a real `AVAudioSession` in a test, and
/// all of them are a few deterministic lines behind a seam.
@MainActor
protocol AudioSessionControlling: AnyObject {
    /// Take the session for deliberate playback: audible with the ringer switch off, and other
    /// audio stopped rather than mixed with (MEMNG-183).
    func claimPlayback()
    /// Give it back, telling the system to let whatever was interrupted resume.
    func release()
    /// Start hearing about calls and alarms. Called with the viewer on screen and never before.
    func observeInterruptions(_ handler: @escaping (MediaViewerPlayback.Interruption) -> Void)
    func stopObservingInterruptions()
}

/// The two system calls a claim is made of, as their own seam so that the ORDER can be asserted:
/// activating a session before its category is set activates the category it had BEFORE, which is
/// the one that obeys the silent switch.
@MainActor
protocol AudioSessionRouting: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionRouting {}

/// The real session: `AVAudioSession.sharedInstance()`, one per process.
///
/// `.playback` with no options is the deliberate choice Photos and YouTube make: a video somebody
/// opened is meant to be heard, so it plays through the silent switch and takes the session from
/// whatever was playing instead of mixing under it. Before this, a memo's video was silent for
/// anyone whose ringer was off, with nothing on screen to say why.
@MainActor
final class ViewerAudioSession: AudioSessionControlling {
    private let session: any AudioSessionRouting
    private var observer: (any NSObjectProtocol)?
    private var onInterruption: ((MediaViewerPlayback.Interruption) -> Void)?

    init(session: any AudioSessionRouting = AVAudioSession.sharedInstance()) {
        self.session = session
    }

    func claimPlayback() {
        do {
            try claim()
        } catch {
            // A refused claim is a video that plays silently, not a viewer that fails to open.
            MemosLog.media.error("audio session claim refused: \(error.localizedDescription)")
        }
    }

    func release() {
        do {
            try deactivate()
        } catch {
            MemosLog.media.error("audio session release refused: \(error.localizedDescription)")
        }
    }

    /// The claim as the system may refuse it. `claimPlayback()` is this with the refusal logged;
    /// this one is what a test can watch throw.
    func claim() throws {
        // Category first, THEN activation — see `AudioSessionRouting`.
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        try session.setActive(true, options: [])
    }

    /// `.notifyOthersOnDeactivation` is the half that makes leaving polite: without it the podcast
    /// this video interrupted stays paused after the viewer is closed.
    func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func observeInterruptions(_ handler: @escaping (MediaViewerPlayback.Interruption) -> Void) {
        stopObservingInterruptions()
        onInterruption = handler
        // The notification is posted on a queue of the system's choosing. Asking for the main one
        // is what makes the isolation assumption below true rather than hopeful, and it is also
        // the only way a `Notification` — which is not `Sendable` — stays out of the closure
        // that crosses: the two numbers it carries are read here and nothing else travels.
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.deliver(type: type, options: options)
            }
        }
    }

    /// Explicit rather than a `deinit`, because a block observer is held by the notification centre
    /// until it is removed: a viewer that closed without this would go on hearing about calls.
    func stopObservingInterruptions() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        onInterruption = nil
    }

    private func deliver(type: UInt?, options: UInt) {
        guard let event = Self.interruption(type: type, options: options) else { return }
        onInterruption?(event)
    }

    /// What the notification means, out of the two raw numbers it arrives as. Its own function so
    /// the reading of the system's dictionary is a test rather than a hope.
    static func interruption(type: UInt?, options: UInt) -> MediaViewerPlayback.Interruption? {
        guard let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else {
            return nil
        }
        switch interruption {
        case .began:
            return .began
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: options)
            return .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}

/// The live player as the viewer commands it: built for a page, told to play and pause, started
/// over at its end, and thrown away.
@MainActor
protocol MediaViewerPlayerCommanding: AnyObject {
    /// The player itself, to hand to the page it belongs to. `nil` when there is none.
    var player: AVPlayer? { get }
    /// How long the attached item is, once it knows — `nil` while it does not, and for a stream
    /// whose length is indefinite.
    var duration: Duration? { get }
    /// The player for this stream. A no-op when the player already playing it is this one, which
    /// is what makes a swipe back a resume rather than a second download.
    func attach(url: URL)
    /// Stop reading the stream and let the player go. A paused player still holds its signed URL
    /// open; this is the difference between the pause a swipe causes and the teardown it causes.
    func detach()
    func play()
    func pause()
    /// Back to the first frame, and nothing else. The auto-loop (MEMNG-184) is this FOLLOWED BY
    /// `play()` rather than one combined "restart", because the two halves fail separately: a seek
    /// with no play leaves a frozen first frame, a play with no seek replays nothing at an ended
    /// item. As one call a test could only assert that a restart was asked for; as two it asserts
    /// that both halves were, and in that order.
    func seekToStart()
    /// Start hearing about the item reaching its end.
    func observeItemEnded(_ handler: @escaping () -> Void)
    func stopObservingItemEnded()
}

/// The real one, around the single `AVPlayer` the viewer owns.
@MainActor
final class AVPlayerCommands: MediaViewerPlayerCommanding {
    private(set) var player: AVPlayer?
    /// What the current player was built for, so `attach` can tell "the same video again" from
    /// "a different one".
    private var attachedURL: URL?
    private var observer: (any NSObjectProtocol)?
    private var onItemEnded: (() -> Void)?

    /// Read synchronously off the item rather than awaited through `load(.duration)`, and that is
    /// deliberate: the only moment this is asked is the moment the item has just played to its END
    /// (`itemEnded`), and an item whose timeline has completed already knows how long it was.
    /// `nil` or indefinite AT THAT POINT is not "not loaded yet" — it is media of genuinely
    /// unknown length (a live stream), which the loop rule deliberately never restarts. Loading it
    /// asynchronously in advance would add a second race against the first frame and answer the
    /// same question no better, so do not "fix" this back to `load(.duration)`.
    var duration: Duration? {
        guard let item = player?.currentItem else { return nil }
        return MediaViewerPlayback.duration(of: item.duration)
    }

    func attach(url: URL) {
        guard player == nil || attachedURL != url else { return }
        detach()
        let live = AVPlayer(url: url)
        player = live
        attachedURL = url
        observeEnd(of: live.currentItem)
    }

    func detach() {
        // The item is detached first so the stream stops being read at once, rather than when the
        // player happens to be released.
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        attachedURL = nil
        removeItemObserver()
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seekToStart() {
        player?.seek(to: .zero)
    }

    func observeItemEnded(_ handler: @escaping () -> Void) {
        onItemEnded = handler
        observeEnd(of: player?.currentItem)
    }

    func stopObservingItemEnded() {
        onItemEnded = nil
        removeItemObserver()
    }

    private func observeEnd(of item: AVPlayerItem?) {
        removeItemObserver()
        guard let item, onItemEnded != nil else { return }
        // Scoped to THIS item: the notification is posted for every player in the process, and a
        // loop that restarted on somebody else's video would be a fine bug to find later.
        observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onItemEnded?()
            }
        }
    }

    private func removeItemObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}

extension MediaViewerPlayback {
    /// A `CMTime` as a length, or `nil` when it is not one.
    ///
    /// `CMTime` says "I do not know" in several ways — indefinite for a live stream, invalid
    /// before the item has loaded, zero for an item with nothing in it — and every one of them
    /// has to mean "do not loop this" rather than "loop it forever".
    static func duration(of time: CMTime) -> Duration? {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite, time.seconds > 0 else {
            return nil
        }
        return .seconds(time.seconds)
    }
}

/// Everything the viewer's playback DOES, in one object: the policy's answer turned into commands
/// to the player and to the audio session.
///
/// It is not the view because the view cannot be asked about orders. "Claimed before it plays",
/// "released when the pager leaves it", "released once, not once per loop", "resumed only if it
/// was running when the call came" are all statements about sequences of two seams, and behind
/// this object they are assertions instead of behaviour somebody watches for on a device.
@MainActor
@Observable
final class MediaViewerPlaybackCoordinator {
    /// The pages the playback rules are measured against. It is a `var` because the library's
    /// viewer grows: a video on a page that arrived after the viewer opened has to be a page these
    /// rules can find, or its play control asks for a player that is never built (MEMNG-189).
    private var selection: MediaViewerSelection
    private let audio: any AudioSessionControlling
    private let commands: any MediaViewerPlayerCommanding

    /// What `MediaViewerPlayback` says the player should be.
    private(set) var playback: MediaViewerPlayback.Player?
    /// The live player, mirrored out of the command seam so the page that owns it redraws when it
    /// appears and disappears.
    private(set) var livePlayer: AVPlayer?
    /// Whether the session is held. The policy already refuses to claim twice; this is the second
    /// half of that promise — nothing is ever released that was not taken.
    private var claimed = false
    /// See `MediaViewerPlayback.Interrupted.resumable`.
    private var resumable = false

    init(
        selection: MediaViewerSelection,
        audio: any AudioSessionControlling = ViewerAudioSession(),
        commands: any MediaViewerPlayerCommanding = AVPlayerCommands()
    ) {
        self.selection = selection
        self.audio = audio
        self.commands = commands
    }

    /// Takes in a longer list of pages, without disturbing the player that is running.
    ///
    /// Only the pages change. The current player, the session claim and the resume state are all
    /// about what is PLAYING, and a page appearing at the far end of the list is not an event that
    /// happened to any of them.
    func adopt(pages: [MediaPage], startingAt id: String) {
        guard !pages.isEmpty else { return }
        let start = pages.firstIndex { $0.id == id } ?? 0
        selection = MediaViewerSelection(pages: pages, startIndex: start)
    }

    /// The live player, and only for the page it belongs to. Every other page gets `nil` and
    /// draws its poster — the reason a page cannot create, duplicate or outlive a player.
    func player(for page: String) -> AVPlayer? {
        playback?.page == page ? livePlayer : nil
    }

    /// One event in, one desired player out of `MediaViewerPlayback`, and both seams made to match
    /// it.
    func advance(_ event: MediaViewerPlayback.Event) {
        if case .opened = event {
            listen()
        }
        let next = MediaViewerPlayback.player(after: event, player: playback, in: selection)
        // A player that belongs to a different page than the one wanted is released rather than
        // paused and kept — the rule `MediaViewerPlayback` states about distance, applied. There
        // is nothing to tear down before the first one exists.
        apply(next, tearingDown: playback != nil && playback?.page != next?.page)
        if case .dismissed = event {
            deafen()
        }
    }

    /// A call, an alarm, or another app taking the session. The player is paused and the session
    /// let go on the way in, and only a player that was RUNNING is started again on the way out.
    func interrupted(_ event: MediaViewerPlayback.Interruption) {
        let outcome = MediaViewerPlayback.interrupted(event, player: playback, resumable: resumable)
        resumable = outcome.resumable
        apply(outcome.player, tearingDown: false)
    }

    /// The item reached its end. A short clip starts over; a long one stops there.
    ///
    /// The session is deliberately untouched: a loop is one continuous piece of playback, and
    /// releasing and re-claiming on every lap would tell every other app on the phone to stop,
    /// twice a minute.
    func itemEnded() {
        guard playback?.isPlaying == true else { return }
        guard MediaViewerPlayback.shouldLoop(duration: commands.duration) else { return }
        commands.seekToStart()
        commands.play()
    }

    private func apply(_ next: MediaViewerPlayback.Player?, tearingDown: Bool) {
        let command = MediaViewerPlayback.sessionCommand(from: playback, to: next)
        if tearingDown {
            commands.detach()
        }
        playback = next
        // Claimed BEFORE the play, released AFTER the pause: the session has to be held for the
        // whole time sound is coming out, and a claim that lands second is a first second of
        // silence.
        if command == .claim {
            claim()
        }
        if let next {
            commands.attach(url: next.url)
            if next.isPlaying {
                commands.play()
            } else {
                commands.pause()
            }
        }
        if command == .release {
            release()
        }
        livePlayer = commands.player
    }

    private func claim() {
        guard !claimed else { return }
        audio.claimPlayback()
        claimed = true
    }

    private func release() {
        guard claimed else { return }
        audio.release()
        claimed = false
    }

    private func listen() {
        audio.observeInterruptions { [weak self] event in
            self?.interrupted(event)
        }
        commands.observeItemEnded { [weak self] in
            self?.itemEnded()
        }
    }

    private func deafen() {
        audio.stopObservingInterruptions()
        commands.stopObservingItemEnded()
    }
}
