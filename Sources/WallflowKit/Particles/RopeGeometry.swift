import Foundation

/// 로프·로프 트레일 파티클을 이어진 띠(리본)로 만드는 지오메트리.
///
/// 실물 `genericropeparticle.vert`/`.geom`을 그대로 옮겼다 — 카트멀롬 곡선을
/// 베지어로 바꿔(장력 0.15) `subdivision`개 보간점을 넣고, 각 점에서 리본의
/// 폭 방향(법선)을 만든다. 지오메트리 셰이더가 없는 대신 CPU에서 점 목록을
/// 만들고, 렌더러가 그 점마다 정점 두 개(좌우)를 펼쳐 삼각형 스트립으로 그린다.
public enum RopeGeometry {
    /// 리본의 점 하나. 렌더러가 `position ± right`로 정점 두 개를 만든다.
    public struct Point: Equatable, Sendable {
        public var position: Vec3
        /// 접선(카트멀롬)에 수직인 오프셋 벡터. 길이가 **입자 크기**다(직교 2D,
        /// z는 0). 실물 `.geom`은 `|right| = size`로 반폭을 만든다 — 정점이
        /// `position - right`/`position + right`이니 전체 폭은 2*size다.
        /// 브리프 문구 "폭 = 입자 크기"는 이 반폭 기준으로 읽었다: 폭 자체를
        /// size로 두면(반폭 size/2) 실물보다 리본이 절반으로 가늘어진다.
        public var right: Vec3
        public var color: Vec3
        public var alpha: Double
        /// UV의 V(세로). U는 렌더러가 좌우 정점에 0/1로 준다.
        public var v: Double

        public init(position: Vec3, right: Vec3, color: Vec3, alpha: Double, v: Double) {
            self.position = position
            self.right = right
            self.color = color
            self.alpha = alpha
            self.v = v
        }
    }

    /// `rope` 렌더러. `orderedParticles`는 이미 `ParticleSystem.ropeOrderedParticles`가
    /// 정렬한 순서(age 내림차순, 동률은 생성 순번 오름차순)여야 한다.
    /// 파티클이 0·1개면 이을 선분이 없어 빈 배열이다.
    public static func rope(
        orderedParticles: [Particle], subdivision: Int, uvScale: Double
    ) -> [Point] {
        build(orderedParticles, subdivision: subdivision, uvNormalizer: nil,
              uvScale: uvScale, fadeAlpha: false)
    }

    /// `ropetrail` 렌더러. `segments`가 UV와 페이드를 정규화하는 값이다(실물
    /// `.vert`의 `in_SegmentMaxCount`) — `length`는 GPU 쪽의 자동 트레일 스폰과
    /// 관련된 값이라 이 이산 파티클 모델에는 쓸 자리가 없다.
    public static func ropeTrail(
        orderedParticles: [Particle], subdivision: Int, segments: Int, fadeAlpha: Bool,
        uvScale: Double
    ) -> [Point] {
        build(orderedParticles, subdivision: subdivision, uvNormalizer: max(1, segments),
              uvScale: uvScale, fadeAlpha: fadeAlpha)
    }

