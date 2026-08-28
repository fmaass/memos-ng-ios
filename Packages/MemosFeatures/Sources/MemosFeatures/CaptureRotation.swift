import CoreGraphics
import Foundation

/// How the phone is being held, as the system's rotation coordinator answers it.
///
/// Two angles, and they are not interchangeable. `preview` is what the layer showing the live
/// picture wants; `capture` is what the connection the FILE is written through wants, and on a phone
/// held sideways they are different numbers. Reaching for the wrong one is exactly the defect this
/// type exists to make visible: the screen looks right — the preview never was wrong — and the file
/// that lands in the outbox is on its side.
nonisolated struct CaptureRotation: Equatable, Sendable {
    /// What the live picture wants. Nothing here writes it: the preview layer was already correct
    /// and is left alone. It is carried so that the choice between the two angles is made inside a
    /// function the gate can run, rather than at a call site on hardware it cannot reach.
    let preview: CGFloat
    /// What a still or a recording wants — the angle stamped on the output connection.
    let capture: CGFloat

    init(preview: CGFloat, capture: CGFloat) {
        self.preview = preview
        self.capture = capture
    }
}

/// A capture output's connection, as the two things a rotation needs from it.
///
/// `AVCaptureConnection` cannot be built outside a running session and a simulator has no camera, so
/// without this seam the whole rule would live somewhere the gate cannot execute. The real
/// connection reaches it through a two-line adapter in `CameraDevice.swift`.
@MainActor
protocol CaptureConnection: AnyObject {
    /// Whether the connection will take that angle. Asked every time rather than assumed: setting
    /// an angle a connection does not support raises, and a photograph is not worth a crash.
    func accepts(rotationAngle angle: CGFloat) -> Bool
    var rotationAngle: CGFloat { get set }
}

/// Which connection a capture's rotation is stamped on, and when.
///
/// This is the whole of the fix, kept on the side of the seam a test can drive. Without it a still
/// or a recording is written at whatever angle the sensor is mounted at, however the phone was being
/// held — the preview is rotated for the screen by its own layer, so the picture looks upright right
/// up until the file is opened again.
///
/// The angle is PULLED at the moment of the capture rather than pushed at this object as the phone
/// turns. That is deliberate and it is what makes "one angle per recording" true by construction
/// rather than by a flag: nothing observes the coordinator, so there is nothing that could reach a
/// movie connection in the middle of a file.
@MainActor
struct CaptureRotationStamp {
    /// How the phone is being held, right now. A closure and not a value because WHEN it is read is
    /// the point: a still is stamped with the angle the phone is at when the shutter is pressed,
    /// not the one it was at when the session was configured.
    private let rotation: @MainActor () -> CaptureRotation?

    init(rotation: @escaping @MainActor () -> CaptureRotation?) {
        self.rotation = rotation
    }

    /// The angle to write on a capture connection, or nil for "leave it as it is".
    ///
    /// Two ways to answer nil and both of them are a capture that still happens, carrying whatever
    /// angle the connection already had: a session whose coordinator does not exist yet, and a
    /// connection that will not take the angle asked for.
    static func angle(
        for rotation: CaptureRotation?,
        accepting accepts: (CGFloat) -> Bool
    ) -> CGFloat? {
        guard let rotation, accepts(rotation.capture) else { return nil }
        return rotation.capture
    }

    /// A still is about to be taken. Every one of them is stamped, because between two photographs
    /// the phone may have been turned over.
    func stampStill(on connection: (any CaptureConnection)?) {
        apply(to: connection)
    }

    /// A recording is about to start.
    ///
    /// A recording that is ALREADY running is left alone. One `.mov` carries one orientation in its
    /// container metadata, so a second stamp part-way through does not rotate the file — it changes
    /// what the rest of the frames claim to be, which is worse than either answer on its own.
    func stampRecording(on connection: (any CaptureConnection)?, alreadyRecording: Bool) {
        guard !alreadyRecording else { return }
        apply(to: connection)
    }

    private func apply(to connection: (any CaptureConnection)?) {
        guard let connection else { return }
        let wanted = Self.angle(for: rotation()) { connection.accepts(rotationAngle: $0) }
        guard let wanted else { return }
        connection.rotationAngle = wanted
    }
}
