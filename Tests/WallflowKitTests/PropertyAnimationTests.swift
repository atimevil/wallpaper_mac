import XCTest
@testable import WallflowKit

/// 타임라인 키프레임 애니메이션 파싱·재생. JSON은 실물 씬 3147346398
/// (Minecraft Lo-Fi Fireplace)와 2938612768("1比1")에서 그대로 옮겼다.
final class PropertyAnimationTests: XCTestCase {
    /// 3147346398 "Solid Placeholder" alpha: 단발(single), 30fps에 120프레임(4초)
    /// 동안 1→0으로 페이드한다. `relative`가 없다 — alpha는 절댓값이다.
    private let fireplaceAlphaJSON: [String: Any] = [
        "c0": [
            ["frame": 0, "value": 1,
             "front": ["enabled": true, "x": 1.0, "y": 0], "back": ["enabled": true, "x": -1.0, "y": 0]],
            ["frame": 120, "value": 0,
             "front": ["enabled": true, "x": 1.0, "y": 0], "back": ["enabled": true, "x": -1.0, "y": 0]],
        ],
        "options": ["fps": 30, "length": 120, "mode": "single", "wraploop": NSNull()],
    ]

    func testFireplaceAlphaParsesAsSingleAbsolute() {
        let anim = PropertyAnimation.parse(fireplaceAlphaJSON)
        let unwrapped = try! XCTUnwrap(anim)
        XCTAssertEqual(unwrapped.mode, .single)
        XCTAssertFalse(unwrapped.relative)
        XCTAssertEqual(unwrapped.fps, 30)
        XCTAssertEqual(unwrapped.length, 120)
        XCTAssertEqual(unwrapped.curves.count, 1)
    }

    /// 핵심 회귀: 예전 "정착값" 지름길은 재생 없이 항상 마지막 값(0)을 줬다.
    /// 이제는 실제 시간에 따라 논다 — 시작은 불투명, 중간은 반, 끝은 투명, 그
    /// 뒤로는(단발이라) 투명에 고정된다.
    func testFireplaceAlphaPlaysOverFourSeconds() {
        let anim = try! XCTUnwrap(PropertyAnimation.parse(fireplaceAlphaJSON))
        XCTAssertEqual(anim.scalar(atSeconds: 0, base: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(anim.scalar(atSeconds: 2, base: 1), 0.5, accuracy: 1e-6)
        XCTAssertEqual(anim.scalar(atSeconds: 4, base: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(anim.scalar(atSeconds: 10, base: 1), 0, accuracy: 1e-9, "단발은 끝값에 고정된다")
    }

    /// 2938612768 "1比1" origin.c1(y축): mirror, 1.2fps에 60프레임(50초) 길이.
    /// `relative: true`라 커브값은 기준 좌표(1080)에 더하는 오프셋이다.
    private let mirrorOriginYJSON: [String: Any] = [
        "c0": [
            ["frame": 0, "value": 0, "front": ["enabled": false], "back": ["enabled": false]],
            ["frame": 60, "value": 0, "front": ["enabled": false], "back": ["enabled": false]],
        ],
        "c1": [
            ["frame": 0, "value": -680, "front": ["enabled": false], "back": ["enabled": false]],
            ["frame": 60, "value": 660, "front": ["enabled": false], "back": ["enabled": false]],
        ],
        "c2": [
            ["frame": 0, "value": 0, "front": ["enabled": false], "back": ["enabled": false]],
            ["frame": 60, "value": 0, "front": ["enabled": false], "back": ["enabled": false]],
        ],
        "options": ["fps": 1.2, "length": 60, "mode": "mirror", "wraploop": NSNull()],
        "relative": true,
    ]

    func testMirrorModePingPongsAtHalfway() {
        let anim = try! XCTUnwrap(PropertyAnimation.parse(mirrorOriginYJSON))
        let base = Vec3(x: 1920, y: 1080, z: 0)
        // 50초 길이(60프레임 / 1.2fps)를 왕복한다.
        XCTAssertEqual(anim.vector(atSeconds: 0, base: base).y, 1080 - 680, accuracy: 1e-6)
        XCTAssertEqual(anim.vector(atSeconds: 50, base: base).y, 1080 + 660, accuracy: 1e-6, "절반에서 끝값")
        // 되짚어 온 지점(1.5배 길이)은 다시 처음 값으로 돌아온다.
        XCTAssertEqual(anim.vector(atSeconds: 100, base: base).y, 1080 - 680, accuracy: 1e-6,
                       "한 바퀴 왕복 뒤에는 시작값으로 되짚는다")
    }

    /// loop 모드는 length로 감아 돈다(끝나면 다시 처음부터).
    func testLoopModeWrapsAtLength() {
        let json: [String: Any] = [
            "c0": [
                ["frame": 0, "value": 10, "front": ["enabled": false], "back": ["enabled": false]],
                ["frame": 30, "value": 20, "front": ["enabled": false], "back": ["enabled": false]],
            ],
            "options": ["fps": 30, "length": 30, "mode": "loop"],
        ]
        let anim = try! XCTUnwrap(PropertyAnimation.parse(json))
        XCTAssertEqual(anim.scalar(atSeconds: 0, base: 0), 10, accuracy: 1e-9)
        XCTAssertEqual(anim.scalar(atSeconds: 1 - 1.0 / 60, base: 0), 20, accuracy: 0.2,
                       "길이 끝 바로 전(29프레임째)은 끝값에 가깝다")
        XCTAssertEqual(anim.scalar(atSeconds: 1, base: 0), 10, accuracy: 1e-9,
                       "1초=30프레임=길이 끝 → 감아 돌아 다시 처음 프레임")
    }

    /// 손잡이(front/back)가 둘 다 켜져 있으면 직선이 아니라 완만한 S자(가감속)로
    /// 논다 — 구간 중앙이 직선 보간값(0.5)보다 시작 쪽에 더 붙어 있다.
    func testBezierHandlesEaseInsteadOfLinear() {
        let json: [String: Any] = [
            "c0": [
                ["frame": 0, "value": 0,
                 "front": ["enabled": true, "x": 1.0, "y": 0], "back": ["enabled": true, "x": -1.0, "y": 0]],
                ["frame": 10, "value": 1,
                 "front": ["enabled": true, "x": 1.0, "y": 0], "back": ["enabled": true, "x": -1.0, "y": 0]],
            ],
            "options": ["fps": 10, "length": 10, "mode": "single"],
        ]
        let anim = try! XCTUnwrap(PropertyAnimation.parse(json))
        let midpoint = anim.scalar(atSeconds: 0.5, base: 0)
        XCTAssertEqual(midpoint, 0.5, accuracy: 1e-6, "구간 한가운데는 직선과 같다(대칭 S자)")
        let quarter = anim.scalar(atSeconds: 0.25, base: 0)
        XCTAssertLessThan(quarter, 0.25, "가감속 커브는 시작에서 직선보다 느리게 붙는다")
    }

    func testMalformedAnimationParsesToNil() {
        XCTAssertNil(PropertyAnimation.parse("not a dict"))
        XCTAssertNil(PropertyAnimation.parse(["c0": []] as [String: Any]))
        XCTAssertNil(PropertyAnimation.parse(["c0": [["frame": 0, "value": 1]], "options": ["fps": 0]]))
    }
}
