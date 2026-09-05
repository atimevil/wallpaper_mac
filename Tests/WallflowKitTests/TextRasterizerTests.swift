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
        let assets = try AssetsStore(root: URL(fileURLWithPath: assetsPath))
        let data = try assets.data(for: "fonts/Monofur-PK7og.ttf")
        let image = try TextRasterizer.rasterize(
            text: "12:34", fontData: data, pointSize: 64, color: white)
        XCTAssertGreaterThan(image.width, 0)
        // 시스템 폰트와 폭이 달라야 실제로 그 폰트를 쓴 것이다.
        let system = try TextRasterizer.rasterize(
            text: "12:34", fontData: nil, pointSize: 64, color: white)
        XCTAssertNotEqual(image.width, system.width, "폰트 바이트가 무시되고 있다")
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
