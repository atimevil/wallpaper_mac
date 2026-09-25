import XCTest
@testable import WallflowKit

/// `spritetrail` 축 계산의 순수 함수 테스트. 실제 정점 셰이더는 App 타깃이라
/// 유닛 테스트가 없어서, 여기서 방향·clamp·0 속도 분기를 먼저 검증한다.
final class ParticleTrailTangentTests: XCTestCase {
    /// 속도가 0이면 스프라이트 경로로 넘기라는 신호로 nil을 돌려줘야 한다.
    func testZeroVelocityReturnsNil() {
        let axes = ParticleTrailTangent.compute(
            velocity: Vec3(x: 0, y: 0, z: 0), length: 1, maxLength: 10, minLength: 0)
        XCTAssertNil(axes)
    }

    /// 세로 속도(반딧불·불티가 위로 뜨는 가장 흔한 경우)에서 right가 오늘
    /// 스프라이트 기본값(회전 0일 때 (1,0,0))과 같은 부호여야 텍스처가 안
    /// 뒤집힌다. eyeDirection=(0,0,-1) 선택의 근거다.
    func testUpwardVelocityMatchesSpriteDefaultRight() throws {
        let axes = try XCTUnwrap(ParticleTrailTangent.compute(
            velocity: Vec3(x: 0, y: 1, z: 0), length: 1, maxLength: 10, minLength: 0))
        XCTAssertEqual(axes.right, Vec3(x: 1, y: 0, z: 0))
        // up은 속도 방향 그대로, 길이만 clamp된 값으로 늘어난다.
        XCTAssertEqual(axes.up.x, 0, accuracy: 1e-9)
        XCTAssertEqual(axes.up.y, 1, accuracy: 1e-9)  // speed=1, length=1 → clamp(1,0,10)=1
    }

    /// 가로 속도에서 right는 up과 수직인 (0,±1,0) 축이어야 한다.
    func testRightwardVelocityGivesPerpendicularRight() throws {
        let axes = try XCTUnwrap(ParticleTrailTangent.compute(
            velocity: Vec3(x: 1, y: 0, z: 0), length: 1, maxLength: 10, minLength: 0))
        XCTAssertEqual(axes.right, Vec3(x: 0, y: -1, z: 0))
        XCTAssertEqual(axes.up, Vec3(x: 1, y: 0, z: 0))
    }

    /// 실물 rain_screen_4k.json 값(length 0.01, maxlength 1.5, minlength 1)에서
    /// 아주 느린 속도는 minlength로 죈다 — 빗방울이 멈춰도 트레일이 사라지지 않는다.
    func testSlowSpeedClampsToMinLength() throws {
        let axes = try XCTUnwrap(ParticleTrailTangent.compute(
            velocity: Vec3(x: 0, y: -0.1, z: 0), length: 0.01, maxLength: 1.5, minLength: 1))
        XCTAssertEqual(axes.up.y, -1, accuracy: 1e-9)  // speed*length=0.001 < minlength=1
    }

    /// 아주 빠른 속도는 maxlength로 죈다 — 트레일이 화면을 가로지르지 않는다.
    func testFastSpeedClampsToMaxLength() throws {
        let axes = try XCTUnwrap(ParticleTrailTangent.compute(
            velocity: Vec3(x: 0, y: -1000, z: 0), length: 0.01, maxLength: 1.5, minLength: 1))
        XCTAssertEqual(axes.up.y, -1.5, accuracy: 1e-9)  // speed*length=10 > maxlength=1.5
    }

    /// 유한하지 않은 속도(스크립트가 NaN을 줄 수 있다)는 nil로 스프라이트에 떨어진다.
    func testNonFiniteVelocityReturnsNil() {
        let axes = ParticleTrailTangent.compute(
            velocity: Vec3(x: .nan, y: 1, z: 0), length: 1, maxLength: 10, minLength: 0)
        XCTAssertNil(axes)
    }
}
