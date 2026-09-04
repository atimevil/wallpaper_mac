import CoreGraphics
import Foundation

/// .tex에서 꺼낸 결과. 세 가지 중 하나다.
public enum TextureData: Sendable {
    /// JPEG/PNG를 ImageIO로 디코딩한 것.
    case image(CGImage)
    /// 원시 픽셀. LZ4였다면 이미 풀린 상태다.
    case pixels(bytes: Data, width: Int, height: Int, format: TexPixelFormat)
    /// MP4 파일 바이트 그대로. AVFoundation이 읽는다.
    case video(Data)
}
