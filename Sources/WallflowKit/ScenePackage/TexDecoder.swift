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
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil) else {
                throw TexError.imageDecodeFailed
            }
            // 실제로 픽셀을 만들기 전에 헤더가 선언한 치수부터 확인한다. 압축
            // 해제 폭탄(수백 KB짜리가 10만x10만을 선언)은 CGImageSourceCreateImageAtIndex가
            // 그 치수 그대로 비트맵을 올리게 만들므로, rawPixels 분기와 같은 16384
            // 상한을 여기서도 걸지 않으면 세 분기 중 이 둘만 무방비다.
            //
            // 실패 닫힘(fail closed)으로 짠다. 이전 버전은 `if let`으로만 감싸서
            // CGImageSourceCopyPropertiesAtIndex가 nil을 주거나 캐스팅이 실패하면
            // 검사 자체를 건너뛰었고, 두 치수를 각각 `?? 0`으로 기본값 처리해
            // "치수를 못 읽음"과 "치수가 0"을 구분하지 못했다(0 <= 16384라 통과).
            // 이제는 프로퍼티를 못 읽거나, 두 키 중 하나라도 없거나 양수 Int가
            // 아니면 그 자체를 dimensionsOutOfRange로 취급한다 — 치수를 안전하게
            // 확인할 수 없는 이미지는 통과시키지 않는다.
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
                let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
                width <= TexHeader.maxTextureDimension,
                height <= TexHeader.maxTextureDimension
            else {
                throw TexError.dimensionsOutOfRange
            }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
            // 16384는 애플 실리콘의 maxTexture2DDimension이다 (TexHeader 참고).
            guard mip.width <= TexHeader.maxTextureDimension,
                  mip.height <= TexHeader.maxTextureDimension else {
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
            if format == .rg88 {
                // RG88을 RGBA8888로 편다. 아래 경로(Metal 업로드, 셰이더)가 그대로 쓰인다.
                // 실물 light_shafts_0.tex를 재보니 R은 전 픽셀 255로 고정이고 G만
                // 0~228로 변한다 — 흑백 밝기와 알파다. 그래서 RGB에 R을, A에 G를 넣는다.
                // rg8Unorm으로 그냥 올리면 파랑이 0이고 알파가 1이라 색이 틀린다.
                return .pixels(
                    bytes: expandRG88(bytes), width: mip.width, height: mip.height,
                    format: .rgba8888)
            }
            return .pixels(bytes: bytes, width: mip.width, height: mip.height, format: format)
        }
    }

    /// RG88 두 채널을 RGBA8888로 편다. R은 밝기, G는 알파다.
    private static func expandRG88(_ bytes: Data) -> Data {
        var out = Data(count: bytes.count * 2)
        bytes.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                guard let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<(bytes.count / 2) {
                    let luminance = s[i * 2]
                    let alpha = s[i * 2 + 1]
                    d[i * 4] = luminance
                    d[i * 4 + 1] = luminance
                    d[i * 4 + 2] = luminance
                    d[i * 4 + 3] = alpha
                }
            }
        }
        return out
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
