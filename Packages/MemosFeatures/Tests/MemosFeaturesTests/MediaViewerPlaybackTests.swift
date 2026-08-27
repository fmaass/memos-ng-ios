import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The viewer's one player: what opens it, what pauses it, what throws it away.
///
/// A video is a PAGE of the pager now rather than a screen presented over it, so the answer to
/// "what is playing" moved into the paging. That is exactly the kind of rule that rots inside a
/// view body: it involves a real `AVPlayer`, an appearance, a scroll and a dismissal, and testing
/// it there means a simulator, a hosted window and a sleep long enough to hope. So the decision is
/// a pure function over the selection and the player, and these are its cases — no clock, no
/// device, no sleep. What the view is left with is making the real player match what it returns.
@Suite("Viewer playback")
struct MediaViewerPlaybackTests {
    /// photo, video, photo, video — so a swipe can be one page or three, and so "the page next
    /// door" and "two pages away" are both reachable from the same video.
    private static let attachments: [MemoAttachment] = [
        MediaViewerPageTests.image("p1"),
        MediaViewerPageTests.video("v1"),
        MediaViewerPageTests.image("p2"),
        MediaViewerPageTests.video("v2"),
    ]

    private func viewer(at uid: String) throws -> MediaViewerSelection {
        try #require(MediaViewerPresentation.viewer(for: Self.attachments, startingAt: uid))
    }

    /// The player as it is the instant a video page opens, for the tests that start from there.
    private func playingV1() throws -> (MediaViewerSelection, MediaViewerPlayback.Player) {
        let viewer = try viewer(at: "v1")
        let player = try #require(
            MediaViewerPlayback.player(after: .opened, player: nil, in: viewer)
        )
        return (viewer, player)
    }

    /// The requirement a poster page with a play button on it failed: a tap on a video means play
    /// it, and the viewer that opens on it is already playing when it gets there.
    @Test("a viewer opened on the video that was tapped is already playing")
    func openingOnAVideoPlays() throws {
        let viewer = try viewer(at: "v1")
        let player = try #require(
            MediaViewerPlayback.player(after: .opened, player: nil, in: viewer)
        )
        #expect(player.page == "v1")
        #expect(player.isPlaying, "the tapped video opened waiting to be asked a second time")
        #expect(player.url == viewer.startPage.playbackURL, "it played something else's stream")
    }

    /// The other half of it: opening is not a reason for the video NEXT DOOR to start. Nothing
    /// plays because it happens to be beside the picture somebody tapped.
    @Test("a viewer opened on a photo starts nothing, whatever it is sitting next to")
    func openingOnAPhotoPlaysNothing() throws {
        let viewer = try viewer(at: "p1")
        #expect(viewer.pages[1].kind == .video, "the fixture stopped having a video next door")
        #expect(MediaViewerPlayback.player(after: .opened, player: nil, in: viewer) == nil)
    }

    /// The reason a video may be a page at all: leaving it silences it. A player left running
    /// under the photo somebody swiped to is a voice from an empty room.
    @Test("swiping off a playing video pauses it")
    func swipingAwayPauses() throws {
        let (viewer, playing) = try playingV1()
        let after = try #require(
            MediaViewerPlayback.player(after: .paged(to: "p2"), player: playing, in: viewer)
        )
        #expect(!after.isPlaying, "the video went on playing after the pager left it")
        #expect(after.page == "v1", "the paused player stopped belonging to its own page")
    }

    /// Paused, not discarded — which is the whole difference between a swipe back that carries on
    /// and a swipe back that starts the download again. The pure half of "resume" is that the SAME
    /// player comes back rather than a new one; the position it resumes at belongs to the
    /// `AVPlayer` the view kept because of this.
    @Test("swiping back onto it resumes the same player rather than building another")
    func swipingBackResumes() throws {
        let (viewer, playing) = try playingV1()
        let paused = try #require(
            MediaViewerPlayback.player(after: .paged(to: "p2"), player: playing, in: viewer)
        )
        let resumed = try #require(
            MediaViewerPlayback.player(after: .paged(to: "v1"), player: paused, in: viewer)
        )
        #expect(resumed.isPlaying, "the video came back paused, with nothing to say so")
        #expect(resumed.page == paused.page, "coming back built a player for a different page")
        #expect(resumed.url == paused.url, "coming back built a player for a different stream")
    }

    /// The memory rule. A paused player is kept for one page — one swipe back — and no further:
    /// past that it is a signed URL held open for something nobody can reach in one gesture.
    @Test("a video two pages away is torn down, not held paused")
    func distantVideoIsEvicted() throws {
        let (viewer, playing) = try playingV1()
        let paused = try #require(
            MediaViewerPlayback.player(after: .paged(to: "p2"), player: playing, in: viewer)
        )
        #expect(
            MediaViewerPlayback.player(after: .paged(to: "v2"), player: paused, in: viewer) == nil,
            "a player was still held two pages behind the pager"
        )
    }

    /// Arriving at a video is not asking for it. The play control is what asks — see
    /// `MediaViewerPageTests`' companion rule that a swiped-to video keeps its poster.
    @Test("swiping onto a video does not start it")
    func swipingOntoAVideoStartsNothing() throws {
        let viewer = try viewer(at: "p1")
        #expect(MediaViewerPlayback.player(after: .paged(to: "v1"), player: nil, in: viewer) == nil)
    }

    /// One player, not one per video visited. Asking a second page to play REPLACES the first;
    /// the type cannot hold two, which is the point of it being a single optional value.
    @Test("asking a video page to play replaces whatever player there was")
    func playingReplacesTheOnePlayer() throws {
        let (viewer, playing) = try playingV1()
        let second = try #require(
            MediaViewerPlayback.player(after: .played(page: "v2"), player: playing, in: viewer)
        )
        #expect(second.page == "v2")
        #expect(second.isPlaying)
        #expect(second.url == viewer.pages[3].playbackURL)
    }

    /// A photo page has no play control, and the decision does not invent one: an event for a page
    /// with nothing to stream leaves the player exactly as it was.
    @Test("asking a photo page to play changes nothing")
    func playingAPhotoChangesNothing() throws {
        let (viewer, playing) = try playingV1()
        #expect(
            MediaViewerPlayback.player(after: .played(page: "p1"), player: playing, in: viewer)
                == playing
        )
    }

    /// The exit. Every way out of the viewer lands here, and none of them may leave a player
    /// behind — paused or otherwise.
    @Test("leaving the viewer tears the player down")
    func dismissTearsDown() throws {
        let (viewer, playing) = try playingV1()
        #expect(MediaViewerPlayback.player(after: .dismissed, player: playing, in: viewer) == nil)
        let paused = try #require(
            MediaViewerPlayback.player(after: .paged(to: "p2"), player: playing, in: viewer)
        )
        #expect(
            MediaViewerPlayback.player(after: .dismissed, player: paused, in: viewer) == nil,
            "a paused player survived the viewer it belonged to"
        )
    }

    /// A video whose streamable rendition the server has not produced yet is a poster and nothing
    /// else. There is no URL to build a player from, so neither opening on it nor tapping it
    /// produces one — rather than producing a player pointed at the original (ADR-0008).
    @Test("a video with no streamable rendition never becomes a player")
    func posterOnlyVideoNeverPlays() throws {
        let posterOnly = MemoAttachment(
            uid: "v9",
            mime: "video/quicktime",
            status: .ready,
            thumbnailURL: MediaViewerPageTests.url("v9", "thumb"),
            posterURL: MediaViewerPageTests.url("v9", "poster")
        )
        let viewer = try #require(
            MediaViewerPresentation.viewer(for: [posterOnly], startingAt: "v9")
        )
        #expect(viewer.startPage.kind == .video)
        #expect(viewer.startPage.playbackURL == nil, "the fixture grew a stream")
        #expect(MediaViewerPlayback.player(after: .opened, player: nil, in: viewer) == nil)
        #expect(
            MediaViewerPlayback.player(after: .played(page: "v9"), player: nil, in: viewer) == nil
        )
    }
}