    private static func build(
        _ particles: [Particle], subdivision: Int, uvNormalizer: Int?, uvScale: Double,
        fadeAlpha: Bool
    ) -> [Point] {
        let n = particles.count
        guard n >= 2 else { return [] }
        let sub = max(0, subdivision)
        // rope는 n-1(마디 수)로 정규화한다(브리프의 V = 1 - i/(n-1)).
        // ropetrail은 `segments`로 정규화한다(실물 `.vert`가 트레일 렌더러의
        // 최대 마디 수로 나눈다 — 트레일이 아직 안 다 자랐으면 n-1 < segments라
        // 머리 쪽 V/페이드가 0·1에 못 닿는다. 이게 실물 동작이다).
        let denom = Double(uvNormalizer ?? max(1, n - 1))

        // 카트멀롬 접선. 끝점은 이웃을 자기 자신으로 클램프해 세그먼트 방향으로
        // 내려앉는다 — .geom이 이 경우를 안 보여 주지만, 유일하게 말이 되는 값이다.
        func tangent(at i: Int) -> Vec3 {
            let prev = particles[max(0, i - 1)].position
            let next = particles[min(n - 1, i + 1)].position
            return Vec3(x: next.x - prev.x, y: next.y - prev.y, z: 0)
        }
        func perpendicular(_ v: Vec3) -> Vec3 {
            let length = (v.x * v.x + v.y * v.y).squareRoot()
            guard length > 1e-9 else { return Vec3(x: 0, y: 0, z: 0) }
            return Vec3(x: -v.y / length, y: v.x / length, z: 0)
        }
        func right(at i: Int) -> Vec3 {
            let normal = perpendicular(tangent(at: i))
            let size = particles[i].size
            return Vec3(x: normal.x * size, y: normal.y * size, z: 0)
        }
        func v(at i: Int) -> Double { (1 - Double(i) / denom) * uvScale }
        // 실물 `.vert`의 `sin(saturate(idx/usableLength) * π)` — idx=0(꼬리)과
        // idx=usableLength(머리, 다 자란 트레일)에서 0이고 가운데서 1이다.
        func fade(at i: Int) -> Double {
            guard fadeAlpha else { return 1 }
            let x = min(max(Double(i) / denom, 0), 1)
            return sin(.pi * x)
        }
        func mix(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
            Vec3(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
        }
        func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        func cubicBezier(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3, _ t: Double) -> Vec3 {
            let u = 1 - t
            let b0 = u * u * u, b1 = 3 * t * u * u, b2 = 3 * t * t * u, b3 = t * t * t
            return Vec3(
                x: b0 * a.x + b1 * b.x + b2 * c.x + b3 * d.x,
                y: b0 * a.y + b1 * b.y + b2 * c.y + b3 * d.y,
                z: b0 * a.z + b1 * b.z + b2 * c.z + b3 * d.z)
        }

        var out: [Point] = []
        out.reserveCapacity((n - 1) * (sub + 1) + 1)
        out.append(Point(
            position: particles[0].position, right: right(at: 0), color: particles[0].color,
            alpha: particles[0].alpha * fade(at: 0), v: v(at: 0)))

        for i in 0..<(n - 1) {
            let start = particles[i], end = particles[i + 1]
            let tangentStart = tangent(at: i), tangentEnd = tangent(at: i + 1)
            // 카트멀롬→베지어(장력 0.15): B1 = P_i + t*(P_{i+1}-P_{i-1}),
            // B2 = P_{i+1} - t*(P_{i+2}-P_i). 실물 `.geom`의
            // `CPStart = start + 0.15*CPStart`, `CPEnd = end + 0.15*CPEnd`와 같다.
            let b1 = Vec3(x: start.position.x + 0.15 * tangentStart.x,
                          y: start.position.y + 0.15 * tangentStart.y, z: 0)
            let b2 = Vec3(x: end.position.x - 0.15 * tangentEnd.x,
                          y: end.position.y - 0.15 * tangentEnd.y, z: 0)
            let rightStart = right(at: i), rightEnd = right(at: i + 1)
            let aStart = start.alpha * fade(at: i), aEnd = end.alpha * fade(at: i + 1)

            if sub > 0 {
                for k in 1...sub {
                    // .geom: `s = smoothstep(0, 1, subDivCounter)`,
                    // subDivCounter = k / (subdivision + 1).
                    let t = smoothstep(Double(k) / Double(sub + 1))
                    let position = cubicBezier(start.position, b1, b2, end.position, t)
                    out.append(Point(
                        position: position, right: mix(rightStart, rightEnd, t),
                        color: mix(start.color, end.color, t), alpha: aStart + (aEnd - aStart) * t,
                        v: v(at: i) + (v(at: i + 1) - v(at: i)) * t))
                }
            }
            out.append(Point(
                position: end.position, right: rightEnd, color: end.color, alpha: aEnd,
                v: v(at: i + 1)))
        }
        return out
    }
}
