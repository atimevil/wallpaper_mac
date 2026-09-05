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

    /// TEXB0001은 원시 픽셀 전용이고 freeImageFormat 필드가 아예 없다.
    /// 그 필드를 읽으려 들면 이후 전부가 어긋난다.
    func testParsesTEXB0001() throws {
        let pixels = Data(repeating: 0xFF, count: 32 * 32 * 4)
        let tex = buildTexV1(size: (32, 32), mips: [(32, 32, pixels)])
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .rawPixels)
        XCTAssertEqual(header.mipmaps.count, 1)
        XCTAssertEqual(header.mipmaps[0].width, 32)
        XCTAssertFalse(header.mipmaps[0].isLZ4, "0001에는 LZ4 필드가 없다")
        XCTAssertNil(header.spriteSheet)
    }

    func testTEXB0001MipmapChain() throws {
        let mips: [(Int32, Int32, Data)] = [
            (32, 32, Data(repeating: 1, count: 32 * 32 * 4)),
            (16, 16, Data(repeating: 2, count: 16 * 16 * 4)),
        ]
        let header = try TexHeader.parse(buildTexV1(mips: mips))
        XCTAssertEqual(header.mipmaps.map(\.width), [32, 16])
    }

    func testParsesTEXB0002WithLZ4Fields() throws {
        let tex = buildTexV2(size: (16, 16),
                             mips: [(16, 16, 1, 16 * 16 * 4, Data(repeating: 7, count: 40))])
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .rawPixels)
        XCTAssertTrue(header.mipmaps[0].isLZ4)
        XCTAssertEqual(header.mipmaps[0].decompressedSize, 16 * 16 * 4)
        XCTAssertNil(header.spriteSheet)
    }

    /// flags & 4면 밉맵 뒤에 스프라이트 시트가 붙는다. M2는 이것을 몰라서
    /// 잔여 바이트를 남긴 채 파싱했다.
    func testDetectsSpriteSheetSectionV2() throws {
        var tex = buildTexV2(flags: 4, size: (64, 64),
                             mips: [(64, 64, 0, 0, Data(repeating: 3, count: 100))])
        tex += spriteSheetV2(frameCount: 64)
        let sheet = try XCTUnwrap(try TexHeader.parse(tex).spriteSheet)
        XCTAssertEqual(sheet.frameCount, 64)
        XCTAssertNil(sheet.gridWidth, "TEXS0002에는 격자 정보가 없다")
    }

    func testDetectsSpriteSheetSectionV3WithGrid() throws {
        var tex = buildTex(flags: 4, freeImageFormat: -1, size: (128, 128),
                           mips: [(128, 128, 0, 0, Data(repeating: 5, count: 60))])
        tex += spriteSheetV3(frameCount: 16, grid: (128, 128))
        let sheet = try XCTUnwrap(try TexHeader.parse(tex).spriteSheet)
        XCTAssertEqual(sheet.frameCount, 16)
        XCTAssertEqual(sheet.gridWidth, 128)
        XCTAssertEqual(sheet.gridHeight, 128)
    }

    /// flags & 4가 없으면 뒤를 읽으려 하지 않는다.
    func testNoSpriteSheetWhenFlagAbsent() throws {
        let tex = buildTex(flags: 2, mips: [(8, 8, 0, 0, Data(repeating: 0, count: 20))])
        XCTAssertNil(try TexHeader.parse(tex).spriteSheet)
    }

    /// 프레임 수도 파일에서 온 값이다. 검증 전에 믿고 할당하면 죽는다.
    /// 파일에서 온 값이 검증을 통과하지 못하면 spriteSheet는 nil이 되지만
    /// 텍스처 자체는 여전히 쓸 수 있다.
    func testAbsurdFrameCountThrowsInsteadOfAllocating() throws {
        var tex = buildTex(flags: 4, mips: [(8, 8, 0, 0, Data(repeating: 0, count: 20))])
        tex += nullTerminated("TEXS0002") + le32(Int32.max)
        let header = try TexHeader.parse(tex)
        XCTAssertNil(header.spriteSheet, "frameCount 검증 실패시 spriteSheet는 nil")
        XCTAssertEqual(header.mipmaps.count, 1, "밉맵은 여전히 유효해야 한다")
    }

    /// 스프라이트 시트를 못 읽는다고 텍스처 전체를 버리지는 않는다.
    /// 잘린 TEXS 섹션은 spriteSheet == nil 로 떨어지고 밉맵은 살아 있어야 한다.
    func testTruncatedSpriteSheetLeavesMipmapsUsable() throws {
        var tex = buildTex(flags: 4, mips: [(8, 8, 0, 0, Data(repeating: 0, count: 20))])
        tex += nullTerminated("TEXS0002")   // frameCount가 없다
        let header = try TexHeader.parse(tex)
        XCTAssertNil(header.spriteSheet)
        XCTAssertEqual(header.mipmaps.count, 1)
    }
}