/// What the viewer's playback asks of the device's audio session, as a rule about TRANSITIONS.
///
/// The defect these exist for is one the owner confirmed on a real phone: with the ringer switch
/// off, a memo's video played silently, because nothing ever told the system that this sound was
/// deliberate (MEMNG-183). The fix is a claim — and a claim is an event other apps hear, so the
/// interesting cases are all about when it must NOT be sent again: a video that keeps playing
/// while the pager moves under it, a paused player torn down, a picture looked at.
@Suite("Viewer audio session policy")
struct MediaViewerSessionCommandTests {
    private func player(_ page: String = "v1", playing: Bool) -> MediaViewerPlayback.Player {
        MediaViewerPlayback.Player(
            page: page,
            url: MediaViewerPageTests.url(page, "stream"),
            isPlaying: playing
        )
    }

    @Test("the first play takes the session")
    func firstPlayClaims() {
        #expect(
            MediaViewerPlayback.sessionCommand(from: nil, to: player(playing: true)) == .claim
        )
    }

    @Test("a player that goes on playing does not take it again")
    func playingOnAsksNothing() {
        let playing = player(playing: true)
        #expect(MediaViewerPlayback.sessionCommand(from: playing, to: playing) == nil)
        #expect(
            MediaViewerPlayback.sessionCommand(from: playing, to: player("v2", playing: true))
                == nil,
            "changing which video plays told every other app on the phone to stop, twice"
        )
    }

    @Test("pausing on the page next door gives it back")
    func pauseReleases() {
        let playing = player(playing: true)
        let paused = player(playing: false)
        #expect(MediaViewerPlayback.sessionCommand(from: playing, to: paused) == .release)
    }

    @Test("swiping back onto it takes it again")
    func resumeReclaims() {
        let paused = player(playing: false)
        let playing = player(playing: true)
        #expect(MediaViewerPlayback.sessionCommand(from: paused, to: playing) == .claim)
    }

    @Test("tearing a playing player down gives it back")
    func teardownReleases() {
        let playing = player(playing: true)
        #expect(MediaViewerPlayback.sessionCommand(from: playing, to: nil) == .release)
    }

    @Test("a paused player asks nothing on the way out — it gave the session back when it paused")
    func pausedTeardownAsksNothing() {
        #expect(MediaViewerPlayback.sessionCommand(from: player(playing: false), to: nil) == nil)
    }

    @Test("looking at pictures never touches the session")
    func picturesAskNothing() {
        #expect(MediaViewerPlayback.sessionCommand(from: nil, to: nil) == nil)
    }
}

