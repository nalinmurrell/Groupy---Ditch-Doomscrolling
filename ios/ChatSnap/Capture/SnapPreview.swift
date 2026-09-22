import AVFoundation
import SwiftUI

/// What was just captured, filling the screen: a still, or a clip that
/// loops with sound.
struct SnapPreview: View {
    let snap: Snap

    var body: some View {
        // Fill from a screen-sized base and clip, otherwise the media widens
        // the whole ZStack and pushes the corner buttons off the edges.
        Color.clear
            .overlay {
                switch snap.media {
                case .photo(let image):
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                case .video(let url):
                    LoopingVideo(url: url)
                }
            }
            .clipped()
            .ignoresSafeArea()
    }
}

/// An AVPlayerLayer that fills its view and loops forever.
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = gravity
        view.play(url)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.url != url { uiView.play(url) }
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        private(set) var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func play(_ url: URL) {
            self.url = url
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            looper = AVPlayerLooper(player: player, templateItem: item)
            self.player = player
            playerLayer.player = player
            player.play()
        }

        func stop() {
            player?.pause()
            looper = nil
            player = nil
            playerLayer.player = nil
        }
    }
}
