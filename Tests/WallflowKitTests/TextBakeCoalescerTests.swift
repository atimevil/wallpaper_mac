import XCTest
@testable import WallflowKit

/// `SceneRenderer.rasterizeAsync`가 실제로 쓰는 판정 로직. Metal 없이 여기서
/// 순서 문제 두 가지를 확정적으로 검증한다.
final class TextBakeCoalescerTests: XCTestCase {
    /// 정상 경로: 굽기 하나 시작해서 그대로 끝나면 반영한다.
    func testSingleBakeApplies() {
        var c = TextBakeCoalescer()
        guard case .bake(let token) = c.start(isEmpty: false) else {
            return XCTFail("첫 요청은 바로 구워야 한다")
        }
        XCTAssertEqual(c.finish(token: token), .apply)
    }

    /// 치명적 버그였던 경로: "A"→"B"(굽기 시작) → "B"→""(지움, 토큰 올림) →
    /// 늦게 끝난 "B" 결과가 와도 반영되면 안 된다.
    func testLateResultAfterClearIsDroppedNotShown() {
        var c = TextBakeCoalescer()
        guard case .bake(let bToken) = c.start(isEmpty: false) else {
            return XCTFail("\"B\"는 바로 구워야 한다")
        }
        // "B"가 굽는 도중 빈 문자열로 바뀐다. 토큰이 올라간다.
        XCTAssertEqual(c.start(isEmpty: true), .clear, "빈 문자열은 즉시 지워야 한다")
        // 늦게 끝난 "B" 굽기 결과가 이제 돌아온다.
        XCTAssertEqual(c.finish(token: bToken), .stale,
                       "지워진 뒤에 끝난 결과가 되살아나면 안 된다")
    }

    /// 굽기 속도보다 빠르게(예: 매 프레임) 값이 바뀌어도 동시에 굽는 건
    /// 하나뿐이어야 한다 — 시계처럼 계속 바뀌는 글자가 큐를 끝없이 늘리면 안 된다.
    func testRapidChangesCoalesceToAtMostOneInFlight() {
        var c = TextBakeCoalescer()
        guard case .bake = c.start(isEmpty: false) else {
            return XCTFail("첫 요청은 바로 구워야 한다")
        }
        // 굽는 동안 19번 더 바뀐다. 전부 기다려야지 새로 굽기 시작하면 안 된다
        // — 즉 이 시점에 "굽는 중"은 언제나 최대 하나다.
        for _ in 0..<19 {
            XCTAssertEqual(c.start(isEmpty: false), .wait,
                           "이미 굽는 중이면 큐에 더 쌓지 않고 기다려야 한다")
        }
    }

    /// 굽는 도중 더 바뀌었으면 끝났을 때 `.rebake`를 돌려주고, 그 재요청은
    /// 최신 값을 새 토큰으로 바로 굽기 시작한다 — "마지막 값이 결국 구워진다."
    func testFinishReturnsRebakeWhenCoalesced() {
        var c = TextBakeCoalescer()
        guard case .bake(let firstToken) = c.start(isEmpty: false) else {
            return XCTFail("첫 요청은 바로 구워야 한다")
        }
        for _ in 0..<19 {
            XCTAssertEqual(c.start(isEmpty: false), .wait)
        }
        // 첫 굽기가 끝난다. 그사이 요청이 쌓였으니 다시 구워야 한다 — 이
        // 결과(첫 굽기 결과)는 쓰지 않는다.
        XCTAssertEqual(c.finish(token: firstToken), .rebake)
        // 다시 구울 차례다 — 지금은 굽는 중이 아니므로 바로 시작해야 한다.
        guard case .bake(let secondToken) = c.start(isEmpty: false) else {
            return XCTFail("rebake 뒤 재요청은 바로 굽기 시작해야 한다")
        }
        XCTAssertNotEqual(firstToken, secondToken, "새 굽기는 새 토큰을 받아야 한다")
        XCTAssertEqual(c.finish(token: secondToken), .apply)
    }

    /// 지우는 요청 사이에 아무 굽기도 없었으면 그냥 지운다 — 상태가 꼬이지 않는다.
    func testClearWithNothingInFlightIsInert() {
        var c = TextBakeCoalescer()
        XCTAssertEqual(c.start(isEmpty: true), .clear)
        XCTAssertEqual(c.start(isEmpty: true), .clear)
    }
}
