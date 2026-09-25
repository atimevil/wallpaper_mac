# Wallflow 마무리 — 파티클 인스턴스 배율·프리웜·감쇠 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 파티클 `instanceoverride`를 공식 문서의 뜻대로 적용하고(스크립트로 바뀌는 값 포함), 같이 드러난 파티클 결함(감쇠 NaN, 프리웜 없음)을 고쳐 v0.1.1로 마감한다.

**Architecture:** 씬 배율을 프리셋 초기화자에 굽지 않고 `ParticlePreset.instance`로 들고 가서 `ParticleSystem`이 스폰 순간(크기·투명도·수명·속도·색·밝기)과 매 틱(힘·시간·방출량)에 곱한다. 스크립트는 `layer.instance`와 `instanceoverride.<키>` 속성 스크립트로 같은 값을 바꾸고, 스냅샷 → 렌더러 → `system.instance`로 흐른다(재질 상수 스크립트와 같은 길).

**Tech Stack:** Swift 6 / SwiftPM, XCTest, JavaScriptCore, Metal(앱 쪽만)

**Spec:** `docs/superpowers/specs/2026-09-04-wallflow-design.md`, 공식 문서 [IParticleSystemInstance](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IParticleSystemInstance.html) · [IParticleSystem](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IParticleSystem.html)

## 체크리스트

- [ ] T1 `MODELDBG` 진단 줄 삭제, `ParticleOverride` 설명 주석 제자리
- [ ] T2 배율을 스폰 결과에 곱하기(colorn은 틴트) + `brightness` + `speed`가 힘·remapvalue에도 + `drag` NaN 수정 + 예산 경로 분리
- [ ] T3 인스턴스 스크립트: `layer.instance` 왕복, `instanceoverride.<키>` 속성 스크립트(모듈 import 포함), 한 틱 안의 `stop(); play()` 재시작
- [ ] T4 `count` = 방출량, `rate` = 시뮬레이션 속도 (게이트 통과 — 아래 기록)
- [ ] T5 `starttime` 프리웜
- [ ] T6 검증: 전체 테스트, 앱 재빌드·재실행, 라이브러리 촬영 대조, 배경화면 복원
- [ ] T7 기록·릴리스: README, v0.1.1 DMG·태그·GitHub 릴리스, 메모리
- [x] `backup/before-scrub` 로컬 브랜치 삭제 (2026-09-25, 사용자 승인)

공식 정의(IParticleSystemInstance — 전부 배율, 1이면 그대로):

| 키 | 문서 | 지금 코드 | 이 계획 |
|---|---|---|---|
| alpha | "opacity" | alpharandom에만 | 스폰 결과 (T2) |
| size | "size" | sizerandom에만 | 스폰 결과 (T2) |
| lifetime | "lifetime" | lifetimerandom에만 | 스폰 결과 (T2) |
| speed | "initial velocity and forces" | 속도 초기화자에만 | 최종 초기 속도 + 중력·난류·소용돌이·끌림·remapvalue 속도 (T2) |
| colorn | "Modifies the color assigned to particles" | colorrandom 범위 **교체** | 스폰 색에 **곱**(틴트) (T2) |
| brightness | 문서 표엔 없음 — WE 자체 번개 미리보기가 5.0을 씀 | 무시 | 색에 곱함 (T2) |
| count | "emission rate" | maxCount만 | 방출률·일괄 개수 × count, maxCount × count (T4) |
| rate | "simulation rate" | 방출률 | dt × rate (T4) |

근거(2026-09-25 조사):
- **count/rate:** 공식 문서와 catsout/wallpaper-scene-renderer(`newEm.rate *= count`, `particleTime = frameTime * m_rate`)가 일치한다. Almamu/linux-wallpaperengine은 count→maxCount, rate→방출률로 문서와 반대다 — 지금 우리 코드가 이쪽이다.
- **colorn 곱:** 문서의 "Modifies", catsout(`MutiplyInitColor`)와 Almamu(`colorn; // Multiplies particle color`) 모두 곱, WE 자체 `previewwaterimpact`가 이미 하늘색인 프리셋(193~219/201~230/255)에 파란 colorn을 얹는다 — 프리셋 미리보기가 프리셋의 색 변화를 버릴 이유가 없다. 0~255 `color`(교체)는 코퍼스에 없어 넣지 않는다.
- **speed의 힘 범위:** catsout은 초기 속도(이미터 속력 포함)+movement, Almamu는 거의 모든 연산자. 문서 "initial velocity and forces"에 맞춰 초기 속도 전체와 속도를 바꾸는 연산자(중력·난류·소용돌이·끌림·remapvalue velocity/speed)에 곱한다. 회전(angularmovement)은 넣지 않는다.
- **자식 시스템:** 두 구현 모두 부모 배율을 자식에 넘기는 근거가 없다. 시간(`rate`)만 부모 dt를 따라 저절로 내려가고, 나머지는 넘기지 않는다(지금 동작 유지).

## Global Constraints

- `WallflowKit`은 AppKit·Metal·AVFoundation을 import하지 않는다.
- 실물 테스트는 환경변수가 있어야 돈다 — 빼면 **조용히 건너뛴다**:
  `WALLFLOW_TEST_SCENES="$HOME/Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960" WALLFLOW_TEST_ASSETS="$HOME/Library/Application Support/Wallflow/Assets" swift test`
- 기준선(2026-09-25): 566 테스트, 실패 0, 건너뜀 6. 빌드 경고 0.
- 커밋 메시지는 저장소 관례(한국어 "…한다" 문장). `Co-Authored-By`·`Claude-Session` 줄을 **넣지 않는다**.
- 주석은 주변처럼 한국어로 "왜"를 쓴다. 파일·스크립트에서 온 배율은 유한하고 0~100일 때만 받는다(`ParticleOverride.parse`의 규칙).
- 서브에이전트는 `git worktree add .worktrees/<task> -b <task>`에서 일하고 앱을 띄우거나 화면을 찍지 않는다(T6만 한다).
- 기존 테스트가 새 동작 때문에 깨지면 그 테스트가 무엇을 지키려 했는지 먼저 읽고, 지키려던 것이 여전히 맞으면 코드를, 옛 해석에 기댄 것이면 테스트를 고친다. 고친 이유를 커밋 메시지에 쓴다.

## Review Focus

1. **PS2 시계 파티클이 검게 사라짐** — `particles/particles2.json`은 가산 혼합이고 colorrandom이 없다. T2가 정적 `colorn "0 0 0"`을 스폰 색에 곱하면 T3 전까지 안 보인다. T2·T3은 같은 빌드로 나간다(앱 재빌드는 T6에서만). T3 `testInstanceColorScriptUsesUserProperties`와 T6 촬영이 막는다.
2. **예산이 씬 배율을 지움** — `scaledToBudget`이 지금은 `applying(ParticleOverride)`를 거친다. `instance`를 저장하게 되면 예산이 씬 배율을 덮어쓴다. T2가 예산을 자기 경로로 떼고 `testBudgetKeepsSceneInstance`로 막는다.
3. **스크립트가 NaN·음수·거대한 값을 씀** — `layer.instance.rate = NaN` 등. 파일과 같은 규칙으로 버린다. T3 `testApplyFiltersScriptValues`.
4. **큰 `rate`·긴 프리웜** — rate 100 × 0.1초, starttime 수천 초. 곱한 뒤 `maxTimeStep`으로 죄고 프리웜은 상한을 둔다. T4 `testHugeRateIsClamped`, T5 `testPrewarmIsCapped`.
5. **한 틱 안의 `stop(); play()`** — 최종 상태만 보면 재생→재생이라 재시작이 사라진다. 실물 PS2 오브가 색을 바꾼 뒤 이렇게 다시 튼다. `stop()` 횟수를 따로 센다. T3 `testStopThenPlayInOneTickCountsRestart`.

