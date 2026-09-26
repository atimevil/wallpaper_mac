import XCTest
@testable import WallflowKit

/// 데스크톱 마우스를 웹 배경화면에 넘기는 좌표 변환 — 세 좌표계(AppKit 전역/Quartz
/// 창 목록/DOM 페이지)를 잘못 섞으면 커서가 화면과 반대로 움직이거나 엉뚱한 곳을
/// 찍는다.
final class WebCursorBridgeTests: XCTestCase {
    /// AppKit은 왼쪽 아래가 원점, Quartz는 왼쪽 위가 원점 — 화면 맨 위(AppKit y =
    /// 화면 높이)가 Quartz y = 0이어야 한다.
    func testQuartzPointFlipsY() {
        let top = WebCursorBridge.quartzPoint(
            appKit: CGPoint(x: 10, y: 1080), primaryScreenHeight: 1080)
        XCTAssertEqual(top, CGPoint(x: 10, y: 0))
        let bottom = WebCursorBridge.quartzPoint(
            appKit: CGPoint(x: 10, y: 0), primaryScreenHeight: 1080)
        XCTAssertEqual(bottom, CGPoint(x: 10, y: 1080))
    }

    /// 창의 왼쪽 위 구석 바로 안쪽이 페이지 좌표 (0,0) 근처여야 한다.
    /// (`CGRect.contains`가 max 변은 반열림이라 정확한 모서리 자체는 뺀다.)
    func testPagePointOriginIsWindowTopLeft() throws {
        let windowFrame = CGRect(x: 100, y: 200, width: 1920, height: 1080)
        let point = try XCTUnwrap(WebCursorBridge.pagePoint(
            screenPoint: CGPoint(x: 100, y: 200 + 1079), windowFrame: windowFrame))
        XCTAssertEqual(point, CGPoint(x: 0, y: 1))
    }

    /// 창의 오른쪽 아래 구석 바로 안쪽이 페이지 크기(너비, 높이) 근처여야 한다.
    func testPagePointBottomRightIsWindowSize() throws {
        let windowFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let point = try XCTUnwrap(WebCursorBridge.pagePoint(
            screenPoint: CGPoint(x: 1919, y: 0), windowFrame: windowFrame))
        XCTAssertEqual(point, CGPoint(x: 1919, y: 1080))
    }

    /// 창 밖 점은 이 화면 담당이 아니다 — nil.
    func testPagePointOutsideWindowIsNil() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertNil(WebCursorBridge.pagePoint(
            screenPoint: CGPoint(x: 3000, y: 500), windowFrame: windowFrame))
    }

    /// 폭·높이가 0인 창(아직 배치 전)은 아무 점도 담당하지 않는다.
    func testPagePointDegenerateWindowIsNil() {
        XCTAssertNil(WebCursorBridge.pagePoint(
            screenPoint: .zero, windowFrame: .zero))
    }

    func testMouseEventJSDispatchesAtElementFromPoint() {
        let js = WebCursorBridge.mouseEventJS(type: "mousemove", x: 12.5, y: 34)
        XCTAssertTrue(js.contains("elementFromPoint"))
        XCTAssertTrue(js.contains("'mousemove'"))
        XCTAssertTrue(js.contains("var x = 12.5, y = 34.0"))
        XCTAssertTrue(js.contains("clientX: x, clientY: y"))
    }
}
