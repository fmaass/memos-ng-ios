import AVFoundation
import SwiftUI
import UIKit

/// Taking a photo or a video without leaving the memo you are writing.
///
/// It is deliberately the smallest camera that can exist: a picture, two modes, a shutter and a way
/// out. Everything a phone's own camera does better than this — focus, exposure, the flash, the
/// front lens — is a reason to use the phone's own camera and share the result in, which is a road
/// that already works. What this screen is for is the one thing that road does not do: putting the
/// encoder's own bytes into the outbox with nothing in between.
///
/// The `AVCaptureSession` behind it cannot run under `xcodebuild test` — a simulator has no camera.
/// So the screen holds no rules: what the shutter means, what each permission answer leads to and
/// where the bytes go are all in `CameraCapture`, which the gate runs against a stub, and what is
/// left here is a layout and the words on it (`Camera.Words`, held by their own tests).
struct CameraView: View {
    /// Handed in rather than built here so a test can drive the screen with a stubbed device. The
    /// `@State` is what keeps ONE of them: a `fullScreenCover`'s content closure is re-evaluated
    /// whenever the sheet behind it redraws, and only the first value is kept.
    @State private var capture: CameraCapture

    @Environment(\.dismiss) private var dismiss

    init(capture: CameraCapture) {
        _capture = State(initialValue: capture)
    }

    var body: some View {
        ZStack {
            Color.black
            CameraPreview(session: capture.preview)
            VStack(spacing: DesignTokens.Space.regular) {
                top
                Spacer()
                message
                Spacer()
                controls
            }
            .padding(DesignTokens.Space.regular)
        }
        .ignoresSafeArea(edges: .bottom)
        .task { await capture.begin() }
        // One capture closes the screen: it is attached, and the memo is what somebody was in the
        // middle of writing.
        .onChange(of: capture.stagedCount) { _, _ in dismiss() }
        .onDisappear { capture.end() }
    }

    private var top: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.4), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Camera.Words.close)
            Spacer()
        }
        .foregroundStyle(.white)
    }

    /// What the screen has to say: a refusal, a camera that never came up, or — on one that is
    /// working — the last capture that did not come off, and otherwise the standing condition of
    /// the session. The last try comes first: it is the thing that just happened.
    @ViewBuilder
    private var message: some View {
        switch capture.state {
        case .denied(let denial):
            note(Camera.Words.denial(denial))
        case .failed(let reason):
            note(reason)
        case .starting, .ready, .capturing, .recording:
            if let said = capture.problem ?? capture.notice { note(said) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(DesignTokens.Space.regular)
            .background(.black.opacity(0.5), in: .rect(cornerRadius: DesignTokens.Radius.tile))
    }

    private var controls: some View {
        VStack(spacing: DesignTokens.Space.regular) {
            HStack(spacing: DesignTokens.Space.snug) {
                modeButton(.photo, saying: Camera.Words.photoMode)
                modeButton(.video, saying: Camera.Words.videoMode)
            }
            shutter
        }
    }

    private func modeButton(_ mode: Camera.Mode, saying words: String) -> some View {
        Button {
            Task { await capture.choose(mode) }
        } label: {
            Text(words)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, DesignTokens.Space.regular)
                .padding(.vertical, DesignTokens.Space.snug)
                .background(
                    capture.mode == mode ? Color.white.opacity(0.25) : Color.clear, in: .capsule
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(words)
        .accessibilityAddTraits(capture.mode == mode ? [.isSelected] : [])
    }

    /// One button that says three different things, and never moves while it changes: a still to
    /// take, a recording to start, a recording to stop.
    private var shutter: some View {
        Button {
            capture.shutter()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                if capture.state == .recording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(capture.mode == .photo ? Color.white : Color.red)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(capture.state != .ready && capture.state != .recording)
        .accessibilityLabel(
            Camera.Words.shutter(mode: capture.mode, isRecording: capture.state == .recording)
        )
    }
}

/// The live picture, which is a `CALayer` and therefore the one piece of UIKit on this screen.
///
/// `AVCaptureVideoPreviewLayer` is attached as the view's OWN layer rather than as a sublayer, so
/// it is resized by the view system instead of by a `layoutSubviews` that has to remember to.
struct CameraPreview: UIViewRepresentable {
    /// Nil until the session is running — and always nil in a test, where the device is a stub with
    /// no session at all and this draws nothing over the black behind it.
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView {
        PreviewView()
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.attach(session)
    }

    final class PreviewView: UIView {
        // `nonisolated` deliberately: UIKit asks a view class for its layer class before there is
        // an instance, and an override may be less isolated than what it overrides but never more.
        nonisolated override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        func attach(_ session: AVCaptureSession?) {
            guard let preview = layer as? AVCaptureVideoPreviewLayer else { return }
            preview.videoGravity = .resizeAspectFill
            if preview.session !== session { preview.session = session }
        }
    }
}