---

### Task 1: MODELDBG 삭제, 주석 제자리

**Files:**
- Modify: `Sources/WallflowApp/ModelRenderer.swift:226-232`
- Modify: `Sources/WallflowKit/Particles/ParticlePreset.swift:187-191`

- [ ] **Step 1: 진단 블록을 지운다**

```swift
        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_DEBUG"] != nil {
            FileHandle.standardError.write(Data("""
            MODELDBG \(materialPath) shader=\(shaderName) 정점 \(model.vertexCount) 색인 \(model.indices.count) \
            속성 \(vertex.attributes.map { "\($0.slot):\($0.name)" }) 뒤화면 \(backgroundSlots) \
            텍스처 \(bound.keys.sorted()) 블렌딩 \(blending)

            """.utf8))
        }
```

이 블록에서만 쓰던 지역 변수가 남아 경고가 나면 같이 지운다.

- [ ] **Step 2: 떨어진 설명 주석을 옮긴다**

`ParticleRemapOutput` 위에 붙은 네 줄(`/// 씬이 프리셋 위에 얹는 조정값.` … `/// Hiyuki의 벚꽃은 `count`가 0.05라 프리셋 200장 중 10장만 원한다.`)을 `public struct ParticleOverride` 바로 위로 옮긴다. `ParticleRemapOutput` 위에는 `/// `remapvalue`가 무엇에 값을 넣는지.`만 남는다. (T2가 이 주석을 다시 쓴다.)

- [ ] **Step 3: 확인**

Run: `swift build 2>&1 | grep -E "warning|error"; grep -rn MODELDBG Sources`
Expected: 출력 없음

- [ ] **Step 4: Commit**

```bash
git add Sources/WallflowApp/ModelRenderer.swift Sources/WallflowKit/Particles/ParticlePreset.swift
git commit -m "모델 렌더러의 MODELDBG 진단 줄을 지우고 ParticleOverride 설명을 제자리에 둔다"
```

---

### Task 2: 배율을 스폰 결과와 힘에 곱하고, 감쇠 NaN을 고친다

**Files:**
- Modify: `Sources/WallflowKit/Particles/ParticlePreset.swift` — `ParticleOverride`(brightness, 틴트 주석), `ParticlePreset.instance`·init·`applying`·`withChildren`·`scaledToBudget`, `ParticleInitializer.scaled(size:speed:lifetime:alpha:color:)` 삭제
- Modify: `Sources/WallflowKit/Particles/ParticleSystem.swift` — `instance`, `emitParticle`, `applyOperator`(movement 중력·감쇠, turbulence, vortex, controlPointAttract, remapValue velocity/speed)
- Modify: `Tests/WallflowKitTests/ParticleOverrideTests.swift`
- Create: `Tests/WallflowKitTests/ParticleInstanceTests.swift`

**Interfaces:**
- Produces: `ParticleOverride.brightness: Double`(기본 1) · `ParticlePreset.instance: ParticleOverride`(init 마지막 인자 `instance: ParticleOverride = ParticleOverride()`) · `ParticleSystem.instance: ParticleOverride`(public var) · `scaledToBudget(_:)`은 `instance`를 건드리지 않는다 · 테스트 헬퍼 `ParticleInstanceTests.bare(rate:burst:operators:)`·`spawn(_:_:dt:)`·`zero`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/WallflowKitTests/ParticleInstanceTests.swift`:

```swift
import XCTest
@testable import WallflowKit

/// 씬 배율(`instanceoverride`)은 초기화자가 아니라 **스폰 결과**와 힘에 곱한다.
/// 공식 문서 IParticleSystemInstance: 전부 배율이고 1이면 그대로다.
final class ParticleInstanceTests: XCTestCase {
    let zero = Vec3(x: 0, y: 0, z: 0)

    /// 초기화자가 하나도 없는 프리셋. 기본값(크기 1·투명도 1·수명 1·흰색)만 있다.
    func bare(rate: Double = 0, burst: ParticleEmitterBurst = ParticleEmitterBurst(count: 8),
              initializers: [ParticleInitializer] = [],
              operators: [ParticleOperator] = []) -> ParticlePreset {
        ParticlePreset(
            maxCount: 64, startTime: 0, materialPath: "m.json",
            emitters: [.sphereRandom(rate: rate, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0, burst: burst)],
            initializers: initializers, operators: operators, unsupportedNames: [])
    }

    func spawn(_ preset: ParticlePreset, _ o: ParticleOverride, dt: Double = 0.05) -> [Particle] {
        let system = ParticleSystem(preset: preset.applying(o), random: SeededRandom(seed: 7))
        system.update(deltaTime: dt)
        return system.particles
    }

    /// 실물 PS2 시계 파티클은 colorrandom이 없다. 초기화자에 곱하던 때는 colorn이
    /// 통째로 버려졌다. 크기·투명도·수명도 같은 처지였다.
    func testFactorsApplyWithoutInitializers() {
        var o = ParticleOverride()
        o.size = 2; o.alpha = 0.5; o.lifetime = 3
        o.color = Vec3(x: 0.2, y: 0.4, z: 0.6)
        let ps = spawn(bare(), o)
        XCTAssertEqual(ps.count, 8)
        for p in ps {
            XCTAssertEqual(p.size, 2, accuracy: 1e-9)
            XCTAssertEqual(p.alpha, 0.5, accuracy: 1e-9)
            XCTAssertEqual(p.lifetime, 3, accuracy: 1e-9)
            XCTAssertEqual(p.color, Vec3(x: 0.2, y: 0.4, z: 0.6))  // 흰색 × 틴트
        }
    }

    /// colorn은 틴트다 — 프리셋 색에 곱한다. WE 자체 물 튀김 미리보기가 이미 하늘색인
    /// 프리셋에 파란 colorn을 얹는다.
    func testColornTintsPresetColor() throws {
        var o = ParticleOverride()
        o.color = Vec3(x: 0.5, y: 0.5, z: 1)
        let preset = bare(initializers: [.colorRandom(min: Vec3(x: 1, y: 0.5, z: 0.5),
                                                      max: Vec3(x: 1, y: 0.5, z: 0.5))])
        let p = try XCTUnwrap(spawn(preset, o).first)
        XCTAssertEqual(p.color.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.color.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.color.z, 0.5, accuracy: 1e-9)
    }

    /// WE 자체 번개 미리보기가 brightness 5를, 실물 Universal Reflex 3이 10·3을 쓴다.
    /// 색에 곱한다 — 1을 넘어도 된다(가산 혼합에서 더 밝게 더해진다).
    func testBrightnessMultipliesColor() throws {
        var o = ParticleOverride()
        o.brightness = 10
        let p = try XCTUnwrap(spawn(bare(), o).first)
        XCTAssertEqual(p.color, Vec3(x: 10, y: 10, z: 10))
    }

