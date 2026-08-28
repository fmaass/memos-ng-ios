import CoreGraphics
import Foundation
import Testing

@testable import MemosFeatures

/// A capture connection, scripted: it says which angles it will take and remembers every one it was
/// given.
///
/// `AVCaptureConnection` has no initialiser reachable from a test and a simulator has no camera to
/// produce one, so this is the shape the rotation rule is written against. It records SETS rather
/// than changes — a connection written with the angle it already had is still a connection that was
/// written, and the difference matters for "how many times was this stamped".
@MainActor
final class StubCaptureConnection: CaptureConnection {
    /// The angles this connection will take. Nil is a connection that takes anything, which is what
    /// a phone's own camera does for the four quarter turns.
    var accepted: Set<CGFloat>?
    private(set) var stamps: [CGFloat] = []

    /// Starts at the angle the sensor is mounted at, which is what a connection nobody has stamped
    /// carries — and is the defect, when the phone is not being held that way.
    var rotationAngle: CGFloat = 90 {
        didSet { stamps.append(rotationAngle) }
    }

    func accepts(rotationAngle angle: CGFloat) -> Bool {
        accepted?.contains(angle) ?? true
    }
}

/// What a capture is stamped with, and when.
///
/// The defect these hold shut: nothing set a rotation angle on the photo or the movie connection at
/// all, so a capture taken with the phone held any way but the sensor's own was written sideways —
/// while the preview, which is rotated for the screen by its own layer, looked perfectly upright the
/// whole time. Nobody sees it until the file is opened again.
///
/// None of this can be asserted on the real objects: `AVCaptureConnection` and
/// `AVCaptureDevice.RotationCoordinator` are both hardware, and `xcodebuild test` runs on a
/// simulator that has no camera. So the decision lives above the seam, here, and what is left on the
/// AVFoundation side is a coordinator read and three forwarding lines.
@MainActor
@Suite("Capture rotation")
struct CaptureRotationTests {
    /// The four quarter turns a rotation coordinator answers with. Which physical way of holding the
    /// phone produces which of them is the coordinator's business — it works that out from the
    /// accelerometer and the camera's mounting, and this app's job is only to carry its answer
    /// through unchanged.
    static let quarterTurns: [CGFloat] = [0, 90, 180, 270]

    @Test("a capture is stamped with the angle a CAPTURE wants, never the preview's")
    func theCaptureAngleIsTheOneThatLands() {
        let connection = StubCaptureConnection()
        let stamp = CaptureRotationStamp { CaptureRotation(preview: 0, capture: 180) }

        stamp.stampStill(on: connection)

        #expect(connection.stamps == [180], "the preview's angle was written to a capture")
        // And the decision itself, without a connection in the way.
        #expect(
            CaptureRotationStamp.angle(
                for: CaptureRotation(preview: 270, capture: 90),
                accepting: { _ in true }
            ) == 90
        )
    }

    @Test("every quarter turn the coordinator reports is what lands on the connection")
    func everyQuarterTurnIsCarriedThrough() {
        for turn in Self.quarterTurns {
            let connection = StubCaptureConnection()
            // The preview is deliberately a DIFFERENT quarter turn, so a stamp that took the wrong
            // one of the two cannot pass by landing on the same number.
            let other = (turn + 90).truncatingRemainder(dividingBy: 360)
            let stamp = CaptureRotationStamp {
                CaptureRotation(preview: other, capture: turn)
            }

            stamp.stampStill(on: connection)

            #expect(connection.stamps == [turn], "\(turn)° was written as \(connection.stamps)")
        }
    }

    /// Setting an angle a connection does not support raises, and a photograph is not worth a crash:
    /// the capture happens at whatever angle the connection already carried.
    @Test("an angle the connection will not take is left alone rather than forced onto it")
    func anUnsupportedAngleIsNotWritten() {
        let connection = StubCaptureConnection()
        connection.accepted = [90]
        let sideways = CaptureRotationStamp { CaptureRotation(preview: 90, capture: 180) }

        sideways.stampStill(on: connection)
        sideways.stampRecording(on: connection, alreadyRecording: false)

        #expect(connection.stamps.isEmpty, "an angle the connection refuses was written anyway")
        #expect(connection.rotationAngle == 90, "the connection's own angle was overwritten")
        // The control: the angle it DOES take still lands, so the assertions above measured the
        // refusal and not a stamp that never works.
        let upright = CaptureRotationStamp { CaptureRotation(preview: 180, capture: 90) }
        upright.stampStill(on: connection)
        #expect(connection.stamps == [90])
    }

    /// Before the session has committed a configuration there is no coordinator and no connection.
    /// Neither is a reason to fail a capture — both are a capture that keeps the default.
    @Test("a capture with nothing to read and nothing to stamp is left as it is")
    func nothingToStampIsNotAFailure() {
        let connection = StubCaptureConnection()
        let unknown = CaptureRotationStamp { nil }

        unknown.stampStill(on: connection)
        unknown.stampRecording(on: connection, alreadyRecording: false)
        #expect(connection.stamps.isEmpty, "an unknown rotation was written as an angle")

        let known = CaptureRotationStamp { CaptureRotation(preview: 0, capture: 270) }
        known.stampStill(on: nil)
        known.stampRecording(on: nil, alreadyRecording: false)
        // The control: with something to read and something to stamp, it stamps.
        known.stampStill(on: connection)
        #expect(connection.stamps == [270])
    }

    /// The phone can be turned over between two photographs, and the second one has to be written
    /// the way it was taken. Reading the angle when the session was configured would give both
    /// stills the orientation of whichever way the phone happened to be held when the camera opened.
    @Test("each still is stamped with the angle the phone is at when the shutter is pressed")
    func aStillIsStampedAtTheShutter() {
        let connection = StubCaptureConnection()
        let held = Box<CGFloat>(90)
        let stamp = CaptureRotationStamp { CaptureRotation(preview: 0, capture: held.value) }

        stamp.stampStill(on: connection)
        held.value = 180
        stamp.stampStill(on: connection)

        #expect(
            connection.stamps == [90, 180],
            "a still was stamped with an angle read before the shutter: \(connection.stamps)"
        )
    }

    /// One recording, one orientation. A `.mov` carries its rotation once, in the container, so a
    /// second stamp part-way through does not turn the file — it changes what the remaining frames
    /// claim to be, which is worse than either answer on its own.
    @Test("a recording carries one angle for the whole file, whatever the phone does mid-take")
    func aRecordingIsStampedOnceAtItsStart() {
        let connection = StubCaptureConnection()
        let held = Box<CGFloat>(90)
        let stamp = CaptureRotationStamp { CaptureRotation(preview: 0, capture: held.value) }

        stamp.stampRecording(on: connection, alreadyRecording: false)
        // The phone turned over while the file was open.
        held.value = 180
        stamp.stampRecording(on: connection, alreadyRecording: true)

        #expect(
            connection.stamps == [90],
            "the movie connection was re-stamped mid-file: \(connection.stamps)"
        )

        // The control: the NEXT recording is a new file, and it does take the angle the phone is at
        // now — so the assertion above measured "one angle per recording" and not a stamp that
        // stopped working after the first.
        stamp.stampRecording(on: connection, alreadyRecording: false)
        #expect(connection.stamps == [90, 180])
    }
}
