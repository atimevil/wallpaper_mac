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

    /// flags & 4가 없으면 뒤에 읽을 수 있는 TEXS 섹션이 있어도 읽지 않는다.
    /// 뒤가 비어 있는 픽스처로는 이것을 증명할 수 없다 — 가드를 지워도
    /// EOF 때문에 nil이 나오기 때문이다.
    func testNoSpriteSheetWhenFlagAbsentEvenWithParseableSection() throws {
        var tex = buildTex(flags: 2, mips: [(8, 8, 0, 0, Data(repeating: 0, count: 20))])
        tex += spriteSheetV2(frameCount: 4)
        XCTAssertNil(try TexHeader.parse(tex).spriteSheet)
    }

    /// 프레임 수도 파일에서 온 값이다. 검증 전에 믿고 할당하면 죽는다.
    /// 스프라이트 시트 파싱은 try?로 감싸므로 오류가 호출자에 도달하지 않는다 —
    /// 관측 가능한 결과는 "spriteSheet가 nil이고 밉맵은 살아 있다"이다.
    func testAbsurdFrameCountYieldsNilSheetInsteadOfAllocating() throws {
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

    // MARK: - 프레임 표 디코드 (Task 5)

    /// 실물 Loading...(3795096226)의 background.tex 앞 두 칸과 같은 값으로
    /// 합성한다. 배치가 [예약, 길이(초), x, y, 폭, 미상, 미상, 높이]임을
    /// 실물 8종으로 확인했다(TexSpriteFrame 문서 참고) — 여기서는 그 배치대로
    /// 디코드되는지만 본다.
    func testDecodesFrameTableIntoRectsAndDurations() throws {
        let frames = [
            spriteFrame(x: 0, y: 0, width: 320, height: 200, duration: 0.1),
            spriteFrame(x: 320, y: 0, width: 320, height: 200, duration: 0.1),
        ]
        var tex = buildTex(flags: 4, freeImageFormat: -1, size: (3200, 1200),
                           mips: [(3200, 1200, 1, 15360000, Data(repeating: 9, count: 40))])
        tex += spriteSheetV3(frameCount: 2, grid: (320, 200), frames: frames)
        let sheet = try XCTUnwrap(try TexHeader.parse(tex).spriteSheet)
        // duration은 파일에 float32로 적힌다. Double(Float(0.1))로 같은 반올림을
        // 거쳐야 비교가 맞는다 — literal 0.1(Double)과는 마지막 자리가 다르다.
        let point1 = Double(Float(0.1))
        XCTAssertEqual(sheet.frames, [
            TexSpriteFrame(x: 0, y: 0, width: 320, height: 200, duration: point1),
            TexSpriteFrame(x: 320, y: 0, width: 320, height: 200, duration: point1),
        ])
    }

    /// TEXS0002(격자 없음)도 같은 32바이트 배치를 쓴다 — 실물 smoke3·lightning1·2가
    /// 이 컨테이너다. duration이 0이어도(파티클 시트는 실물 전부 이렇다) 프레임
    /// 자체는 정확히 디코드되어야 한다.
    func testDecodesFrameTableWithoutGrid() throws {
        let frames = [spriteFrame(x: 128, y: 0, width: 128, height: 128, duration: 0)]
        var tex = buildTexV2(flags: 4, size: (256, 256),
                             mips: [(256, 256, 0, 0, Data(repeating: 1, count: 20))])
        tex += spriteSheetV2(frameCount: 1, frames: frames)
        let sheet = try XCTUnwrap(try TexHeader.parse(tex).spriteSheet)
        XCTAssertEqual(sheet.frames, [
            TexSpriteFrame(x: 128, y: 0, width: 128, height: 128, duration: 0),
        ])
    }

    // MARK: - 프레임 선택 (Task 5, 순수 함수)

    func testFrameSelectionEmptySheetReturnsNil() {
        let sheet = TexSpriteSheet(frameCount: 0, gridWidth: nil, gridHeight: nil, frames: [])
        XCTAssertNil(sheet.frame(atElapsed: 1))
    }

    /// 누적 길이를 따라간다: 0~1초는 0번, 1~2초는 1번, 2~3초는 2번.
    func testFrameSelectionWalksAccumulatedDurations() {
        let frames = (0..<3).map {
            TexSpriteFrame(x: Double($0), y: 0, width: 1, height: 1, duration: 1)
        }
        let sheet = TexSpriteSheet(frameCount: 3, gridWidth: nil, gridHeight: nil, frames: frames)
        XCTAssertEqual(sheet.frame(atElapsed: 0), frames[0])
        XCTAssertEqual(sheet.frame(atElapsed: 0.9), frames[0])
        XCTAssertEqual(sheet.frame(atElapsed: 1.5), frames[1])
        XCTAssertEqual(sheet.frame(atElapsed: 2.999), frames[2])
    }

    /// 전체 길이(3초)를 넘기면 되감는다. 몇 바퀴를 돌아도 위상만 같으면 같은 칸이다.
    func testFrameSelectionLoops() {
        let frames = (0..<3).map {
            TexSpriteFrame(x: Double($0), y: 0, width: 1, height: 1, duration: 1)
        }
        let sheet = TexSpriteSheet(frameCount: 3, gridWidth: nil, gridHeight: nil, frames: frames)
        XCTAssertEqual(sheet.frame(atElapsed: 3.5), frames[0])
        XCTAssertEqual(sheet.frame(atElapsed: 99.5), frames[0])   // 33바퀴 + 0.5초
        XCTAssertEqual(sheet.frame(atElapsed: 7.2), frames[1])
    }

    /// 길이가 0인 칸은 창이 없어 절대 고를 수 없다 — 항상 다음 칸으로 넘어간다.
    func testFrameSelectionSkipsZeroDurationFrames() {
        let frames = [
            TexSpriteFrame(x: 0, y: 0, width: 1, height: 1, duration: 0),
            TexSpriteFrame(x: 1, y: 0, width: 1, height: 1, duration: 0.5),
        ]
        let sheet = TexSpriteSheet(frameCount: 2, gridWidth: nil, gridHeight: nil, frames: frames)
        XCTAssertEqual(sheet.frame(atElapsed: 0), frames[1])
        XCTAssertEqual(sheet.frame(atElapsed: 0.4), frames[1])
    }

    /// 전부 0(또는 음수)이면 되감을 길이 자체가 없다. 나누기 0이나 무한 루프 대신
    /// 첫 프레임에 멈춘다 — TEXS0002 파티클 시트가 실물로 이 모양이다.
    func testFrameSelectionAllNonPositiveDurationsReturnsFirstFrame() {
        let frames = [
            TexSpriteFrame(x: 0, y: 0, width: 1, height: 1, duration: 0),
            TexSpriteFrame(x: 1, y: 0, width: 1, height: 1, duration: -1),
        ]
        let sheet = TexSpriteSheet(frameCount: 2, gridWidth: nil, gridHeight: nil, frames: frames)
        XCTAssertEqual(sheet.frame(atElapsed: 5), frames[0])
    }

    // MARK: - 칸 시작 시각 (Task 5 fix round 1, 순수 함수)

    /// n번째 칸이 시작되는 시각은 그 앞 칸들의 duration 합이다.
    func testStartTimeOfFrameSumsEarlierDurations() {
        let frames = (0..<4).map {
            TexSpriteFrame(x: Double($0), y: 0, width: 1, height: 1, duration: 0.5)
        }
        let sheet = TexSpriteSheet(frameCount: 4, gridWidth: nil, gridHeight: nil, frames: frames)
        XCTAssertEqual(sheet.startTime(ofFrame: 0), 0)
        XCTAssertEqual(sheet.startTime(ofFrame: 1), 0.5)
        XCTAssertEqual(sheet.startTime(ofFrame: 3), 1.5)
    }

    /// 범위를 벗어난 n(음수 포함)도 count로 감싸 항상 유효한 칸을 가리킨다.
    func testStartTimeOfFrameWrapsOutOfRangeIndices() {
        let frames = (0..<3).map {
            TexSpriteFrame(x: Double($0), y: 0, width: 1, height: 1, duration: 1)
        }
        let sheet = TexSpriteSheet(frameCount: 3, gridWidth: nil, gridHeight: nil, frames: frames)
        XCTAssertEqual(sheet.startTime(ofFrame: 3), 0)     // 한 바퀴 돌아 0번과 같다
        XCTAssertEqual(sheet.startTime(ofFrame: 4), 1)     // 4 % 3 = 1
        XCTAssertEqual(sheet.startTime(ofFrame: -1), 2)    // 마지막 칸
    }

    /// duration이 전부 0인 시트(TEXS0002 파티클 시트가 실물로 이 모양이다)는
    /// 더할 것이 없어 어느 n을 줘도 0이다 — 크래시도, 의미 없는 값도 아니다.
    func testStartTimeOfFrameOnAllZeroDurationSheetIsZero() {
        let frames = [TexSpriteFrame(x: 0, y: 0, width: 1, height: 1, duration: 0),
                     TexSpriteFrame(x: 1, y: 0, width: 1, height: 1, duration: 0)]
        let sheet = TexSpriteSheet(frameCount: 2, gridWidth: nil, gridHeight: nil, frames: frames)
        XCTAssertEqual(sheet.startTime(ofFrame: 0), 0)
        XCTAssertEqual(sheet.startTime(ofFrame: 1), 0)
    }

    func testStartTimeOfEmptySheetIsZero() {
        let sheet = TexSpriteSheet(frameCount: 0, gridWidth: nil, gridHeight: nil, frames: [])
        XCTAssertEqual(sheet.startTime(ofFrame: 5), 0)
    }

    /// 렌더러가 실제로 기대는 성질: `elapsed`를 n번 칸의 시작 시각으로 옮기면
    /// `frame(atElapsed:)`가 정확히 그 n번 칸을 돌려준다. 이게 깨지면 setFrame(n)이
    /// 화면에 다른 칸을 그린다.
    func testStartTimeOfFrameRoundTripsThroughFrameAtElapsed() {
        let frames = [
            TexSpriteFrame(x: 0, y: 0, width: 1, height: 1, duration: 1),
            TexSpriteFrame(x: 1, y: 0, width: 1, height: 1, duration: 1),
            TexSpriteFrame(x: 2, y: 0, width: 1, height: 1, duration: 1),
        ]
        let sheet = TexSpriteSheet(frameCount: 3, gridWidth: nil, gridHeight: nil, frames: frames)
        for n in 0..<3 {
            XCTAssertEqual(sheet.frame(atElapsed: sheet.startTime(ofFrame: n)), frames[n])
        }
    }
}
