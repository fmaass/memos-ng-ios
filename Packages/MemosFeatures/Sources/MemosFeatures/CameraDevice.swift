import AVFoundation
import Foundation

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

    func start() {
        queue.async { [self] in
            if !session.isRunning { session.startRunning() }
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
        do {
            try add(.video, to: session)
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
        applyMovieCodec(configuration)
        box.start()
    }

    func stop() {
        box?.stop()
    }

    func capturePhoto() {
        let delegate = PhotoDelegate { [weak self] result in self?.photoHandler?(result) }
        photoDelegate = delegate
        photoOutput.capturePhoto(with: stillSettings(), delegate: delegate)
    }

    func startRecording(to url: URL) {
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

    private func add(_ media: AVMediaType, to session: AVCaptureSession) throws {
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

/// One still, delivered.
///
/// `nonisolated`: AVFoundation calls this back on a queue of its own choosing. The bytes are taken
/// out of the `AVCapturePhoto` THERE — the photo object cannot cross to the main actor and its file
/// representation can — and only the `Data` travels.
private nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let deliver: @MainActor @Sendable (Result<Data, CameraFailure>) -> Void

    init(deliver: @escaping @MainActor @Sendable (Result<Data, CameraFailure>) -> Void) {
        self.deliver = deliver
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        let result: Result<Data, CameraFailure>
        if let error {
            result = .failure(CameraFailure(error))
        } else if let data = photo.fileDataRepresentation() {
            result = .success(data)
        } else {
            result = .failure(CameraFailure("The camera produced no file for that photo."))
        }
        let deliver = self.deliver
        Task { @MainActor in deliver(result) }
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
