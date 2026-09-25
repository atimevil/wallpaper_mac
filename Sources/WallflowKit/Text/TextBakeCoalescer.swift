import Foundation

/// 백그라운드 글자 굽기 요청을 조율하는 순수 상태 기계.
///
/// CoreText·Metal과 전혀 무관한 판단(지금 구울지, 기다릴지, 끝난 결과를
/// 버릴지)만 담아서 Kit에 둔다 — App 쪽 코드 없이도 이 판정만 단위 테스트할
/// 수 있다.
///
/// 두 가지 문제를 함께 푼다.
/// 1. **늦게 끝난 결과가 최신 값을 덮는 문제.** "B"를 굽는 도중 "B"→""로
///    바뀌면, 그 자리에서 바로 지우고 요청 번호(토큰)를 올려 둔다. 늦게 끝난
///    "B" 결과가 도착했을 때 토큰이 달라 버려진다(``finish(token:)``가
///    ``FinishDecision/stale``를 돌려준다).
/// 2. **굽기 속도보다 빠르게 바뀌는 글자가 큐를 무한정 늘리는 문제.** 이미
///    굽는 중이면 새로 굽기 시작하지 않고 "끝나면 다시 구워라"라고만 표시해
///    둔다(``StartDecision/wait``). `dirty`는 엣지 트리거라 —
///    `TextState.value`가 이미 새 값으로 바뀐 뒤에 불린다 — 건너뛴 요청은
///    다시 오지 않는다. 그래서 그냥 무시하면 안 되고, 끝나는 시점에
///    ``FinishDecision/rebake``로 "최신 값을 다시 읽어 한 번 더 구워라"를
///    돌려줘야 한다.
public struct TextBakeCoalescer: Equatable {
    private var token: UInt64 = 0
    private var inFlight = false
    private var needsRebake = false

    public init() {}

    public enum StartDecision: Equatable {
        /// 빈 글자(또는 공백만)다. 굽지 않고 바로 지운다.
        case clear
        /// 지금 바로 굽기 시작한다. 끝나면 이 토큰으로 ``finish(token:)``를 부른다.
        case bake(token: UInt64)
        /// 이미 굽는 중이다. 큐에 더 넣지 않고 기다린다 — 끝나면 최신 값으로
        /// 다시 구워질 것이다.
        case wait
    }

    /// 값이 바뀌어 다시 구워야 할 때 부른다.
    ///
    /// 토큰은 `isEmpty` 여부와 무관하게 **항상 먼저** 올린다 — 그래야 굽는
    /// 도중 빈 문자열로 바뀐 경우에도 늦게 끝난 결과가 토큰 불일치로 버려진다.
    @discardableResult
    public mutating func start(isEmpty: Bool) -> StartDecision {
        token &+= 1
        guard !isEmpty else { return .clear }
        guard !inFlight else {
            needsRebake = true
            return .wait
        }
        inFlight = true
        return .bake(token: token)
    }

    public enum FinishDecision: Equatable {
        /// 굽는 동안 또 값이 바뀌었다. 최신 값을 다시 읽어 ``start(isEmpty:)``를
        /// 한 번 더 불러야 한다 — 지금 들고 있는 결과는 쓰지 않는다.
        case rebake
        /// 이 결과보다 최신 요청(다른 굽기나 지우기)이 있었다. 버린다.
        case stale
        /// 이 결과를 그대로 반영한다.
        case apply
    }

    /// 백그라운드 굽기가 끝났을 때, 그 굽기를 시작시킨 `token`(``StartDecision/bake(token:)``이
    /// 돌려준 값)으로 부른다.
    @discardableResult
    public mutating func finish(token completedToken: UInt64) -> FinishDecision {
        inFlight = false
        if needsRebake {
            needsRebake = false
            return .rebake
        }
        guard token == completedToken else { return .stale }
        return .apply
    }
}
