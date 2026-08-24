import AVKit
import MemosCore
import SwiftUI

/// The full-screen playback of one video attachment's streamable rendition.
///
/// The player is created for exactly one URL and torn down on dismiss — a shared player kept
/// warm would go on buffering a signed URL after its signature lapsed.
struct VideoPlayback: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct VideoPlayerView: View {
    let playback: VideoPlayback
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding()
            }
            .accessibilityLabel("Close")
        }
        .task {
            let player = AVPlayer(url: playback.url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}
