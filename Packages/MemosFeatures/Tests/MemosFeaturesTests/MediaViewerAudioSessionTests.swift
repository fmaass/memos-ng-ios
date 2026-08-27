import AVFoundation
import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The audio session, recorded. What is under test is not what it does to the device but WHEN the
/// viewer speaks to it: twice would be an event other apps hear twice, never would be a video that
/// goes on playing over a podcast that was told nothing.
@MainActor
final class AudioSessionSpy: AudioSessionControlling {
    enum Call: Equatable {
        case claim
        case release
    }

    private(set) var calls: [Call] = []
    private var handler: ((MediaViewerPlayback.Interruption) -> Void)?

    /// Whether the viewer is currently hearing about calls and alarms.
    var isListening: Bool { handler != nil }

    func claimPlayback() { calls.append(.claim) }

    func release() { calls.append(.release) }

    func observeInterruptions(_ handler: @escaping (MediaViewerPlayback.Interruption) -> Void) {
        self.handler = handler
    }

    func stopObservingInterruptions() { handler = nil }

    /// What the system does when a call arrives, or ends.
    func interrupt(_ event: MediaViewerPlayback.Interruption) { handler?(event) }
}

/// The live player, recorded. No real `AVPlayer` is built: what the wiring gets wrong is the
/// pairing — a pause with no release, a lap of the loop that re-takes the session — and a player
/// would only add a download and a wait to a question about order.
@MainActor
final class PlayerCommandSpy: MediaViewerPlayerCommanding {
    enum Call: Equatable {
        case attach(URL)
        case detach
        case play
        case pause
        case seekToStart
    }

    private(set) var calls: [Call] = []
    /// What the attached item reports. `nil` is an item whose length nobody knows.
    var duration: Duration?
    var player: AVPlayer? { nil }
    private var handler: (() -> Void)?

    var isListening: Bool { handler != nil }

    func attach(url: URL) { calls.append(.attach(url)) }

    func detach() { calls.append(.detach) }

    func play() { calls.append(.play) }

    func pause() { calls.append(.pause) }

    func seekToStart() { calls.append(.seekToStart) }

    func observeItemEnded(_ handler: @escaping () -> Void) { self.handler = handler }

    func stopObservingItemEnded() { handler = nil }

    /// The video reached its end.
    func finishItem() { handler?() }
}

/// The wiring between the two seams: the policy's answers turned into real commands, in order.
///
/// The pure rules are asserted in `MediaViewerPlaybackTests`. These are the other half — that the
/// viewer actually SENDS them, and sends nothing else. Every defect this pair was built for is a
/// missing or duplicated call rather than a wrong decision: a session claimed after the play
/// started, a pause with no release behind it, a loop that took the session again on every lap.
@Suite("Viewer playback wiring")
struct MediaViewerPlaybackWiringTests {
    private static let attachments: [MemoAttachment] = [
        MediaViewerPageTests.image("p1"),
        MediaViewerPageTests.video("v1"),
        MediaViewerPageTests.image("p2"),
        MediaViewerPageTests.image("p3"),
    ]

    private struct Wired {
        let coordinator: MediaViewerPlaybackCoordinator
        let audio: AudioSessionSpy
        let commands: PlayerCommandSpy
        /// The rendition `v1` plays.
        let stream: URL
    }

