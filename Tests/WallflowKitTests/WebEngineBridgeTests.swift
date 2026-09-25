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

    /// 실물 893418273의 `backgroundsource` 콤보는 project.json에 1~4 "숫자"로
    /// 적혀 있다. `UserProperty`는 씬 조건식 평가를 위해 콤보를 전부 `.text(String)`로
    /// 정규화해 두지만, 그걸 그대로 JSON 문자열로 보내면 페이지의
    /// `switch (properties.backgroundsource.value) { case 1: ... }`가 `"1" === 1`이
    /// 거짓이라 전부 비교에 실패해 그 안에서 설정하는 변수(`imageBackground`)가
    /// 끝내 선언되지 않고 ReferenceError로 applyUserProperties 전체가 중간에
    /// 죽는다(실물 앱에서 직접 관측). 숫자로 온전히 파싱되는 문자열은 JSON 숫자로
    /// 되돌려야 한다.
    func testNumericComboValueIsSentAsJSONNumberNotString() throws {
        let json = WebEngineBridge.propertiesJSON(["backgroundsource": .text("1")])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        XCTAssertEqual(object["backgroundsource"]?["value"] as? Int, 1)
        XCTAssertNil(object["backgroundsource"]?["value"] as? String,
            "숫자로 파싱되면 문자열로 남으면 안 된다")
    }

    /// 진짜 문자열 콤보("clock"/"orbs" 같은)는 그대로 문자열로 남아야 한다 —
    /// 숫자로 안 파싱되니 위 되돌리기가 손대지 않는다.
    func testNonNumericComboValueStaysString() throws {
        let json = WebEngineBridge.propertiesJSON(["mode": .text("clock")])
        XCTAssertTrue(json.contains("\"clock\""), json)
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

    /// 웹 배경화면이 소리에 실제로 반응하려면, 페이지가 `wallpaperRegisterAudioListener`를
    /// **부를 때**(등록만 해 두고 안 쓰는 페이지도 있으니 "정의돼 있다"가 아니라
    /// "불렀다") 앱에 알려야 `SceneRenderer.audioNeeders`에 등록할 수 있다.
    func testAudioRegistrationPostsMessageWhenPageCallsIt() {
        let js = WebEngineBridge.bootstrapJS
        // 등록 함수 본문 안에서 부르는지(정의만 해 두고 밖에서 조건 없이 부르면
        // 등록 여부와 상관없이 "필요하다"고 오판한다) — postMessage가
        // wallpaperRegisterAudioListener 대입문 뒤, 다음 대입문(__wallflowDispatchAudio)
        // 앞에 있는지로 확인한다.
        guard let assign = js.range(of: "window.wallpaperRegisterAudioListener = function"),
              let dispatch = js.range(of: "window.__wallflowDispatchAudio = function"),
              let postMessage = js.range(of: "postMessage") else {
            return XCTFail("등록/디스패치 함수를 못 찾았다: \(js)")
        }
        XCTAssertTrue(assign.upperBound < postMessage.lowerBound
            && postMessage.upperBound < dispatch.lowerBound,
            "postMessage는 등록 함수 안, 디스패치 함수보다 앞에 있어야 한다")
        XCTAssertTrue(js.contains("webkit.messageHandlers.\(WebEngineBridge.audioNeededMessageName)"))
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
