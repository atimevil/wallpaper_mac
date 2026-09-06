import XCTest
@testable import WallflowKit

final class TextRasterizerTests: XCTestCase {
    private let white = Vec3(x: 1, y: 1, z: 1)

    func testRasterizesWithSystemFont() throws {
        let image = try TextRasterizer.rasterize(
            text: "12:34", fontData: nil, pointSize: 64, color: white)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        // 다섯 글자가 한 글자보다 넓어야 한다. 크기가 상수면 이 단언이 잡는다.
        let one = try TextRasterizer.rasterize(
            text: "1", fontData: nil, pointSize: 64, color: white)
        XCTAssertGreaterThan(image.width, one.width, "글자 수가 폭에 반영되지 않았다")
    }

    /// 실제로 픽셀이 칠해져야 한다. 크기만 보면 빈 비트맵도 통과한다.
    func testActuallyDrawsPixels() throws {
        let image = try TextRasterizer.rasterize(
            text: "8", fontData: nil, pointSize: 96, color: white)
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        let lit = bytes.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count
        XCTAssertGreaterThan(lit, 0, "알파가 전부 0이다 — 아무것도 그려지지 않았다")
    }

    /// 크기가 점 크기를 따라야 한다. 안 그러면 시계가 항상 같은 크기로 나온다.
    func testPointSizeChangesDimensions() throws {
        let small = try TextRasterizer.rasterize(
            text: "00:00", fontData: nil, pointSize: 24, color: white)
        let large = try TextRasterizer.rasterize(
            text: "00:00", fontData: nil, pointSize: 96, color: white)
        XCTAssertGreaterThan(large.width, small.width)
        XCTAssertGreaterThan(large.height, small.height)
    }

    func testEmptyTextThrows() {
        XCTAssertThrowsError(try TextRasterizer.rasterize(
            text: "", fontData: nil, pointSize: 32, color: white))
        XCTAssertThrowsError(try TextRasterizer.rasterize(
            text: "   ", fontData: nil, pointSize: 32, color: white),
            "공백만 있으면 0x0이 되어 Metal이 거부한다")
    }

    /// 스크립트가 만든 값이 파일에서 오므로 점 크기도 신뢰할 수 없다.
    func testAbsurdPointSizeDoesNotTrap() {
        for size in [0.0, -1.0, Double.nan, .infinity, 1e9] {
            XCTAssertThrowsError(try TextRasterizer.rasterize(
                text: "1", fontData: nil, pointSize: size, color: white),
                "\(size)에서 던지지 않았다")
        }
    }

    /// 깨진 폰트 바이트로 글자가 사라지면 안 된다. 시스템 폰트로라도 나와야 한다.
    func testGarbageFontFallsBackToSystemFont() throws {
        let image = try TextRasterizer.rasterize(
            text: "12:34", fontData: Data([0, 1, 2, 3, 4]), pointSize: 48, color: white)
        XCTAssertGreaterThan(image.width, 0)
    }

    /// 실물 폰트로 실제로 구워져야 한다. 시스템 폰트만 되면 의미가 없다.
    func testRasterizesWithRealWorkshopFont() throws {
        guard let assetsPath = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"] else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let assets = AssetsStore(root: URL(fileURLWithPath: assetsPath))
        let data = try assets.data(for: "fonts/Monofur-PK7og.ttf")
        let image = try TextRasterizer.rasterize(
            text: "12:34", fontData: data, pointSize: 64, color: white)
        XCTAssertGreaterThan(image.width, 0)
        // 시스템 폰트와 폭이 달라야 실제로 그 폰트를 쓴 것이다.
        let system = try TextRasterizer.rasterize(
            text: "12:34", fontData: nil, pointSize: 64, color: white)
        XCTAssertNotEqual(image.width, system.width, "폰트 바이트가 무시되고 있다")
    }

    /// 상자에 맞춰 줄일 때 비율이 유지되어야 한다. 안 그러면 글자가 늘어난다.
    func testFitPreservesAspect() {
        let r = TextRasterizer.fit(imageWidth: 600, imageHeight: 200,
                                   boxWidth: 300, boxHeight: 300)
        XCTAssertEqual(r.width, 300, accuracy: 0.01)
        XCTAssertEqual(r.height, 100, accuracy: 0.01, "비율이 깨졌다")
    }

