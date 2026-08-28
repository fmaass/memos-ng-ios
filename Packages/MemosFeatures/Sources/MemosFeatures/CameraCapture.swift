import AVFoundation
import Foundation
import Observation

/// The camera as a set of values, kept apart from the device that answers to them.
///
/// Everything a test can hold is in here: which mode the screen is in, what was asked of the
/// hardware, what went wrong, and every sentence the screen says. The AVFoundation session cannot
/// run under `xcodebuild test` — a simulator has no camera — so the split is not a nicety: it is
/// the difference between logic that is checked and logic that is looked at on a phone.
nonisolated public enum Camera {
    /// What the shutter does.
    public enum Mode: String, CaseIterable, Sendable, Equatable {
        case photo
        case video
    }

    /// Which device was refused. Neither can be un-refused from inside the app — only Settings
    /// can — so this is a thing to say, not a thing to retry.
    public enum Denial: String, Sendable, Equatable {
        case camera
        case microphone
    }

    /// What the screen is doing, as the one value it draws from.
    public enum State: Equatable {
        /// Asking for permission, or configuring the device — and, until the session is actually
        /// RUNNING, still this. A camera that says it is ready before frames are flowing is a
        /// shutter somebody can press into nothing.
        case starting
        case ready
        /// A still has been asked for and the photo output has not answered yet. It is its own
        /// state because the shutter must not fire twice into one answer: the screen closes on the
        /// first capture it stages, so a second one lands after the screen is gone — attached to a
        /// memo nobody is looking at any more.
        case capturing
        case recording
        case denied(Denial)
        /// The camera could not be brought up at all. Nothing here is retryable, which is what
        /// separates it from `problem`: one photograph that did not come off leaves a working
        /// camera, and this does not.
        case failed(String)
    }

    /// What the hardware is asked to produce.
    ///
    /// It is a value the MODEL builds and the device merely applies, which is what makes "the
    /// camera is asked for HEVC" an assertion rather than a line somebody reads in a file the gate
    /// cannot run. HEVC on both sides: a still lands in a HEIF container and a recording in an
    /// HEVC `.mov`, and both go to the server as the phone's own encoder wrote them — the original
    /// is the archive master (ADR-0008), so the phone's encoder is the only one that ever touches
    /// these bytes.
    public struct Configuration: Equatable {
        public var mode: Mode
        public var stillCodec: AVVideoCodecType
        public var movieCodec: AVVideoCodecType
        /// Whether the recording carries sound. False when the microphone was refused — a video
        /// with no sound is still the video somebody meant to take.
        public var includesAudio: Bool

        public init(
            mode: Mode,
            stillCodec: AVVideoCodecType = .hevc,
            movieCodec: AVVideoCodecType = .hevc,
            includesAudio: Bool
        ) {
            self.mode = mode
            self.stillCodec = stillCodec
            self.movieCodec = movieCodec
            self.includesAudio = includesAudio
        }
    }

    /// Everything the camera screen says, in one place, so a screen reader's version of it is held
    /// by a test rather than by whoever last edited the view.
    public enum Words {
        public static let close = "Close the camera"
        public static let photoMode = "Take photos"
        public static let videoMode = "Record video"

        public static func shutter(mode: Mode, isRecording: Bool) -> String {
            if isRecording { return "Stop recording" }
            return mode == .photo ? "Take a photo" : "Start recording"
        }

        public static func denial(_ denial: Denial) -> String {
            switch denial {
            case .camera:
                "Memos cannot use the camera. Turn it on for Memos in Settings and come back."
            case .microphone:
                "Memos cannot use the microphone."
            }
        }

        /// Said out loud rather than discovered afterwards: a recording made with the microphone
        /// refused is silent, and finding that out on playback is finding it out too late.
        public static let silentRecording =
            "The microphone is off for Memos, so this records without sound."

        /// What a failure says. Its own function so the sentences are held by a test.
        public static func failure(_ error: any Error) -> String {
            guard let staging = error as? CaptureStagingError else {
                return error.localizedDescription
            }
            switch staging {
            case .unrecognisedStill:
                return
                    "That photo came back in a format this app does not know, so nothing was"
                    + " attached — an original is never re-encoded to make it fit."
            case .recordingMissing:
                return
                    "The recording was not where the camera said it was, so nothing was attached."
            }
        }
    }
}

