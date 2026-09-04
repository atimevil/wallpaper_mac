import AppKit
import AVFoundation
import WallflowKit

/// mp4/mov 배경화면을 무한 루프로 재생한다.
/// AVPlayerLooper 대신 rate=0 감지 후 seek을 쓰지 않고, 끝 알림에서 되감는다.
final class VideoRenderer: WallpaperRenderer {
    private let item: WallpaperItem
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(item: WallpaperItem) {
        self.item = item
    }

    func makeView() -> NSView {
        PlayerLayerView(player: player)
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: item.contentURL.path) else {
            throw RendererError.contentMissing(item.contentURL)
        }
        let asset = AVURLAsset(url: item.contentURL)
        let template = AVPlayerItem(asset: asset)
        // AVPlayerLooper가 큐를 관리해 이음매 없는 반복을 만든다.
        looper = AVPlayerLooper(player: player, templateItem: template)
        player.isMuted = true              // 배경화면이 소리를 내면 안 된다
        player.actionAtItemEnd = .advance
        player.play()
    }

    func apply(_ directive: PlaybackDirective) {
        switch directive {
        case .paused:
            player.pause()
        case .playing:
            // 비디오는 소스 자체의 프레임레이트로 디코딩된다.
            // 임의로 낮추면 재생이 끊기므로 fps는 무시하고 재생/정지만 따른다.
            // 전력 절감은 정지 조건이 담당한다.
            if player.rate == 0 { player.play() }
        }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
    }
}

/// AVPlayerLayer를 담는 뷰. 화면을 꽉 채우도록 잘라 맞춘다.
private final class PlayerLayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill   // 여백 없이 채운다
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
