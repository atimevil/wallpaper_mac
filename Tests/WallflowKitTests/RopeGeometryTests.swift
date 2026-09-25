import XCTest
@testable import WallflowKit

/// `RopeGeometry`의 순수 기하 테스트. 실물 `genericropeparticle.vert/.geom`을
/// 옮긴 규칙(카트멀롬→베지어 장력 0.15, subdivision 보간, UV)을 고정한다.
final class RopeGeometryTests: XCTestCase {
    private func particle(_ x: Double, _ y: Double, size: Double = 2, alpha: Double = 1) -> Particle {
        Particle(position: Vec3(x: x, y: y, z: 0), velocity: Vec3(x: 0, y: 0, z: 0),
                 rotation: Vec3(x: 0, y: 0, z: 0), angularVelocity: Vec3(x: 0, y: 0, z: 0),
                 color: Vec3(x: 1, y: 1, z: 1), size: size, alpha: alpha, age: 0, lifetime: 1)
    }

    // MARK: 0·1개

    func testZeroParticlesProducesNothing() {
        XCTAssertTrue(RopeGeometry.rope(orderedParticles: [], subdivision: 2, uvScale: 1).isEmpty)
    }

    func testOneParticleProducesNothing() {
        let points = RopeGeometry.rope(
            orderedParticles: [particle(0, 0)], subdivision: 2, uvScale: 1)
        XCTAssertTrue(points.isEmpty)
    }

    // MARK: 정점 수 — (n-1)(s+1)+1

    func testVertexCountMatchesFormula() {
        let particles = (0..<4).map { particle(Double($0) * 10, 0) }
        for sub in [0, 1, 2, 5] {
            let points = RopeGeometry.rope(
                orderedParticles: particles, subdivision: sub, uvScale: 1)
            XCTAssertEqual(points.count, (particles.count - 1) * (sub + 1) + 1,
                           "subdivision \(sub)")
        }
    }

    // MARK: UV 끝값 — 꼬리(입력 배열의 0번, age가 가장 큰 쪽) 1, 머리 0

    func testRopeUVTailIsOneHeadIsZero() {
        let particles = (0..<5).map { particle(Double($0) * 10, 0) }
        let points = RopeGeometry.rope(orderedParticles: particles, subdivision: 3, uvScale: 1)
        XCTAssertEqual(points.first!.v, 1, accuracy: 1e-9)
        XCTAssertEqual(points.last!.v, 0, accuracy: 1e-9)
    }

    func testUVScaleMultipliesV() {
        let particles = (0..<3).map { particle(Double($0) * 10, 0) }
        let points = RopeGeometry.rope(orderedParticles: particles, subdivision: 0, uvScale: 2.5)
        XCTAssertEqual(points.first!.v, 2.5, accuracy: 1e-9)
    }

    // MARK: 순서 — 직선 위 3점이면 중간 보간점도 그 직선 위에 있어야 한다

    func testInterpolatedPointsLieOnStraightLine() {
        let particles = [particle(0, 0), particle(10, 0), particle(20, 0)]
        let points = RopeGeometry.rope(orderedParticles: particles, subdivision: 4, uvScale: 1)
        for point in points {
            XCTAssertEqual(point.position.y, 0, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(point.position.x, -1e-9)
            XCTAssertLessThanOrEqual(point.position.x, 20 + 1e-9)
        }
        // 직선이면 폭 방향(법선)이 전 구간에서 같은 수직 방향이어야 한다.
        for point in points {
            XCTAssertEqual(point.right.x, 0, accuracy: 1e-6)
            XCTAssertEqual(abs(point.right.y), 2, accuracy: 1e-6, "폭 = 입자 크기(반폭)")
        }
    }

    // MARK: ropetrail — segments가 UV 정규화 값

    func testRopeTrailUVUsesSegmentsNotParticleCount() {
        // segments(10)가 파티클 수(4)-1보다 커서, "아직 다 안 자란 트레일"이다.
        let particles = (0..<4).map { particle(Double($0) * 10, 0) }
        let points = RopeGeometry.ropeTrail(
            orderedParticles: particles, subdivision: 0, segments: 10, fadeAlpha: false,
            uvScale: 1)
        XCTAssertEqual(points.first!.v, 1, accuracy: 1e-9)
        // 머리(마지막)는 아직 segments에 못 미쳐 0이 아니다: 1 - 3/10 = 0.7.
        XCTAssertEqual(points.last!.v, 0.7, accuracy: 1e-9)
    }

    // MARK: fadealpha — 다 자란 트레일(n-1 == segments)이면 양 끝이 0

    func testFadeAlphaBothEndsZeroWhenTrailIsFull() {
        let segments = 6
        let particles = (0...segments).map { particle(Double($0) * 10, 0) }
        let points = RopeGeometry.ropeTrail(
            orderedParticles: particles, subdivision: 2, segments: segments, fadeAlpha: true,
            uvScale: 1)
        XCTAssertEqual(points.first!.alpha, 0, accuracy: 1e-9)
        XCTAssertEqual(points.last!.alpha, 0, accuracy: 1e-9)
        // 가운데 근방은 안 죽는다 — 페이드가 사인 봉우리 모양이어야 한다.
        let middle = points[points.count / 2]
        XCTAssertGreaterThan(middle.alpha, 0.5)
    }

    func testFadeAlphaOffKeepsFullAlpha() {
        let particles = (0..<4).map { particle(Double($0) * 10, 0, alpha: 0.8) }
        let points = RopeGeometry.ropeTrail(
            orderedParticles: particles, subdivision: 1, segments: 3, fadeAlpha: false,
            uvScale: 1)
        XCTAssertTrue(points.allSatisfy { abs($0.alpha - 0.8) < 1e-9 })
    }

    // MARK: 인스턴스끼리 안 섞임 — 서로 다른 배열을 넣으면 결과가 독립적이다

    func testDifferentInstancesProduceIndependentGeometry() {
        let a = (0..<3).map { particle(Double($0) * 10, 0) }
        let b = (0..<3).map { particle(0, Double($0) * 10) }
        let pointsA = RopeGeometry.rope(orderedParticles: a, subdivision: 1, uvScale: 1)
        let pointsB = RopeGeometry.rope(orderedParticles: b, subdivision: 1, uvScale: 1)
        // a는 x축을 따라가고 b는 y축을 따라간다 — 하나로 합쳐 이었다면 서로
        // 섞인 대각선 좌표가 나왔을 것이다.
        XCTAssertTrue(pointsA.allSatisfy { abs($0.position.y) < 1e-9 })
        XCTAssertTrue(pointsB.allSatisfy { abs($0.position.x) < 1e-9 })
    }
}