    /// speed는 "initial velocity" — 이미터가 주는 속력(불꽃)까지 포함한 최종 속도다.
    func testSpeedScalesEmitterSpeed() throws {
        var o = ParticleOverride()
        o.speed = 3
        let preset = bare(burst: ParticleEmitterBurst(count: 1, speedMin: 10, speedMax: 10))
        let p = try XCTUnwrap(spawn(preset, o, dt: 1e-6).first)
        let v = p.velocity
        XCTAssertEqual((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot(), 30, accuracy: 1e-6)
    }

    /// speed는 "and forces" — 중력도 같이 커져야 궤적이 같은 모양으로 늘어난다.
    func testSpeedScalesGravity() throws {
        var o = ParticleOverride()
        o.speed = 2
        let preset = bare(burst: ParticleEmitterBurst(count: 1),
                          operators: [.movement(gravity: Vec3(x: 0, y: -10, z: 0), drag: 0)])
        let p = try XCTUnwrap(spawn(preset, o, dt: 0.1).first)
        XCTAssertEqual(p.velocity.y, -2, accuracy: 1e-9)  // -10 × 2 × 0.1
    }

    /// remapvalue가 속도를 정하는 프리셋(실물 rain_screen)도 speed 배율을 받는다.
    func testSpeedScalesRemapVelocity() throws {
        var o = ParticleOverride()
        o.speed = 2
        let preset = bare(burst: ParticleEmitterBurst(count: 1), operators: [
            .remapValue(output: .velocity, transform: .noise, inputScale: 1,
                        outputMin: Vec3(x: 10, y: 0, z: 0), outputMax: Vec3(x: 10, y: 0, z: 0)),
        ])
        let p = try XCTUnwrap(spawn(preset, o, dt: 0.05).first)
        XCTAssertEqual(p.velocity.x, 20, accuracy: 1e-9)
    }

    /// drag는 초당 감쇠 계수다(dv/dt = −drag·v). 실물 프리셋의 3분의 1이 1을 넘는다
    /// (반딧불 2.5, 불꽃 3.5~4). `pow(1 − drag, dt)`는 그때 NaN이 되어 파티클이 사라졌다.
    func testDragAboveOneStaysFinite() throws {
        let preset = bare(burst: ParticleEmitterBurst(count: 1, speedMin: 10, speedMax: 10),
                          operators: [.movement(gravity: zero, drag: 2.5)])
        let p = try XCTUnwrap(spawn(preset, ParticleOverride(), dt: 0.1).first)
        let v = p.velocity
        let speed = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        XCTAssertTrue(speed.isFinite)
        XCTAssertEqual(speed, 10 * exp(-0.25), accuracy: 1e-9)
    }

    /// 예산은 개수만 줄인다. 씬 배율을 지우면 안 된다.
    func testBudgetKeepsSceneInstance() {
        var o = ParticleOverride()
        o.size = 2
        let p = bare(rate: 10).applying(o).scaledToBudget(0.5)
        XCTAssertEqual(p.instance.size, 2)
        XCTAssertEqual(p.maxCount, 32)
    }
}
```

`Tests/WallflowKitTests/ParticleOverrideTests.swift`에서 `testRateSizeSpeedLifetimeMultiply`와 `testColorOverrideReplacesRange`를 이것으로 바꾼다(색은 `ParticleInstanceTests`가 맡는다):

```swift
    /// 배율은 프리셋에 굽지 않고 `instance`로 들고 간다. 초기화자는 그대로다.
    func testApplyingStoresInstanceAndKeepsInitializers() {
        var o = ParticleOverride()
        o.rate = 0.5; o.size = 2; o.speed = 3; o.lifetime = 0.5
        let p = preset().applying(o)
        XCTAssertEqual(p.instance, o)
        XCTAssertEqual(p.initializers, preset().initializers)
        guard case .sphereRandom(let rate, _, _, let lo, let hi, _) = p.emitters[0] else {
            return XCTFail("sphererandom이어야 한다")
        }
        XCTAssertEqual(rate, 10, accuracy: 0.001)
        // **뿌리는 범위는 배율을 따르지 않는다.** 한동안 크기 배율을 범위에까지
        // 곱했는데, 그러면 비가 화면 일부에만 내린다(실물에서 반경 1024가 0.65배로
        // 줄어 가로 3분의 2에만 왔다).
        XCTAssertEqual(lo, 10, accuracy: 0.001)
        XCTAssertEqual(hi, 100, accuracy: 0.001)
    }
```

`testParsesRealShape`의 입력에 `"brightness": 10.0`을 넣고 `XCTAssertEqual(o.brightness, 10, accuracy: 0.001)`을 더한다.

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter "ParticleInstanceTests|ParticleOverrideTests"`
Expected: 컴파일 실패 — `brightness`·`instance`가 없다

- [ ] **Step 3: `ParticleOverride`** (`ParticlePreset.swift`)

설명 주석과 필드·`isIdentity`를 이것으로 바꾸고, `parse`의 `result.alpha = …` 다음에 `result.brightness = factor("brightness") ?? 1`을 더한다:

```swift
/// 씬이 프리셋 위에 얹는 조정값(`instanceoverride`).
///
/// 공식 문서 IParticleSystemInstance: 전부 배율이고 1이면 그대로다 — alpha "opacity",
/// size "size", count "emission rate", speed "initial velocity and forces", lifetime
/// "lifetime", rate "simulation rate", colorn "Modifies the color assigned to particles".
/// 무시하면 씬이 의도한 것과 전혀 다른 밀도로 뿌린다 — 실물 Hiyuki의 벚꽃은
/// `count`가 0.05다. `brightness`는 문서 표에 없지만 WE 자체 번개 미리보기(5)와
/// 실물 6곳(3, 10)이 쓴다 — 색에 곱한다.
public struct ParticleOverride: Equatable, Sendable {
    /// 전부 배율이다. 1이면 프리셋 그대로.
    public var count: Double = 1
    public var rate: Double = 1
    public var size: Double = 1
    public var speed: Double = 1
    public var lifetime: Double = 1
    public var alpha: Double = 1
    public var brightness: Double = 1
    /// 색도 곱한다(틴트). 0~1이다. 프리셋의 색 변화는 남는다.
    public var color: Vec3?

    public init() {}

    /// 아무것도 바꾸지 않는지. 그러면 프리셋을 그대로 쓴다.
    public var isIdentity: Bool {
        count == 1 && rate == 1 && size == 1 && speed == 1
            && lifetime == 1 && alpha == 1 && brightness == 1 && color == nil
    }
```

`parse` 안 colorn 주석(`// colorn은 이미 0~1이다. …`)은 그대로 둔다.

- [ ] **Step 4: 프리셋이 배율을 들고 가게 한다** (`ParticlePreset.swift`)

`children` 선언 아래에 필드, `init`의 마지막 인자와 대입:

```swift
    /// 씬의 `instanceoverride`. 초기화자에 굽지 않는다 — `ParticleSystem`이 스폰
    /// 결과와 힘에 곱한다. 초기화자가 없는 프리셋에도 먹어야 하기 때문이다.
    public let instance: ParticleOverride
```

```swift
        controlPoints: [ParticleControlPoint] = [],
        instance: ParticleOverride = ParticleOverride()
    ) {
        self.instance = instance
```

`applying`(방출률은 T4 전까지 지금처럼 rate로 곱한다):

```swift
    /// 씬의 조정값을 얹은 프리셋을 만든다.
    ///
    /// 개수는 최소 1로 남긴다 — 배율이 0.05여도 아예 안 나오면 씬이 의도한
    /// "드물게 흩날림"이 아니라 "없음"이 된다.
    public func applying(_ override: ParticleOverride) -> ParticlePreset {
        guard !override.isIdentity else { return self }
        let scaledCount = override.count == 1 ? maxCount
            : Swift.max(1, Swift.min(Int((Double(maxCount) * override.count).rounded()),
                                     Self.maxAllowedCount))
        return ParticlePreset(
            maxCount: scaledCount, startTime: startTime, materialPath: materialPath,
            emitters: emitters.map { $0.scaled(rate: override.rate) },
            initializers: initializers, operators: operators,
            unsupportedNames: unsupportedNames, malformedNames: malformedNames,
            animationMode: animationMode, childReferences: childReferences,
            children: children, controlPoints: controlPoints, instance: override)
    }
```

`withChildren`의 생성자 호출에 `instance: instance`를 더한다. `scaledToBudget`을 자기 경로로:

```swift
    /// 예산에 맞춰 개수와 방출률을 같은 배율로 줄인다.
    ///
    /// 개수만 줄이면 방출이 빈 슬롯을 기다리며 몰려, 밀도 대신 수명이 짧아 보인다.
    /// 둘을 같이 줄여야 "덜 많다"로 보이고 씬이 의도한 모양이 남는다.
    /// 씬 배율(`instance`)은 그대로 둔다 — 예산은 씬의 뜻이 아니다.
    public func scaledToBudget(_ factor: Double) -> ParticlePreset {
        guard factor < 1, factor > 0 else { return self }
        return ParticlePreset(
            maxCount: Swift.max(1, Int((Double(maxCount) * factor).rounded())),
            startTime: startTime, materialPath: materialPath,
            emitters: emitters.map { $0.scaled(rate: factor) },
            initializers: initializers, operators: operators,
            unsupportedNames: unsupportedNames, malformedNames: malformedNames,
            animationMode: animationMode, childReferences: childReferences,
            children: children, controlPoints: controlPoints, instance: instance)
    }
```

`ParticleInitializer.scaled(size:speed:lifetime:alpha:color:)`를 통째로 지운다(부르는 곳이 없어진다).

- [ ] **Step 5: 시스템이 스폰 결과와 힘에 곱한다** (`ParticleSystem.swift`)

`preset` 선언 근처에 필드, `init` 첫머리에 `self.instance = preset.instance`:

```swift
    /// 씬 배율(`instanceoverride`). 스크립트가 `layer.instance`로 바꾼다 —
    /// 스폰 결과는 **새로 나는** 파티클부터, 힘은 바로 먹는다.
    public var instance: ParticleOverride
```

`emitParticle`에서 초기화자 루프 뒤, `particle.baseSize = particle.size` 앞:

```swift
        // 씬 배율은 초기화자가 끝난 **결과**에 곱한다. 초기화자에 곱하면 그 초기화자가
        // 없는 프리셋(기본 크기·수명·흰색)에는 안 먹는다 — 실물 PS2 시계 파티클은
        // colorrandom이 없어 colorn이 통째로 버려졌다. 속도는 이미터 속력(불꽃)까지
        // 포함한 최종 속도다. 색은 틴트(곱)에 밝기를 얹는다.
        let o = instance
        particle.size *= o.size
        particle.alpha *= o.alpha
        particle.lifetime *= o.lifetime
        particle.velocity = Vec3(x: particle.velocity.x * o.speed,
                                 y: particle.velocity.y * o.speed,
                                 z: particle.velocity.z * o.speed)
        let tint = o.color ?? Vec3(x: 1, y: 1, z: 1)
        particle.color = Vec3(x: particle.color.x * tint.x * o.brightness,
                              y: particle.color.y * tint.y * o.brightness,
                              z: particle.color.z * tint.z * o.brightness)
```

`applyOperator`의 `.movement`에서 **중력 세 줄과 감쇠 계수 한 줄만** 바꾼다(위치 적분 줄은 그대로):

```swift
        case .movement(let gravity, let drag):
            // 중력은 힘이다. 초기 속도와 함께 speed 배율을 받아야 궤적이 같은
            // 모양으로 늘어난다(문서: "initial velocity and forces").
            let force = instance.speed
            particle.velocity = Vec3(
                x: particle.velocity.x + gravity.x * force * dt,
                y: particle.velocity.y + gravity.y * force * dt,
                z: particle.velocity.z + gravity.z * force * dt
            )

            // drag는 초당 감쇠 계수다 — dv/dt = −drag·v. 실물 프리셋의 3분의 1이 1을
            // 넘는다(반딧불 2.5, 불꽃 3.5~4). `pow(1 − drag, dt)`는 그때 밑이 음수라
            // NaN이 되어 파티클이 첫 프레임 뒤 사라졌다.
            if drag > 0 {
                let dampFactor = exp(-drag * dt)
```

나머지 세 힘:

```swift
            // .turbulence
            let speed = (speedMin + Self.hash(particle.frameSeed, 31) * (speedMax - speedMin))
                * instance.speed
```

```swift
            // .vortex
            let speed = (speedInner + (speedOuter - speedInner) * ratio) * instance.speed
```

```swift
            // .controlPointAttract
            let strength = scale * falloff * dt * instance.speed
```

`.remapValue`의 속도 출력 둘(다른 출력은 그대로):

```swift
            case .velocity:
                // 속도를 정하는 연산자도 speed 배율을 받는다(실물 rain_screen).
                particle.velocity = Vec3(x: value.x * instance.speed, y: value.y * instance.speed,
                                         z: value.z * instance.speed)
```

```swift
                    let scale = value.x * instance.speed / magnitude
```

- [ ] **Step 6: 통과를 확인한다**

Run: 전체 테스트(Global Constraints의 환경변수 포함)
Expected: 전부 통과, 실패 0, 새 경고 0. 감쇠식이 바뀌어 drag 0~1 프리셋의 기존 수치 테스트가 깨지면 Global Constraints의 규칙대로 판단한다(새 식은 `exp(−drag·dt)`).

- [ ] **Step 7: Commit**

```bash
git add Sources/WallflowKit/Particles Tests/WallflowKitTests/ParticleInstanceTests.swift Tests/WallflowKitTests/ParticleOverrideTests.swift
git commit -m "파티클 씬 배율을 스폰 결과와 힘에 곱하고, brightness를 읽고, 1을 넘는 drag의 NaN을 고친다"
```

---

### Task 3: 인스턴스 스크립트

**Files:**
- Modify: `Sources/WallflowKit/Particles/ParticlePreset.swift` — `ParticleOverride.scriptKeys`·`scriptValues`·`apply(_:)`
- Modify: `Sources/WallflowKit/Particles/ParticleSystem.swift` — `restartsSeen`
- Modify: `Sources/WallflowKit/ScenePackage/SceneDocument.swift` — `scriptHolders(of:)` 새로, `layerScripts(of:)`·`loadScriptModules`가 그것을 쓴다
- Modify: `Sources/WallflowKit/Scripting/SceneScriptHost.swift` — `LayerSeed.instance`, `seedJSON`, JS(`__wfInstance`·`__wfMakeLayer`·`stop`·`__wfValue`·`__wfAssign`·`__wfSnapshot`), `LayerState.instance`·`restarts`, `parse`
- Modify: `Sources/WallflowApp/SceneRenderer.swift:646-652`
- Test: `Tests/WallflowKitTests/ParticleInstanceTests.swift`, `Tests/WallflowKitTests/SceneDocumentTests.swift`, `Tests/WallflowKitTests/SceneScriptHostTests.swift`

**Interfaces:**
- Consumes: `ParticleSystem.instance`, `ParticlePreset.instance` (T2)
- Produces: `ParticleOverride.scriptKeys: [String]` · `scriptValues: [String: EffectConstant]` · `mutating apply(_ values: [String: EffectConstant])` · `SceneDocument.scriptHolders(of:) -> [(property: String, holder: [String: Any])]` · `LayerSeed.instance` · `LayerState.instance: [String: EffectConstant]` · `LayerState.restarts: Int` · `ParticleSystem.restartsSeen: Int` · 속성 이름 `"instanceoverride.<키>"`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`ParticleInstanceTests`에:

```swift
    /// 스크립트가 쓴 값도 파일과 같은 규칙으로 거른다.
    func testApplyFiltersScriptValues() {
        var o = ParticleOverride()
        o.apply(["rate": .scalar(0.5), "size": .scalar(.nan), "speed": .scalar(-1),
                 "count": .scalar(1e9), "colorn": .vector([0.1, 0.2, 0.3]),
                 "brightness": .vector([1, 2, 3])])
        XCTAssertEqual(o.rate, 0.5)
        XCTAssertEqual(o.size, 1)
        XCTAssertEqual(o.speed, 1)
        XCTAssertEqual(o.count, 1)
        XCTAssertEqual(o.brightness, 1)
        XCTAssertEqual(o.color, Vec3(x: 0.1, y: 0.2, z: 0.3))
    }

    /// 스크립트 쪽 시작값은 지금 배율 그대로다. 색은 있을 때만.
    func testScriptValuesRoundTrip() {
        var o = ParticleOverride()
        o.rate = 0.19
        var back = ParticleOverride()
        back.apply(o.scriptValues)
        XCTAssertEqual(back, o)
        XCTAssertNil(o.scriptValues["colorn"])
    }
```

`SceneDocumentTests`에:

```swift
    /// instanceoverride 값도 스크립트일 수 있다(실물 PS2 시계 colorn, Universal Reflex 3 rate).
    func testInstanceOverrideScriptsAreLayerScripts() {
        let object: [String: Any] = [
            "particle": "particles/p.json",
            "instanceoverride": [
                "id": 1, "count": 2.0,
                "rate": ["script": "export function update(v) { return v; }", "value": 0.19],
            ],
        ]
        XCTAssertEqual(SceneDocument.layerScripts(of: object).map(\.property),
                       ["instanceoverride.rate"])
        XCTAssertEqual(SceneDocument.scriptHolders(of: object).map(\.property),
                       ["instanceoverride.rate"])
    }
```

`SceneScriptHostTests`에(파일의 `seed(...)` 헬퍼를 쓴다):

```swift
    /// 파티클 배율(`layer.instance`). 속성 스크립트 `instanceoverride.<키>`가 시작값을
    /// 받고, 돌려준 값이 스냅샷으로 나온다.
    func testInstanceOverrideScriptRoundTrip() {
        var s = seed(3, "vortex", scripts: [LayerScript(
            property: "instanceoverride.rate",
            source: "export function update(v) { return v * 2; }")])
        s.instance = ["rate": .scalar(0.25)]
        let host = SceneScriptHost(layers: [s], camera: nil)
        XCTAssertEqual(host.tick(frametime: 0.1).layers[3]?.instance["rate"], .scalar(0.5))
    }

    /// 실물 PS2 시계의 `particles` 레이어 스크립트 그대로다. colorn 시작값은 "0 0 0"이고
    /// 스크립트가 테마색 × 0.175로 바꾼다 — 안 돌리면 가산 혼합이라 파티클이 안 보인다.
    func testInstanceColorScriptUsesUserProperties() {
        let source = """
        let particleColor = new Vec3(0, 0, 0);
        export function update(value) { return particleColor; }
        export function applyUserProperties(userProperties) {
            particleColor = userProperties.schemecolor.multiply(0.175);
        }
        """
        var s = seed(4, "particles", scripts: [LayerScript(
            property: "instanceoverride.colorn", source: source)])
        s.instance = ["colorn": .vector([0, 0, 0])]
        let host = SceneScriptHost(layers: [s], camera: nil,
                                   userProperties: ["schemecolor": .color(Vec3(x: 1, y: 0.5, z: 0))])
        guard case .vector(let c)? = host.tick(frametime: 0.1).layers[4]?.instance["colorn"] else {
            return XCTFail("colorn 벡터가 나와야 한다")
        }
        XCTAssertEqual(c[0], 0.175, accuracy: 1e-9)
        XCTAssertEqual(c[1], 0.0875, accuracy: 1e-9)
    }

    /// 일반 속성 스크립트 안에서 `thisLayer.instance`를 고쳐도 나온다(실물 PS2 오브).
    func testLayerInstanceWritesAreReported() {
        let host = SceneScriptHost(layers: [
            seed(5, "orb", scripts: [LayerScript(
                property: "origin",
                source: "export function update(v) { thisLayer.instance.colorn = new Vec3(0.1, 0.2, 0.3); return v; }")]),
        ], camera: nil)
        XCTAssertEqual(host.tick(frametime: 0.1).layers[5]?.instance["colorn"],
                       .vector([0.1, 0.2, 0.3]))
    }

    /// 한 틱 안의 `stop(); play()`는 재시작이다. 최종 상태만 보면 사라지므로 횟수로 센다.
    func testStopThenPlayInOneTickCountsRestart() {
        let host = SceneScriptHost(layers: [
            SceneScriptHost.LayerSeed(
                id: 6, name: "orb", origin: Vec3(x: 0, y: 0, z: 0),
                angles: Vec3(x: 0, y: 0, z: 0), scale: Vec3(x: 1, y: 1, z: 1),
                alpha: 1, visible: true, playing: true,
                scripts: [LayerScript(
                    property: "origin",
                    source: "let done = false; export function update(v) { if (!done) { thisLayer.stop(); thisLayer.play(); done = true; } return v; }")]),
        ], camera: nil)
        let state = host.tick(frametime: 0.1).layers[6]
        XCTAssertEqual(state?.playing, true)
        XCTAssertEqual(state?.restarts, 1)
    }
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter "ParticleInstanceTests|SceneDocumentTests|SceneScriptHostTests"`
Expected: 컴파일 실패 — `apply`·`scriptValues`·`scriptHolders`·`instance`·`restarts`가 없다

- [ ] **Step 3: `ParticleOverride`에 스크립트 쪽 입출구를 단다**

```swift
    /// 스크립트(`layer.instance`, `instanceoverride.<키>`)가 읽고 쓰는 이름.
    /// `colorn`만 벡터다.
    public static let scriptKeys = [
        "alpha", "size", "count", "speed", "lifetime", "rate", "brightness", "colorn",
    ]

    /// 스크립트 쪽 `layer.instance`의 시작값.
    public var scriptValues: [String: EffectConstant] {
        var out: [String: EffectConstant] = [
            "alpha": .scalar(alpha), "size": .scalar(size), "count": .scalar(count),
            "speed": .scalar(speed), "lifetime": .scalar(lifetime), "rate": .scalar(rate),
            "brightness": .scalar(brightness),
        ]
        if let color { out["colorn"] = .vector([color.x, color.y, color.z]) }
        return out
    }

    /// 스크립트가 쓴 값을 얹는다. 파일과 같은 규칙 — 유한하고 0~100인 배율만 받는다.
    public mutating func apply(_ values: [String: EffectConstant]) {
        for (key, value) in values {
            switch (key, value) {
            case ("colorn", .vector(let v)) where v.count >= 3 && v.prefix(3).allSatisfy(\.isFinite):
                color = Vec3(x: v[0], y: v[1], z: v[2])
            case (_, .scalar(let d)) where d.isFinite && d >= 0 && d <= 100:
                switch key {
                case "alpha": alpha = d
                case "size": size = d
                case "count": count = d
                case "speed": speed = d
                case "lifetime": lifetime = d
                case "rate": rate = d
                case "brightness": brightness = d
                default: break
                }
            default: break
            }
        }
    }
```

- [ ] **Step 4: 씬이 instanceoverride 스크립트를 내놓는다** (`SceneDocument.swift`)

```swift
    /// 스크립트를 품을 수 있는 자리 전부. 파티클의 `instanceoverride` 값도 스크립트일 수
    /// 있다(실물 PS2 시계 `colorn`, Universal Reflex 3 `rate`) — 이름은 `instanceoverride.<키>`.
    /// 속성 스크립트와 모듈 import 수집이 같은 목록을 봐야 한다.
    static func scriptHolders(of object: [String: Any]) -> [(property: String, holder: [String: Any])] {
        var holders: [(property: String, holder: [String: Any])] =
            scriptableProperties.compactMap { key in
                (object[key] as? [String: Any]).map { (key, $0) }
            }
        let instance = object["instanceoverride"] as? [String: Any] ?? [:]
        for key in ParticleOverride.scriptKeys {
            if let holder = instance[key] as? [String: Any] {
                holders.append(("instanceoverride.\(key)", holder))
            }
        }
        return holders
    }

    /// 오브젝트의 속성 스크립트 전부. `text`는 `text` 객체 안에 있다.
    static func layerScripts(of object: [String: Any]) -> [LayerScript] {
        var scripts: [LayerScript] = []
        for (key, holder) in scriptHolders(of: object) {
            guard let source = holder["script"] as? String else { continue }
            var properties: [String: ScriptPropertyValue] = [:]
            for (name, raw) in (holder["scriptproperties"] as? [String: Any] ?? [:]) {
                if let n = raw as? NSNumber, !(raw is String) {
                    properties[name] = .number(n.doubleValue)
                } else if let t = raw as? String {
                    properties[name] = .text(t)
                }
            }
            scripts.append(LayerScript(property: key, source: source, scriptProperties: properties))
        }
        return scripts
    }
```

`loadScriptModules`의 안쪽 루프 머리를 같은 목록으로 바꾼다:

```swift
            for (_, holder) in scriptHolders(of: object) {
                guard let script = holder["script"] as? String else { continue }
```

- [ ] **Step 5: 스크립트 호스트가 instance를 주고받는다** (`SceneScriptHost.swift`)

`LayerSeed`에 필드를 더하고 `init(_ layer:)`에서 채운다(지역 변수 `var instance: [String: EffectConstant] = [:]`를 다른 지역 변수 옆에, 끝에서 `self.instance = instance`):

```swift
        /// 파티클이면 씬 배율(`layer.instance`)의 시작값. 아니면 비어 있다.
        public var instance: [String: EffectConstant] = [:]
```

```swift
            case .particle(let preset, _, _, _, _):
                // 파티클도 `play()/stop()`의 대상이다. 처음에는 돈다.
                playing = true
                instance = preset.instance.scriptValues
```

`seedJSON`에:

```swift
        if !seed.instance.isEmpty {
            let pairs = seed.instance.sorted { $0.key < $1.key }.map { key, value -> String in
                switch value {
                case .scalar(let d): return "\(jsString(key)): \(finite(d))"
                case .vector(let v): return "\(jsString(key)): [\(v.map { "\(finite($0))" }.joined(separator: ","))]"
                }
            }
            fields["io"] = "{" + pairs.joined(separator: ", ") + "}"
        }
```

JS 앞머리(`__wfMakeLayer` 위):

```js
    function __wfInstance(raw) {
        var out = {};
        for (var k in (raw || {})) {
            var v = raw[k];
            out[k] = (v && v.length >= 3) ? new Vec3(v[0], v[1], v[2]) : v;
        }
        return out;
    }
```

`__wfMakeLayer`에서 `instance: {},` → `instance: __wfInstance(seed.io),`. `stop`을:

```js
            // stop()은 파티클을 거둔다. 한 틱 안의 stop(); play()는 최종 상태만 보면
            // 사라지므로 횟수를 센다 — 렌더러가 이걸로 재시작한다.
            stop: function () { this.__playing = false; this.__restarts = (this.__restarts || 0) + 1; },
```

`__wfValue` 첫 줄:

```js
        if (p.indexOf('instanceoverride.') === 0) { return L.instance[p.slice(17)]; }
```

`__wfAssign`의 재질 분기 뒤:

```js
        if (p.indexOf('instanceoverride.') === 0) {
            var key = p.slice(17);
            if (typeof r === 'number') { if (isFinite(r)) { L.instance[key] = r; } }
            else if (typeof r === 'object') { L.instance[key] = new Vec3(r); }
            return;
        }
```

`__wfSnapshot`의 `if (L.__material)` 앞:

```js
            if (L.instance) {
                var io = {}, anyIO = false;
                for (var ik in L.instance) {
                    var iv = L.instance[ik];
                    if (typeof iv === 'number') { io[ik] = iv; anyIO = true; }
                    else if (iv && typeof iv === 'object' && typeof iv.x === 'number') {
                        io[ik] = [+iv.x, +iv.y, +iv.z]; anyIO = true;
                    }
                }
                if (anyIO) { entry.io = io; }
            }
            if (typeof L.__restarts === 'number') { entry.rs = L.__restarts; }
```

`LayerState`에:

```swift
        /// 파티클 배율(`layer.instance`). 스크립트가 안 건드렸어도 시작값이 온다.
        public var instance: [String: EffectConstant] = [:]
        /// 스크립트가 `stop()`을 부른 횟수. 한 틱 안의 `stop(); play()`는 최종 상태만
        /// 보면 사라지므로 횟수로 재시작을 알린다.
        public var restarts = 0
```

`parse`의 `state.material = material` 뒤:

```swift
            var instance: [String: EffectConstant] = [:]
            for (key, value) in (raw["io"] as? [String: Any] ?? [:]) {
                if let d = Self.number(value) { instance[key] = .scalar(d) }
                else if let v = Self.vec3(value) { instance[key] = .vector([v.x, v.y, v.z]) }
            }
            state.instance = instance
            state.restarts = Swift.max(0, (raw["rs"] as? NSNumber)?.intValue ?? 0)
```

- [ ] **Step 6: 렌더러가 시스템에 넘긴다**

`ParticleSystem.swift`에:

```swift
    /// 렌더러가 마지막으로 본 스크립트 `stop()` 횟수.
    public var restartsSeen = 0
```

`SceneRenderer.swift`의 파티클 분기(`if let pi = target.particleIndex …`)를:

```swift
        if let pi = target.particleIndex, pi < particles.count {
            let system = particles[pi].system
            particles[pi].layerOrigin = SIMD2(Float(world.origin.x), Float(world.origin.y))
            // 스크립트의 `layer.instance`. 스폰 결과는 새로 나는 파티클부터 먹는다.
            var instance = system.instance
            instance.apply(state.instance)
            if instance != system.instance {
                system.instance = instance
                changed = true
            }
            // 한 틱 안의 `stop(); play()`는 재시작이다(실물 PS2 오브가 색을 바꾼 뒤
            // 이렇게 다시 튼다). 거둔 뒤 아래 play()가 다시 뿌린다.
            if state.restarts > system.restartsSeen {
                system.restartsSeen = state.restarts
                system.stop()
                changed = true
            }
            // 스크립트의 play()/stop(). 바뀔 때만 — stop()은 파티클을 거두므로 매 틱 부르면 안 된다.
            if let playing = state.playing, playing != system.isPlaying {
                playing ? system.play() : system.stop()
                changed = true
            }
        }
```

- [ ] **Step 7: 통과를 확인한다**

Run: 전체 테스트(환경변수 포함), `swift build`(앱 타깃 포함)
Expected: 전부 통과, 실패 0, 새 경고 0

- [ ] **Step 8: Commit**

```bash
git add Sources Tests
git commit -m "파티클 인스턴스 배율을 스크립트가 읽고 쓰게 하고 한 틱 안의 재시작을 전한다"
```

---

### Task 4: count는 방출량, rate는 시뮬레이션 속도

**Files:**
- Modify: `Sources/WallflowKit/Particles/ParticlePreset.swift` — `applying`
- Modify: `Sources/WallflowKit/Particles/ParticleSystem.swift` — `update`, `emitParticles`, `emitBurst`
- Test: `Tests/WallflowKitTests/ParticleInstanceTests.swift`, `Tests/WallflowKitTests/ParticleOverrideTests.swift`

**Interfaces:**
- Consumes: `ParticleSystem.instance`, 테스트 헬퍼 `bare`·`spawn`·`zero` (T2)
- Produces: `update(deltaTime:)`가 `deltaTime × instance.rate`를 `maxTimeStep`으로 죈 시뮬레이션 시간으로 걷는다 (T5가 이 위에 프리웜을 얹는다)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`ParticleInstanceTests`에:

```swift
    /// rate는 "simulation rate" — 시간을 늦춘다. 방출률이 아니다.
    /// 실물 The Gilded Shore의 소용돌이 8개가 rate 0.18이다(magic_vortex_0: maxcount 256,
    /// 방출 512/s, 수명 0.4~0.7). 방출률로 읽으면 ~50개가 빨리 돌고, 시간으로 읽으면
    /// ~256개가 5.5배 느리게 돈다.
    func testRateSlowsSimulationNotEmission() {
        let preset = ParticlePreset(
            maxCount: 256, startTime: 0, materialPath: "m.json",
            emitters: [.sphereRandom(rate: 512, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0)],
            initializers: [.lifetimeRandom(min: 0.4, max: 0.7)],
            operators: [], unsupportedNames: [])
        var o = ParticleOverride()
        o.rate = 0.18
        let system = ParticleSystem(preset: preset.applying(o), random: SeededRandom(seed: 3))
        for _ in 0..<150 { system.update(deltaTime: 1.0 / 30) }  // 5초
        XCTAssertGreaterThan(system.aliveCount, 200)
    }

    /// 나이도 같은 시계를 따른다 — rate 0.5면 1초 뒤 나이는 0.5초다.
    func testRateScalesAge() throws {
        var o = ParticleOverride()
        o.rate = 0.5; o.lifetime = 100
        let system = ParticleSystem(preset: bare(burst: ParticleEmitterBurst(count: 1)).applying(o),
                                    random: SeededRandom(seed: 5))
        for _ in 0..<10 { system.update(deltaTime: 0.1) }
        XCTAssertEqual(try XCTUnwrap(system.particles.first).age, 0.5, accuracy: 1e-9)
    }

    /// 큰 rate도 한 걸음에 maxTimeStep을 넘지 않는다. (0.05초 × 100 = 5초 → 0.1초로 죈다.
    /// 옛 코드는 rate를 무시해 0.05초라 실패한다.)
    func testHugeRateIsClamped() throws {
        var o = ParticleOverride()
        o.rate = 100; o.lifetime = 1000
        let system = ParticleSystem(preset: bare(burst: ParticleEmitterBurst(count: 1)).applying(o),
                                    random: SeededRandom(seed: 5))
        system.update(deltaTime: 0.05)
        XCTAssertEqual(try XCTUnwrap(system.particles.first).age, ParticleSystem.maxTimeStep,
                       accuracy: 1e-9)
    }

    /// count는 "emission rate" — 계속 뿌리는 양도, 한꺼번에 뿌리는 양도 곱한다.
    func testCountScalesEmissionAndBurst() {
        var o = ParticleOverride()
        o.count = 3; o.lifetime = 100
        let continuous = ParticleSystem(preset: bare(rate: 10, burst: .none).applying(o),
                                        random: SeededRandom(seed: 1))
        for _ in 0..<10 { continuous.update(deltaTime: 0.1) }
        XCTAssertTrue((29...31).contains(continuous.aliveCount), "\(continuous.aliveCount)")

        o.count = 0.5
        XCTAssertEqual(spawn(bare(burst: ParticleEmitterBurst(count: 4)), o, dt: 1e-6).count, 2)
        // 있던 일괄 방출을 0으로 만들지는 않는다(실물 PS2 오브는 일괄 1개다).
        o.count = 0.05
        XCTAssertEqual(spawn(bare(burst: ParticleEmitterBurst(count: 1)), o, dt: 1e-6).count, 1)
    }
```

`ParticleOverrideTests.testApplyingStoresInstanceAndKeepsInitializers`의 `XCTAssertEqual(rate, 10, …)`을 `XCTAssertEqual(rate, 20, accuracy: 0.001)`로 바꾸고 주석을 단다: `// rate는 방출률이 아니다(시뮬레이션 속도). 이미터는 그대로다.`

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter "ParticleInstanceTests|ParticleOverrideTests"`
Expected: 새 테스트 넷과 바꾼 단언 하나가 실패

- [ ] **Step 3: 구현**

`applying`에서 `emitters: emitters.map { $0.scaled(rate: override.rate) },` → `emitters: emitters,`.

`update(deltaTime:)`에서 `let dt = Swift.min(deltaTime, Self.maxTimeStep)`을:

```swift
        // rate는 "simulation rate"(공식 문서) — 이 시스템의 시계를 늦추거나 당긴다.
        // 곱한 뒤 다시 죈다. 큰 배율이 한 걸음에 길게 걷게 두면 적분이 튄다.
        let dt = Swift.min(deltaTime * instance.rate, Self.maxTimeStep)
        guard dt > 0 else { return }
```

`emitParticles`에서 `emissionCredits[emitterIndex] += rate * dt` →

```swift
            // count는 "emission rate"(공식 문서). 개수 상한은 불러올 때 이미 곱했다.
            emissionCredits[emitterIndex] += rate * instance.count * dt
```

`emitBurst`에서 `let count = emitter.burst.count` / `guard count > 0 else { continue }` →

```swift
            // count는 한꺼번에 뿌리는 몫에도 먹는다. 있던 것을 0으로 만들지는 않는다
            // (실물 PS2 오브는 일괄 1개다). 슬롯 수보다 크게 잡을 이유는 없다.
            let authored = emitter.burst.count
            guard authored > 0 else { continue }
            let count = Swift.max(1, Int(Swift.min((Double(authored) * instance.count).rounded(),
                                                   Double(particleBuffer.count))))
```

- [ ] **Step 4: 통과를 확인한다**

Run: 전체 테스트(환경변수 포함)
Expected: 전부 통과, 실패 0. `ParticleBudgetTests`가 깨지면 예산이 방출률을 그대로 줄이는지(`scaledToBudget`) 먼저 본다.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallflowKit/Particles Tests/WallflowKitTests
git commit -m "instanceoverride의 count를 방출량으로, rate를 시뮬레이션 속도로 읽는다"
```

---

### Task 5: starttime 프리웜

`ParticlePreset.startTime`은 읽기만 하고 아무도 안 쓴다. 실물 빛줄기(`light_shafts_0` 10초)·반딧불·`light_shafts_1`·`magic_sparkle`(15초)이 앱을 켤 때마다 빈 화면에서 몇 분에 걸쳐 차오른다(빛줄기: 방출 0.2/s, 수명 8~20초).

**Files:**
- Modify: `Sources/WallflowKit/Particles/ParticleSystem.swift` — `update(deltaTime:)`를 `step(_:)`로 나누고 첫 호출에 프리웜
- Test: `Tests/WallflowKitTests/ParticleInstanceTests.swift`

**Interfaces:**
- Consumes: T4의 `update(deltaTime:)`
- Produces: `ParticleSystem.maxPrewarm: Double`(30초)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
    /// starttime은 프리웜이다 — 첫 프레임에 이미 그만큼 돈 상태여야 한다.
    func testStartTimePrewarms() {
        let preset = ParticlePreset(
            maxCount: 64, startTime: 10, materialPath: "m.json",
            emitters: [.sphereRandom(rate: 1, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [], unsupportedNames: [])
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 2))
        system.update(deltaTime: 1.0 / 30)
        XCTAssertTrue((9...11).contains(system.aliveCount), "\(system.aliveCount)")
    }

