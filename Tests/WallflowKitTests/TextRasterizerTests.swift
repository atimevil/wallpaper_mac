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

/// 줄바꿈. **실물 시계 위젯의 날짜가 한 글자씩 세로로 쌓는다** —
/// `"0\n7\n\nS\nE\nP\n\n2\n0\n2\n6"` 꼴이다. 줄바꿈을 무시하면 그게 한 줄로
/// 이어지고, 상자에 맞추느라 깨알같이 작아진다.
extension TextRasterizerTests {
    private func multiline(
        _ text: String, wrapWidth: Double = 0, maxRows: Int = 0
    ) throws -> CGImage {
        try TextRasterizer.rasterize(
            text: text, fontData: nil, pointSize: 64, color: white,
            wrapWidth: wrapWidth, maxRows: maxRows, usesEllipsis: false)
    }

    func testHardBreaksStackLines() throws {
        let stacked = try multiline("0\n7\nS")
        let inline = try multiline("07S")
        XCTAssertGreaterThan(stacked.height, inline.height * 2, "세로로 쌓여야 한다")
        XCTAssertLessThan(stacked.width, inline.width, "한 글자 폭이어야 한다")
    }

    /// 빈 줄도 한 줄만큼 자리를 차지한다. 실물 날짜가 묶음 사이를 빈 줄로 띄운다.
    func testBlankLinesTakeSpace() throws {
        let spaced = try multiline("0\n\n7")
        let tight = try multiline("0\n7")
        XCTAssertGreaterThan(spaced.height, tight.height, "빈 줄이 사라졌다")
    }

    /// 폭 제한이 없어도 줄바꿈은 지킨다. 예전에는 폭 제한이 있을 때만 여러 줄이었다.
    func testHardBreaksWorkWithoutWrapWidth() throws {
        let text = "0\n7\n\nS\nE\nP\n\n2\n0\n2\n6"
        let image = try multiline(text)
        let single = try TextRasterizer.rasterize(
            text: "07SEP2026", fontData: nil, pointSize: 64, color: white)
        XCTAssertGreaterThan(image.height, single.height * 8, "11줄이 쌓여야 한다")
        XCTAssertLessThan(image.width, single.width, "세로로 쌓이면 폭이 좁아진다")
    }

    /// 줄 수 제한은 그대로 걸린다. 스크립트가 만든 글자가 끝없이 길어질 수 있다.
    func testMaxRowsStillLimits() throws {
        let all = try multiline("1\n2\n3\n4\n5\n6")
        let capped = try multiline("1\n2\n3\n4\n5\n6", maxRows: 2)
        XCTAssertLessThan(capped.height, all.height)
    }

    /// 줄바꿈 안에서도 폭 제한은 살아 있다. 문단마다 따로 접어야 한다.
    func testWrapsInsideEachParagraph() throws {
        let wrapped = try multiline(
            "aaaaaaaaaaaaaaaa\nbb", wrapWidth: 120)
        let short = try multiline("aa\nbb", wrapWidth: 120)
        XCTAssertGreaterThan(wrapped.height, short.height, "긴 문단이 접히지 않았다")
    }
}

/// 글자 크기는 **저장된 글자**와 상자의 비에서 온다.
///
/// 오브젝트의 `size`는 편집기에 저장된 글자(`Date`, `12:34` 같은 자리표시자)를
/// 잰 값이다. 실행 중 글자는 그보다 길다(`7 September.2026.Monday`). 상자에
/// 맞추면 길수록 작아져서, 실물 시계 위젯의 날짜가 하나같이 깨알만 해진다.
extension TextRasterizerTests {
    func testScaleComesFromTheAuthoredText() throws {
        // 저장된 글자가 200x50이고 상자가 400x100이면 픽셀당 2 단위다.
        let scale = try XCTUnwrap(TextRasterizer.unitsPerPixel(
            authoredWidth: 200, authoredHeight: 50, boxWidth: 400, boxHeight: 100))
        XCTAssertEqual(scale, 2, accuracy: 0.0001)
    }

    /// 긴 글자는 **커지지 않고 상자를 넘어간다.** 이게 상자 맞춤과 갈리는 지점이다.
    func testLongerTextKeepsGlyphSizeAndOverflows() throws {
        let box = (width: 400.0, height: 100.0)
        let scale = try XCTUnwrap(TextRasterizer.unitsPerPixel(
            authoredWidth: 200, authoredHeight: 50,
            boxWidth: box.width, boxHeight: box.height))
        // 실행 중 글자가 세 배 길다.
        let drawn = (width: 600.0 * scale, height: 50.0 * scale)
        XCTAssertEqual(drawn.height, box.height, accuracy: 0.0001, "글자 높이는 그대로다")
        XCTAssertGreaterThan(drawn.width, box.width, "긴 글자는 상자를 넘어간다")
        // 상자에 맞추던 예전 방식은 같은 글자를 절반 이하로 줄였다.
        let fitted = TextRasterizer.fit(
            imageWidth: 600, imageHeight: 50, boxWidth: box.width, boxHeight: box.height)
        XCTAssertLessThan(fitted.height, box.height / 2)
    }

    /// 잴 수 없으면 nil이다. 부르는 쪽이 예전 방식으로 돌아간다.
    func testNoScaleWithoutAuthoredTextOrBox() {
        XCTAssertNil(TextRasterizer.unitsPerPixel(
            authoredWidth: 0, authoredHeight: 50, boxWidth: 400, boxHeight: 100))
        XCTAssertNil(TextRasterizer.unitsPerPixel(
            authoredWidth: 200, authoredHeight: 50, boxWidth: 0, boxHeight: 100))
        XCTAssertNil(TextRasterizer.unitsPerPixel(
            authoredWidth: 200, authoredHeight: 50,
            boxWidth: .nan, boxHeight: 100))
    }

    /// 가로세로 비가 어긋나면 작은 쪽을 쓴다. 큰 쪽을 쓰면 저장된 글자부터
    /// 상자를 넘는다.
    func testUsesTheSmallerRatio() throws {
        let scale = try XCTUnwrap(TextRasterizer.unitsPerPixel(
            authoredWidth: 200, authoredHeight: 50, boxWidth: 400, boxHeight: 60))
        XCTAssertEqual(scale, 1.2, accuracy: 0.0001)
    }
}
