import AVFoundation
import Foundation
import SwiftUI
import Testing

@testable import MemosFeatures

/// The hardware, scripted.
///
/// It records what it was ASKED for — which is the half of the camera a test can hold, because the
/// decisions (which mode, which codec, whether the microphone is in it, what the shutter means) all
/// live above this line — and it delivers bytes on command, which is the other half.
@MainActor
final class StubCameraDevice: CameraDeviceControlling {
    private(set) var configurations: [Camera.Configuration] = []
    private(set) var photosAsked = 0
    private(set) var recordings: [URL] = []
    private(set) var stopsAsked = 0
    private(set) var stopped = 0
    /// What `start` throws, for the path where the device has nothing to offer.
    var refusal: CameraFailure?

    private var photo: (@MainActor (Result<Data, CameraFailure>) -> Void)?
    private var movie: (@MainActor (Result<URL, CameraFailure>) -> Void)?

    // Real hardware takes its time coming up, and the window between "start was asked for" and
    // "frames are flowing" is where a shutter must not be pressable. These two let a test hold
    // `start` open and stand inside that window.
    private var holdsStart = false
    private var hasEnteredStart = false
    private var startGate: CheckedContinuation<Void, Never>?
    private var startEntered: CheckedContinuation<Void, Never>?

    var previewSession: AVCaptureSession? { nil }

    /// `start` will not finish until `releaseStart()`.
    func holdStart() { holdsStart = true }

    func releaseStart() {
        holdsStart = false
        startGate?.resume()
        startGate = nil
    }

    /// Returns once `start` has been ENTERED — so a test can assert what is true while the device
    /// is still coming up, rather than racing it.
    func waitUntilStarting() async {
        if hasEnteredStart { return }
        await withCheckedContinuation { startEntered = $0 }
    }

    func start(_ configuration: Camera.Configuration) async throws {
        if let refusal { throw refusal }
        hasEnteredStart = true
        startEntered?.resume()
        startEntered = nil
        if holdsStart {
            await withCheckedContinuation { startGate = $0 }
        }
        configurations.append(configuration)
    }

    func stop() { stopped += 1 }
    func capturePhoto() { photosAsked += 1 }
    func startRecording(to url: URL) { recordings.append(url) }
    func stopRecording() { stopsAsked += 1 }

    func onPhoto(_ handler: @escaping @MainActor (Result<Data, CameraFailure>) -> Void) {
        photo = handler
    }

    func onMovie(_ handler: @escaping @MainActor (Result<URL, CameraFailure>) -> Void) {
        movie = handler
    }

    /// The device answering, as it does on a phone once the shutter has been pressed.
    func deliver(photo result: Result<Data, CameraFailure>) { photo?(result) }
    func deliver(movie result: Result<URL, CameraFailure>) { movie?(result) }
}

/// The two permission answers, as a test sets them.
@MainActor
final class StubCameraPermission: CameraPermitting {
    var camera: AVAuthorizationStatus = .authorized
    var microphone: AVAuthorizationStatus = .authorized
    /// What the system's own prompt answers, for a device nobody has been asked about yet.
    var grantsWhenAsked = true
    private(set) var prompted: [AVMediaType] = []

    func authorization(for media: AVMediaType) -> AVAuthorizationStatus {
        media == .audio ? microphone : camera
    }

    func requestAccess(for media: AVMediaType) async -> Bool {
        prompted.append(media)
        return grantsWhenAsked
    }
}

/// The in-app camera's logic, which is all of it except the frames.
///
/// The `AVCaptureSession` cannot run under `xcodebuild test` — a simulator has no camera — so every
/// assertion here is about what this app DOES: what it asks the hardware for, where the bytes go
/// when they arrive, and what happens on each of the answers a person or a device can give. The
/// real device (`AVCameraDevice`) holds no decisions for that reason, and the one thing that cannot
/// be checked here — that a physical camera actually produces HEVC — rides a TestFlight build.
@MainActor
@Suite("Camera capture")
struct CameraCaptureTests {
    static let taken = Date(timeIntervalSince1970: 1_787_926_530)