/// Whether this app may use the camera and the microphone.
///
/// A protocol because the answer is a device state a test cannot set, and because the interesting
/// behaviour is entirely in what the app DOES with each answer — asks once, says so and stops, or
/// carries on without sound.
@MainActor
protocol CameraPermitting: AnyObject {
    func authorization(for media: AVMediaType) -> AVAuthorizationStatus
    func requestAccess(for media: AVMediaType) async -> Bool
}

extension CameraPermitting {
    /// Whether this app may use that device now, asking once if it has never been asked.
    ///
    /// `.denied` and `.restricted` are not asked again: the system shows the prompt once per
    /// install, and a second `requestAccess` on a refused device returns false without showing
    /// anything at all — so a screen that retried would sit there looking like it was waiting.
    func ensure(_ media: AVMediaType) async -> Bool {
        switch authorization(for: media) {
        case .authorized: true
        case .notDetermined: await requestAccess(for: media)
        default: false
        }
    }
}

/// The capture hardware, as the little of it this app needs.
///
/// The bytes come back through the two handlers rather than as return values because that is how
/// AVFoundation delivers them — a still arrives at a delegate, a recording arrives when the file is
/// closed — and a seam that pretended otherwise would be testing a shape the real device does not
/// have.
@MainActor
protocol CameraDeviceControlling: AnyObject {
    /// The session a preview layer draws, once there is one. Nil before `start`, and always nil in
    /// a test — a stub has no session, and the screen draws its placeholder instead.
    var previewSession: AVCaptureSession? { get }
    /// Apply a configuration and begin. Throws when the device has nothing to offer.
    func start(_ configuration: Camera.Configuration) async throws
    func stop()
    /// Ask for one still. The bytes arrive at the photo handler.
    func capturePhoto()
    func startRecording(to url: URL)
    func stopRecording()
    /// `Data` here is `AVCapturePhoto.fileDataRepresentation()` and nothing else.
    func onPhoto(_ handler: @escaping @MainActor (Result<Data, CameraFailure>) -> Void)
    /// The file the movie output closed, at the path it was given.
    func onMovie(_ handler: @escaping @MainActor (Result<URL, CameraFailure>) -> Void)
}

/// Taking a photo or a video in the app, and putting it in the outbox unchanged.
///
/// This object is the whole of the camera's logic: what permission each mode needs, what the
/// hardware is asked for, what the shutter means in each mode and each state, and where the bytes
/// go when they arrive. What it deliberately does NOT do is touch a frame. A still is written from
/// the photo output's own `fileDataRepresentation()` and a recording is moved from where the movie
/// output wrote it (`PickedMedia.captured`), and from there both take the same road as a photo
/// picked from the library: `StagedSource` into `OutboxRepository.enqueue`, one queue, one
/// manifest, one chunked upload.
///
/// The audio session is deliberately left to AVFoundation. `AVCaptureSession` configures the app's
/// session itself while it runs and puts it back afterwards, and the one other claimant in this app
/// — the media viewer, which takes `.playback` for a video somebody opened
/// (`MediaViewerAudioSession`) — is a screen that cannot be up at the same time as this one. Two
/// pieces of code taking turns at the same session by hand is how the turns get missed; the
/// microphone input is added only in video mode, so a stills session never touches it at all.
@MainActor
@Observable
final class CameraCapture {
    private(set) var mode: Camera.Mode
    private(set) var state: Camera.State = .starting
    /// A standing condition of this session that the screen has to say out loud — today, that a
    /// recording will have no sound. It lasts as long as the session does.
    private(set) var notice: String?
    /// What went wrong with the LAST capture, if anything.
    ///
    /// Kept apart from both of its neighbours because it is neither of them. It is not `notice`,
    /// which is true of the whole session; and it is not `.failed`, which is a camera that never
    /// came up and stays unusable. A photo the device could not deliver, or bytes in a container
    /// this app will not rename, leaves the session running and the obvious next thing to do is
    /// take another one — so the shutter comes back and this says what happened to the last try.
    private(set) var problem: String?
    /// The session the preview draws, mirrored off the device once it is running so that the view
    /// redraws when it appears.
    private(set) var preview: AVCaptureSession?
    /// How many captures this screen has staged. The screen watches it so that a capture CLOSES the
    /// camera — one shot, attached, back to the memo — without this object having to know what a
    /// screen is, or a view having to guess from an attachment list it does not own.
    private(set) var stagedCount = 0