    private func wired(at uid: String) throws -> Wired {
        let selection = try #require(
            MediaViewerPresentation.viewer(for: Self.attachments, startingAt: uid)
        )
        let video = try #require(selection.pages.first { $0.id == "v1" })
        let audio = AudioSessionSpy()
        let commands = PlayerCommandSpy()
        let coordinator = MediaViewerPlaybackCoordinator(
            selection: selection,
            audio: audio,
            commands: commands
        )
        return Wired(
            coordinator: coordinator,
            audio: audio,
            commands: commands,
            stream: try #require(video.playbackURL)
        )
    }

    @Test("opening on a video takes the session before it plays")
    func openingClaims() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        #expect(wired.audio.calls == [.claim], "the video played into a session nobody had taken")
        #expect(wired.commands.calls == [.attach(wired.stream), .play])
    }

    @Test("swiping to the picture next door pauses it and gives the session back")
    func swipingAwayReleases() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        wired.coordinator.advance(.paged(to: "p2"))
        #expect(wired.audio.calls == [.claim, .release])
        #expect(wired.commands.calls.last == .pause)
        #expect(
            !wired.commands.calls.contains(.detach),
            "the player next door was thrown away rather than kept paused"
        )
    }

    @Test("swiping back onto it takes the session again")
    func swipingBackReclaims() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        wired.coordinator.advance(.paged(to: "p2"))
        wired.coordinator.advance(.paged(to: "v1"))
        #expect(wired.audio.calls == [.claim, .release, .claim])
        #expect(wired.commands.calls.last == .play)
    }

    @Test("leaving the viewer gives the session back, tears the player down and stops listening")
    func dismissReleases() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        wired.coordinator.advance(.dismissed)
        #expect(wired.audio.calls == [.claim, .release])
        #expect(wired.commands.calls.contains(.detach))
        #expect(!wired.audio.isListening, "a closed viewer went on hearing about calls")
        #expect(!wired.commands.isListening)
    }

    @Test("a video the pager left two pages behind releases the session as it is torn down")
    func distantTeardownReleases() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        wired.coordinator.advance(.paged(to: "p2"))
        wired.coordinator.advance(.paged(to: "p3"))
        #expect(wired.audio.calls == [.claim, .release], "the release was sent twice")
        #expect(wired.commands.calls.last == .detach)
    }

    @Test("looking at pictures touches neither the session nor a player")
    func picturesTouchNothing() throws {
        let wired = try wired(at: "p1")
        wired.coordinator.advance(.opened)
        wired.coordinator.advance(.paged(to: "p2"))
        #expect(wired.audio.calls.isEmpty)
        #expect(wired.commands.calls.isEmpty)
    }

    @Test("a call pauses the player through the seam and gives the session back")
    func interruptionPauses() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        wired.audio.interrupt(.began)
        #expect(wired.commands.calls.last == .pause)
        #expect(wired.audio.calls == [.claim, .release])
    }

    @Test("the call ending plays it again and takes the session again")
    func interruptionResumes() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        wired.audio.interrupt(.began)
        wired.audio.interrupt(.ended(shouldResume: true))
        #expect(wired.audio.calls == [.claim, .release, .claim])
        #expect(wired.commands.calls.last == .play)
    }

    @Test("a call ending after the pager left the video starts nothing")
    func interruptionAfterSwipingAway() throws {
        let wired = try wired(at: "v1")
        wired.coordinator.advance(.opened)
        wired.coordinator.advance(.paged(to: "p2"))
        wired.audio.interrupt(.began)
        wired.audio.interrupt(.ended(shouldResume: true))
        #expect(wired.audio.calls == [.claim, .release], "a page nobody was on started talking")
        #expect(!wired.commands.calls.dropFirst(2).contains(.play))
    }

    @Test("a short clip starts itself over at its end without touching the session")
    func shortClipLoops() throws {
        let wired = try wired(at: "v1")
        wired.commands.duration = .seconds(30)
        wired.coordinator.advance(.opened)
        wired.commands.finishItem()
        #expect(
            Array(wired.commands.calls.suffix(2)) == [.seekToStart, .play],
            "a lap that only seeks freezes on the first frame; one that only plays replays nothing"
        )
        #expect(
            wired.audio.calls == [.claim],
            "every lap of the loop told the rest of the phone to stop"
        )
    }

    @Test("a long one stops at its end")
    func longClipStops() throws {
        let wired = try wired(at: "v1")
        wired.commands.duration = .seconds(200)
        wired.coordinator.advance(.opened)
        wired.commands.finishItem()
        #expect(!wired.commands.calls.contains(.seekToStart))
    }

    @Test("a clip whose length nobody knows stops at its end")
    func unknownLengthStops() throws {
        let wired = try wired(at: "v1")
        wired.commands.duration = nil
        wired.coordinator.advance(.opened)
        wired.commands.finishItem()
        #expect(!wired.commands.calls.contains(.seekToStart))
    }

    @Test("an item that ends under a player the pager already paused does not restart")
    func endedWhilePausedDoesNotLoop() throws {
        let wired = try wired(at: "v1")
        wired.commands.duration = .seconds(30)
        wired.coordinator.advance(.opened)
        wired.coordinator.advance(.paged(to: "p2"))
        wired.commands.finishItem()
        #expect(!wired.commands.calls.contains(.seekToStart))
    }
}

