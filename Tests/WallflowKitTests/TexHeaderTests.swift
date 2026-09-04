import XCTest
@testable import WallflowKit

final class TexHeaderTests: XCTestCase {
    func testParsesTEXB0004WithJPEGPayload() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 100)
        let tex = buildTex(mips: [(2048, 1164, 0, 0, jpeg)])
        let header = try TexHeader.parse(tex)

        XCTAssertEqual(header.version, "TEXV0005")
        XCTAssertEqual(header.imageWidth, 2048)
        XCTAssertEqual(header.imageHeight, 1164)
        XCTAssertEqual(header.freeImageFormat, 2)
        XCTAssertEqual(header.kind, .jpeg)
        XCTAssertFalse(header.isVideo)
        XCTAssertEqual(header.mipmaps.count, 1)
        XCTAssertEqual(header.mipmaps[0].width, 2048)
    }

    /// TEXB0003은 int32 하나가 적다. 이걸 틀리면 이후 전부가 어긋난다.
    func testParsesTEXB0003WhichHasOneFewerField() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0, count: 40)
        let tex = buildTex(
            container: "TEXB0003", freeImageFormat: 13,
            size: (2048, 512), mips: [(1920, 313, 0, 0, png)]
        )
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .png)
        XCTAssertEqual(header.mipmaps.count, 1)
        XCTAssertEqual(header.mipmaps[0].width, 1920)
        XCTAssertEqual(header.mipmaps[0].height, 313)
    }

    /// flags 비트 32가 비디오 텍스처를 뜻한다. 실물 226MB 텍스처 두 개가 이 경우였다.
    func testFlagBit32MeansVideo() throws {
        let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 40)
        let tex = buildTex(
            flags: 34, freeImageFormat: -1,
            size: (3200, 1800), mips: [(3200, 1800, 0, 0, mp4)]
        )
        let header = try TexHeader.parse(tex)
        XCTAssertTrue(header.isVideo)
        XCTAssertEqual(header.kind, .video)
    }

    func testFlag35IsAlsoVideo() throws {
        let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)
        let tex = buildTex(flags: 35, freeImageFormat: -1, mips: [(3840, 2160, 0, 0, mp4)])
        XCTAssertTrue(try TexHeader.parse(tex).isVideo)
    }

    func testFreeFormatMinusOneWithoutVideoFlagIsRawPixels() throws {
        let raw = Data(repeating: 7, count: 64)
        let tex = buildTex(flags: 0, freeImageFormat: -1, size: (256, 256),
                          mips: [(256, 256, 1, 262144, raw)])
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .rawPixels)
        XCTAssertFalse(header.isVideo)
        XCTAssertTrue(header.mipmaps[0].isLZ4)
        XCTAssertEqual(header.mipmaps[0].decompressedSize, 262144)
    }

    func testPixelFormatMapping() throws {
        let raw = Data(repeating: 0, count: 16)
        let rgba = try TexHeader.parse(
            buildTex(format: 0, flags: 0, freeImageFormat: -1, mips: [(4, 4, 0, 64, raw)])
        )
        XCTAssertEqual(rgba.pixelFormat, .rgba8888)

        let r8 = try TexHeader.parse(
            buildTex(format: 9, flags: 2, freeImageFormat: -1, mips: [(4, 4, 0, 16, raw)])
        )
        XCTAssertEqual(r8.pixelFormat, .r8)
    }

    func testParsesFullMipmapChain() throws {
        let mips: [(Int32, Int32, Int32, Int32, Data)] = [
            (2048, 1164, 0, 0, Data([0xFF, 0xD8, 0xFF] + Array(repeating: 0, count: 20))),
            (1024, 582, 0, 0, Data(repeating: 1, count: 15)),
            (512, 291, 0, 0, Data(repeating: 2, count: 10)),
            (256, 145, 0, 0, Data(repeating: 3, count: 5)),
        ]
        let header = try TexHeader.parse(buildTex(mips: mips))
        XCTAssertEqual(header.mipmaps.map(\.width), [2048, 1024, 512, 256])
        XCTAssertEqual(header.mipmaps.map(\.height), [1164, 582, 291, 145])
    }

    func testBadMagicThrows() {
        let junk = Data("NOTATEXTURE\0".utf8) + Data(repeating: 0, count: 80)
        XCTAssertThrowsError(try TexHeader.parse(junk)) { error in
            guard case TexError.badMagic = error else {
                return XCTFail("expected badMagic, got \(error)")
            }
        }
    }

    func testUnknownContainerThrows() {
        let tex = buildTex(container: "TEXB9999", mips: [(4, 4, 0, 0, Data([1, 2, 3]))])
        XCTAssertThrowsError(try TexHeader.parse(tex)) { error in
            guard case TexError.unsupportedContainer(let name) = error else {
                return XCTFail("expected unsupportedContainer, got \(error)")
            }
            XCTAssertEqual(name, "TEXB9999")
        }
    }

    func testTruncatedMipmapDataThrows() {
        var tex = buildTex(mips: [(2048, 1164, 0, 0, Data(repeating: 0, count: 100))])
        tex = tex.prefix(tex.count - 50)   // 데이터 절반을 잘라낸다
        XCTAssertThrowsError(try TexHeader.parse(tex))
    }

    /// 손상된 파일이 밉맵 수를 거짓말할 수 있다. 검증 전에 그것을 믿고 할당하면 죽는다.
    func testAbsurdMipmapCountThrowsInsteadOfAllocating() {
        var tex = nullTerminated("TEXV0005") + nullTerminated("TEXI0001")
        tex += le32(0) + le32(2)
        tex += le32(8) + le32(8) + le32(8) + le32(8)
        tex += le32(0)
        tex += nullTerminated("TEXB0004")
        tex += le32(1) + le32(2) + le32(0)
        tex += le32(Int32.max)          // 밉맵이 21억 개라고 주장한다
        XCTAssertThrowsError(try TexHeader.parse(tex)) { error in
            XCTAssertEqual(error as? TexError, .truncated)
        }
    }

    func testZeroMipmapCountThrows() {
        let tex = buildTex(mips: [])
        XCTAssertThrowsError(try TexHeader.parse(tex)) { error in
            XCTAssertEqual(error as? TexError, .noMipmaps)
        }
    }
}