    private let device: any CameraDeviceControlling
    private let permission: any CameraPermitting
    /// Where a capture is staged. The app's temporary directory in production — the outbox copies
    /// what it is given into its own container, exactly as it does for the picker's export.
    private let directory: URL
    private let clock: () -> Date
    /// Where a staged capture goes: the compose sheet's attachment list.
    private let stage: @MainActor (PickedMedia) -> Void

    init(
        mode: Camera.Mode = .photo,
        device: any CameraDeviceControlling = AVCameraDevice(),
        permission: any CameraPermitting = SystemCameraPermission(),
        directory: URL = .temporaryDirectory,
        clock: @escaping () -> Date = Date.init,
        stage: @escaping @MainActor (PickedMedia) -> Void
    ) {
        self.mode = mode
        self.device = device
        self.permission = permission
        self.directory = directory
        self.clock = clock
        self.stage = stage
    }

    /// The screen appeared.
    func begin() async {
        await start(in: mode)
    }

    /// The screen went away. The session is stopped rather than left running behind whatever comes
    /// next: a camera that keeps its light on after its screen is gone is the kind of thing people
    /// notice and never trust again.
    func end() {
        device.stop()
        preview = nil
    }

    /// The person chose the other mode. It is a restart, because the two modes are different
    /// sessions — video needs the microphone, stills do not, and asking for the microphone before
    /// anyone has asked for video is a permission prompt nobody understands.
    /// Never while something is in flight: reconfiguring the session under a capture that has not
    /// been answered yet is how the answer arrives against hardware that has moved on.
    func choose(_ mode: Camera.Mode) async {
        guard mode != self.mode, state != .recording, state != .capturing else { return }
        await start(in: mode)
    }

    /// The shutter. In photo it takes one — one, however many times it is pressed before the photo
    /// output answers — and in video the first tap starts and the next stops.
    func shutter() {
        problem = nil
        switch state {
        case .ready where mode == .photo:
            device.capturePhoto()
            state = .capturing
        case .ready:
            device.startRecording(
                to: directory.appending(path: "recording-\(UUID().uuidString).mov")
            )
            state = .recording
        case .recording:
            device.stopRecording()
        case .starting, .capturing, .denied, .failed:
            break
        }
    }

    private func start(in mode: Camera.Mode) async {
        self.mode = mode
        state = .starting
        notice = nil
        problem = nil
        preview = nil
        guard await permission.ensure(.video) else {
            state = .denied(.camera)
            return
        }
        var sound = false
        if mode == .video {
            sound = await permission.ensure(.audio)
            if !sound { notice = Camera.Words.silentRecording }
        }
        do {
            try await device.start(
                Camera.Configuration(mode: mode, includesAudio: sound)
            )
            device.onPhoto { [weak self] result in self?.deliver(photo: result) }
            device.onMovie { [weak self] result in self?.deliver(movie: result) }
            preview = device.previewSession
            state = .ready
        } catch {
            state = .failed(Camera.Words.failure(error))
        }
    }

    /// The still's own bytes, staged. Nothing between the photo output and the file.
    ///
    /// The state leaves `.capturing` on BOTH outcomes, first thing: a delivery that failed must
    /// leave a camera somebody can press again, not one whose shutter never comes back.
    private func deliver(photo result: Result<Data, CameraFailure>) {
        state = .ready
        switch result {
        case .success(let data):
            keep { try PickedMedia.captured(photo: data, at: clock(), into: directory) }
        case .failure(let error):
            problem = Camera.Words.failure(error)
        }
    }

    /// The recording, staged by moving the file the movie output closed.
    ///
    /// Same discipline as the still, for the same reason: a recording that failed must not leave a
    /// camera stuck on "recording" with a stop button that does nothing.
    private func deliver(movie result: Result<URL, CameraFailure>) {
        state = .ready
        switch result {
        case .success(let url):
            keep { try PickedMedia.captured(movie: url, at: clock(), into: directory) }
        case .failure(let error):
            problem = Camera.Words.failure(error)
        }
    }

    /// Both callers have already returned the state to `.ready`; this only decides whether a
    /// capture was added or a reason was given.
    private func keep(_ staging: () throws -> PickedMedia) {
        do {
            let media = try staging()
            stagedCount += 1
            stage(media)
        } catch {
            problem = Camera.Words.failure(error)
        }
    }
}
