import Compression
import CoreGraphics
import ImageIO
import XCTest
@testable import WallflowKit

final class TexDecoderTests: XCTestCase {
    /// 실제 JPEG 바이트를 만들어야 ImageIO가 디코딩할 수 있다.
    private func realJPEG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testDecodesJPEGToImage() throws {
        let jpeg = try realJPEG(width: 64, height: 32)
        let tex = buildTex(freeImageFormat: 2, size: (64, 32), mips: [(64, 32, 0, 0, jpeg)])
        guard case .image(let cg) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .image")
        }
        XCTAssertEqual(cg.width, 64)
        XCTAssertEqual(cg.height, 32)
    }

    func testDecodesOnlyTheLargestMipmap() throws {
        // 밉맵이 여러 개여도 0번(최대 해상도)만 쓴다.
        let big = try realJPEG(width: 64, height: 32)
        let small = try realJPEG(width: 32, height: 16)
        let tex = buildTex(freeImageFormat: 2, size: (64, 32), mips: [
            (64, 32, 0, 0, big), (32, 16, 0, 0, small),
        ])
        guard case .image(let cg) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .image")
        }
        XCTAssertEqual(cg.width, 64)
    }

    func testVideoTextureReturnsRawMP4Bytes() throws {
        let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8) + Data(repeating: 0xAB, count: 64)
        let tex = buildTex(flags: 34, freeImageFormat: -1, size: (320, 240),
                          mips: [(320, 240, 0, 0, mp4)])
        guard case .video(let bytes) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .video")
        }
        XCTAssertEqual(bytes, mp4, "MP4는 손대지 않고 그대로 넘겨야 AVFoundation이 읽는다")
    }

    func testDecompressesLZ4RawPixels() throws {
        let original = Data((0..<(8 * 8 * 4)).map { UInt8($0 % 251) })
        let compressed = try XCTUnwrap(lz4RawCompress(original))
        let tex = buildTex(
            format: 0, flags: 0, freeImageFormat: -1, size: (8, 8),
            mips: [(8, 8, 1, Int32(original.count), compressed)]
        )
        guard case .pixels(let bytes, let w, let h, let fmt) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .pixels")
        }
        XCTAssertEqual(bytes, original)
        XCTAssertEqual(w, 8)
        XCTAssertEqual(h, 8)
        XCTAssertEqual(fmt, .rgba8888)
    }

    func testUncompressedRawPixelsPassThrough() throws {
        let raw = Data(repeating: 0x5A, count: 4 * 4 * 4)
        let tex = buildTex(format: 0, flags: 0, freeImageFormat: -1, size: (4, 4),
                          mips: [(4, 4, 0, raw.count32, raw)])
        guard case .pixels(let bytes, _, _, _) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .pixels")
        }
        XCTAssertEqual(bytes, raw)
    }

    func testSingleChannelMaskFormat() throws {
        let raw = Data(repeating: 0xFF, count: 16 * 16)
        let tex = buildTex(format: 9, flags: 2, freeImageFormat: -1, size: (16, 16),
                          mips: [(16, 16, 0, raw.count32, raw)])
        guard case .pixels(_, _, _, let fmt) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .pixels")
        }
        XCTAssertEqual(fmt, .r8)
    }

    func testUnknownPixelFormatThrows() {
        let raw = Data(repeating: 0, count: 16)
        let tex = buildTex(format: 77, flags: 0, freeImageFormat: -1, size: (2, 2),
                          mips: [(2, 2, 0, 16, raw)])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .unsupportedPixelFormat(77))
        }
    }

    func testCorruptImageBytesThrowRatherThanCrash() {
        let notAnImage = Data(repeating: 0x41, count: 128)
        let tex = buildTex(freeImageFormat: 2, size: (8, 8), mips: [(8, 8, 0, 0, notAnImage)])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            // N1의 실패 닫힘 수정 이후로는 에러 종류가 바뀐다: 완전히 깨진
            // 바이트라 CGImageSourceCopyPropertiesAtIndex조차 치수를 못 읽으므로
            // CGImageSourceCreateImageAtIndex(imageDecodeFailed)까지 가지 않고
            // 그 앞의 치수 가드에서 dimensionsOutOfRange로 먼저 던진다. 트랩하지
            // 않고 오류로 던진다는 이 테스트의 본래 목적은 그대로 지켜진다.
            XCTAssertEqual(error as? TexError, .dimensionsOutOfRange)
        }
    }

    // Regression tests for allocation safety (Finding 1 & 2)
    func testEmptyLZ4PayloadThrowsInsteadOfCrashing() throws {
        // LZ4 mipmap with payload size 0, but decompressedSize > 0.
        // This would cause empty buffer's baseAddress to be nil, trapping on force-unwrap.
        let tex = buildTex(format: 0, flags: 0, freeImageFormat: -1, size: (8, 8),
                          mips: [(8, 8, 1, 256, Data())])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .lz4Failed)
        }
    }

    func testIgnoresDecompressedSizeFieldInFavorOfDimensions() throws {
        // This test verifies that the file's decompressedSize field is IGNORED
        // in favor of the dimension-derived expected size.
        // - Dimensions: 8×8×4 = 256 bytes (expected)
        // - LZ4 payload: genuinely compresses/decompresses to 256 bytes
        // - File's decompressedSize field: 999 (mismatched, should be ignored)
        // Pre-fix: decoder would pass 999 to decompressLZ4, written=256, 256≠999 → throws
        // Post-fix: decoder passes 256 to decompressLZ4, written=256, 256=256 → succeeds
        let original = Data((0..<256).map { UInt8($0 % 251) })
        let compressed = try XCTUnwrap(lz4RawCompress(original))
        let tex = buildTex(
            format: 0, flags: 0, freeImageFormat: -1, size: (8, 8),
            mips: [(8, 8, 1, 999, compressed)]  // decompressedSize disagrees
        )
        guard case .pixels(let bytes, 8, 8, .rgba8888) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .pixels")
        }
        XCTAssertEqual(bytes.count, 256, "decoded to dimension-derived size, not file's field")
    }

    func testUncompressedRawPayloadTooShortThrows() throws {
        // Uncompressed pixel data smaller than width × height × bytesPerPixel.
        // 8×8×4 = 256 bytes, but we provide 128.
        let tooSmall = Data(repeating: 0x5A, count: 128)
        let tex = buildTex(format: 0, flags: 0, freeImageFormat: -1, size: (8, 8),
                          mips: [(8, 8, 0, 256, tooSmall)])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .lz4Failed)
        }
    }

    func testArithmeticOverflowThrowsInsteadOfTrapping() throws {
        // width × height × bytesPerPixel can overflow Int even when each component is valid.
        // With width=height=Int32.max and format=0 (rgba8888), the C1 fix now catches this
        // via the 16384 dimension bound before the multiplication is ever attempted — the
        // bound subsumes this case. The overflow-reporting arithmetic below it stays as
        // defense in depth, but for dimensions this large it never gets a chance to fire.
        let raw = Data(repeating: 0, count: 1)
        let tex = buildTex(
            format: 0, flags: 0, freeImageFormat: -1,
            size: (Int32.max, Int32.max),
            mips: [(Int32.max, Int32.max, 0, 1, raw)]
        )
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .dimensionsOutOfRange)
        }
    }

    /// PNG는 rawPixels와 달리 헤더 스캔이 아니라 CGImageSource에 그대로 맡겨진다.
    ///
    /// 처음에는 IHDR의 폭/높이 필드만 손으로 부풀린 조작된 PNG로 이 경로를
    /// 검증하려 했다. 실측 결과 ImageIO는 선언된 치수가 실제 압축 데이터 길이와
    /// 크게 어긋나면(수백 바이트짜리 데이터로 1000x1000을 선언하는 정도로도
    /// 이미) CGImageSourceCopyPropertiesAtIndex 단계에서 빈 딕셔너리를 돌려주고
    /// 조용히 거부한다 — 즉 그런 식으로 조작한 PNG는 우리 코드에 닿기도 전에
    /// ImageIO가 먼저 걸러버려 dimensionsOutOfRange 경로를 실제로 타지 못한다.
    ///
    /// 대신 폭이 정말로 16384를 넘는 진짜(조작하지 않은) PNG를 싸게 만든다:
    /// 높이 1짜리 단색 줄무늬는 16385x1이어도 압축 후 수백 바이트에 불과하다.
    /// 조작이 아니라 진짜 헤더이므로 ImageIO가 순순히 폭/높이를 읽어주고, 우리
    /// 쪽 가드가 CGImageSourceCreateImageAtIndex(실제 픽셀 디코딩) 전에 먼저
    /// dimensionsOutOfRange로 끊는지를 그대로 검증할 수 있다.
    func testOversizedPNGWidthThrowsDimensionsOutOfRangeInsteadOfDecoding() throws {
        let png = try realPNG(width: 16385, height: 1)
        let tex = buildTex(freeImageFormat: 13, size: (16385, 1), mips: [(16385, 1, 0, 0, png)])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .dimensionsOutOfRange)
        }
    }

    /// N1 회귀 테스트: 가드가 프로퍼티를 읽지 못하는(또는 못 미더운) 경우 실패
    /// 닫힘(fail closed)으로 동작하는지 확인한다.
    ///
    /// IHDR의 폭/높이만 8에서 1000으로 부풀리고 CRC를 다시 계산한 PNG를 쓴다.
    /// 실측 결과 ImageIO는 이 정도로 선언과 실제 데이터가 어긋나면
    /// CGImageSourceCopyPropertiesAtIndex가 "실패"가 아니라 빈 딕셔너리([:])를
    /// 돌려준다 — nil이 아니라 캐스팅은 성공하지만 필요한 키가 없다.
    /// 수정 전 코드는 `if let properties = ... as? [CFString: Any]`가 성공하면
    /// (빈 딕셔너리도 성공이다) 그 안에서 width/height를 각각 `?? 0`으로 기본값
    /// 처리했으므로 0 <= 16384가 그냥 통과해 가드를 조용히 빠져나간 뒤
    /// CGImageSourceCreateImageAtIndex를 시도했다(이 경우는 그것도 nil이라
    /// imageDecodeFailed가 났지만, 가드가 실제로는 아무 일도 하지 않았다는
    /// 사실은 그대로다). 수정 후 코드는 프로퍼티에서 두 키를 모두 읽지 못하면
    /// 그 자체로 dimensionsOutOfRange를 던지므로, 디코딩을 시도하기도 전에
    /// 정확한 이유로 실패해야 한다.
    func testUnreadablePNGDimensionsFailClosedRatherThanDefaultingToZero() throws {
        var png = try realPNG(width: 8, height: 8)
        let widthOffset = 16
        let heightOffset = 20
        let bumped = UInt32(1000).bigEndianBytes
        png.replaceSubrange(widthOffset..<(widthOffset + 4), with: bumped)
        png.replaceSubrange(heightOffset..<(heightOffset + 4), with: bumped)
        let chunkTypeAndData = png.subdata(in: 12..<29)
        let crc = crc32PNG(chunkTypeAndData).bigEndianBytes
        png.replaceSubrange(29..<33, with: crc)

        let tex = buildTex(freeImageFormat: 13, size: (8, 8), mips: [(8, 8, 0, 0, png)])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(
                error as? TexError, .dimensionsOutOfRange,
                "치수를 읽을 수 없으면 디코딩을 시도하기 전에 dimensionsOutOfRange로 실패 닫힘해야 한다")
        }
    }

    /// 실제 PNG 바이트를 만들어야 IHDR을 조작할 대상이 생긴다.
    private func realPNG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testR8DimensionsAtInt32MaxThrowDimensionsOutOfRangeInsteadOfCrashing() throws {
        // format=9(r8, bytesPerPixel=1)이면 width×height가 오버플로우 없이 거대해질 수
        // 있다. width=height=Int32.max일 때 area는 약 4.6e18로, 오버플로우 검사 두
        // 단계를 그대로 통과해 (isLZ4=1이라) decompressLZ4의 Data(count:) 할당까지
        // 도달하면 malloc 실패로 트랩한다. 차원 자체를 먼저 제한해야만 이 값을 걸러낼
        // 수 있다.
        let raw = Data(repeating: 0, count: 1)
        let tex = buildTex(
            format: 9, flags: 0, freeImageFormat: -1,
            size: (Int32.max, Int32.max),
            mips: [(Int32.max, Int32.max, 1, 1, raw)]
        )
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .dimensionsOutOfRange)
        }
    }
}

extension Data {
    var count32: Int32 { Int32(count) }
}

extension UInt32 {
    /// PNG IHDR의 width/height/CRC 필드는 모두 빅엔디안 4바이트다.
    var bigEndianBytes: Data {
        var be = self.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
}

/// PNG 표준의 CRC-32(zlib과 같은 다항식). 시스템 zlib을 링크하지 않고 IHDR을
/// 손으로 패치한 테스트 픽스처의 CRC를 다시 계산하는 데만 쓴다.
func crc32PNG(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        table[n] = c
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}


/// 테스트 픽스처용 LZ4 압축. 구현부의 압축 해제와 짝을 이룬다.
func lz4RawCompress(_ input: Data) -> Data? {
    let capacity = input.count + 1024
    var output = Data(count: capacity)
    let written = output.withUnsafeMutableBytes { dst -> Int in
        input.withUnsafeBytes { src -> Int in
            compression_encode_buffer(
                dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                nil, COMPRESSION_LZ4_RAW
            )
        }
    }
    guard written > 0 else { return nil }
    return output.prefix(written)
}
