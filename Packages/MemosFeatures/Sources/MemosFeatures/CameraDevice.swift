import AVFoundation
import CoreGraphics
import Foundation
import os

/// A failure the capture hardware reported, flattened to something that can cross a queue.
///
/// `any Error` is not `Sendable` and these arrive on whatever queue AVFoundation chose, so the
/// reason is read where it lands and carried on as a value rather than as the error object.
nonisolated struct CameraFailure: LocalizedError, Sendable, Equatable {
    let reason: String

    var errorDescription: String? { reason }

    init(_ reason: String) {
        self.reason = reason
    }

    init(_ error: any Error) {
        self.reason = error.localizedDescription
    }
}

/// The system's answer about the camera and the microphone.
@MainActor
final class SystemCameraPermission: CameraPermitting {
    func authorization(for media: AVMediaType) -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: media)
    }

    func requestAccess(for media: AVMediaType) async -> Bool {
        await AVCaptureDevice.requestAccess(for: media)
    }
}

/// The capture session, and the queue its start and stop are made on.
///
/// `@unchecked Sendable` is deliberate and narrow. `AVCaptureSession.startRunning()` blocks until
/// the session is running and must not be called on the main thread, and this box is the only thing
/// in the app that touches the session from another queue — with nothing but those two calls.
/// Everything else (configuration, and the preview layer's attachment) happens on the main actor,
/// where the session is created and where it stays.
private nonisolated final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "live.discomarder.memosng.camera")

    /// Starts the session and returns WHEN IT IS RUNNING.
    ///
    /// The waiting is the point. `startRunning()` blocks until the session is live, which is why it
    /// is on this queue rather than the main actor — but a fire-and-forget `queue.async` then hands
    /// control back immediately, and the screen above published itself as ready while the session
    /// was still coming up. The shutter was tappable for that window, against a session with
    /// nothing flowing through it, which is a photo that silently never happens.
    ///
    /// A session that is already running takes the same trip through the queue rather than
    /// returning early: after a reconfigure the caller has to wait for whatever this queue is still
    /// doing, and "it was already running" is not the same as "it is running the thing you just
    /// asked for".
    func start() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

/// The real camera: an `AVCaptureSession` with one still output and one movie output.
///
/// It holds no rules. Which mode to be in, what permission that mode needs, what to do with the
/// bytes and what to say when something fails are all decided in `CameraCapture`, which a test can
/// run; this applies a configuration to hardware and hands back what the hardware produced. That
/// division is the point: a simulator has no camera, so anything decided in HERE is decided
/// somewhere the gate cannot reach.
///
/// The two outputs are the ones that do not re-encode. `AVCapturePhotoOutput` hands over a
/// `fileDataRepresentation()` — the encoder's own bytes, in their own container — and
/// `AVCaptureMovieFileOutput` writes a finished `.mov` to a path we give it. Neither of them is
/// `UIImagePickerController`, which returns a re-encoded JPEG for a still it was given as HEIF and
/// is the reason this screen exists at all.
@MainActor
final class AVCameraDevice: CameraDeviceControlling {
    private var box: CaptureSessionBox?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var configuration: Camera.Configuration?
    private var photoHandler: (@MainActor (Result<Data, CameraFailure>) -> Void)?
    private var movieHandler: (@MainActor (Result<URL, CameraFailure>) -> Void)?
    // Both outputs hold their delegate WEAKLY, so a delegate nobody else keeps is deallocated
    // between the shutter and the photo and the capture is delivered to nothing at all.
    private var photoDelegate: PhotoDelegate?
    private var movieDelegate: MovieDelegate?
    /// How the phone is being held, as the system works it out from the accelerometer and the
    /// camera's own mounting. Rebuilt with the session, because it answers for ONE device and a
    /// mode change puts a new input in.
    ///
    /// Built with no preview layer on purpose. The layer lives in the view, and it is only the
    /// coordinator's PREVIEW answer that is measured against one; the capture answer — the one
    /// stamped on a file — is a property of the device and the way the phone is held. The preview
    /// was never what was wrong here.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// The rule about which connection is stamped and when. It reads the coordinator through this
    /// closure at the moment of each capture, which is why nothing here observes it: there is no
    /// notification that could reach a movie connection in the middle of a file.
    private lazy var rotation = CaptureRotationStamp { [weak self] in
        guard let coordinator = self?.rotationCoordinator else { return nil }
        return CaptureRotation(
            preview: coordinator.videoRotationAngleForHorizonLevelPreview,
            capture: coordinator.videoRotationAngleForHorizonLevelCapture
        )
    }

