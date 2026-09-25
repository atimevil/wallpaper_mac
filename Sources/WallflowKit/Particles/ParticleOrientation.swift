import Foundation

/// `sprite` 렌더러의 `orientation` 필드. WE 문서(Particle Component - Renderers)의
/// Orientation 옵션 중 셋 — Screen(기본)/Upright/Fixed. 네 번째 Worldspace는
/// "카메라가 회전할 때만" 뜻이 갈리는 토글이라(문서: "mostly relevant when
/// Orientation is set to Upright or Fixed") 우리 카메라(직교, 고정, 절대 안
/// 돈다)에서는 셋 다와 마찬가지로 영향이 없다 — 파싱하지 않는다.
public enum ParticleSpriteOrientation: Equatable, Sendable {
    /// 항상 카메라(화면)를 향한다. 안 적으면 이것 — 실물 다수(`orb.json`
    /// 등)가 아예 `orientation` 필드를 안 적는다.
    case screen
    /// 월드 업으로 세운 채 카메라를 향해 돈다. 문서: "Mainly for 3D scenes."
    case upright
    /// `axis`가 판의 법선이다 — 카메라를 안 본다. 문서: "Mainly for 3D scenes."
    /// 예: 3D 씬의 빗방울 자국을 바닥에 눕히려면 축을 Y로 준다.
    case fixed

    public static func parse(_ raw: Any?) -> ParticleSpriteOrientation {
        switch (raw as? String)?.lowercased() {
        case "upright": return .upright
        case "fixed": return .fixed
        default: return .screen
        }
    }
}

/// `orientation`/`axis`를 실제 빌보드 축(회전 적용 **전**)으로 바꾼다.
///
/// WE 호스트는 매 드로우콜 전에 `g_OrientationRight`/`g_OrientationUp`/
/// `g_OrientationForward`를 채워 셰이더에 넘긴다(카메라·씬 상태에 달렸다 —
/// 셰이더 자체엔 이 계산이 없다, `common_particles.h`의
/// `ComputeParticleTangents`는 그 값을 받아서만 쓴다). 우리 렌더러는 카메라가
/// 늘 직교·고정이라(`ParticleTrailTangent`의 `eyeDirection = (0,0,-1)`과 같은
/// 가정 — 씬 좌표계는 y-up이고 카메라는 +z에서 -z를 본다) 그 계산을 고정
/// 카메라 기저로 대신한다.
///
/// `ComputeParticleTangents`는 `mRotation = (회전행렬) * mat3(orientRight,
/// orientUp, orientForward)`를 만들고 `right = mRotation의 0번째 열`,
/// `up = mRotation의 1번째 열`을 쓴다. 열 계산은 forward 없이도 끝난다 —
/// `(A*B)`의 0번째 열은 `A * B의 0번째 열`이라, `right = 회전행렬 * orientRight`,
/// `up = 회전행렬 * orientUp`이면 충분하다(App의 `particle_vertex`가 이 축에
/// 파티클 회전을 곱한다 — 여기서는 회전 전 축만 낸다).
public enum ParticleOrientationBasis {
    public struct Axes: Equatable {
        public let right: Vec3
        public let up: Vec3
    }

    /// 우리 카메라의 고정 기저. `ParticleTrailTangent`와 같은 가정 —
    /// 화면 axis: right=+x, up=+y, (카메라→파티클 방향은 +z, 카메라가 보는
    /// 방향은 -z). 씬이 원근 변환을 걸어도(`useTransform`) 그 변환은 빌보드를
    /// 만든 **다음** 레이어 전체에 적용된다(`particle_vertex`의 `u.transform`) —
    /// 카메라 자체가 도는 게 아니라 레이어가 통째로 돈다는 뜻이라, 빌보드
    /// 축 계산에서는 카메라가 항상 이 기저다.
    private static let cameraRight = Vec3(x: 1, y: 0, z: 0)
    private static let cameraUp = Vec3(x: 0, y: 1, z: 0)
    /// 파티클에서 카메라로 향하는 방향(카메라가 보는 방향의 반대).
    private static let towardCamera = Vec3(x: 0, y: 0, z: 1)
    private static let worldUp = Vec3(x: 0, y: 1, z: 0)

    public static func compute(orientation: ParticleSpriteOrientation, axis: Vec3) -> Axes {
        switch orientation {
        case .screen:
            return Axes(right: cameraRight, up: cameraUp)

        case .upright:
            // Up은 월드 업으로 고정, Right는 그 축과 "카메라 방향"의 외적 —
            // 세운 채로 카메라를 향해 돈다. 우리 카메라는 절대 안 돌아서
            // worldUp × towardCamera가 항상 같은 값이고, 계산하면 정확히
            // cameraRight와 같다 — 결과가 screen과 늘 같다(문서의 "3D
            // 전용"이라는 말과 맞는다: 카메라가 도는 3D 씬에서만 갈린다).
            guard let right = normalizedCross(worldUp, towardCamera) else {
                return Axes(right: cameraRight, up: cameraUp)
            }
            return Axes(right: right, up: worldUp)

        case .fixed:
            // 판의 법선이 axis다. 축이 유한하지 않거나 0벡터면(실물에 그런
            // 값은 없지만 방어적으로) 카메라 방향으로 대신한다 — screen과
            // 같은 모양이 되어 최소한 안 보이지는 않는다.
            let normal = axis.isFiniteNonZero ? normalizeVector(axis) : towardCamera
            guard let right = normalizedCross(worldUp, normal) else {
                // normal이 worldUp과 평행하면(똑바로 위/아래를 보는 axis) 그
                // 외적이 0이 된다 — 대신 카메라 오른쪽을 축으로 쓴다.
                return Axes(right: cameraRight, up: cross(normal, cameraRight))
            }
            return Axes(right: right, up: cross(normal, right))
        }
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private static func normalizeVector(_ v: Vec3) -> Vec3 {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard length > 0, length.isFinite else { return v }
        return Vec3(x: v.x / length, y: v.y / length, z: v.z / length)
    }

    private static func normalizedCross(_ a: Vec3, _ b: Vec3) -> Vec3? {
        let c = cross(a, b)
        let length = (c.x * c.x + c.y * c.y + c.z * c.z).squareRoot()
        guard length.isFinite, length > 1e-9 else { return nil }
        return Vec3(x: c.x / length, y: c.y / length, z: c.z / length)
    }
}

extension Vec3 {
    fileprivate var isFiniteNonZero: Bool {
        x.isFinite && y.isFinite && z.isFinite && (x != 0 || y != 0 || z != 0)
    }
}