/// A call, an alarm, or another app taking the session: what the viewer's player does about it.
///
/// The whole difficulty is the RESUME. The system's `.ended` says only "you may start again", and
/// a viewer that took that literally would start talking out of a page the pager left minutes ago
/// — so what a `.began` remembers is whether the player it paused was actually running.
@Suite("Viewer interruption policy")
struct MediaViewerInterruptionTests {
    private func player(playing: Bool) -> MediaViewerPlayback.Player {
        MediaViewerPlayback.Player(
            page: "v1",
            url: MediaViewerPageTests.url("v1", "stream"),
            isPlaying: playing
        )
    }

    @Test("a call pauses a running video and remembers that it was running")
    func beganPauses() {
        let outcome = MediaViewerPlayback.interrupted(
            .began,
            player: player(playing: true),
            resumable: false
        )
        #expect(outcome.player?.isPlaying == false)
        #expect(outcome.player?.page == "v1", "the interruption threw the player away")
        #expect(outcome.resumable)
    }

    @Test("a call over a paused video remembers nothing to resume")
    func beganOnPausedRemembersNothing() {
        let outcome = MediaViewerPlayback.interrupted(
            .began,
            player: player(playing: false),
            resumable: false
        )
        #expect(outcome.player?.isPlaying == false)
        #expect(!outcome.resumable)
    }

    @Test("the call ending resumes what it interrupted")
    func endedResumes() {
        let outcome = MediaViewerPlayback.interrupted(
            .ended(shouldResume: true),
            player: player(playing: false),
            resumable: true
        )
        #expect(outcome.player?.isPlaying == true)
        #expect(!outcome.resumable, "the memory outlived the interruption it belonged to")
    }

    @Test("a call ending without the system's blessing resumes nothing")
    func endedWithoutBlessing() {
        let outcome = MediaViewerPlayback.interrupted(
            .ended(shouldResume: false),
            player: player(playing: false),
            resumable: true
        )
        #expect(outcome.player?.isPlaying == false)
    }

    @Test("a call ending over a video the pager had already left resumes nothing")
    func endedOverAPausedPageResumesNothing() {
        let outcome = MediaViewerPlayback.interrupted(
            .ended(shouldResume: true),
            player: player(playing: false),
            resumable: false
        )
        #expect(
            outcome.player?.isPlaying == false,
            "a video started talking out of a page nobody was on"
        )
    }

    @Test("an interruption with no player at all is nothing")
    func noPlayer() {
        let outcome = MediaViewerPlayback.interrupted(.began, player: nil, resumable: false)
        #expect(outcome.player == nil)
        #expect(!outcome.resumable)
    }
}

/// Which clips restart themselves at their end (MEMNG-184).
@Suite("Viewer auto-loop threshold")
struct MediaViewerAutoLoopTests {
    @Test("the threshold is two minutes")
    func threshold() {
        #expect(MediaViewerPlayback.autoLoopMaximumDuration == .seconds(120))
    }

    @Test("a clip at the threshold loops and one a second past it does not")
    func atAndPastTheThreshold() {
        #expect(MediaViewerPlayback.shouldLoop(duration: .seconds(120)))
        #expect(MediaViewerPlayback.shouldLoop(duration: .seconds(3)))
        #expect(!MediaViewerPlayback.shouldLoop(duration: .seconds(121)))
        #expect(!MediaViewerPlayback.shouldLoop(duration: .seconds(600)))
    }

    @Test("a length nobody knows never loops")
    func unknownLength() {
        #expect(!MediaViewerPlayback.shouldLoop(duration: nil))
        #expect(
            !MediaViewerPlayback.shouldLoop(duration: .zero),
            "an item reporting nothing at all was treated as a very short clip"
        )
    }
}