    var previewSession: AVCaptureSession? { box?.session }

    func start(_ configuration: Camera.Configuration) async throws {
        let box = self.box ?? CaptureSessionBox()
        self.box = box
        let session = box.session
        session.beginConfiguration()
        // A mode change is a reconfiguration of the SAME session: video needs the microphone that
        // stills must not ask for, and the two outputs want different presets.
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = configuration.mode == .photo ? .photo : .high
        let camera: AVCaptureDevice
        do {
            camera = try add(.video, to: session)
            if configuration.includesAudio { try add(.audio, to: session) }
            let output: AVCaptureOutput =
                configuration.mode == .photo ? photoOutput : movieOutput
            guard session.canAddOutput(output) else {
                throw CameraFailure("This device cannot record in that mode.")
            }
            session.addOutput(output)
        } catch {
            // The session is left in one piece whatever happened: an unbalanced
            // `beginConfiguration` is a session that never runs again.
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        self.configuration = configuration
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(
            device: camera, previewLayer: nil
        )
        applyMovieCodec(configuration)
        // Awaited, so this method answers only once the session is actually running: everything
        // above treats a returned `start` as "the camera is live", and it has to be true.
        await box.start()
    }

    func stop() {
        box?.stop()
    }

    func capturePhoto() {
        // Before the shutter, not at configuration time: the phone may have been turned over since
        // the session came up, and the angle a still keeps is the one it was taken at.
        rotation.stampStill(on: rotatable(photoOutput))
        let delegate = PhotoDelegate { [weak self] result in self?.photoHandler?(result) }
        photoDelegate = delegate
        photoOutput.capturePhoto(with: stillSettings(), delegate: delegate)
    }

    func startRecording(to url: URL) {
        // At the start of the file and nowhere else. `isRecording` is the output's own answer
        // rather than a flag kept here, so a recording the hardware ended by itself cannot leave
        // this thinking a file is still open.
        rotation.stampRecording(
            on: rotatable(movieOutput), alreadyRecording: movieOutput.isRecording
        )
        let delegate = MovieDelegate { [weak self] result in self?.movieHandler?(result) }
        movieDelegate = delegate
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    func onPhoto(_ handler: @escaping @MainActor (Result<Data, CameraFailure>) -> Void) {
        photoHandler = handler
    }

    func onMovie(_ handler: @escaping @MainActor (Result<URL, CameraFailure>) -> Void) {
        movieHandler = handler
    }

    /// The output's video connection, behind the seam the rotation rule is written against. Nil
    /// before the session has committed a configuration, which is a capture nobody asked for yet.
    private func rotatable(_ output: AVCaptureOutput) -> (any CaptureConnection)? {
        guard let connection = output.connection(with: .video) else { return nil }
        return AVConnection(connection)
    }

    /// Returns the device it added, so the caller can build a rotation coordinator for the camera
    /// this session is actually using.
    @discardableResult
    private func add(_ media: AVMediaType, to session: AVCaptureSession) throws -> AVCaptureDevice {
        guard let device = AVCaptureDevice.default(for: media) else {
            throw CameraFailure(
                media == .video
                    ? "This device has no camera." : "This device has no microphone."
            )
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraFailure("The camera could not be opened.")
        }
        session.addInput(input)
        return device
    }

    /// HEVC for the recording, asked for only where the device offers it — a phone that cannot
    /// encode HEVC records in whatever it can, and a capture in the wrong codec is still a capture
    /// worth keeping. The available list is only populated once the output has a connection, which
    /// is why this runs after the configuration is committed rather than inside it.
    private func applyMovieCodec(_ configuration: Camera.Configuration) {
        guard configuration.mode == .video,
            let connection = movieOutput.connection(with: .video),
            movieOutput.availableVideoCodecTypes.contains(configuration.movieCodec)
        else { return }
        movieOutput.setOutputSettings(
            [AVVideoCodecKey: configuration.movieCodec], for: connection
        )
    }

    /// HEIF where the device offers it, and the device's own default where it does not. Nothing is
    /// converted either way: what `fileDataRepresentation()` answers with is what is written.
    private func stillSettings() -> AVCapturePhotoSettings {
        guard let codec = configuration?.stillCodec,
            photoOutput.availablePhotoCodecTypes.contains(codec)
        else { return AVCapturePhotoSettings() }
        return AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
    }
}

/// A real capture connection, behind `CaptureConnection`.
///
/// The whole AVFoundation half of the orientation fix, and it is three forwarding lines: this is
/// the only place in the app that names `videoRotationAngle`, and what to write there is decided
/// above it, where the gate can run it. Nothing here re-encodes anything — the angle is a
/// property of the connection the file is written THROUGH, so it reaches the file as container
/// metadata and the encoder's own bytes are untouched.
private final class AVConnection: CaptureConnection {
    private let connection: AVCaptureConnection

    init(_ connection: AVCaptureConnection) {
        self.connection = connection
    }

    func accepts(rotationAngle angle: CGFloat) -> Bool {
        connection.isVideoRotationAngleSupported(angle)
    }

    var rotationAngle: CGFloat {
        get { connection.videoRotationAngle }
        set { connection.videoRotationAngle = newValue }
    }
}

/// One still, delivered — once, whichever way the capture ends.
///
/// `nonisolated`: AVFoundation calls this back on a queue of its own choosing. The bytes are taken
/// out of the `AVCapturePhoto` THERE — the photo object cannot cross to the main actor and its file
/// representation can — and only the `Data` travels.
///
/// A capture reports through TWO callbacks and the difference between them is the whole reason this
/// class has a lock in it. The photograph arrives at `didFinishProcessingPhoto`; the END of the
/// capture arrives at `didFinishCaptureFor`, for every capture, successful ones included. A capture
/// cut short before any photograph existed — the camera interrupted, the session torn down mid-shot
/// — reports through the second and NOTHING else, so a delegate that implements only the first
/// leaves the screen waiting for an answer that is never coming: `.capturing` for the rest of the
/// session, with a dead shutter and a mode switch that refuses to run under a capture in flight.
///
/// So both roads lead here and exactly one of them may answer. The claim is made SYNCHRONOUSLY,
/// where the callback lands, rather than after the hop to the main actor: two hops have no
/// guaranteed order between them, and claiming there would let the end of a successful capture
/// report a failure for the photograph that had just succeeded.
nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let deliver: @MainActor @Sendable (Result<Data, CameraFailure>) -> Void
    private let oneAnswer = OSAllocatedUnfairLock(initialState: false)

    init(deliver: @escaping @MainActor @Sendable (Result<Data, CameraFailure>) -> Void) {
        self.deliver = deliver
    }

    /// The photo output answered: a photograph, or the reason there is not one.
    ///
    /// Separate from the callback because `AVCapturePhoto` cannot be built outside a camera, so
    /// this is the seam a test can reach — the routing and the one-answer rule are here, and the
    /// callback below is the adapter that extracts the bytes.
    func finishedProcessing(_ result: Result<Data, CameraFailure>) {
        hand(result)
    }

    /// The capture ENDED.
    ///
    /// On the ordinary path the photograph above has already answered and this is dropped. What it
    /// catches is the capture that ended without one; a nil error here means the capture finished
    /// and nobody said anything, which is the same wedge by another road.
    ///
    /// Separate from the callback for the same reason as above: `AVCaptureResolvedPhotoSettings`
    /// has no initialiser, so the callback carrying one cannot be called from a test.
    func finishedCapture(error: (any Error)?) {
        if let error {
            hand(.failure(CameraFailure(error)))
        } else {
            hand(.failure(CameraFailure("That photograph did not arrive.")))
        }
    }

    private func hand(_ result: Result<Data, CameraFailure>) {
        let isTheAnswer = oneAnswer.withLock { answered -> Bool in
            guard !answered else { return false }
            answered = true
            return true
        }
        guard isTheAnswer else { return }
        let deliver = self.deliver
        Task { @MainActor in deliver(result) }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        if let error {
            finishedProcessing(.failure(CameraFailure(error)))
        } else if let data = photo.fileDataRepresentation() {
            finishedProcessing(.success(data))
        } else {
            finishedProcessing(
                .failure(CameraFailure("The camera produced no file for that photo."))
            )
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        finishedCapture(error: error)
    }
}

/// One recording, delivered when its file is closed.
private nonisolated final class MovieDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let deliver: @MainActor @Sendable (Result<URL, CameraFailure>) -> Void

    init(deliver: @escaping @MainActor @Sendable (Result<URL, CameraFailure>) -> Void) {
        self.deliver = deliver
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        // An error here does not always mean there is nothing on disk: AVFoundation reports a
        // recording it stopped for its own reasons — the disk filling, the session interrupted —
        // with a flag saying the file it wrote is nonetheless finished and playable. Throwing that
        // away would lose a video that exists.
        let result: Result<URL, CameraFailure>
        if let error {
            let finished =
                (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
                ?? false
            result = finished ? .success(outputFileURL) : .failure(CameraFailure(error))
        } else {
            result = .success(outputFileURL)
        }
        let deliver = self.deliver
        Task { @MainActor in deliver(result) }
    }
}
