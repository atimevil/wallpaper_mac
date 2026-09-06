import XCTest
@testable import WallflowKit

/// 씬 전체 파티클 예산. 프리셋 하나의 상한만으로는 상시 구동 앱을 못 지킨다 —
/// 파티클 레이어가 여섯인 실물 씬이 있고 `instanceoverride`가 개수를 올리기도 한다.
final class ParticleBudgetTests: XCTestCase {
    private func preset(count: Int, rate: Double = 100) -> ParticlePreset {
        ParticlePreset(
            maxCount: count, startTime: 0, materialPath: "m",
            emitters: [.sphereRandom(rate: rate, origin: Vec3(x: 0, y: 0, z: 0),
                                     directions: Vec3(x: 1, y: 1, z: 1),
                                     distanceMin: 10, distanceMax: 20)],
            initializers: [.sizeRandom(min: 1, max: 2)],
            operators: [], unsupportedNames: [])
    }

    private func layer(_ id: Int, _ preset: ParticlePreset) -> SceneLayer {
        SceneLayer(id: id, name: "p\(id)", visible: true,
                   origin: Vec3(x: 0, y: 0, z: 0), size: Vec2(x: 1, y: 1),
                   content: .particle(preset: preset, texturePath: "t", blend: .additive))
    }

    private func counts(_ layers: [SceneLayer]) -> [Int] {
        layers.compactMap {
            if case .particle(let p, _, _, _, _) = $0.content { return p.maxCount }
            return nil
        }
    }

    private func rates(_ layers: [SceneLayer]) -> [Double] {
        layers.compactMap {
            guard case .particle(let p, _, _, _, _) = $0.content,
                  case .sphereRandom(let r, _, _, _, _, _) = p.emitters[0] else { return nil }
            return r
        }
    }

    /// 예산 안이면 손대지 않는다. 대부분의 씬이 여기 해당하므로,
    /// 여기서 값이 바뀌면 잘 나오던 배경화면이 조용히 묽어진다.
    func testUnderBudgetIsUntouched() {
        let layers = [layer(1, preset(count: 500)), layer(2, preset(count: 300))]
        XCTAssertEqual(SceneDocument.applyingParticleBudget(layers), layers)
    }

    /// 넘치면 총량이 예산 안으로 들어와야 한다.
    func testOverBudgetIsClamped() {
        let each = ParticlePreset.maxAllowedSceneCount  // 6배 = 예산의 6배
        let layers = (1...6).map { layer($0, preset(count: each)) }
        let total = counts(SceneDocument.applyingParticleBudget(layers)).reduce(0, +)
        XCTAssertLessThanOrEqual(total, ParticlePreset.maxAllowedSceneCount)
        XCTAssertGreaterThan(total, ParticlePreset.maxAllowedSceneCount / 2,
                             "예산에 맞추는 것이지 필요 이상으로 깎는 게 아니다")
    }

    /// 레이어 사이의 밀도 관계가 남아야 한다. 큰 것만 자르면 씬이 다른 그림이 된다.
    /// 눈이 1000, 반짝임이 100인 씬을 1000/1000으로 만들면 안 된다.
    /// 개수는 프리셋 하나당 상한(8192) 안에서 잡는다. 그보다 큰 레이어는
    /// 파싱에서 이미 잘리므로 파일에서 나올 수 없고, 그런 값으로 재면
    /// 예산이 아니라 그 상한을 재게 된다.
    func testRelativeDensitiesArePreserved() throws {
        let layers = [layer(1, preset(count: 8000)), layer(2, preset(count: 800)),
                      layer(3, preset(count: 4000)), layer(4, preset(count: 4000))]
        let out = counts(SceneDocument.applyingParticleBudget(layers))
        XCTAssertLessThanOrEqual(out.reduce(0, +), ParticlePreset.maxAllowedSceneCount)
        XCTAssertEqual(Double(out[0]) / Double(out[1]), 10, accuracy: 0.3,
                       "10:1 비율이 유지돼야 한다: \(out)")
    }

    /// 방출률도 같이 줄어야 한다. 개수만 줄이면 방출이 빈 슬롯을 기다리며 몰려,
    /// 밀도가 아니라 수명이 짧아 보인다 — 씬이 다른 움직임이 된다.
    func testEmissionRateScalesWithCount() throws {
        let each = ParticlePreset.maxAllowedSceneCount
        let layers = (1...4).map { layer($0, preset(count: each, rate: 100)) }
        let out = try XCTUnwrap(rates(SceneDocument.applyingParticleBudget(layers)).first)
        XCTAssertEqual(out, 100 * 0.25, accuracy: 1,
                       "개수가 1/4로 줄면 방출률도 1/4이어야 한다: \(out)")
    }

    /// 배율이 아무리 작아도 레이어가 사라지면 안 된다. 0개는 "드물게"가 아니라 "없음"이다.
    func testTinyLayerSurvives() {
        let layers = [layer(1, preset(count: ParticlePreset.maxAllowedSceneCount * 100)),
                      layer(2, preset(count: 1))]
        XCTAssertEqual(counts(SceneDocument.applyingParticleBudget(layers))[1], 1)
    }

    /// 파티클이 아닌 레이어는 건드리지 않는다.
    func testNonParticleLayersAreUnchanged() {
        let text = SceneLayer(id: 9, name: "t", visible: true,
                              origin: Vec3(x: 0, y: 0, z: 0), size: Vec2(x: 1, y: 1),
                              content: .solidColor(Vec3(x: 1, y: 1, z: 1)))
        let layers = [layer(1, preset(count: ParticlePreset.maxAllowedSceneCount * 4)), text]
        XCTAssertEqual(SceneDocument.applyingParticleBudget(layers)[1], text)
    }
}
