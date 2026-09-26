import Foundation

/// 타임라인 키프레임 하나. `{"frame":.., "value":.., "front":{"enabled":..,"x":..,"y":..},
/// "back":{...}}` 모양이다. `front`는 이 키프레임에서 다음 키프레임 쪽으로 나가는 손잡이,
/// `back`은 이전 키프레임에서 이 키프레임으로 들어오는 손잡이다.
public struct AnimationKeyframe: Equatable, Sendable {
    public let frame: Double
    public let value: Double
    public let frontEnabled: Bool
    public let front: Vec2
    public let backEnabled: Bool
    public let back: Vec2

    public init(frame: Double, value: Double,
                frontEnabled: Bool = false, front: Vec2 = Vec2(x: 1, y: 0),
                backEnabled: Bool = false, back: Vec2 = Vec2(x: -1, y: 0)) {
        self.frame = frame
        self.value = value
        self.frontEnabled = frontEnabled
        self.front = front
        self.backEnabled = backEnabled
        self.back = back
    }

    static func parse(_ raw: [String: Any]) -> AnimationKeyframe? {
        guard let frame = (raw["frame"] as? NSNumber)?.doubleValue, frame.isFinite,
              let value = (raw["value"] as? NSNumber)?.doubleValue, value.isFinite
        else { return nil }
        func handle(_ key: String) -> (enabled: Bool, vec: Vec2) {
            guard let dict = raw[key] as? [String: Any] else { return (false, Vec2(x: 0, y: 0)) }
            let enabled = dict["enabled"] as? Bool ?? false
            let x = (dict["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (dict["y"] as? NSNumber)?.doubleValue ?? 0
            return (enabled, Vec2(x: x.isFinite ? x : 0, y: y.isFinite ? y : 0))
        }
        let front = handle("front")
        let back = handle("back")
        return AnimationKeyframe(frame: frame, value: value,
                                  frontEnabled: front.enabled, front: front.vec,
                                  backEnabled: back.enabled, back: back.vec)
    }
}

public enum AnimationMode: String, Equatable, Sendable {
    case single, loop, mirror
}

/// 축 하나(스칼라 하나, 또는 벡터의 c0/c1/c2 중 하나)의 재생 가능한 커브.
public struct PropertyCurve: Equatable, Sendable {
    public let keyframes: [AnimationKeyframe]

    public init(keyframes: [AnimationKeyframe]) {
        self.keyframes = keyframes.sorted { $0.frame < $1.frame }
    }

    /// 프레임 좌표에서의 값. 첫/마지막 프레임보다 밖이면 그 끝 값에 고정한다.
    public func value(atFrame frame: Double) -> Double {
        guard let first = keyframes.first else { return 0 }
        guard let last = keyframes.last, keyframes.count > 1 else { return first.value }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i], b = keyframes[i + 1]
            if frame >= a.frame, frame <= b.frame { return Self.interpolate(a: a, b: b, frame: frame) }
        }
        return last.value
    }

    private static func interpolate(a: AnimationKeyframe, b: AnimationKeyframe, frame: Double) -> Double {
        let span = b.frame - a.frame
        guard span > 0 else { return a.value }
        guard a.frontEnabled, b.backEnabled else {
            let t = (frame - a.frame) / span
            return a.value + (b.value - a.value) * t
        }
        // 손잡이가 걸린 구간은 (프레임, 값) 평면의 3차 베지어다. 편집기 손잡이 길이는
        // 구간의 1/3로 본다(`locklength`가 늘 걸려 있어 편집기 자체가 그렇게 재는
        // 관행이다) — 실물 씬 전부가 x=±1, y=0(수평 손잡이, 완만한 가감속)이라
        // 정확한 배율을 알 길이 없어 통상적인 애니메이션 커브 편집기 관행을 따른다.
        let h = span / 3
        let p0x = a.frame, p0y = a.value
        let p1x = a.frame + a.front.x * h, p1y = a.value + a.front.y * h
        let p2x = b.frame + b.back.x * h, p2y = b.value + b.back.y * h
        let p3x = b.frame, p3y = b.value
        let t = bezierParameter(forX: frame, p0: p0x, p1: p1x, p2: p2x, p3: p3x)
        return cubic(t, p0y, p1y, p2y, p3y)
    }

    private static func cubic(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
        let mt = 1 - t
        return mt * mt * mt * p0 + 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t * p3
    }