    /// 파일에서 온 값이라 상한을 둔다. 한 번에 치를 값이어야 한다.
    func testPrewarmIsCapped() throws {
        let preset = ParticlePreset(
            maxCount: 8, startTime: 1e6, materialPath: "m.json",
            emitters: [.sphereRandom(rate: 0, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0,
                                     burst: ParticleEmitterBurst(count: 1))],
            initializers: [.lifetimeRandom(min: 1e7, max: 1e7)],
            operators: [], unsupportedNames: [])
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 2))
        system.update(deltaTime: 0.05)
        XCTAssertEqual(try XCTUnwrap(system.particles.first).age,
                       ParticleSystem.maxPrewarm + 0.05, accuracy: 1e-6)
    }
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter ParticleInstanceTests`
Expected: 컴파일 실패 — `maxPrewarm`이 없다

- [ ] **Step 3: 구현**

필드:

```swift
    /// 프리웜 상한(초). 파일에서 온 값이라 한 번에 치를 만큼으로 죈다.
    public static let maxPrewarm = 30.0
    private var didPrewarm = false
```

`update(deltaTime:)`의 본문(시간 계산 뒤)을 `private func step(_ dt: Double)`로 옮기고, `update`는 이렇게 된다:

```swift
    public func update(deltaTime: Double) {
        guard deltaTime.isFinite, deltaTime > 0, isPlaying else { return }
        // `starttime`(프리웜): 처음 보일 때 이미 이만큼 돈 상태여야 한다. 시뮬레이션
        // 시간이라 rate 배율과 상관없이 그대로 돈다.
        if !didPrewarm {
            didPrewarm = true
            var remaining = Swift.min(Swift.max(preset.startTime, 0), Self.maxPrewarm)
            while remaining > 1e-9 {
                let dt = Swift.min(remaining, Self.maxTimeStep)
                step(dt)
                remaining -= dt
            }
        }
        // rate는 "simulation rate"(공식 문서) — 이 시스템의 시계를 늦추거나 당긴다.
        // 곱한 뒤 다시 죈다. 큰 배율이 한 걸음에 길게 걷게 두면 적분이 튄다.
        let dt = Swift.min(deltaTime * instance.rate, Self.maxTimeStep)
        guard dt > 0 else { return }
        step(dt)
    }

    /// 시뮬레이션 한 걸음. `dt`는 이미 시뮬레이션 시간이다.
    private func step(_ dt: Double) {
        // Remove dead particles from alive tracking
        removeDeadParticles()

        // 시작할 때 한꺼번에 뿌리는 몫. 첫 걸음에서 한 번만 한다.
        if !didBurst {
            didBurst = true
            emitBurst()
            // `type`이 없는 자식은 "한 번만, 시스템 원점에"다. 실물의 절반이
            // 이 경우이고, 그런 프리셋은 내용 전부가 자식에 들어 있다.
            spawnChildren(on: .once, at: originOffset, slot: nil)
        }

        // Emit new particles
        emitParticles(dt: dt)

        elapsed += dt

        // Apply operators to alive particles
        applyOperators(dt: dt)

        // 자식 시스템도 같은 시간만큼 굴린다.
        updateChildren(dt: dt)

        // Age particles
        ageParticles(dt: dt)
    }
