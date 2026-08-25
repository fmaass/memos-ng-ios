import AVKit
import SwiftUI

/// The playing half of a video PAGE of the media viewer.
///
/// It is a layer inside the pager, not a screen over it. It used to be the latter — a
/// `fullScreenCover` presented above the viewer — and that is exactly what made a memo's other
/// attachments unreachable the moment a video started: the pager was still there, underneath a
/// cover nothing could swipe. So the player draws where the poster would have been, and the swipe
/// that turns the page is the pager's, unchanged.
///
/// The `AVPlayer` is not created here. The viewer owns the one player there is and hands it to
/// whichever page it belongs to (`MediaViewerPlayback`), so a page cannot outlive it, duplicate it
/// or keep it running off screen.
struct VideoPlayerLayer: View {
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
    }
}
