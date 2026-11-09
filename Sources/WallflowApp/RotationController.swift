import AppKit
import WallflowKit

/// 자동으로 바꾸기. 정해 둔 간격마다 다음 배경으로 바꾼다(무엇으로 바꿀지는 AppCoordinator).
///
/// `Timer`는 잠자기 동안을 세지 않고 앱을 다시 켜면 0부터 센다 — "하루"가 영영 안 온다.
/// 그래서 마지막으로 바꾼 시각을 저장해 두고, 짧은 주기로 "간격이 지났나"만 확인한다.
/// 전력 정책이 멈춤이어도 제때 바꾼다(멈춘 채로 불러온다) — 미뤘다 재개 순간에 바꾸면
/// 바탕화면을 보려고 드러낸 순간 배경이 바뀐다. 화면이 잠들어 있을 때만 건너뛴다.
@MainActor
final class RotationController {
    static let intervalKey = "wallflow.rotationInterval"
    static let shuffleKey = "wallflow.rotationShuffle"
    static let excludedKey = "wallflow.rotationExcluded"
    static let lastDateKey = "wallflow.rotationLastDate"

    /// 메뉴에 보일 간격(초). 0은 끔.
    static let choices: [(String, TimeInterval)] = [
        ("끔", 0), ("5분", 300), ("15분", 900), ("30분", 1800), ("1시간", 3600), ("하루", 86400),
    ]

    static var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: intervalKey)
        return v.isFinite && v > 0 ? v : 0
    }

    static var shuffle: Bool { UserDefaults.standard.bool(forKey: shuffleKey) }

    static var excluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: excludedKey) ?? [])
    }

    static func setExcluded(_ id: String, _ excluded: Bool) {
        var set = self.excluded
        if excluded { set.insert(id) } else { set.remove(id) }
        UserDefaults.standard.set(set.sorted(), forKey: excludedKey)
    }

    /// 바꾼 시각을 지금으로. 자동으로 바꿀 때, 사용자가 직접 고를 때, 간격을 켤 때 부른다.
    static func markChanged(_ now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: lastDateKey)
    }

    private static var lastChange: Date? {
        UserDefaults.standard.object(forKey: lastDateKey) as? Date
    }

    private let rotate: () -> Void
    private var timer: Timer?

    init(rotate: @escaping () -> Void) {
        self.rotate = rotate
    }

    /// 설정대로 다시 건다(멱등). 간격을 바꾸거나 앱이 뜰 때 부른다.
    func reload() {
        timer?.invalidate()
        timer = nil
        let interval = Self.interval
        guard interval > 0 else { return }
        if Self.lastChange == nil { Self.markChanged() }
        // 간격의 4분의 1마다, 길어도 1분마다 확인한다 — 하루 간격이어도 1분 안에 맞춘다.
        let period = max(1, min(60, interval / 4))
        let timer = Timer(timeInterval: period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = period / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let now = Date()
        // 시계가 크게 뒤로 갔으면(기준이 미래) 기준을 지금으로 — 안 그러면 그만큼 안 바뀐다.
        if let last = Self.lastChange, last > now { Self.markChanged(now) }
        guard WallpaperRotation.isDue(lastChange: Self.lastChange, now: now, interval: Self.interval)
        else { return }
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        Self.markChanged(now)
        rotate()
    }
}