```

- [ ] **Step 4: 통과를 확인한다**

Run: 전체 테스트(환경변수 포함)
Expected: 전부 통과, 실패 0. 실물 테스트가 "첫 몇 프레임의 개수"를 단언하다 깨지면 프리웜이 원인인지 보고 Global Constraints의 규칙대로 판단한다.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallflowKit/Particles/ParticleSystem.swift Tests/WallflowKitTests/ParticleInstanceTests.swift
git commit -m "파티클 프리셋의 starttime만큼 미리 돌려 두고 보인다"
```

---

### Task 6: 실물 검증 (메인 세션만)

- [ ] **Step 1:** 전체 테스트(환경변수 포함) — 실패 0. `swift build -c release 2>&1 | grep -c warning` → 0
- [ ] **Step 2:** 지금 배경화면을 적어 둔다: `defaults read dev.timevil.wallflow wallflow.lastSelectedID`
- [ ] **Step 3:** 앱을 새로 만들고 띄운다: `Scripts/bundle.sh && pkill -x Wallflow; open build/Wallflow.app`
- [ ] **Step 4:** `Scripts/shoot-library.sh <scratchpad>/shots 10` — 라이브러리 전부를 찍는다
- [ ] **Step 5:** 대조한다
  - The Gilded Shore(3794775331): 소용돌이·반짝이가 느리고 촘촘하다
  - Universal Reflex 3(3793718927): 별이 전보다 많다(레이어당 ~630 → ~2400 예상)
  - PS2 시계(1979606285): 파티클이 흰색도 검정도 아닌 테마색 × 0.175로 은은하다
  - Skyrim(3795217986): 반딧불이 보인다(감쇠 NaN 수정), 안개가 느리다, 빛줄기가 켜자마자 있다(프리웜)
  - one piece 4K(3793241848): 불꽃이 보인다(감쇠 NaN 수정)
  - Hiyuki(3714517753): 벚꽃이 드문드문(count 0.05) 그대로
  - 나머지: 전과 달라진 게 없다