    /// One camera, its device and its permissions, and the list its captures land in.
    struct Rig {
        let capture: CameraCapture
        let device: StubCameraDevice
        let permission: StubCameraPermission
        let staged: Box<[PickedMedia]>
        let directory: URL
    }

    static func rig(
        permission: StubCameraPermission = StubCameraPermission()
    ) throws -> Rig {
        let directory = try CapturedMediaTests.scratch()
        let device = StubCameraDevice()
        let staged = Box<[PickedMedia]>([])
        let capture = CameraCapture(
            device: device,
            permission: permission,
            directory: directory,
            clock: { Self.taken },
            stage: { staged.value.append($0) }
        )
        return Rig(
            capture: capture,
            device: device,
            permission: permission,
            staged: staged,
            directory: directory
        )
    }

    // MARK: - the bytes

    @Test("a still the device delivers is staged from its own bytes and handed on")
    func aStillIsRoutedToTheStagingSeam() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()
        #expect(rig.capture.state == .ready)

        rig.capture.shutter()
        #expect(rig.device.photosAsked == 1)
        #expect(rig.device.recordings.isEmpty, "the photo shutter started a recording")

        let bytes = CapturedMediaTests.heif()
        rig.device.deliver(photo: .success(bytes))

        let media = try #require(rig.staged.value.first)
        let written = try Data(contentsOf: media.url)
        #expect(written == bytes, "\(written.count) bytes staged of the camera's \(bytes.count)")
        #expect(media.mime == "image/heic")
        #expect(media.filename.hasPrefix("IMG_"))
        #expect(rig.capture.stagedCount == 1)
        #expect(rig.capture.state == .ready)
    }

    @Test("a recording is staged by moving the file the device wrote")
    func aRecordingIsRoutedToTheStagingSeam() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()
        await rig.capture.choose(.video)

        rig.capture.shutter()
        let recording = try #require(rig.device.recordings.first)
        #expect(rig.capture.state == .recording)
        #expect(rig.device.photosAsked == 0, "the video shutter took a photo")

        // The device writing its file, which is the one thing a stub cannot do for itself.
        let bytes = CapturedMediaTests.movie()
        try bytes.write(to: recording)

        rig.capture.shutter()
        #expect(rig.device.stopsAsked == 1)
        #expect(rig.device.recordings.count == 1, "the second tap started a second recording")

        rig.device.deliver(movie: .success(recording))

        let media = try #require(rig.staged.value.first)
        let written = try Data(contentsOf: media.url)
        #expect(written == bytes)
        #expect(media.mime == "video/quicktime")
        #expect(
            !FileManager.default.fileExists(atPath: recording.path(percentEncoded: false)),
            "the recording was copied out rather than moved"
        )
        #expect(rig.capture.state == .ready)
    }

    /// The window a camera is at its most dangerous in: asked for, not yet running.
    ///
    /// `AVCaptureSession.startRunning()` blocks until frames are flowing, so the device's `start`
    /// is the only thing that knows when the camera is live. Publishing `.ready` off anything else
    /// — the call having been MADE rather than ANSWERED — puts a working-looking shutter in front
    /// of a session with nothing in it, and the photo silently never happens.
    @Test("the camera is not ready until the device says it is running")
    func readyWaitsForTheDeviceToFinishStarting() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        rig.device.holdStart()

        let starting = Task { await rig.capture.begin() }
        await rig.device.waitUntilStarting()

        #expect(
            rig.capture.state == .starting,
            "ready was published before the session was running"
        )
        // And the shutter really is inert in that window, rather than merely looking it.
        rig.capture.shutter()
        #expect(rig.device.photosAsked == 0, "the shutter fired into a session not yet running")

        rig.device.releaseStart()
        await starting.value

        #expect(rig.capture.state == .ready)
        // The control: the shutter works the moment the device has answered, so the assertion
        // above measured the window and not a camera that never becomes usable.
        rig.capture.shutter()
        #expect(rig.device.photosAsked == 1)
    }

    /// A mode switch reconfigures the session, so it must not happen under a capture that has not
    /// been answered: the answer would arrive against hardware that had moved on.
    @Test("the mode cannot be switched out from under a capture in flight")
    func theModeHoldsWhileACaptureIsInFlight() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()
        rig.capture.shutter()

        await rig.capture.choose(.video)

        #expect(rig.capture.mode == .photo, "the session was reconfigured under a capture")
        #expect(rig.device.configurations.count == 1)
    }

    // MARK: - one tap, one photograph

    /// The defect this holds shut: the shutter called `capturePhoto()` without leaving `.ready`,
    /// so a second tap before the photo output answered took a SECOND photograph. The screen
    /// closes on the first capture it stages, so that second one arrives after the screen is gone
    /// — attached to a memo nobody is looking at, and impossible to notice.
    @Test("a second tap before the first photo is answered does not take a second photograph")
    func theShutterTakesOnePhotographPerAnswer() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()

        rig.capture.shutter()
        rig.capture.shutter()
        rig.capture.shutter()

        #expect(rig.device.photosAsked == 1, "\(rig.device.photosAsked) photographs for one answer")
        #expect(rig.capture.state == .capturing)

        rig.device.deliver(photo: .success(CapturedMediaTests.heif()))

        #expect(rig.capture.stagedCount == 1)
        #expect(rig.staged.value.count == 1)
        // And the camera is usable again afterwards — the state left `.capturing` rather than
        // trading one defect for a shutter that only ever works once.
        #expect(rig.capture.state == .ready)
        rig.capture.shutter()
        #expect(rig.device.photosAsked == 2)
    }

    /// The other half of the same fix. A photograph the device could not deliver must not leave the
    /// shutter stuck down: the session is still running, and the obvious next thing to do is take
    /// another one.
    @Test("a still that fails to arrive leaves a camera somebody can press again")
    func aFailedStillReturnsTheShutter() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()
        rig.capture.shutter()

        rig.device.deliver(photo: .failure(CameraFailure("The camera was interrupted.")))

        #expect(rig.capture.state == .ready, "the shutter never came back")
        #expect(rig.capture.problem == "The camera was interrupted.")
        #expect(rig.staged.value.isEmpty)
        rig.capture.shutter()
        #expect(rig.device.photosAsked == 2)
        // Asking for a new one clears what was said about the last.
        #expect(rig.capture.problem == nil)
    }

    // MARK: - one answer per shutter press

    /// Lets whatever a delegate hopped to the main actor actually run. Yields rather than sleeps:
    /// the work is already enqueued here, so it needs a turn, not a delay.
    static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// The wedge this closes, and the reason it is worth a lock.
    ///
    /// A capture cut short before any photograph existed — the camera interrupted, the session torn
    /// down mid-shot — is reported by `AVCapturePhotoOutput` through the END of the capture and
    /// nothing else. With nothing routing that, the answer never comes: the screen stays
    /// `.capturing` for the rest of the session, its shutter dead and its mode switch refusing to
    /// run under a capture in flight. `aFailedStillReturnsTheShutter` above holds the other half —
    /// that such an answer puts the camera back to `.ready` with the reason on it.
    @Test("a capture cut short before any photograph answers as a failure")
    func anAbortedCaptureIsAnswered() async {
        let answers = Box<[Result<Data, CameraFailure>]>([])
        let delegate = PhotoDelegate { answers.value.append($0) }

        delegate.finishedCapture(error: CameraFailure("The session was interrupted."))
        await Self.settle()

        #expect(answers.value.count == 1, "the capture ended and nobody was ever told")
        guard case .failure(let failure) = answers.value.first else {
            Issue.record("an aborted capture did not answer with a failure")
            return
        }
        #expect(failure.reason == "The session was interrupted.")
    }

    /// The trap on the other side of that fix. The end-of-capture callback fires for EVERY capture,
    /// the successful ones included — so routing it without deduplicating answers twice for one
    /// shutter press, and the second answer is a failure arriving on top of a photograph that
    /// worked. Exactly one answer, and it is the photograph.
    @Test("a successful capture answers once, though both callbacks fire")
    func aSuccessfulCaptureAnswersOnce() async {
        let answers = Box<[Result<Data, CameraFailure>]>([])
        let delegate = PhotoDelegate { answers.value.append($0) }
        let bytes = CapturedMediaTests.heif()

        delegate.finishedProcessing(.success(bytes))
        delegate.finishedCapture(error: nil)
        delegate.finishedCapture(error: CameraFailure("and one that arrived even later"))
        await Self.settle()

        #expect(answers.value.count == 1, "one shutter press answered \(answers.value.count) times")
        guard case .success(let data) = answers.value.first else {
            Issue.record("a photograph that arrived was answered as a failure")
            return
        }
        #expect(data == bytes)
    }

    // MARK: - what the hardware is asked for

    @Test("the camera asks for HEVC, and for the microphone only when it is recording video")
    func theHardwareIsAskedForHEVC() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }

        await rig.capture.begin()
        let stills = try #require(rig.device.configurations.first)
        #expect(stills.mode == .photo)
        #expect(stills.stillCodec == .hevc, "the still was not asked for as HEVC, so not as HEIF")
        #expect(!stills.includesAudio, "a stills session asked for the microphone")
        #expect(
            !rig.permission.prompted.contains(.audio),
            "the microphone was asked for before anyone asked for video"
        )

        await rig.capture.choose(.video)
        let video = try #require(rig.device.configurations.last)
        #expect(video.mode == .video)
        #expect(video.movieCodec == .hevc)
        #expect(video.includesAudio)
        #expect(rig.capture.mode == .video)
    }

    @Test("choosing the mode that is already up does not restart the device")
    func choosingTheSameModeIsNothing() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()

        await rig.capture.choose(.photo)

        #expect(rig.device.configurations.count == 1)
    }

    // MARK: - the answers a person or a device can give

    @Test("a refused camera says so, and the device is never started")
    func aRefusedCameraStopsThere() async throws {
        let permission = StubCameraPermission()
        permission.camera = .denied
        let rig = try Self.rig(permission: permission)
        defer { CapturedMediaTests.discard(rig.directory) }

        await rig.capture.begin()

        #expect(rig.capture.state == .denied(.camera))
        #expect(rig.device.configurations.isEmpty, "the device was started without permission")
        // A refusal is not asked again: the system shows its prompt once, and a second request on
        // a refused device returns false without showing anything at all.
        #expect(rig.permission.prompted.isEmpty)
        // And the shutter does nothing, rather than asking hardware that was never configured.
        rig.capture.shutter()
        #expect(rig.device.photosAsked == 0)
    }

    @Test("a camera nobody has been asked about is asked about once")
    func anUndeterminedCameraIsAskedFor() async throws {
        let permission = StubCameraPermission()
        permission.camera = .notDetermined
        let rig = try Self.rig(permission: permission)
        defer { CapturedMediaTests.discard(rig.directory) }

        await rig.capture.begin()

        #expect(rig.permission.prompted == [.video])
        #expect(rig.capture.state == .ready)
    }

    @Test("a refused microphone records without sound rather than refusing the video")
    func aRefusedMicrophoneRecordsSilently() async throws {
        let permission = StubCameraPermission()
        permission.microphone = .denied
        let rig = try Self.rig(permission: permission)
        defer { CapturedMediaTests.discard(rig.directory) }

        await rig.capture.begin()
        await rig.capture.choose(.video)

        #expect(rig.capture.state == .ready, "a refused microphone refused the whole video")
        // And it is said out loud, because finding out on playback is finding out too late.
        #expect(rig.capture.notice == Camera.Words.silentRecording)
        let video = try #require(rig.device.configurations.last)
        #expect(!video.includesAudio)
    }

    @Test("a device that cannot start says why, and stays out of the way")
    func aDeviceThatRefusesSaysWhy() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        rig.device.refusal = CameraFailure("This device has no camera.")

        await rig.capture.begin()

        #expect(rig.capture.state == .failed("This device has no camera."))
        rig.capture.shutter()
        #expect(rig.device.photosAsked == 0)
    }

    @Test("bytes in a container this app does not know are refused, never re-encoded")
    func unrecognisedBytesAreRefusedRatherThanConverted() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()
        rig.capture.shutter()

        rig.device.deliver(photo: .success(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])))

        #expect(rig.staged.value.isEmpty, "bytes nobody could identify were attached anyway")
        #expect(rig.capture.stagedCount == 0)
        let reason = try #require(rig.capture.problem)
        #expect(reason.contains("re-encoded"), "the reason given was: \(reason)")
        // Refusing one photograph is not a broken camera: the session is still running, so the
        // shutter comes back rather than the screen becoming a dead end.
        #expect(rig.capture.state == .ready)
    }

    @Test("a recording that fails leaves a camera somebody can still use")
    func aFailedRecordingIsNotStuck() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()
        await rig.capture.choose(.video)
        rig.capture.shutter()
        rig.capture.shutter()

        rig.device.deliver(movie: .failure(CameraFailure("The disk is full.")))

        // Usable, and honest about the recording that was lost — the same rule the still path
        // follows, because they are the same seam and a camera that bricks on one bad delivery is
        // the defect either way.
        #expect(rig.capture.state == .ready)
        #expect(rig.capture.problem == "The disk is full.")
        #expect(rig.staged.value.isEmpty)
    }

    @Test("the device is stopped when the screen goes")
    func theDeviceIsStoppedOnTheWayOut() async throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }
        await rig.capture.begin()

        rig.capture.end()

        #expect(rig.device.stopped == 1)
        #expect(rig.capture.preview == nil)
    }

    // MARK: - the words, and the screen they are on

    @Test("every control on the camera says what it does")
    func theWordsSayWhatTheControlsDo() {
        #expect(Camera.Words.shutter(mode: .photo, isRecording: false) == "Take a photo")
        #expect(Camera.Words.shutter(mode: .video, isRecording: false) == "Start recording")
        // Once it is running, the shutter is the same thing in both modes: a way to stop.
        #expect(Camera.Words.shutter(mode: .photo, isRecording: true) == "Stop recording")
        #expect(Camera.Words.shutter(mode: .video, isRecording: true) == "Stop recording")
        // A refusal names the only place it can be undone.
        #expect(Camera.Words.denial(.camera).contains("Settings"))
        #expect(Camera.Words.silentRecording.contains("without sound"))
        // The failure sentence for bytes nobody could identify says what was NOT done to them.
        #expect(Camera.Words.failure(CaptureStagingError.unrecognisedStill).contains("re-encoded"))
        #expect(Camera.Words.failure(CameraFailure("The disk is full.")) == "The disk is full.")
    }

    /// The other half, on the real screen: every control is there, and every one of them is a thing
    /// VoiceOver can name. A camera whose shutter is an unlabelled circle is a camera one household
    /// member cannot use at all.
    @Test("the camera screen's controls are on it, and labelled")
    func theCameraScreenIsLabelled() throws {
        let rig = try Self.rig()
        defer { CapturedMediaTests.discard(rig.directory) }

        let labels = ScreenProbe.labels(of: CameraView(capture: rig.capture))

        #expect(labels.contains(Camera.Words.close), "no way out of the camera: \(labels)")
        #expect(labels.contains(Camera.Words.photoMode), "\(labels)")
        #expect(labels.contains(Camera.Words.videoMode), "\(labels)")
        #expect(
            labels.contains(Camera.Words.shutter(mode: .photo, isRecording: false)),
            "the shutter is not a labelled control: \(labels)"
        )
    }
}
