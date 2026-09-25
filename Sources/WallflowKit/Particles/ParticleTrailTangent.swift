import Foundation

/// `spritetrail` 렌더러의 빌보드 축. `common_particles.h`의
/// `ComputeParticleTrailTangents`를 그대로 옮긴 순수 함수다 — 실제 정점 셰이더
/// (`particle_vertex`)는 App 타깃이라 유닛 테스트가 없다. 이 함수로 방향·clamp·
/// 0 속도 분기를 먼저 검증하고, MSL 쪽은 이 결과와 같은 식을 그대로 쓴다.
public enum ParticleTrailTangent {
    public struct Axes: Equatable {
        /// 트레일의 폭 방향(텍스처 u축).
        public let right: Vec3
        /// 트레일이 늘어나는 방향(텍스처 v축) × clamp된 길이.
        public let up: Vec3
    }

    /// - Parameters:
    ///   - velocity: 레이어 로컬 공간 속도. 위치와 같은 좌표계다.
    ///   - length: `g_RenderVar0.x` — 속력에 곱하는 배율.
    ///   - maxLength: `g_RenderVar0.y` — 위 클램프.
    ///   - minLength: `g_RenderVar0.z` — 아래 클램프.
    /// - Returns: 속도가 0(또는 유한하지 않음)이면 `nil` — 호출자가 스프라이트
    ///   경로(회전 기반 `right`/`up`)로 그대로 떨어지라는 뜻이다.
    public static func compute(
        velocity: Vec3, length: Double, maxLength: Double, minLength: Double
    ) -> Axes? {
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y
            + velocity.z * velocity.z).squareRoot()
        guard speed.isFinite, speed > 0 else { return nil }

        // 직교 2D 시선. WE 원문은 `eyeDirection = localPosition - eye`(카메라에서
        // 파티클로 향하는 방향)이고, 우리 카메라는 +z에 있고 -z를 바라보는
        // 쪽으로 뒀다 — 그래서 (0,0,-1). 이 부호가 일반적으로 안 뒤집힘을
        // 준다: eye=(0,0,-1)일 때 cross(eye,v) = (vy, -vx, 0)이라 (right, up)
        // 기저의 행렬식이 vx²+vy² > 0(속도가 z 평면 위에 있는 한 항상 양수)
        // 이라 늘 오른손 방향(거울상 아님)이다. 세로 속도((0,1,0), 반딧불·
        // 불티가 위로 뜨는 가장 흔한 경우)로 검증하면 cross=(1,0,0) — 오늘
        // 스프라이트 기본값(rotation 0일 때 right=(1,0,0))과 정확히 같다.
        let eye = Vec3(x: 0, y: 0, z: -1)
        let rawRight = cross(eye, velocity)
        let rightLength = (rawRight.x * rawRight.x + rawRight.y * rawRight.y
            + rawRight.z * rawRight.z).squareRoot()
        // 직교 2D에서 속도가 항상 z=0 평면 위에 있는 한 eye=(0,0,-1)과 평행할 수
        // 없어 rightLength가 0이 될 일은 없다. 그래도 스크립트가 z 속도를 줄 수
        // 있으니 방어적으로 0/비유한 값을 막는다.
        guard rightLength.isFinite, rightLength > 0 else { return nil }
        let right = Vec3(x: rawRight.x / rightLength, y: rawRight.y / rightLength,
                         z: rawRight.z / rightLength)

        let clamped = Swift.max(minLength, Swift.min(speed * length, maxLength))
        let up = Vec3(x: velocity.x / speed * clamped, y: velocity.y / speed * clamped,
                      z: velocity.z / speed * clamped)
        return Axes(right: right, up: up)
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }
}