/// The two system calls a claim is made of, recorded, so their ORDER is an assertion.
@MainActor
final class AudioRoutingSpy: AudioSessionRouting {
    enum Call: Equatable {
        case category(String, String, UInt)
        case active(Bool, UInt)
    }

    private(set) var calls: [Call] = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        calls.append(.category(category.rawValue, mode.rawValue, options.rawValue))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        calls.append(.active(active, options.rawValue))
    }
}

/// The real adapter against the real `AVAudioSession`, because the claim is only worth anything if
/// the system ends up in the state the fix is about: `.playback`, movie playback, no options —
/// which is what makes a video audible with the ringer switch off.
///
/// Serialized: there is one audio session per process, and a suite that changes it under another
/// one running beside it is a flake waiting to be reported as a bug.
@Suite("Viewer audio session adapter", .serialized)
struct ViewerAudioSessionAdapterTests {
    @Test("the category is set before the session is activated, and released with a notification")
    func claimOrder() {
        let routing = AudioRoutingSpy()
        let adapter = ViewerAudioSession(session: routing)
        adapter.claimPlayback()
        #expect(
            routing.calls == [
                .category(
                    AVAudioSession.Category.playback.rawValue,
                    AVAudioSession.Mode.moviePlayback.rawValue,
                    0
                ),
                .active(true, 0),
            ],
            "activating before the category is set activates the category it had before"
        )
        adapter.release()
        let notifying = AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation.rawValue
        #expect(
            routing.calls.last == .active(false, notifying),
            "the podcast this video interrupted was left paused"
        )
    }

    @Test("a claim leaves the real session on playback and movie playback, and lets go again")
    func realSession() throws {
        let adapter = ViewerAudioSession()
        try adapter.claim()
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playback, "the silent switch still silences a memo's video")
        #expect(session.mode == .moviePlayback)
        #expect(session.categoryOptions.isEmpty, "the claim mixed instead of taking over")
        try adapter.deactivate()
    }

    @Test("the system's interruption notification is read as the system means it")
    func interruptionReading() {
        let began = AVAudioSession.InterruptionType.began.rawValue
        let ended = AVAudioSession.InterruptionType.ended.rawValue
        let resume = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        #expect(ViewerAudioSession.interruption(type: began, options: 0) == .began)
        #expect(
            ViewerAudioSession.interruption(type: ended, options: resume)
                == .ended(shouldResume: true)
        )
        #expect(
            ViewerAudioSession.interruption(type: ended, options: 0) == .ended(shouldResume: false)
        )
        #expect(ViewerAudioSession.interruption(type: nil, options: 0) == nil)
    }

    @Test("a time that is not a length is not one")
    func durationBridge() {
        #expect(
            MediaViewerPlayback.duration(of: CMTime(seconds: 30, preferredTimescale: 600))
                == .seconds(30)
        )
        #expect(MediaViewerPlayback.duration(of: .indefinite) == nil, "a live stream would loop")
        #expect(MediaViewerPlayback.duration(of: .invalid) == nil)
        #expect(MediaViewerPlayback.duration(of: .zero) == nil)
        let indefinite = MediaViewerPlayback.duration(of: .indefinite)
        #expect(!MediaViewerPlayback.shouldLoop(duration: indefinite))
    }
}
