import Foundation
import simd

/// 원근 씬의 행렬. 순수 simd라 여기 두고 시험한다 — 렌더러는 곱하기만 한다.
///
/// 관례는 Metal의 것이다: 오른손 좌표계, 카메라는 -Z를 본다, 클립 깊이는 0~1.
/// 행렬은 **열 우선**이고 벡터에 왼쪽에서 곱한다(`M * v`). 셰이더의 `mul(v, M)`
/// 행벡터 관례와 헷갈리기 쉬운데, 그쪽은 전치를 넘겨 맞춘다.
public enum Scene3D {
    /// 눈에서 `center`를 보는 뷰 행렬.
    public static func lookAt(eye: Vec3, center: Vec3, up: Vec3) -> simd_float4x4 {
        let e = SIMD3<Float>(Float(eye.x), Float(eye.y), Float(eye.z))
        let c = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
        var u = SIMD3<Float>(Float(up.x), Float(up.y), Float(up.z))
        var forward = c - e
        // 눈이 보는 점과 겹치면 방향이 없다. 파일이 그렇게 주면 -Z를 본다.
        if simd_length(forward) < 1e-6 { forward = SIMD3(0, 0, -1) }
        forward = simd_normalize(forward)
        if simd_length(u) < 1e-6 || abs(simd_dot(simd_normalize(u), forward)) > 0.999 {
            u = abs(forward.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        }
        let right = simd_normalize(simd_cross(forward, u))
        let trueUp = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4(right.x, trueUp.x, -forward.x, 0),
            SIMD4(right.y, trueUp.y, -forward.y, 0),
            SIMD4(right.z, trueUp.z, -forward.z, 0),
            SIMD4(-simd_dot(right, e), -simd_dot(trueUp, e), simd_dot(forward, e), 1)))
    }

    /// 세로 시야각(도)의 원근 투영. 깊이는 near→0, far→1(Metal).
    public static func perspective(
        fovDegrees: Double, aspect: Double, nearZ: Double, farZ: Double
    ) -> simd_float4x4 {
        let fov = Swift.min(Swift.max(fovDegrees, 1), 179) * .pi / 180
        let a = Float(aspect.isFinite && aspect > 0 ? aspect : 1)
        let n = Float(nearZ), f = Float(Swift.max(farZ, nearZ * 1.001))
        let y = 1 / tan(Float(fov) / 2)
        let x = y / a
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, f / (n - f), -1),
            SIMD4(0, 0, n * f / (n - f), 0)))
    }

    /// 레이어의 세계 변환. 크기 → 회전 → 이동 순이다.
    ///
    /// `angles`는 도 단위이고 WE는 X·Y·Z 순으로 적용한다(스크립트의
    /// `Mat4.fromEuler(angles, "XYZ")`가 그 관례다). 크기가 (0,0,0)인 레이어는
    /// 보이지 않아야 하므로 그대로 0을 둔다 — 실물 스크립트 전용 레이어가 그렇다.
    public static func world(
        origin: Vec3, anglesDegrees: Vec3, scale: Vec3, size: Vec2 = Vec2(x: 1, y: 1)
    ) -> simd_float4x4 {
        let s = simd_float4x4(diagonal: SIMD4(
            Float(scale.x * size.x), Float(scale.y * size.y), Float(scale.z), 1))
        let r = rotation(anglesDegrees)
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(Float(origin.x), Float(origin.y), Float(origin.z), 1)
        return t * r * s
    }

    /// X·Y·Z 순 오일러 회전(도).
    public static func rotation(_ degrees: Vec3) -> simd_float4x4 {
        func axis(_ a: SIMD3<Float>, _ d: Double) -> simd_float4x4 {
            let q = simd_quatf(angle: Float(d * .pi / 180), axis: a)
            return simd_float4x4(q)
        }
        return axis(SIMD3(0, 0, 1), degrees.z) * axis(SIMD3(0, 1, 0), degrees.y)
            * axis(SIMD3(1, 0, 0), degrees.x)
    }
}

extension SceneCamera {
    /// 이 카메라의 뷰·투영. `aspect`는 화면 가로/세로다.
    public func viewProjection(aspect: Double) -> simd_float4x4 {
        Scene3D.perspective(fovDegrees: fov, aspect: aspect, nearZ: nearZ, farZ: farZ)
            * Scene3D.lookAt(eye: eye, center: center, up: up)
    }
}
