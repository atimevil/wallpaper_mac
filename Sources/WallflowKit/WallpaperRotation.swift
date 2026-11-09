import Foundation

/// 자동으로 바꾸기의 순수 로직: 다음 배경 고르기, 바꿀 때가 됐는지.
public enum WallpaperRotation {
    /// 후보 중 다음 배경. 순서대로면 지금 것 다음(끝이면 처음), 지금 것이 후보에 없으면 처음 것.
    /// 무작위면 지금 것이 아닌 것 하나(`random(n)`은 0..<n). 바꿀 게 없으면 nil.
    public static func next(after current: String?, in candidates: [String], shuffle: Bool,
                            random: (Int) -> Int) -> String? {
        if shuffle {
            let pool = candidates.filter { $0 != current }
            guard !pool.isEmpty else { return nil }
            return pool[min(max(random(pool.count), 0), pool.count - 1)]
        }
        guard !candidates.isEmpty else { return nil }
        guard let current, let i = candidates.firstIndex(of: current) else { return candidates[0] }
        let next = candidates[(i + 1) % candidates.count]
        return next == current ? nil : next
    }

    /// 마지막으로 바꾼 뒤 간격이 지났나. 꺼짐(간격 0 이하)이거나 기준 시각이 없으면 아니다 —
    /// 켤 때 기준을 지금으로 잡는다. 기준이 미래(시계가 뒤로 감)여도 아니다.
    public static func isDue(lastChange: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard interval > 0, let lastChange else { return false }
        return now.timeIntervalSince(lastChange) >= interval
    }
}