    /// `x(t) == frame`인 t를 이분법으로 찾는다. 손잡이가 구간 진행 방향을 벗어나지
    /// 않는 한(실물 값 전부가 그렇다) x(t)는 단조증가라 이분법이 안전하다.
    private static func bezierParameter(
        forX x: Double, p0: Double, p1: Double, p2: Double, p3: Double
    ) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if cubic(mid, p0, p1, p2, p3) < x { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

/// WE 타임라인 애니메이션 하나(`{"c0": [...], "options": {...}, "relative": ...}`).
/// 스칼라(alpha·brightness)는 커브가 c0 하나고, 벡터(origin·scale·angles·color)는
/// c0~c2 세 축이다.
public struct PropertyAnimation: Equatable, Sendable {
    public let curves: [PropertyCurve]
    public let fps: Double
    /// 프레임 단위 길이. single은 이 값에서 멈추고, loop·mirror는 이 값으로 감아 돈다.
    public let length: Double
    public let mode: AnimationMode
    /// true면 커브 값이 절댓값이 아니라 저자가 편집기에서 남긴 정적 `value`(기준값)에
    /// 더하는 오프셋이다.
    public let relative: Bool

    public init(curves: [PropertyCurve], fps: Double, length: Double,
                mode: AnimationMode, relative: Bool) {
        self.curves = curves
        self.fps = fps
        self.length = length
        self.mode = mode
        self.relative = relative
    }

    /// `dict["animation"]` 자리의 원본(`Any?`)을 읽는다. 실패하면(옵션 없음, fps<=0,
    /// 커브가 비었음) nil — 그런 레이어는 정적 값 그대로 그린다.
    public static func parse(_ raw: Any?) -> PropertyAnimation? {
        guard let dict = raw as? [String: Any],
              let options = dict["options"] as? [String: Any],
              let fps = (options["fps"] as? NSNumber)?.doubleValue, fps.isFinite, fps > 0
        else { return nil }
        var curves: [PropertyCurve] = []
        for key in ["c0", "c1", "c2"] {
            guard let rawCurve = dict[key] as? [[String: Any]] else { break }
            let keyframes = rawCurve.compactMap(AnimationKeyframe.parse)
            guard !keyframes.isEmpty else { return nil }
            curves.append(PropertyCurve(keyframes: keyframes))
        }
        guard !curves.isEmpty else { return nil }
        let length = (options["length"] as? NSNumber)?.doubleValue ?? (curves[0].keyframes.last?.frame ?? 0)
        let mode = AnimationMode(rawValue: options["mode"] as? String ?? "") ?? .single
        let relative = dict["relative"] as? Bool ?? false
        return PropertyAnimation(
            curves: curves, fps: fps, length: Swift.max(length, 0), mode: mode, relative: relative)
    }

    /// single: 양끝에 고정. loop: length로 감아 돈다. mirror: 왕복(핑퐁)한다.
    func playbackFrame(atSeconds seconds: Double) -> Double {
        let raw = Swift.max(0, seconds) * fps
        guard length > 0 else { return raw }
        switch mode {
        case .single: return Swift.min(raw, length)
        case .loop: return raw.truncatingRemainder(dividingBy: length)
        case .mirror:
            let period = length * 2
            let m = raw.truncatingRemainder(dividingBy: period)
            return m <= length ? m : period - m
        }
    }

    /// t초일 때 각 축의 커브값(재생 모드만 적용한 값. `relative`는 아직 안 섞였다).
    public func curveValues(atSeconds seconds: Double) -> [Double] {
        let frame = playbackFrame(atSeconds: seconds)
        return curves.map { $0.value(atFrame: frame) }
    }

    /// 스칼라 하나(c0)와 저자가 남긴 기준값을 합쳐 최종값을 낸다.
    public func scalar(atSeconds seconds: Double, base: Double) -> Double {
        guard let v = curveValues(atSeconds: seconds).first else { return base }
        return relative ? base + v : v
    }

    /// 벡터(c0~c2)와 기준값을 축마다 합쳐 최종값을 낸다. 축이 c0뿐이면 나머지
    /// 축은 기준값 그대로다.
    public func vector(atSeconds seconds: Double, base: Vec3) -> Vec3 {
        let values = curveValues(atSeconds: seconds)
        func axis(_ index: Int, _ baseComponent: Double) -> Double {
            guard index < values.count else { return baseComponent }
            return relative ? baseComponent + values[index] : values[index]
        }
        return Vec3(x: axis(0, base.x), y: axis(1, base.y), z: axis(2, base.z))
    }
}
