import AVFoundation
import CoreVideo
import Metal
import Foundation

enum VideoTextureError: Error {
    case cacheCreationFailed
    case temporaryFileFailed(String)
    case assetNotPlayable
}

/// .tex 안에 들어 있던 MP4를 재생하며 프레임마다 Metal 텍스처를 내놓는다.
///
/// 검증된 사실 두 가지가 이 구현을 규정한다.
///
/// 1) AVPlayerItemVideoOutput → copyPixelBuffer → CVMetalTextureCache 경로는 동작한다.
///    3200x1800 H.264에서 MTLTexture 생성을 확인했다.
/// 2) **AVPlayerLooper와 함께 쓸 수 없다.** 루퍼는 템플릿 아이템의 복사본을
///    재생하므로 템플릿에 붙인 출력은 프레임을 한 장도 받지 못한다. 실측에서
///    0프레임이었다. 그래서 루프는 didPlayToEndTime 알림에서 되감아 처리한다.
@MainActor
final class VideoTexture {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let cache: CVMetalTextureCache
    private let temporaryURL: URL
    /// CVMetalTexture를 살려둬야 그것이 감싼 MTLTexture가 유효하다.
    private var retainedFrame: CVMetalTexture?
    private var endObserver: NSObjectProtocol?

    private(set) var isPlaying = false

    init(mp4: Data, device: MTLDevice) throws {
        // AVAsset은 URL을 요구한다. 메모리에서 직접 읽으려면
        // AVAssetResourceLoaderDelegate가 필요한데, M3는 단순한 임시 파일로 간다.
        // 226MB짜리가 있으므로 M4 이후 리소스 로더로 바꿀 여지를 남긴다.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-video-\(UUID().uuidString).mp4")
        do {
            try mp4.write(to: url, options: .atomic)
        } catch {
            throw VideoTextureError.temporaryFileFailed("\(error)")
        }
        temporaryURL = url

        var created: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &created) == kCVReturnSuccess,
              let cache = created else {
            try? FileManager.default.removeItem(at: url)
            throw VideoTextureError.cacheCreationFailed
        }
        self.cache = cache

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)

        player = AVPlayer(playerItem: item)
        player.isMuted = true          // 배경화면은 소리를 내지 않는다
        player.actionAtItemEnd = .none

        // 루퍼를 쓸 수 없으므로 끝에서 되감는다.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            MainActor.assumeIsolated {
                player?.seek(to: .zero)
                player?.play()
            }
        }
    }

    @MainActor
    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.pause()
        isPlaying = false
        retainedFrame = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    /// 지금 보여줄 프레임. 새 프레임이 없으면 직전 것을 그대로 돌려준다.
    func currentTexture() -> MTLTexture? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else {
            return retainedFrame.flatMap(CVMetalTextureGetTexture)
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var created: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &created)
        guard result == kCVReturnSuccess, let created else {
            return retainedFrame.flatMap(CVMetalTextureGetTexture)
        }
        retainedFrame = created
        return CVMetalTextureGetTexture(created)
    }
}
