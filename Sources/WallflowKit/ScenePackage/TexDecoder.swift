import Compression
import CoreGraphics
import Foundation
import ImageIO

/// .tex를 실제로 디코딩한다.
/// 밉맵 체인이 있어도 0번(최대 해상도)만 쓴다. 화면을 채우는 것이 목적이라
/// 축소본은 필요 없고, 메모리만 더 쓴다.
public enum TexDecoder {
    public static func decode(_ data: Data) throws -> TextureData {
        let header = try TexHeader.parse(data)
        guard let mip = header.mipmaps.first else { throw TexError.noMipmaps }
        // mip.range는 0 기준 오프셋이다. 슬라이스가 넘어올 수 있으므로 기준을 더한다.
        let lower = data.startIndex + mip.range.lowerBound
        let upper = data.startIndex + mip.range.upperBound
        let payload = data.subdata(in: lower..<upper)

        switch header.kind {
        case .video:
            // 손대지 않는다. AVFoundation이 통째로 읽는다.
            return .video(payload)

        case .jpeg, .png:
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw TexError.imageDecodeFailed
            }
            return .image(image)

        case .rawPixels:
            guard let format = header.pixelFormat else {
                throw TexError.unsupportedPixelFormat(header.format)
            }
            // 픽셀 버퍼의 크기는 차원과 포맷으로 정확히 결정된다.
            // width/height는 파일에서 온 값이다. Swift의 *는 오버플로우에서 포화가 아니라
            // 트랩하므로, 검사 연산을 써서 트랩 대신 오류로 바꾼다.
            guard mip.width > 0, mip.height > 0 else { throw TexError.lz4Failed }
            // 차원 자체를 먼저 제한한다. area/expectedSize의 오버플로우 검사만으로는
            // 부족하다 — format=9(r8, bytesPerPixel=1)에서 width=height=Int32.max이면
            // area가 약 4.6e18로 Int 오버플로우 없이 거대해지고, 그 결과가 그대로
            // Data(count:) 할당으로 흘러가 malloc 실패로 트랩한다.
            // 16384는 애플 실리콘의 maxTexture2DDimension이다. WallflowKit은 Metal을
            // import하지 않으므로 이 값을 여기서 물어볼 수 없어 상수로 못박는다 —
            // 이보다 큰 차원은 어차피 Metal 텍스처가 될 수 없다.
            let maxTextureDimension = 16384
            guard mip.width <= maxTextureDimension, mip.height <= maxTextureDimension else {
                throw TexError.dimensionsOutOfRange
            }
            let (area, areaOverflow) = mip.width.multipliedReportingOverflow(by: mip.height)
            guard !areaOverflow else { throw TexError.lz4Failed }
            let (expectedSize, sizeOverflow) = area.multipliedReportingOverflow(by: format.bytesPerPixel)
            guard !sizeOverflow, expectedSize > 0 else { throw TexError.lz4Failed }

            let bytes = mip.isLZ4
                ? try decompressLZ4(payload, expecting: expectedSize)
                : payload

            guard bytes.count == expectedSize else { throw TexError.lz4Failed }
            return .pixels(bytes: bytes, width: mip.width, height: mip.height, format: format)
        }
    }

    /// macOS Compression 프레임워크의 LZ4_RAW를 쓴다. 외부 의존성이 필요 없다.
    private static func decompressLZ4(_ input: Data, expecting size: Int) throws -> Data {
        guard size > 0, !input.isEmpty else { throw TexError.lz4Failed }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == size else { throw TexError.lz4Failed }
        return output
    }
}