- [ ] **Step 6:** 적어 둔 배경화면으로 되돌리고 앱을 다시 띄운다

어긋나면 superpowers:systematic-debugging으로 원인부터 찾는다.

---

### Task 7: 기록·릴리스

- [ ] **Step 1:** README에 지원 범위·제한 목록이 있으면 파티클 인스턴스 배율·`layer.instance`·프리웜 문구를 갱신한다(없으면 건드리지 않는다)
- [ ] **Step 2:** `Scripts/version.sh`의 버전을 0.1.1로 올리고 커밋: `git commit -m "0.1.1로 올린다"`
- [ ] **Step 3:** `Scripts/dist.sh`로 DMG를 만들고 마운트해 서명을 확인한다
- [ ] **Step 4:** `git push origin main`, 태그 `v0.1.1` 푸시, `gh release create v0.1.1 build/Wallflow-0.1.1.dmg`(릴리스 노트는 체크리스트 요약)
- [ ] **Step 5:** 메모리(`wallflow-mac-wallpaper-engine.md`)의 "남은 것"과 파티클 교훈을 갱신한다

---

## 사용자 결정 (2026-09-25)

| 항목 | 결정 |
|---|---|
| 실행 방식 | Sonnet 서브에이전트, 작업마다 워크트리, 병합·실물 검증은 메인 세션 |
| 기본 목표 FPS | "30과 60 둘 다 지원" — 설정 창이 이미 15/30/60을 고르게 한다. 확인 중 |
| Developer ID 서명 | 안 함 (자체 서명 유지) |
| `backup/before-scrub` | 지움 (완료) |
| v0.1.1 릴리스 | 함 |

## 게이트 기록 (T4)

- 외부 구현 조사(2026-09-25): catsout/wallpaper-scene-renderer가 문서와 같다(count → 방출률 `newEm.rate *= count`, rate → 하위 시스템 시계 `particleTime = frameTime * m_rate`). Almamu/linux-wallpaperengine은 반대(count → maxCount, rate → 방출률). 문서 + catsout 쪽을 따른다.
- 적대적 검토(2026-09-25, 기술·회귀 두 갈래): 문서 해석에 반대하는 근거 없음. 영향이 큰 씬(Gilded Shore 소용돌이, Universal Reflex 3 별)은 T6에서 눈으로 확인한다.
- 판정: 진행.
