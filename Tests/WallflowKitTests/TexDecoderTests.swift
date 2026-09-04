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
            XCTAssertEqual(error as? TexError, .imageDecodeFailed)
        }
    }
}

extension Data {
    var count32: Int32 { Int32(count) }
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
