import Foundation

/// 파티클 시뮬레이션이 쓰는 난수. 테스트에서 결정적으로 바꿔 끼우기 위해 주입한다.
public protocol RandomSource: AnyObject {
    /// 0 이상 1 미만.
    func next() -> Double
}

/// SplitMix64. 시드가 같으면 같은 수열을 준다.
public final class SeededRandom: RandomSource {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        // 상위 53비트로 [0, 1) 을 만든다.
        return Double(z >> 11) * (1.0 / 9007199254740992.0)
    }
}