    /// 높이가 먼저 막히는 경우.
    func testFitLimitedByHeight() {
        let r = TextRasterizer.fit(imageWidth: 400, imageHeight: 400,
                                   boxWidth: 800, boxHeight: 200)
        XCTAssertEqual(r.width, 200, accuracy: 0.01)
        XCTAssertEqual(r.height, 200, accuracy: 0.01)
    }

    /// 상자가 이미지보다 크면 키운다. 실물 Hiyuki의 시계가 이 경우다.
    func testFitEnlargesToBox() {
        let r = TextRasterizer.fit(imageWidth: 100, imageHeight: 50,
                                   boxWidth: 500, boxHeight: 204)
        XCTAssertEqual(r.width, 408, accuracy: 1)
        XCTAssertEqual(r.height, 204, accuracy: 1)
    }

    /// 상자 값은 씬 파일에서 온다. 0이나 비정상이면 원래 크기를 쓴다.
    func testFitWithBadBoxKeepsOriginalSize() {
        for (w, h) in [(0.0, 100.0), (100.0, 0.0), (Double.nan, 100.0),
                       (100.0, Double.infinity), (-5.0, 100.0)] {
            let r = TextRasterizer.fit(imageWidth: 300, imageHeight: 100,
                                       boxWidth: w, boxHeight: h)
            XCTAssertEqual(r.width, 300, accuracy: 0.01, "상자 (\(w), \(h))")
            XCTAssertEqual(r.height, 100, accuracy: 0.01, "상자 (\(w), \(h))")
        }
    }

    func testColorIsApplied() throws {
        let image = try TextRasterizer.rasterize(
            text: "8", fontData: nil, pointSize: 96, color: Vec3(x: 1, y: 0, z: 0))
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        var sawRed = false
        for i in stride(from: 0, to: bytes.count - 3, by: 4) where bytes[i + 3] > 200 {
            if bytes[i] > 200 && bytes[i + 1] < 60 { sawRed = true; break }
        }
        XCTAssertTrue(sawRed, "빨간 글자가 빨갛게 그려지지 않았다")
    }
}

extension TextRasterizerTests {
    private var white2: Vec3 { Vec3(x: 1, y: 1, z: 1) }

    /// 씬이 limitwidth로 폭을 정해 두는데 무시하면 긴 곡 제목이 한 줄로
    /// 늘어져 화면 밖으로 흐른다.
    func testWrapsAtMaxWidth() throws {
        let long = "이것은 아주 긴 곡 제목이고 한 줄에 들어가지 않는다"
        let single = try TextRasterizer.rasterize(
            text: long, fontData: nil, pointSize: 40, color: white2)
        let wrapped = try TextRasterizer.rasterize(
            text: long, fontData: nil, pointSize: 40, color: white2,
            wrapWidth: 200, maxRows: 0, usesEllipsis: false)
        XCTAssertLessThan(wrapped.width, single.width, "접히지 않았다")
        XCTAssertGreaterThan(wrapped.height, single.height, "여러 줄이 되어야 한다")
    }

    /// maxRows를 넘기면 잘라낸다. 두 줄 제한이면 세 줄이 되면 안 된다.
    func testRespectsMaxRows() throws {
        let long = String(repeating: "가나다라마바사 ", count: 12)
        let two = try TextRasterizer.rasterize(
            text: long, fontData: nil, pointSize: 30, color: white2,
            wrapWidth: 150, maxRows: 2, usesEllipsis: false)
        let four = try TextRasterizer.rasterize(
            text: long, fontData: nil, pointSize: 30, color: white2,
            wrapWidth: 150, maxRows: 4, usesEllipsis: false)
        XCTAssertLessThan(two.height, four.height, "줄 수 제한이 듣지 않았다")
    }

    /// 폭이 0이면 접지 않는다. 씬이 limitwidth를 꺼 둔 경우다.
    func testZeroWidthDoesNotWrap() throws {
        let text = "접히면 안 되는 긴 문장이다 정말로 길다"
        let plain = try TextRasterizer.rasterize(
            text: text, fontData: nil, pointSize: 30, color: white2)
        let unwrapped = try TextRasterizer.rasterize(
            text: text, fontData: nil, pointSize: 30, color: white2,
            wrapWidth: 0, maxRows: 0, usesEllipsis: false)
        XCTAssertEqual(plain.width, unwrapped.width)
        XCTAssertEqual(plain.height, unwrapped.height)
    }

