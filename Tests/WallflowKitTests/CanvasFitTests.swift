import XCTest
@testable import WallflowKit

/// `CanvasFit`는 캔버스를 화면에 맞추는 순수 수학이다. WE 문서(성능/해상도 페이지)는
/// "화면에 적용하면 옆을 잘라 채운다"고 적어 뒀다 — 그게 채우기(cover)이고 기본값이다.
final class CanvasFitTests: XCTestCase {
    private func XCTAssertRect(
        _ rect: CanvasFit.Rect, origin: SIMD2<Double>, size: SIMD2<Double>,
        _ message: String = "", accuracy: Double = 0.001,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(rect.origin.x, origin.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.origin.y, origin.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.size.x, size.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.size.y, size.y, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - 채우기(cover)

    /// 16:9 캔버스를 1.547 화면에 채우면 화면이 캔버스보다 좁은 비율이라 좌우가 잘린다.
    func testCoverOnNarrowerScreenCropsSides() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1547, 1000), mode: .cover, zoom: 1)
        // 높이가 꽉 차고(1080 그대로) 너비만 줄어든다 — 좌우 잘림.
        XCTAssertRect(rect, origin: SIMD2(124.62, 0), size: SIMD2(1670.76, 1080))
    }

    /// 21:9급 초광폭 화면은 반대로 위아래가 잘린다.
    func testCoverOnUltrawideScreenCropsTopAndBottom() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(2560, 1080), mode: .cover, zoom: 1)
        XCTAssertRect(rect, origin: SIMD2(0, 135), size: SIMD2(1920, 810))
    }

    /// 세로형 캔버스(810x1080, 실물 3794448602)를 가로 화면에 채우면 위아래를 크게 잃는다.
    func testCoverOnPortraitCanvasCropsTopAndBottom() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(810, 1080), screen: SIMD2(1920, 1080), mode: .cover, zoom: 1)
        XCTAssertRect(rect, origin: SIMD2(0, 312.1875), size: SIMD2(810, 455.625))
    }

    /// 4:3 화면도 16:9 캔버스의 좌우를 자른다.
    func testCoverOnFourByThreeScreenCropsSides() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1024, 768), mode: .cover, zoom: 1)
        XCTAssertRect(rect, origin: SIMD2(240, 0), size: SIMD2(1440, 1080))
    }

    // MARK: - 전체 보기(contain)

    /// 전체 보기는 반대로 캔버스보다 넓게 보여준다(letterbox) — 보이는 크기가
    /// 캔버스보다 크고 원점이 음수라 캔버스 밖(여백)까지 드러난다.
    func testContainShowsMoreThanCanvasWithBars() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1024, 768), mode: .contain, zoom: 1)
        XCTAssertRect(rect, origin: SIMD2(0, -180), size: SIMD2(1920, 1440))
    }

    // MARK: - 같은 비율 → 항등

    /// 화면과 캔버스 비율이 같으면 세 방식 모두 캔버스를 그대로 보여준다.
    func testSameAspectIsIdentityForAllModes() {
        let canvas = SIMD2<Double>(1920, 1080)
        let screen = SIMD2<Double>(1280, 720) // 같은 16:9
        for mode: CanvasFit.Mode in [.cover, .contain, .stretch] {
            let rect = CanvasFit.visibleRect(canvas: canvas, screen: screen, mode: mode, zoom: 1)
            XCTAssertRect(rect, origin: .zero, size: canvas,
                          "\(mode)는 같은 비율에서 항등이어야 한다")
        }
    }

    // MARK: - 늘이기(stretch, 오늘의 기본 동작)

    /// 늘이기는 축마다 따로 늘여 캔버스 전체가 화면 전체와 같다 — zoom이 1이면
    /// 지금까지의 동작(스트레치, 잘리지도 남지도 않음)과 정확히 같다.
    func testStretchAtZoomOneMatchesTodaysBehavior() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1547, 1000), mode: .stretch, zoom: 1)
        XCTAssertRect(rect, origin: .zero, size: SIMD2(1920, 1080))
    }

    /// 늘이기도 zoom은 받는다 — "늘이기는 zoom을 무시한다"고 오해하지 않게, 화면
    /// 비율과 무관하게 캔버스/zoom로 줄어드는 것을 확인한다.
    func testStretchStillAppliesZoom() {
        let zoomed = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1280, 720), mode: .stretch, zoom: 1.08)
        // 스트레치는 화면 크기와 무관하게 보이는 크기가 canvas/zoom이 된다.
        XCTAssertRect(zoomed, origin: SIMD2(71.111, 40), size: SIMD2(1777.778, 1000))
        let differentScreen = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(3000, 500), mode: .stretch, zoom: 1.08)
        XCTAssertRect(differentScreen, origin: SIMD2(71.111, 40), size: SIMD2(1777.778, 1000))
    }

    // MARK: - zoom (general.zoom)

    /// zoom 1.08 = "8% 더 확대" = 보이는 사각형이 그만큼 더 작아진다(더 많이 잘린다).
    func testZoomShrinksVisibleRectBy8Percent() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1920, 1080), mode: .cover, zoom: 1.08)
        XCTAssertRect(rect, origin: SIMD2(71.111, 40), size: SIMD2(1777.778, 1000))
    }

    /// 0 이하·NaN·무한대는 전부 "확대 없음"(1)로 본다 — 씬이 깨진 zoom 값을 줘도
    /// 화면이 사라지면 안 된다.
    func testInvalidZoomFallsBackToOne() {
        let baseline = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1920, 1080), mode: .cover, zoom: 1)
        for invalid: Double in [0, -1, .nan, .infinity, -.infinity] {
            let rect = CanvasFit.visibleRect(
                canvas: SIMD2(1920, 1080), screen: SIMD2(1920, 1080), mode: .cover, zoom: invalid)
            XCTAssertEqual(rect, baseline, "zoom=\(invalid)은 1과 같아야 한다")
        }
    }

    // MARK: - 역변환 왕복

    /// 화면 비율 → 캔버스 좌표 → 화면 비율로 되돌리면 원래 값이 나와야 한다.
    /// `sceneCursorPosition`이 이 역방향을 쓴다.
    func testScreenFractionAndCanvasPointRoundTrip() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1547, 1000), mode: .cover, zoom: 1)
        for fraction in [SIMD2<Double>(0, 0), SIMD2(1, 1), SIMD2(0.5, 0.5), SIMD2(0.25, 0.75)] {
            let point = rect.canvasPoint(atScreenFraction: fraction)
            let back = rect.screenFraction(of: point)
            XCTAssertEqual(back.x, fraction.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, fraction.y, accuracy: 1e-9)
        }
        for point in [SIMD2<Double>(0, 0), SIMD2(1920, 1080), SIMD2(960, 540)] {
            let fraction = rect.screenFraction(of: point)
            let back = rect.canvasPoint(atScreenFraction: fraction)
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
        }
    }

    /// 화면 왼쪽아래 원점(0,0)은 늘 보이는 사각형의 원점이고, (1,1)은 원점+크기다.
    func testCanvasPointAtCornersMatchesRectBounds() {
        let rect = CanvasFit.visibleRect(
            canvas: SIMD2(1920, 1080), screen: SIMD2(1547, 1000), mode: .cover, zoom: 1)
        let bottomLeft = rect.canvasPoint(atScreenFraction: SIMD2(0, 0))
        XCTAssertEqual(bottomLeft.x, rect.origin.x, accuracy: 1e-9)
        XCTAssertEqual(bottomLeft.y, rect.origin.y, accuracy: 1e-9)
        let topRight = rect.canvasPoint(atScreenFraction: SIMD2(1, 1))
        XCTAssertEqual(topRight.x, rect.origin.x + rect.size.x, accuracy: 1e-9)
        XCTAssertEqual(topRight.y, rect.origin.y + rect.size.y, accuracy: 1e-9)
    }

    // MARK: - 저장된 배경화면별 설정

    func testModeDefaultsToCoverWhenWallpaperUnknown() {
        XCTAssertEqual(CanvasFit.mode(for: "missing-id", in: [:]), .cover)
    }

    func testModeFallsBackToDefaultOnUnknownRawValue() {
        XCTAssertEqual(CanvasFit.mode(for: "id", in: ["id": "bogus"]), .cover)
    }

    func testModeReadsStoredValue() {
        XCTAssertEqual(CanvasFit.mode(for: "id", in: ["id": "contain"]), .contain)
        XCTAssertEqual(CanvasFit.mode(for: "id", in: ["id": "stretch"]), .stretch)
    }

    func testSettingModeSavesAndRoundTrips() {
        let updated = CanvasFit.settingMode(.stretch, for: "id", in: [:])
        XCTAssertEqual(CanvasFit.mode(for: "id", in: updated), .stretch)
    }

    /// 다른 배경화면의 설정은 건드리지 않는다.
    func testSettingModePreservesOtherWallpapers() {
        let updated = CanvasFit.settingMode(.contain, for: "b", in: ["a": "stretch"])
        XCTAssertEqual(CanvasFit.mode(for: "a", in: updated), .stretch)
        XCTAssertEqual(CanvasFit.mode(for: "b", in: updated), .contain)
    }
}
