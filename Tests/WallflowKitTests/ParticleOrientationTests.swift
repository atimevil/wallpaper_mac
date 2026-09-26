import XCTest
@testable import WallflowKit

/// `sprite` 렌더러의 `orientation`/`axis` 순수 함수 테스트. 실제 정점 셰이더는
/// App 타깃이라 유닛 테스트가 없다 — `ParticleTrailTangentTests`와 같은 구조.
final class ParticleOrientationTests: XCTestCase {
    func testParseKnownValues() {
        XCTAssertEqual(ParticleSpriteOrientation.parse("screen"), .screen)
        XCTAssertEqual(ParticleSpriteOrientation.parse("upright"), .upright)
        XCTAssertEqual(ParticleSpriteOrientation.parse("fixed"), .fixed)
        XCTAssertEqual(ParticleSpriteOrientation.parse("UPRIGHT"), .upright, "대소문자 무시")
    }

    /// 안 적으면(`nil`) screen — 실물 `orb.json`/`orbGlow.json`이 이 경우다.
    func testParseMissingDefaultsToScreen() {
        XCTAssertEqual(ParticleSpriteOrientation.parse(nil), .screen)
        XCTAssertEqual(ParticleSpriteOrientation.parse("weird"), .screen)
    }

    func testScreenOrientationIsCameraBasis() {
        let axes = ParticleOrientationBasis.compute(
            orientation: .screen, axis: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(axes.right, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(axes.up, Vec3(x: 0, y: 1, z: 0))
    }

    /// 우리 카메라는 절대 안 돈다 — upright는 "카메라를 향해 돈다"는 부분이
    /// 항상 같은 답을 내 screen과 결과가 같다. 문서가 "3D 전용"이라고 적은
    /// 이유와 맞는다(카메라가 실제로 도는 씬에서만 갈린다).
    func testUprightMatchesScreenWithFixedCamera() {
        let axes = ParticleOrientationBasis.compute(
            orientation: .upright, axis: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(axes.right, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(axes.up, Vec3(x: 0, y: 1, z: 0))
    }

    /// 실물 `Rain_Splash_copy2.json`/`Rain_Splash_Drops_copy1.json` 그대로 —
    /// axis가 항상 "0 0 1"이다. 그 축이 정확히 카메라를 향하는 방향이라(우리
    /// 카메라는 -z를 본다) fixed도 결과가 screen과 같다.
    func testFixedWithRealAxisMatchesScreen() {
        let axes = ParticleOrientationBasis.compute(
            orientation: .fixed, axis: Vec3(x: 0, y: 0, z: 1))
        XCTAssertEqual(axes.right, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(axes.up, Vec3(x: 0, y: 1, z: 0))
    }

    /// WE 문서 예시 그대로 — 3D 씬의 빗방울 자국을 바닥에 눕히는 axis
    /// "X: 0 Y: 1 Z: 0"(worldUp과 평행). 실물 코퍼스엔 없지만, 이 경우 판이
    /// 카메라와 다른 평면에 눕는다는 게 이 함수로 실제로 갈린다는 걸
    /// 검증한다.
    func testFixedWithGroundAxisTiltsAwayFromScreen() {
        let axes = ParticleOrientationBasis.compute(
            orientation: .fixed, axis: Vec3(x: 0, y: 1, z: 0))
        XCTAssertNotEqual(axes.up, Vec3(x: 0, y: 1, z: 0), "바닥에 눕는 판은 up이 화면 up과 달라야 한다")
    }

    /// axis가 카메라 방향과도 worldUp과도 안 겹치면(임의 방향) screen과 다른
    /// 정규직교 기저가 나온다 — fixed가 실제로 카메라를 무시하고 축에
    /// 고정된다는 것의 핵심 증거.
    func testFixedWithArbitraryAxisProducesDifferentOrthonormalBasis() {
        let axes = ParticleOrientationBasis.compute(
            orientation: .fixed, axis: Vec3(x: 1, y: 0, z: 0))
        assertVec3Equal(axes.right, Vec3(x: 0, y: 0, z: -1))
        assertVec3Equal(axes.up, Vec3(x: 0, y: 1, z: 0))
        // 정규직교(단위 길이·서로 수직)인지도 확인한다.
        XCTAssertEqual(dot(axes.right, axes.up), 0, accuracy: 1e-9)
        XCTAssertEqual(length(axes.right), 1, accuracy: 1e-9)
        XCTAssertEqual(length(axes.up), 1, accuracy: 1e-9)
    }

    /// axis가 0벡터거나 비유한이면(실물에 없지만 방어적으로) 카메라 방향으로
    /// 대신한다 — screen과 같은 모양이 되어 최소한 안 보이지는 않는다.
    func testFixedWithDegenerateAxisFallsBackToCameraFacing() {
        let axes = ParticleOrientationBasis.compute(
            orientation: .fixed, axis: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(axes.right, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(axes.up, Vec3(x: 0, y: 1, z: 0))
    }

    private func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private func length(_ v: Vec3) -> Double { dot(v, v).squareRoot() }

    private func assertVec3Equal(
        _ a: Vec3, _ b: Vec3, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: 1e-9, file: file, line: line)
    }
}
