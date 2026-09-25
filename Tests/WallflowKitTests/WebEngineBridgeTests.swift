import XCTest
@testable import WallflowKit

/// 웹 배경화면용 WE API 부트스트랩 — 실물 3개(모듈 비주얼라이저/유체 애니메이션/
/// 오디오 비주얼라이저)가 전부 `applyUserProperties`를 못 받거나
/// `wallpaperRegisterAudioListener`가 없어 흰/검은 화면으로 멎어 있던 것을 고친다.
final class WebEngineBridgeTests: XCTestCase {
    func testPropertiesJSONWrapsEachValueInWEShape() throws {
        let json = WebEngineBridge.propertiesJSON([
            "audio_responsive": .toggle(true),
            "bloom_intensity": .number(0.8),
        ])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        XCTAssertEqual(object["audio_responsive"]?["value"] as? Bool, true)
        XCTAssertEqual(object["bloom_intensity"]?["value"] as? Double, 0.8)
    }

    /// 실물 스크립트(1748506393/script.js:87)가 `properties.background_color.value.split(" ")`로
    /// 읽는다 — 색은 공백으로 나눈 "r g b" 문자열이어야 한다.
    func testColorPropertyIsSpaceSeparated() throws {
        let json = WebEngineBridge.propertiesJSON([
            "background_color": .color(Vec3(x: 0, y: 0, z: 0)),
        ])
        XCTAssertTrue(json.contains("\"0.0 0.0 0.0\""), json)
    }

    func testApplyPropertiesJSGuardsMissingListener() {
        let js = WebEngineBridge.applyPropertiesJS(["paused": .toggle(false)])
        XCTAssertTrue(js.contains("window.wallpaperPropertyListener"))
        XCTAssertTrue(js.contains("applyUserProperties"))
        // 페이지가 리스너를 안 만들었어도 안전해야 한다 — typeof 가드가 있어야 한다.
        XCTAssertTrue(js.contains("typeof l.applyUserProperties === 'function'"))
    }

    func testBootstrapExposesAudioAndMediaRegistration() {
        XCTAssertTrue(WebEngineBridge.bootstrapJS.contains("wallpaperRegisterAudioListener"))
        XCTAssertTrue(WebEngineBridge.bootstrapJS.contains("wallpaperRegisterMediaPropertiesListener"))
        XCTAssertTrue(WebEngineBridge.bootstrapJS.contains("__wallflowDispatchAudio"))
    }

    /// 실물(893418273/main.js:840-850)이 `audioArray[0..63]`만 읽는다 — 왼쪽이 앞
    /// 64칸이어야 한다는 뜻이다.
    func testDispatchAudioJSPutsLeftChannelFirst() {
        let left: [Float] = Array(repeating: 1, count: 3)
        let right: [Float] = Array(repeating: 2, count: 3)
        let js = WebEngineBridge.dispatchAudioJS(left: left, right: right)
        XCTAssertTrue(js.contains("[1.0000,1.0000,1.0000,2.0000,2.0000,2.0000]"), js)
    }

    func testDispatchAudioJSReplacesNonFiniteWithZero() {
        let js = WebEngineBridge.dispatchAudioJS(
            left: [Float.nan, Float.infinity], right: [])
        XCTAssertTrue(js.contains("[0.0000,0.0000]"), js)
    }
}
