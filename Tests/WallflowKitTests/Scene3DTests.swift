import XCTest
import simd
@testable import WallflowKit

/// 원근 씬의 행렬. 관례를 하나라도 틀리면 화면이 뒤집히거나 비어 있다 —
/// 그런데 셰이더는 컴파일되고 아무 오류도 없다. 그래서 수치로 못 박는다.
final class Scene3DTests: XCTestCase {
    private func project(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let c = m * SIMD4(p, 1)
        return SIMD3(c.x, c.y, c.z) / c.w
    }

    /// 기본 카메라(원점을 보는 (0,0,100))에서 원점은 화면 한가운데, 깊이는 0~1 사이.
    func testCenterProjectsToScreenMiddle() {
        let camera = SceneCamera()
        let ndc = project(camera.viewProjection(aspect: 16.0 / 9.0), SIMD3(0, 0, 0))
        XCTAssertEqual(ndc.x, 0, accuracy: 1e-5)
        XCTAssertEqual(ndc.y, 0, accuracy: 1e-5)
        XCTAssertGreaterThan(ndc.z, 0); XCTAssertLessThan(ndc.z, 1)
    }

    /// 오른쪽은 +x, 위는 +y로 나와야 한다. 축이 하나라도 뒤집히면 씬이 거울상이다.
    func testAxesAreNotMirrored() {
        let vp = SceneCamera().viewProjection(aspect: 1)
        XCTAssertGreaterThan(project(vp, SIMD3(10, 0, 0)).x, 0)
        XCTAssertGreaterThan(project(vp, SIMD3(0, 10, 0)).y, 0)
        // 카메라에 가까운 점이 더 앞(깊이가 작다).
        XCTAssertLessThan(project(vp, SIMD3(0, 0, 50)).z, project(vp, SIMD3(0, 0, 0)).z)
    }

    /// Metal 깊이 관례: near→0, far→1.
    func testDepthRangeIsMetal() {
        let p = Scene3D.perspective(fovDegrees: 60, aspect: 1, nearZ: 1, farZ: 100)
        XCTAssertEqual(project(p, SIMD3(0, 0, -1)).z, 0, accuracy: 1e-4)
        XCTAssertEqual(project(p, SIMD3(0, 0, -100)).z, 1, accuracy: 1e-4)
    }

    /// 시야각이 넓을수록 같은 점이 화면 가운데로 모인다.
    func testWiderFOVShrinksTheScene() {
        let narrow = Scene3D.perspective(fovDegrees: 30, aspect: 1, nearZ: 1, farZ: 100)
        let wide = Scene3D.perspective(fovDegrees: 90, aspect: 1, nearZ: 1, farZ: 100)
        let p = SIMD3<Float>(1, 1, -10)
        XCTAssertLessThan(abs(project(wide, p).x), abs(project(narrow, p).x))
    }

    /// 눈과 보는 점이 겹치거나 up이 시선과 나란해도 행렬이 NaN이면 안 된다.
    func testDegenerateCameraStaysFinite() {
        let same = Scene3D.lookAt(eye: Vec3(x: 1, y: 2, z: 3), center: Vec3(x: 1, y: 2, z: 3),
                                  up: Vec3(x: 0, y: 1, z: 0))
        let parallel = Scene3D.lookAt(eye: Vec3(x: 0, y: 0, z: 10), center: Vec3(x: 0, y: 0, z: 0),
                                      up: Vec3(x: 0, y: 0, z: 1))
        for m in [same, parallel] {
            for c in 0..<4 { for r in 0..<4 { XCTAssertTrue(m[c][r].isFinite) } }
        }
    }

    /// 세계 변환: 크기 → 회전 → 이동. 순서가 틀리면 돌린 뒤 옮기는 게 아니라
    /// 옮긴 뒤 돌아 자리가 어긋난다.
    func testWorldAppliesScaleThenRotationThenTranslation() {
        let m = Scene3D.world(origin: Vec3(x: 10, y: 0, z: 0), anglesDegrees: Vec3(x: 0, y: 0, z: 90),
                              scale: Vec3(x: 2, y: 2, z: 2), size: Vec2(x: 1, y: 1))
        // 단위 쿼드의 (0.5, 0) 꼭짓점: 크기 2 → (1,0), z 90° 회전 → (0,1), 이동 → (10,1).
        let p = m * SIMD4<Float>(0.5, 0, 0, 1)
        XCTAssertEqual(p.x, 10, accuracy: 1e-4)
        XCTAssertEqual(p.y, 1, accuracy: 1e-4)
    }

    /// 실물 배경 구름: size 64 × scale 10 = 640 단위 판. 카메라 38에서 fov 53이면
    /// 화면을 훌쩍 덮어야 한다 — 그래서 배경으로 쓰는 것이다.
    func testCloudBackdropCoversTheView() {
        var camera = SceneCamera(fov: 53, nearZ: 1, farZ: 10000)
        camera.eye = Vec3(x: 0, y: 0, z: 38)
        let vp = camera.viewProjection(aspect: 16.0 / 9.0)
        let world = Scene3D.world(origin: Vec3(x: 0, y: 0, z: 0), anglesDegrees: Vec3(x: 0, y: 0, z: 0),
                                  scale: Vec3(x: 10, y: 10, z: 10), size: Vec2(x: 64, y: 64))
        let corner = project(vp * world, SIMD3(0.5, 0.5, 0))
        XCTAssertGreaterThan(corner.x, 1, "화면 밖까지 나가야 덮는다")
        XCTAssertGreaterThan(corner.y, 1)
    }
}
