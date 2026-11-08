import AppKit
import AVFoundation

/// 로컬 영상의 첫 프레임을 `preview.jpg`로 구워 라이브러리 미리보기에 쓴다.
///
/// AVFoundation은 Kit 경계 밖이라 App 계층에 둔다. **실패하면 조용히 넘어간다** —
/// webm처럼 AVFoundation이 못 여는 포맷은 미리보기 없이도 목록에 뜬다
/// (`WallpaperItem.load`가 preview 없음을 허용한다).
enum LocalVideoThumbnail {
    static func generate(forVideoAt videoURL: URL, into directory: URL) {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        // 맨 앞(0초)은 페이드인으로 검을 때가 있어 0.5초 지점을 쓴다.
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? data.write(to: directory.appendingPathComponent("preview.jpg"))
    }
}