    /// 말줄임을 켜면 잘린 마지막 줄이 그렇지 않은 것과 달라야 한다.
    func testEllipsisChangesLastLine() throws {
        let long = String(repeating: "abcdefgh ", count: 20)
        let plain = try TextRasterizer.rasterize(
            text: long, fontData: nil, pointSize: 30, color: white2,
            wrapWidth: 160, maxRows: 2, usesEllipsis: false)
        let dotted = try TextRasterizer.rasterize(
            text: long, fontData: nil, pointSize: 30, color: white2,
            wrapWidth: 160, maxRows: 2, usesEllipsis: true)
        XCTAssertEqual(plain.height, dotted.height, "줄 수는 같아야 한다")
        let a = try XCTUnwrap(plain.dataProvider?.data as Data?)
        let b = try XCTUnwrap(dotted.dataProvider?.data as Data?)
        XCTAssertNotEqual(a, b, "말줄임표가 그려지지 않았다")
    }

    /// 접을 때도 이상한 입력에 죽지 않아야 한다.
    func testWrapSurvivesAbsurdInput() {
        for width in [Double.nan, .infinity, -5] {
            XCTAssertNoThrow(try TextRasterizer.rasterize(
                text: "가", fontData: nil, pointSize: 20, color: Vec3(x: 1, y: 1, z: 1),
                wrapWidth: width, maxRows: 2, usesEllipsis: true), "폭 \(width)")
        }
    }
}

extension TextRasterizerTests {
    /// 그림자는 글자 바깥으로 번지므로 비트맵이 더 커야 한다.
    /// 여백을 안 주면 오른쪽·아래가 잘려 그림자가 각지게 끊긴다.
    func testShadowEnlargesBitmap() throws {
        let plain = try TextRasterizer.rasterize(
            text: "12:34", fontData: nil, pointSize: 48, color: Vec3(x: 1, y: 1, z: 1))
        let shadowed = try TextRasterizer.rasterize(
            text: "12:34", fontData: nil, pointSize: 48, color: Vec3(x: 1, y: 1, z: 1),
            shadow: TextShadow(color: Vec3(x: 0, y: 0, z: 0),
                               offset: Vec2(x: 4, y: 4), blur: 6, opacity: 1),
            shadowScale: 1)
        XCTAssertGreaterThan(shadowed.width, plain.width)
        XCTAssertGreaterThan(shadowed.height, plain.height)
    }

    /// 실제로 어두운 픽셀이 생겨야 한다. 크기만 커지고 안 그려지면 소용없다.
    func testShadowActuallyDraws() throws {
        let shadowed = try TextRasterizer.rasterize(
            text: "8", fontData: nil, pointSize: 64, color: Vec3(x: 1, y: 1, z: 1),
            shadow: TextShadow(color: Vec3(x: 1, y: 0, z: 0),
                               offset: Vec2(x: 6, y: 6), blur: 2, opacity: 1),
            shadowScale: 1)
        let bytes = try XCTUnwrap(shadowed.dataProvider?.data as Data?)
        var sawRedish = false
        for i in stride(from: 0, to: bytes.count - 3, by: 4) where bytes[i + 3] > 60 {
            // 흰 글자에 빨간 그림자다. 빨간데 초록·파랑이 낮으면 그림자다.
            if bytes[i] > 120, bytes[i + 1] < 90, bytes[i + 2] < 90 { sawRedish = true; break }
        }
        XCTAssertTrue(sawRedish, "그림자가 그려지지 않았다")
    }

    /// 씬이 그림자를 끄면 크기가 그대로여야 한다.
    func testNoShadowKeepsSize() throws {
        let a = try TextRasterizer.rasterize(
            text: "x", fontData: nil, pointSize: 32, color: Vec3(x: 1, y: 1, z: 1))
        let b = try TextRasterizer.rasterize(
            text: "x", fontData: nil, pointSize: 32, color: Vec3(x: 1, y: 1, z: 1),
            shadow: nil, shadowScale: 1)
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
    }
}
