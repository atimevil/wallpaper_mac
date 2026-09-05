# Wallflow M4 — 파티클

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wallpaper Engine의 파티클 시스템을 구현한다. 완료 시 보유 씬 `3714517753`에 눈과 벚꽃이 실제로 날린다.

**Architecture:** 파티클 프리셋 파싱과 CPU 시뮬레이션은 `WallflowKit`에 둔다. 그래픽 의존성이 없으므로 GPU 없이 전수 테스트할 수 있고, 이 마일스톤에서 틀리기 쉬운 부분이 대부분 거기다. 렌더링은 `WallflowApp`에서 Metal 인스턴싱 빌보드로 한다.

**Tech Stack:** Swift 6 / Metal. 외부 의존성 0개.

**Spec:** `docs/superpowers/specs/2026-09-04-wallflow-design.md`

## Global Constraints

- 최소 지원 macOS 14.0, Apple Silicon. 외부 SwiftPM 의존성 0개.
- `WallflowKit`은 Metal·MetalKit·AppKit·AVFoundation을 import하지 않는다. M1~M3에서 지켜온 경계이고 M4도 유지한다.
- 클린 빌드 경고 0건.
- **파일에서 온 값은 전부 적대적으로 다룬다.** 할당을 결정하게 하지 말고, 무검사 변환이나 맨 산술을 쓰지 말고, 강제 언랩하지 마라. M2에서 이 부류로 Critical 8건, M3에서 5건, M4 Task 2에서 1건이 나왔다.
  - 구체적으로 `Int(someDouble)`을 쓰지 마라. Swift는 포화시키지 않고 **트랩해서 프로세스를 죽인다**.
    측정값: JSON `"maxcount": 1e20`은 지수 표기라 `as? Int`를 통과하지 못하고 `as? Double`로 내려간 뒤
    `Int(1e20)`에서 `Fatal error: Double value cannot be converted to Int`로 SIGTRAP(exit 133).
    버려도 되면 `Int(exactly: d.rounded(.towardZero))`, 클램프할 거면 양 끝으로 포화시켜라.
    NaN은 어떤 비교도 false라 반드시 `isNaN`으로 먼저 쳐내야 한다.
  - 테스트 입력에 평범한 정수만 쓰면 이 경로를 안 밟는다. Task 2의 `2000000000`이 그랬다.
    숫자 필드를 적대적으로 시험할 땐 지수 표기·NaN·음수 거대값을 반드시 넣어라.
- 실물 검증: `WALLFLOW_TEST_SCENES=~/Downloads/431960 WALLFLOW_TEST_ASSETS=~/Library/Application\ Support/Wallflow/Assets swift test`. 미설정 시 건너뛰고, 설정됐는데 경로가 없으면 실패한다.
- M3의 118개 테스트는 계속 통과해야 한다.
- 커밋 메시지는 한국어, 본문 끝에 다음 두 줄:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
  ```

## 착수 전 검증된 사실 (추측 아님)

**지오메트리 셰이더는 필요 없다.** `genericparticle.vert`에 `#if GS_ENABLED` /
`#else // No geometry shaders` 분기가 있고, 후자에서 정점 셰이더가 빌보드 확장을
직접 한다 — `ComputeParticleTangents(rotation, right, up)` 로 축을 만들고
`ComputeParticlePosition(uvs, textureRatio, vec4(pos, size), right, up)` 으로
코너를 계산한다. 코너 좌표는 정점 속성 `a_TexCoordVec4.xy`로 들어온다.
Metal에는 지오메트리 셰이더가 없지만 이 경로가 곧 Metal 경로다.

**`ComputeParticlePosition`의 실제 수식** (`common_particles.h`에서 그대로):
```
position = positionAndSize.xyz
         + positionAndSize.w * right * (uvs.x - 0.5)
         - positionAndSize.w * up * (uvs.y - 0.5) * textureRatio
```
`textureRatio`는 스프라이트 시트가 아닐 때 `g_Texture0Resolution.y / .x`다.

**구현해야 할 타입이 유한하다.** 보유 씬 4개의 파티클 프리셋 7개를 전수 조사한 결과:

| 종류 | 실제로 쓰이는 것 |
|---|---|
| emitter (2) | `sphererandom`, `boxrandom` |
| initializer (8) | `lifetimerandom`, `sizerandom`, `velocityrandom`, `colorrandom`, `rotationrandom`, `angularvelocityrandom`, `turbulentvelocityrandom`, `alpharandom` |
| operator (6) | `movement`, `alphafade`, `angularmovement`, `oscillateposition`, `oscillatealpha`, `controlpointattract` |

**프리셋의 실제 구조** (`particles/presets/snowflat.json`, M4 목표 씬):
```json
{ "material": "materials/presets/snowflat.json", "maxcount": 300, "starttime": 15,
  "emitter": [{ "name": "sphererandom", "rate": 15, "origin": "0 650 0",
                "directions": "1 0.03 0", "distancemin": 10, "distancemax": 1200 }],
  "initializer": [{ "name": "lifetimerandom", "min": 15, "max": 23 },
                  { "name": "sizerandom", "min": 2, "max": 30 },
                  { "name": "velocityrandom", "min": "-10 -50 0", "max": "-37 -90 0" },
                  { "name": "colorrandom", "min": "255 255 255", "max": "95 98 100" }],
  "operator": [{ "name": "movement", "gravity": "0 0 0" },
               { "name": "oscillateposition", "mask": "1 0.5 0", "scalemin": 20, "scalemax": 35,
                 "frequencymin": 0.8, "frequencymax": 1.0, "phasemin": 0, "phasemax": 1 },
               { "name": "alphafade", "fadeintime": 0.1 }] }
```

**참조 사슬** (실물 확인): `object.particle` → `particles/presets/X.json` →
그 안의 `material` → `materials/presets/X.json` → 셰이더 `genericparticle`
+ 텍스처 `particle/chromaticdot` → `assets/materials/particle/chromaticdot.tex`.

**목표 씬의 파티클 텍스처는 스프라이트 시트가 아니다.** `chromaticdot.tex`는
`TEXB0003`, 밉맵 6단, `flags & 4` 없음. 즉 M4는 스프라이트 시트를 구현할 필요가
없고, **마주쳤을 때 크래시하지 않고 건너뛰기만 하면 된다.**

**구형 컨테이너를 먼저 지원해야 한다.** `TEXB0001`(42개)과 `TEXB0002`(29개)가
assets에 있고 `materials/util/white.tex` 같은 기본 텍스처가 여기 속한다.
M3의 디코더는 이 둘을 `unsupportedContainer`로 거부한다. 레이아웃은 스펙 참조.

## File Structure

```
Sources/WallflowKit/ScenePackage/
  TexHeader.swift          (수정) TEXB0001/0002 + TEXS 스프라이트 시트 섹션
  SceneLayer.swift         (수정) LayerContent에 particle 추가
  SceneDocument.swift      (수정) 파티클 레이어 해석
Sources/WallflowKit/Particles/
  ParticlePreset.swift     프리셋 JSON → 타입 있는 모델 (emitter/initializer/operator)
  ParticleSystem.swift     CPU 시뮬레이션. 순수, 결정적, 전수 테스트 대상
  RandomSource.swift       주입 가능한 난수. 테스트에서 결정적으로 만든다
Sources/WallflowApp/
  ParticleRenderer.swift   인스턴싱 빌보드 + genericparticle 대응 MSL
  MetalCompositor.swift    (수정) LayerSource에 particle 추가
  SceneRenderer.swift      (수정) 파티클 레이어 구동
Tests/WallflowKitTests/
  TexHeaderTests.swift     (수정) 구형 컨테이너
  ParticlePresetTests.swift
  ParticleSystemTests.swift
  RealScenesTests.swift    (수정) 실물 프리셋 해석
```

---

### Task 1: 구형 `.tex` 컨테이너와 스프라이트 시트 인식

M3의 디코더는 `TEXB0001`/`TEXB0002`를 거부하고, `flags & 4`인 텍스처를 잔여 바이트가
남은 채로 파싱한다. 파티클 기본 텍스처가 거기 속하므로 M4의 선행 조건이다.

**Files:**
- Modify: `Sources/WallflowKit/ScenePackage/TexHeader.swift`
- Test: `Tests/WallflowKitTests/TexHeaderTests.swift`

**Interfaces:**
- Consumes: `Cursor`, `TexError` (M2)
- Produces:
  - `TexHeader`에 추가: `var spriteSheet: TexSpriteSheet?`
  - `struct TexSpriteSheet: Equatable, Sendable` — `frameCount: Int`, `gridWidth: Int?`, `gridHeight: Int?`
  - `TexHeader.parse`가 `TEXB0001`~`TEXB0004`를 모두 받아들인다

- [ ] **Step 1: 실패하는 테스트 작성**

`Fixtures.swift`에 구형 컨테이너용 빌더를 **별도 함수로** 더한다.
기존 `buildTex`는 건드리지 않는다 — 호출부가 26곳(`TexDecoderTests` 15,
`TexHeaderTests` 11)이라 시그니처를 바꾸면 diff가 커져 리뷰 범위가 흐려진다.

```swift
/// TEXB0001은 freeImageFormat도 LZ4 필드도 없다. 항상 원시 픽셀이다.
func buildTexV1(format: Int32 = 0, flags: Int32 = 0,
                size: (Int32, Int32) = (32, 32),
                mips: [(Int32, Int32, Data)]) -> Data {
    var d = nullTerminated("TEXV0005") + nullTerminated("TEXI0001")
    d += le32(format) + le32(flags)
    d += le32(size.0) + le32(size.1) + le32(size.0) + le32(size.1)
    d += le32(0)
    d += nullTerminated("TEXB0001")
    d += le32(1) + le32(Int32(mips.count))
    for (w, h, payload) in mips {
        d += le32(w) + le32(h) + le32(Int32(payload.count)) + payload
    }
    return d
}

/// TEXB0002는 TEXB0003에서 freeImageFormat만 빠진 형태다.
func buildTexV2(format: Int32 = 0, flags: Int32 = 0,
                size: (Int32, Int32) = (32, 32),
                mips: [(Int32, Int32, Int32, Int32, Data)]) -> Data {
    var d = nullTerminated("TEXV0005") + nullTerminated("TEXI0001")
    d += le32(format) + le32(flags)
    d += le32(size.0) + le32(size.1) + le32(size.0) + le32(size.1)
    d += le32(0)
    d += nullTerminated("TEXB0002")
    d += le32(1) + le32(Int32(mips.count))
    for (w, h, lz4, decomp, payload) in mips {
        d += le32(w) + le32(h) + le32(lz4) + le32(decomp) + le32(Int32(payload.count))
        d += payload
    }
    return d
}

/// flags & 4면 밉맵 뒤에 TEXS 섹션이 붙는다.
func spriteSheetV2(frameCount: Int32) -> Data {
    nullTerminated("TEXS0002") + le32(frameCount) + Data(count: Int(frameCount) * 32)
}

func spriteSheetV3(frameCount: Int32, grid: (Int32, Int32)) -> Data {
    nullTerminated("TEXS0003") + le32(frameCount) + le32(grid.0) + le32(grid.1)
        + Data(count: Int(frameCount) * 32)
}
```

```swift
    /// TEXB0001은 원시 픽셀 전용이고 freeImageFormat 필드가 아예 없다.
    /// 그 필드를 읽으려 들면 이후 전부가 어긋난다.
    func testParsesTEXB0001() throws {
        let pixels = Data(repeating: 0xFF, count: 32 * 32 * 4)
        let tex = buildTexV1(size: (32, 32), mips: [(32, 32, pixels)])
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .rawPixels)
        XCTAssertEqual(header.mipmaps.count, 1)
        XCTAssertEqual(header.mipmaps[0].width, 32)
        XCTAssertFalse(header.mipmaps[0].isLZ4, "0001에는 LZ4 필드가 없다")
        XCTAssertNil(header.spriteSheet)
    }

    func testTEXB0001MipmapChain() throws {
        let mips: [(Int32, Int32, Data)] = [
            (32, 32, Data(repeating: 1, count: 32 * 32 * 4)),
            (16, 16, Data(repeating: 2, count: 16 * 16 * 4)),
        ]
        let header = try TexHeader.parse(buildTexV1(mips: mips))
        XCTAssertEqual(header.mipmaps.map(\.width), [32, 16])
    }

    func testParsesTEXB0002WithLZ4Fields() throws {
        let tex = buildTexV2(size: (16, 16),
                             mips: [(16, 16, 1, 16 * 16 * 4, Data(repeating: 7, count: 40))])
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .rawPixels)
        XCTAssertTrue(header.mipmaps[0].isLZ4)
        XCTAssertEqual(header.mipmaps[0].decompressedSize, 16 * 16 * 4)
        XCTAssertNil(header.spriteSheet)
    }

    /// flags & 4면 밉맵 뒤에 스프라이트 시트가 붙는다. M2는 이것을 몰라서
    /// 잔여 바이트를 남긴 채 파싱했다.
    func testDetectsSpriteSheetSectionV2() throws {
        var tex = buildTexV2(flags: 4, size: (64, 64),
                             mips: [(64, 64, 0, 0, Data(repeating: 3, count: 100))])
        tex += spriteSheetV2(frameCount: 64)
        let sheet = try XCTUnwrap(try TexHeader.parse(tex).spriteSheet)
        XCTAssertEqual(sheet.frameCount, 64)
        XCTAssertNil(sheet.gridWidth, "TEXS0002에는 격자 정보가 없다")
    }

    func testDetectsSpriteSheetSectionV3WithGrid() throws {
        var tex = buildTex(flags: 4, freeImageFormat: -1, size: (128, 128),
                           mips: [(128, 128, 0, 0, Data(repeating: 5, count: 60))])
        tex += spriteSheetV3(frameCount: 16, grid: (128, 128))
        let sheet = try XCTUnwrap(try TexHeader.parse(tex).spriteSheet)
        XCTAssertEqual(sheet.frameCount, 16)
        XCTAssertEqual(sheet.gridWidth, 128)
        XCTAssertEqual(sheet.gridHeight, 128)
    }

    /// flags & 4가 없으면 뒤를 읽으려 하지 않는다.
    func testNoSpriteSheetWhenFlagAbsent() throws {
        let tex = buildTex(flags: 2, mips: [(8, 8, 0, 0, Data(repeating: 0, count: 20))])
        XCTAssertNil(try TexHeader.parse(tex).spriteSheet)
    }

    /// 프레임 수도 파일에서 온 값이다. 검증 전에 믿고 할당하면 죽는다.
    func testAbsurdFrameCountThrowsInsteadOfAllocating() throws {
        var tex = buildTex(flags: 4, mips: [(8, 8, 0, 0, Data(repeating: 0, count: 20))])
        tex += nullTerminated("TEXS0002") + le32(Int32.max)
        XCTAssertThrowsError(try TexHeader.parse(tex)) { error in
            XCTAssertEqual(error as? TexError, .truncated)
        }
    }

    /// 스프라이트 시트를 못 읽는다고 텍스처 전체를 버리지는 않는다.
    /// 잘린 TEXS 섹션은 spriteSheet == nil 로 떨어지고 밉맵은 살아 있어야 한다.
    func testTruncatedSpriteSheetLeavesMipmapsUsable() throws {
        var tex = buildTex(flags: 4, mips: [(8, 8, 0, 0, Data(repeating: 0, count: 20))])
        tex += nullTerminated("TEXS0002")   // frameCount가 없다
        let header = try TexHeader.parse(tex)
        XCTAssertNil(header.spriteSheet)
        XCTAssertEqual(header.mipmaps.count, 1)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter TexHeaderTests`
Expected: FAIL — `unsupportedContainer("TEXB0001")` 등

- [ ] **Step 3: 구현 수정**

`TexHeader`에 스프라이트 시트 타입을 더한다.

```swift
/// flags & 4인 텍스처의 밉맵 뒤에 붙는 프레임 표.
/// M4는 프레임 내용을 쓰지 않는다 — 존재를 알아야 잔여 바이트가 남지 않고,
/// 파티클이 스프라이트 시트를 요구할 때 건너뛸 근거가 된다.
public struct TexSpriteSheet: Equatable, Sendable {
    public let frameCount: Int
    /// TEXS0003에만 있다.
    public let gridWidth: Int?
    public let gridHeight: Int?
}
```

`parse`의 컨테이너 분기를 네 갈래로 넓힌다.

```swift
        let container = try cursor.readCString()
        let hasFreeImageFormat: Bool
        let hasExtraField: Bool
        let hasCompressionFields: Bool
        switch container {
        case "TEXB0001":
            // 가장 오래된 형태. freeImageFormat도 LZ4 필드도 없고 항상 원시 픽셀이다.
            hasFreeImageFormat = false; hasExtraField = false; hasCompressionFields = false
        case "TEXB0002":
            hasFreeImageFormat = false; hasExtraField = false; hasCompressionFields = true
        case "TEXB0003":
            hasFreeImageFormat = true;  hasExtraField = false; hasCompressionFields = true
        case "TEXB0004":
            hasFreeImageFormat = true;  hasExtraField = true;  hasCompressionFields = true
        default:
            throw TexError.unsupportedContainer(container)
        }

        _ = try cursor.readInt32()                      // imageCount
        let freeImageFormat = hasFreeImageFormat ? try cursor.readInt32() : -1
        if hasExtraField { _ = try cursor.readInt32() }
        let mipCount = try cursor.readInt32()
```

밉맵 루프에서 압축 필드 유무를 분기한다.

```swift
        for _ in 0..<mipCount {
            let w = Int(try cursor.readInt32())
            let h = Int(try cursor.readInt32())
            let lz4: Int32
            let decompressed: Int
            if hasCompressionFields {
                lz4 = try cursor.readInt32()
                decompressed = Int(try cursor.readInt32())
            } else {
                lz4 = 0
                decompressed = 0
            }
            let size = Int(try cursor.readInt32())
            ...
        }
```

밉맵을 다 읽은 뒤 스프라이트 시트를 읽는다.

```swift
        /// flags 비트 4가 서면 밉맵 뒤에 TEXS 섹션이 붙는다.
        /// 이 섹션을 못 읽어도 텍스처 자체는 쓸 수 있으므로 실패시키지 않는다 —
        /// 단, 프레임 수는 파일에서 온 값이라 남은 바이트로 상한을 검사한다.
        var spriteSheet: TexSpriteSheet?
        if flags & spriteSheetFlag != 0 {
            spriteSheet = try? parseSpriteSheet(&cursor, in: data)
        }
```

```swift
    static let spriteSheetFlag: Int32 = 4

    /// 프레임 하나는 32바이트다(실물에서 확인, 잔여 0).
    private static let bytesPerFrame = 32

    private static func parseSpriteSheet(
        _ cursor: inout Cursor, in data: Data
    ) throws -> TexSpriteSheet {
        let magic = try cursor.readCString()
        let grid: (Int, Int)?
        switch magic {
        case "TEXS0002": grid = nil
        case "TEXS0003": grid = (0, 0)          // 아래에서 실제 값을 읽는다
        default: throw TexError.unsupportedContainer(magic)
        }
        let frameCount = Int(try cursor.readInt32())
        var width: Int?
        var height: Int?
        if grid != nil {
            width = Int(try cursor.readInt32())
            height = Int(try cursor.readInt32())
        }
        // frameCount는 파일에서 온 값이다. 남은 바이트로 상한이 정해진다.
        let remaining = data.count - cursor.offset
        guard frameCount >= 0, frameCount <= remaining / bytesPerFrame else {
            throw TexError.truncated
        }
        return TexSpriteSheet(frameCount: frameCount, gridWidth: width, gridHeight: height)
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter TexHeaderTests`
Expected: PASS

- [ ] **Step 5: 실물 전수 검증**

`RealScenesTests`에 다음을 더한다. assets의 `.tex` 전부가 파싱되고 잔여가 없어야 한다.
`materials/lut/*.tex`는 `TEXV` 매직이 없는 별개 포맷이므로 제외한다.

```swift
    /// assets의 모든 .tex가 파싱되어야 한다. M2의 이해는 여기서 불완전했다.
    func testAllAssetTexturesParse() throws {
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let root = assets.root
        var checked = 0
        var failures: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "tex" else { continue }
            // LUT는 TEXV 매직이 없는 컬러 그레이딩 원시 데이터다.
            guard !url.path.contains("/lut/") else { continue }
            let data = try Data(contentsOf: url)
            checked += 1
            do { _ = try TexHeader.parse(data) }
            catch { failures.append("\(url.lastPathComponent): \(error)") }
        }
        XCTAssertGreaterThan(checked, 250, "검사한 텍스처가 너무 적다")
        XCTAssertTrue(failures.isEmpty, "파싱 실패 \(failures.count)건: \(failures.prefix(5))")
    }
```

- [ ] **Step 6: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/TexHeader.swift Tests/WallflowKitTests/TexHeaderTests.swift Tests/WallflowKitTests/Fixtures.swift Tests/WallflowKitTests/RealScenesTests.swift
git commit -m "$(cat <<'MSG'
feat: 구형 .tex 컨테이너와 스프라이트 시트 섹션 지원

TEXB0001은 freeImageFormat도 LZ4 필드도 없는 원시 픽셀 전용이고,
TEXB0002는 거기에 LZ4 필드가 붙은 형태다. 파티클 기본 텍스처가 여기 속한다.

flags 비트 4가 서면 밉맵 뒤에 TEXS 프레임 표가 붙는다. M2는 이것을 몰라
잔여 바이트를 남긴 채 파싱했다. 프레임 수도 파일에서 온 값이라 남은
바이트로 상한을 검사한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 2: 파티클 프리셋 모델

프리셋 JSON을 타입 있는 모델로 바꾼다. 그래픽 의존성이 없고, 구현해야 할 타입이
16개로 유한하므로 전수 테스트한다.

**Files:**
- Create: `Sources/WallflowKit/Particles/ParticlePreset.swift`
- Test: `Tests/WallflowKitTests/ParticlePresetTests.swift`

**Interfaces:**
- Consumes: `Vec3`, `Vec2` (M2), `ReferenceResolver` (M3)
- Produces:
  - `enum ParticleEmitter: Equatable, Sendable` — `sphereRandom(rate:origin:directions:distanceMin:distanceMax:)`, `boxRandom(rate:origin:directions:min:max:)`
  - `enum ParticleInitializer: Equatable, Sendable` — 8종
  - `enum ParticleOperator: Equatable, Sendable` — 6종
  - `struct ParticlePreset: Equatable, Sendable` — `maxCount: Int`, `startTime: Double`, `materialPath: String`, `emitters: [ParticleEmitter]`, `initializers: [ParticleInitializer]`, `operators: [ParticleOperator]`, `unsupportedNames: [String]`, `malformedNames: [String]`; `static func parse(_ json: [String: Any]) -> ParticlePreset?`
  - 진단 필드가 둘로 나뉜다: `unsupportedNames`는 switch에 없는 이름, `malformedNames`는
    이름은 아는데 필드가 깨져 버린 엔트리. 하나로 합치면 지원하는 타입을
    "지원하지 않는다"고 잘못 보고해 사용자를 엉뚱한 원인으로 보낸다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class ParticlePresetTests: XCTestCase {
    private func preset(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// 실물 snowflat.json 그대로. M4 목표 씬이 쓰는 프리셋이다.
    func testParsesRealSnowflatPreset() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"materials/presets/snowflat.json","maxcount":300,"starttime":15,
         "emitter":[{"name":"sphererandom","rate":15,"origin":"0 650 0",
                     "directions":"1 0.03 0","distancemin":10,"distancemax":1200}],
         "initializer":[{"name":"lifetimerandom","min":15,"max":23},
                        {"name":"sizerandom","min":2,"max":30},
                        {"name":"velocityrandom","min":"-10 -50 0","max":"-37 -90 0"},
                        {"name":"colorrandom","min":"255 255 255","max":"95 98 100"}],
         "operator":[{"name":"movement","gravity":"0 0 0"},
                     {"name":"alphafade","fadeintime":0.1}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.maxCount, 300)
        XCTAssertEqual(p.startTime, 15)
        XCTAssertEqual(p.materialPath, "materials/presets/snowflat.json")
        XCTAssertEqual(p.emitters.count, 1)
        XCTAssertEqual(p.initializers.count, 4)
        XCTAssertEqual(p.operators.count, 2)

        guard case .sphereRandom(let rate, let origin, _, let dmin, let dmax) = p.emitters[0] else {
            return XCTFail("sphererandom이어야 한다")
        }
        XCTAssertEqual(rate, 15)
        XCTAssertEqual(origin, Vec3(x: 0, y: 650, z: 0))
        XCTAssertEqual(dmin, 10)
        XCTAssertEqual(dmax, 1200)
    }

    func testParsesScalarInitializers() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"lifetimerandom","min":15,"max":23},
                        {"name":"sizerandom","min":2,"max":30},
                        {"name":"alpharandom","min":0.2,"max":0.9},
                        {"name":"angularvelocityrandom","min":"-1 0 0","max":"1 0 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers.count, 4)
        guard case .lifetimeRandom(let lo, let hi) = p.initializers[0] else {
            return XCTFail("lifetimerandom")
        }
        XCTAssertEqual(lo, 15); XCTAssertEqual(hi, 23)
    }

    func testParsesVectorInitializers() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom","min":"-10 -50 0","max":"-37 -90 0"},
                        {"name":"colorrandom","min":"255 255 255","max":"95 98 100"},
                        {"name":"rotationrandom","min":"0 0 0","max":"0 0 6.28"},
                        {"name":"turbulentvelocityrandom","min":"0 0 0","max":"5 5 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers.count, 4)
        guard case .velocityRandom(let lo, let hi) = p.initializers[0] else {
            return XCTFail("velocityrandom")
        }
        XCTAssertEqual(lo, Vec3(x: -10, y: -50, z: 0))
        XCTAssertEqual(hi, Vec3(x: -37, y: -90, z: 0))
    }

    func testParsesAllSixOperators() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"name":"movement","gravity":"0 -9 0","drag":0.1},
                     {"name":"alphafade","fadeintime":0.1,"fadeouttime":0.2},
                     {"name":"angularmovement","gravity":"0 0 0","drag":0.0},
                     {"name":"oscillateposition","mask":"1 0.5 0","scalemin":20,"scalemax":35,
                      "frequencymin":0.8,"frequencymax":1.0,"phasemin":0,"phasemax":1},
                     {"name":"oscillatealpha","frequencymin":0.5,"frequencymax":1.5,
                      "phasemin":0,"phasemax":1},
                     {"name":"controlpointattract","controlpoint":0,"scale":1.0,"radius":100}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators.count, 6, "여섯 종류가 전부 인식되어야 한다")
    }

    func testBoxRandomEmitter() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "emitter":[{"name":"boxrandom","rate":5,"origin":"0 0 0",
                     "directions":"0 -1 0","min":"-100 -10 0","max":"100 10 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .boxRandom = p.emitters[0] else { return XCTFail("boxrandom") }
    }

    /// 모르는 이름은 씬 전체를 버리지 않고 그것만 빠진다.
    func testUnknownNamesAreDroppedNotFatal() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "emitter":[{"name":"neveheardofthis","rate":1}],
         "initializer":[{"name":"sizerandom","min":1,"max":2},
                        {"name":"alsounknown","min":0,"max":1}],
         "operator":[{"name":"unknownop"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.emitters.isEmpty)
        XCTAssertEqual(p.initializers.count, 1, "아는 것만 남는다")
        XCTAssertTrue(p.operators.isEmpty)
        XCTAssertEqual(p.unsupportedNames.sorted(),
                       ["alsounknown", "neveheardofthis", "unknownop"],
                       "무엇이 빠졌는지 보고할 수 있어야 한다")
    }

    /// maxcount는 파일에서 온 값이고 시뮬레이션 버퍼 크기를 정한다.
    func testAbsurdMaxCountIsClamped() throws {
        let json = try XCTUnwrap(preset(#"{"material":"m.json","maxcount":2000000000}"#))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertLessThanOrEqual(p.maxCount, ParticlePreset.maxAllowedCount)
    }

    func testNegativeMaxCountBecomesZero() throws {
        let json = try XCTUnwrap(preset(#"{"material":"m.json","maxcount":-5}"#))
        XCTAssertEqual(try XCTUnwrap(ParticlePreset.parse(json)).maxCount, 0)
    }

    func testMissingMaterialYieldsNil() throws {
        let json = try XCTUnwrap(preset(#"{"maxcount":10}"#))
        XCTAssertNil(ParticlePreset.parse(json), "머티리얼 없이는 그릴 수 없다")
    }

    /// 벡터 문자열이 깨져 있으면 그 항목만 빠진다.
    func testMalformedVectorDropsOnlyThatEntry() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom","min":"garbage","max":"0 0 0"},
                        {"name":"sizerandom","min":1,"max":2}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers.count, 1)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter ParticlePresetTests`
Expected: FAIL — `cannot find 'ParticlePreset' in scope`

- [ ] **Step 3: 구현 작성**

각 케이스의 연관값은 위 테스트가 요구하는 이름과 순서를 그대로 따른다.
파싱 실패는 `nil`을 돌려주고 상위가 그 항목만 버린다 — 프리셋 하나가 깨졌다고
씬 전체를 버리지 않는다는 M2 이후의 원칙과 같다.

```swift
import Foundation

public enum ParticleEmitter: Equatable, Sendable {
    case sphereRandom(rate: Double, origin: Vec3, directions: Vec3,
                      distanceMin: Double, distanceMax: Double)
    case boxRandom(rate: Double, origin: Vec3, directions: Vec3, min: Vec3, max: Vec3)
}

public enum ParticleInitializer: Equatable, Sendable {
    case lifetimeRandom(min: Double, max: Double)
    case sizeRandom(min: Double, max: Double)
    case alphaRandom(min: Double, max: Double)
    case velocityRandom(min: Vec3, max: Vec3)
    case colorRandom(min: Vec3, max: Vec3)
    case rotationRandom(min: Vec3, max: Vec3)
    case angularVelocityRandom(min: Vec3, max: Vec3)
    case turbulentVelocityRandom(min: Vec3, max: Vec3)
}

public enum ParticleOperator: Equatable, Sendable {
    case movement(gravity: Vec3, drag: Double)
    case angularMovement(gravity: Vec3, drag: Double)
    case alphaFade(fadeInTime: Double, fadeOutTime: Double)
    case oscillatePosition(mask: Vec3, scaleMin: Double, scaleMax: Double,
                           frequencyMin: Double, frequencyMax: Double,
                           phaseMin: Double, phaseMax: Double)
    case oscillateAlpha(frequencyMin: Double, frequencyMax: Double,
                        phaseMin: Double, phaseMax: Double)
    case controlPointAttract(controlPoint: Int, scale: Double, radius: Double)
}

public struct ParticlePreset: Equatable, Sendable {
    /// maxcount는 파일에서 온 값이고 시뮬레이션 버퍼 크기를 정한다.
    /// 실물 프리셋의 최대가 300이므로 8192는 충분히 관대하다.
    public static let maxAllowedCount = 8192

    public let maxCount: Int
    public let startTime: Double
    public let materialPath: String
    public let emitters: [ParticleEmitter]
    public let initializers: [ParticleInitializer]
    public let operators: [ParticleOperator]
    /// 인식하지 못한 이름들. 무엇이 빠졌는지 사용자에게 말할 수 있게 남긴다.
    public let unsupportedNames: [String]

    /// public struct의 memberwise 이니셜라이저는 internal이라 테스트 타깃에서
    /// 쓸 수 없다. Task 3의 시뮬레이션 테스트가 프리셋을 직접 만들어야 하므로
    /// 명시적으로 public을 단다.
    public init(
        maxCount: Int, startTime: Double, materialPath: String,
        emitters: [ParticleEmitter], initializers: [ParticleInitializer],
        operators: [ParticleOperator], unsupportedNames: [String]
    ) {
        self.maxCount = maxCount
        self.startTime = startTime
        self.materialPath = materialPath
        self.emitters = emitters
        self.initializers = initializers
        self.operators = operators
        self.unsupportedNames = unsupportedNames
    }
}
```

파싱은 이름별 분기이므로 길지만 단순하다. 세 배열을 각각 `compactMap`으로 훑고,
인식 실패한 이름을 `unsupportedNames`에 모은다. 숫자는 `as? Double ?? (as? Int).map(Double.init)`
양쪽을 받아야 한다 — JSON이 `15`와 `0.1`을 섞어 쓴다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ParticlePresetTests`
Expected: PASS (10개)

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowKit/Particles/ParticlePreset.swift Tests/WallflowKitTests/ParticlePresetTests.swift
git commit -m "$(cat <<'MSG'
feat: 파티클 프리셋 모델 추가

emitter 2종, initializer 8종, operator 6종. 보유 씬의 프리셋 7개를 전수
조사해 확정한 유한한 집합이다.

모르는 이름은 그 항목만 버리고 무엇이 빠졌는지 남긴다. maxcount는 파일에서
온 값이라 시뮬레이션 버퍼 크기를 정하므로 상한을 둔다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 3: CPU 파티클 시뮬레이션

이 마일스톤에서 틀리기 쉬운 부분이 여기 몰려 있고, 그래픽 의존성이 없어 전수 테스트할
수 있다. 난수를 주입 가능하게 만들어 결정적으로 검증한다.

**Files:**
- Create: `Sources/WallflowKit/Particles/RandomSource.swift`
- Create: `Sources/WallflowKit/Particles/ParticleSystem.swift`
- Test: `Tests/WallflowKitTests/ParticleSystemTests.swift`

**Interfaces:**
- Consumes: `ParticlePreset` 및 그 열거형들 (Task 2), `Vec3` (M2)
- Produces:
  - `protocol RandomSource: AnyObject` — `func next() -> Double` (0..<1)
  - `final class SeededRandom: RandomSource` — `init(seed: UInt64)`
  - `struct Particle: Equatable, Sendable` — `position: Vec3`, `velocity: Vec3`, `rotation: Vec3`, `angularVelocity: Vec3`, `color: Vec3`, `size: Double`, `alpha: Double`, `age: Double`, `lifetime: Double`; `var isAlive: Bool`
  - `final class ParticleSystem` — `init(preset: ParticlePreset, random: RandomSource)`, `func update(deltaTime: Double)`, `var particles: [Particle]` (살아 있는 것만), `var aliveCount: Int`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

/// 테스트용 결정적 난수. 값을 순서대로 돌려주고 끝나면 처음으로 돌아간다.
private final class FixedRandom: RandomSource {
    private let values: [Double]
    private var index = 0
    init(_ values: [Double]) { self.values = values }
    func next() -> Double {
        defer { index = (index + 1) % values.count }
        return values[index]
    }
}

final class ParticleSystemTests: XCTestCase {
    private func preset(
        maxCount: Int = 100,
        emitters: [ParticleEmitter] = [],
        initializers: [ParticleInitializer] = [],
        operators: [ParticleOperator] = []
    ) -> ParticlePreset {
        ParticlePreset(maxCount: maxCount, startTime: 0, materialPath: "m.json",
                       emitters: emitters, initializers: initializers,
                       operators: operators, unsupportedNames: [], malformedNames: [])
    }

    func testStartsEmpty() {
        let system = ParticleSystem(preset: preset(), random: FixedRandom([0.5]))
        XCTAssertEqual(system.aliveCount, 0)
    }

    /// rate는 초당 방출 수다. 1초를 돌리면 그만큼 나와야 한다.
    func testEmitterProducesParticlesAtRate() {
        let e = ParticleEmitter.sphereRandom(
            rate: 10, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [e],
                           initializers: [.lifetimeRandom(min: 100, max: 100)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 1.0)
        XCTAssertEqual(system.aliveCount, 10)
    }

    /// 방출은 프레임 크기와 무관하게 누적되어야 한다.
    /// 60분할로 1초를 돌려도 총량이 같아야 한다.
    func testEmissionAccumulatesAcrossSmallSteps() {
        let e = ParticleEmitter.sphereRandom(
            rate: 10, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [e],
                           initializers: [.lifetimeRandom(min: 100, max: 100)]),
            random: FixedRandom([0.5]))
        for _ in 0..<60 { system.update(deltaTime: 1.0 / 60.0) }
        XCTAssertEqual(system.aliveCount, 10, "프레임 분할이 총 방출량을 바꾸면 안 된다")
    }

    func testMaxCountIsNeverExceeded() {
        let e = ParticleEmitter.sphereRandom(
            rate: 10000, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(maxCount: 50, emitters: [e],
                           initializers: [.lifetimeRandom(min: 100, max: 100)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 1.0)
        XCTAssertEqual(system.aliveCount, 50)
    }

    func testParticlesDieAfterLifetime() {
        let e = ParticleEmitter.sphereRandom(
            rate: 1, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [e],
                           initializers: [.lifetimeRandom(min: 2, max: 2)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 1.0)
        XCTAssertEqual(system.aliveCount, 1)
        system.update(deltaTime: 2.5)
        XCTAssertEqual(system.aliveCount, 0, "수명이 지나면 사라져야 한다")
    }

    /// 죽은 자리는 재사용되어야 한다. 안 그러면 maxCount에 도달한 뒤 영원히 멈춘다.
    func testDeadSlotsAreReused() {
        let e = ParticleEmitter.sphereRandom(
            rate: 10, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(maxCount: 10, emitters: [e],
                           initializers: [.lifetimeRandom(min: 0.5, max: 0.5)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 1.0)
        let first = system.aliveCount
        for _ in 0..<10 { system.update(deltaTime: 1.0) }
        XCTAssertGreaterThan(system.aliveCount, 0, "\(first)개 이후 방출이 멈췄다")
    }

    func testMovementAppliesVelocityAndGravity() {
        let e = ParticleEmitter.sphereRandom(
            rate: 1, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [e],
                           initializers: [.lifetimeRandom(min: 100, max: 100),
                                          .velocityRandom(min: Vec3(x: 10, y: 0, z: 0),
                                                          max: Vec3(x: 10, y: 0, z: 0))],
                           operators: [.movement(gravity: Vec3(x: 0, y: -10, z: 0), drag: 0)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 1.0)
        let p = try! XCTUnwrap(system.particles.first)
        XCTAssertEqual(p.position.x, 10, accuracy: 0.5, "속도가 위치에 반영되어야 한다")
        XCTAssertLessThan(p.position.y, 0, "중력이 아래로 당겨야 한다")
    }

    func testAlphaFadeRisesFromZero() {
        let e = ParticleEmitter.sphereRandom(
            rate: 1, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [e],
                           initializers: [.lifetimeRandom(min: 10, max: 10)],
                           operators: [.alphaFade(fadeInTime: 1.0, fadeOutTime: 0)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 0.1)
        let early = try! XCTUnwrap(system.particles.first).alpha
        system.update(deltaTime: 1.0)
        let later = try! XCTUnwrap(system.particles.first).alpha
        XCTAssertLessThan(early, later, "페이드인 중에는 알파가 올라야 한다")
    }

    /// 같은 시드로 같은 입력을 주면 같은 결과가 나와야 한다.
    /// 결정성이 없으면 회귀를 잡을 수 없다.
    func testDeterministicForSameSeed() {
        func run() -> [Vec3] {
            let e = ParticleEmitter.sphereRandom(
                rate: 20, origin: Vec3(x: 0, y: 100, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
                distanceMin: 5, distanceMax: 50)
            let system = ParticleSystem(
                preset: preset(emitters: [e],
                               initializers: [.lifetimeRandom(min: 5, max: 9),
                                              .velocityRandom(min: Vec3(x: -5, y: -5, z: 0),
                                                              max: Vec3(x: 5, y: -1, z: 0))],
                               operators: [.movement(gravity: Vec3(x: 0, y: -1, z: 0), drag: 0)]),
                random: SeededRandom(seed: 12345))
            for _ in 0..<30 { system.update(deltaTime: 1.0 / 30.0) }
            return system.particles.map(\.position)
        }
        XCTAssertEqual(run(), run())
    }

    /// deltaTime이 비정상이어도 죽지 않아야 한다. 절전에서 깨어나면 큰 값이 들어온다.
    func testAbsurdDeltaTimeIsSurvivable() {
        let e = ParticleEmitter.sphereRandom(
            rate: 100, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(maxCount: 100, emitters: [e],
                           initializers: [.lifetimeRandom(min: 1, max: 1)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 100000)
        XCTAssertLessThanOrEqual(system.aliveCount, 100)
        system.update(deltaTime: 0)
        system.update(deltaTime: -1)
        XCTAssertLessThanOrEqual(system.aliveCount, 100, "음수 시간에 죽으면 안 된다")
    }

    func testNaNVelocityDoesNotPropagate() {
        let e = ParticleEmitter.sphereRandom(
            rate: 1, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [e],
                           initializers: [.lifetimeRandom(min: 10, max: 10),
                                          .velocityRandom(min: Vec3(x: .nan, y: 0, z: 0),
                                                          max: Vec3(x: .nan, y: 0, z: 0))]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 1.0)
        for p in system.particles {
            XCTAssertTrue(p.position.x.isFinite, "NaN 위치가 렌더러로 새면 안 된다")
        }
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter ParticleSystemTests`
Expected: FAIL — `cannot find 'ParticleSystem' in scope`

- [ ] **Step 3: `RandomSource` 작성**

```swift
import Foundation

/// 파티클 시뮬레이션이 쓰는 난수. 테스트에서 결정적으로 바꿔 끼우기 위해 주입한다.
public protocol RandomSource: AnyObject {
    /// 0 이상 1 미만.
    func next() -> Double
}

/// SplitMix64. 시드가 같으면 같은 수열을 준다.
public final class SeededRandom: RandomSource {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        // 상위 53비트로 [0, 1) 을 만든다.
        return Double(z >> 11) * (1.0 / 9007199254740992.0)
    }
}
```

- [ ] **Step 4: `ParticleSystem` 작성**

핵심 설계 세 가지를 지킨다.

1. **고정 크기 배열과 슬롯 재사용.** `maxCount`만큼 미리 잡고, 죽은 슬롯을 다시 쓴다.
   매 프레임 할당하면 상시 구동에서 단편화가 쌓인다.
2. **방출 누적.** `emissionCredit += rate * dt` 로 모으고 정수부만 방출한다.
   프레임 크기가 총 방출량을 바꾸면 안 된다.
3. **입력 위생.** `deltaTime`을 `0...0.1`로 죔인다. 절전에서 깨어나면 수천 초가
   들어오는데 그대로 적분하면 파티클이 화면 밖으로 순간이동한다. 비유한값은
   방출 시점에 걸러 렌더러로 새지 않게 한다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter ParticleSystemTests`
Expected: PASS (11개)

- [ ] **Step 6: 커밋**

```bash
git add Sources/WallflowKit/Particles/RandomSource.swift Sources/WallflowKit/Particles/ParticleSystem.swift Tests/WallflowKitTests/ParticleSystemTests.swift
git commit -m "$(cat <<'MSG'
feat: CPU 파티클 시뮬레이션 추가

고정 크기 배열에 죽은 슬롯을 재사용하고, 방출을 누적해 프레임 크기가
총량을 바꾸지 않게 한다.

deltaTime을 죔인다 — 절전에서 깨어나면 수천 초가 들어오고 그대로 적분하면
파티클이 화면 밖으로 순간이동한다. 비유한값은 방출 시점에 걸러 렌더러로
새지 않게 한다.

난수를 주입 가능하게 만들어 같은 시드에서 같은 결과가 나오는 것을 테스트한다.
결정성이 없으면 회귀를 잡을 수 없다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 4: 씬 문서에 파티클 레이어

`object.particle` 참조를 따라가 프리셋과 텍스처를 해석한다.

**Files:**
- Modify: `Sources/WallflowKit/ScenePackage/SceneLayer.swift`
- Modify: `Sources/WallflowKit/ScenePackage/SceneDocument.swift`
- Test: `Tests/WallflowKitTests/SceneDocumentTests.swift`

**Interfaces:**
- Consumes: `ParticlePreset` (Task 2), `ReferenceResolver` (M3)
- Produces: `LayerContent`에 `case particle(preset: ParticlePreset, texturePath: String)` 추가

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
    /// 실물 참조 사슬 그대로:
    /// object.particle → particles/presets/X.json → material → textures[0]
    func testResolvesParticleLayer() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Snow flat", "origin": "50 50 0",
                          "particle": "particles/presets/snowflat.json"}]}
            """,
            extras: [
                "particles/presets/snowflat.json": """
                {"material":"materials/presets/snowflat.json","maxcount":300,
                 "emitter":[{"name":"sphererandom","rate":15,"origin":"0 650 0",
                             "directions":"1 0.03 0","distancemin":10,"distancemax":1200}],
                 "initializer":[{"name":"sizerandom","min":2,"max":30}]}
                """,
                "materials/presets/snowflat.json":
                    #"{"passes":[{"shader":"genericparticle","textures":["particle/chromaticdot"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .particle(let preset, let texturePath) = doc.layers[0].content else {
            return XCTFail("파티클 레이어여야 한다: \(doc.layers[0].content)")
        }
        XCTAssertEqual(preset.maxCount, 300)
        XCTAssertEqual(preset.emitters.count, 1)
        XCTAssertEqual(texturePath, "materials/particle/chromaticdot.tex")
    }

    func testMissingParticlePresetIsUnsupported() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Snow", "origin": "0 0 0",
                      "particle": "particles/presets/gone.json"}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .unsupported(let reason) = doc.layers[0].content else {
            return XCTFail("참조가 끊기면 unsupported여야 한다")
        }
        XCTAssertTrue(reason.contains("gone.json"), "끊긴 경로를 알려야 한다: \(reason)")
    }

    /// 프리셋은 읽혔지만 머티리얼이 없으면 그릴 수 없다.
    func testParticleWithoutTextureIsUnsupported() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Snow", "origin": "0 0 0",
                          "particle": "particles/presets/p.json"}]}
            """,
            extras: ["particles/presets/p.json":
                        #"{"material":"materials/presets/missing.json","maxcount":10}"#]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("머티리얼이 없으면 unsupported여야 한다")
        }
    }

    /// 인식 못 한 emitter/operator가 있어도 레이어는 살아야 한다.
    func testPartiallyUnsupportedPresetStillRenders() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Snow", "origin": "0 0 0",
                          "particle": "particles/presets/p.json"}]}
            """,
            extras: [
                "particles/presets/p.json": """
                {"material":"materials/presets/p.json","maxcount":10,
                 "emitter":[{"name":"sphererandom","rate":1,"origin":"0 0 0",
                             "directions":"0 1 0","distancemin":0,"distancemax":1},
                            {"name":"mysteryemitter"}]}
                """,
                "materials/presets/p.json":
                    #"{"passes":[{"shader":"genericparticle","textures":["particle/dot"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .particle(let preset, _) = doc.layers[0].content else {
            return XCTFail("일부만 인식 못 해도 그려야 한다")
        }
        XCTAssertEqual(preset.emitters.count, 1)
        XCTAssertEqual(preset.unsupportedNames, ["mysteryemitter"])
    }
```

- [ ] **Step 2~4:** 실패 확인 → `makeLayer`의 `object["particle"]` 분기를 해석으로 바꿈 → 통과 확인

**빌드를 초록으로 유지하려면 `SceneRenderer`도 같이 손봐야 한다.**
`SceneRenderer.swift`의 `switch layer.content`는 `default`가 없는 소진형이라,
`.particle`을 더하면 이 태스크에서 컴파일이 실패한다. 다음 한 분기를 더한다 —
Task 6이 실제 처리로 대체한다.

```swift
            case .particle:
                // Task 6에서 시뮬레이션과 렌더러를 붙인다.
                skipped.append("\(layer.name): 파티클 렌더러는 Task 6에서 연결한다")
```

태스크마다 빌드가 통과해야 그 태스크의 리뷰와 회귀 판정이 성립한다.

M2가 `"파티클은 M3에서 지원한다"`로 떨구던 자리를 실제 해석으로 대체한다.
텍스처 이름은 이미지 레이어와 같은 규칙으로 `materials/<name>.tex`가 된다.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/SceneLayer.swift Sources/WallflowKit/ScenePackage/SceneDocument.swift Tests/WallflowKitTests/SceneDocumentTests.swift
git commit -m "$(cat <<'MSG'
feat: 씬 문서가 파티클 레이어를 해석한다

object.particle을 따라가 프리셋과 텍스처를 해석한다.
인식 못 한 emitter/operator가 섞여 있어도 레이어 자체는 살린다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 5: Metal 인스턴싱 빌보드 렌더러

파티클마다 정점 4개를 그린다. 지오메트리 셰이더가 필요 없다는 것은 착수 전에 확인했다.

**Files:**
- Create: `Sources/WallflowApp/ParticleRenderer.swift`
- Modify: `Sources/WallflowApp/SceneShaders.swift`
- Modify: `Sources/WallflowApp/MetalCompositor.swift`

`MetalCompositor`의 `draw(in:)`에 있는 `switch source`도 `default`가 없는
소진형이다. `LayerSource.particles`를 더하면서 **같은 태스크에서** 그 분기를
반드시 함께 추가해야 빌드가 통과한다. 분기는 파티클 렌더러에게 인코딩을
위임하기만 한다.

**Interfaces:**
- Consumes: `Particle`, `ParticleSystem` (Task 3), `QuadUniforms` (M2)
- Produces:
  - `struct ParticleInstance` — `position: SIMD3<Float>`, `size: Float`, `rotation: SIMD3<Float>`, `color: SIMD4<Float>`
  - `final class ParticleRenderer` — `init(device:) throws`, `func update(from system: ParticleSystem, textureRatio: Float)`, `func encode(into encoder: MTLRenderCommandEncoder, projection: SIMD2<Float>, texture: MTLTexture)`
  - `LayerSource`에 `case particles(ParticleRenderer)` 추가

- [ ] **Step 1: MSL 셰이더 작성**

`genericparticle.vert`의 `GS_ENABLED = 0` 경로를 옮긴 것이다. 코너는
`vertex_id`로, 파티클별 값은 인스턴스 버퍼로 받는다.

```metal
    struct ParticleInstance {
        packed_float3 position;
        float size;
        packed_float3 rotation;
        float _pad;
        float4 color;
    };

    struct ParticleUniforms {
        float2 projection;
        float textureRatio;
        float _pad;
    };

    // ComputeParticleTangents를 옮긴 것.
    // 회전 행렬 세 축을 곱해 right/up을 만든다.
    static void particleTangents(float3 rotation, thread float3 &right, thread float3 &up) {
        float3 c = cos(rotation);
        float3 s = sin(rotation);
        float3x3 rz = float3x3(float3(c.z, -s.z, 0), float3(s.z, c.z, 0), float3(0, 0, 1));
        float3x3 rx = float3x3(float3(1, 0, 0), float3(0, c.x, -s.x), float3(0, s.x, c.x));
        float3x3 ry = float3x3(float3(c.y, 0, s.y), float3(0, 1, 0), float3(-s.y, 0, c.y));
        float3x3 m = rz * rx * ry;
        right = m[0];
        up = m[1];
    }

    vertex VertexOut particle_vertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        constant ParticleInstance *instances [[buffer(0)]],
        constant ParticleUniforms &u [[buffer(1)]]
    ) {
        // 삼각형 스트립 코너: (0,0) (1,0) (0,1) (1,1)
        float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
        ParticleInstance p = instances[iid];

        float3 right, up;
        particleTangents(float3(p.rotation), right, up);

        // ComputeParticlePosition 그대로.
        float3 world = float3(p.position)
            + p.size * right * (corner.x - 0.5)
            - p.size * up * (corner.y - 0.5) * u.textureRatio;

        float2 ndc = float2((world.x / u.projection.x) * 2.0 - 1.0,
                            1.0 - (world.y / u.projection.y) * 2.0);
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = corner;
        out.color = p.color;
        return out;
    }

    fragment float4 particle_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return tex.sample(samp, in.uv) * in.color;
    }
```

**`VertexOut` 확장이 기존 셰이더를 건드린다.** 현재 정의는
`{ float4 position [[position]]; float2 uv; }` 뿐이라 `color`를 더하면
`quad_vertex`가 그 필드를 채우지 않아 쓰레기 값이 프래그먼트로 간다.
`quad_vertex`에 `out.color = float4(1.0);`를 더하고, `quad_fragment`와
`solid_fragment`는 그 값을 무시하도록 그대로 둔다 — 두 함수는 `in.color`를
읽지 않으므로 동작이 바뀌지 않는다.

M2·M3의 리뷰가 확인한 `quad_vertex`의 좌표 수식과 `solid_fragment`의 동작은
바꾸지 않는다. 구조체에 필드를 더하고 채우는 것까지만이다.

- [ ] **Step 2: `ParticleRenderer` 작성**

블렌딩이 이미지 레이어와 다르다. 실물 머티리얼이 `"blending": "additive"`이므로
파이프라인을 따로 만든다 — `sourceRGBBlendFactor = .sourceAlpha`,
`destinationRGBBlendFactor = .one`.

인스턴스 버퍼는 `maxCount`만큼 한 번 잡고 매 프레임 덮어쓴다. 매 프레임
`makeBuffer`를 부르면 상시 구동에서 할당이 쌓인다.

- [ ] **Step 3: 빌드 확인**

Run: `rm -rf .build && swift build 2>&1 | grep -c warning:` → `0`

- [ ] **Step 4: 커밋**

---

### Task 6: 통합과 실사용 검증

**Files:**
- Modify: `Sources/WallflowApp/SceneRenderer.swift`
- Modify: `Tests/WallflowKitTests/RealScenesTests.swift`

- [ ] **Step 1: `SceneRenderer` 연결**

`.particle` 레이어마다 `ParticleSystem`과 `ParticleRenderer`를 만들고
`LayerSource.particles`로 넣는다. 파티클이 있으면 연속 렌더로 전환하고
(비디오와 같은 조건), `apply(_:)`에서 시뮬레이션을 멈춘다 — 단 **뷰를 숨기지 않는다.**
M2·M3에서 같은 실수를 두 번 했다.

프레임마다 `system.update(deltaTime:)`를 부르고 `renderer.update(from:)`로 옮긴다.
`deltaTime`은 `CACurrentMediaTime()` 차분으로 구하되 시뮬레이션이 스스로 죔인다.

- [ ] **Step 2: 실물 회귀 테스트**

```swift
    /// M4 목표 씬의 파티클 세 개가 해석되어야 한다.
    /// Rain perspective는 visible:false라 렌더 대상이 아니지만 해석은 된다.
    func testTargetSceneParticlesResolve() throws {
        guard let reader = try scenePkg("3714517753"),
              let assets = try assetsStore() else {
            throw XCTSkip("환경변수 미설정")
        }
        let doc = try SceneDocument.load(from: reader, assets: assets)
        let particles = doc.layers.compactMap { layer -> ParticlePreset? in
            if case .particle(let preset, _) = layer.content { return preset }
            return nil
        }
        XCTAssertEqual(particles.count, 3, "Snow flat, Rain perspective, Sakura")
        XCTAssertTrue(particles.allSatisfy { $0.maxCount > 0 })
        XCTAssertTrue(particles.allSatisfy { !$0.emitters.isEmpty })
    }

    /// 실물 프리셋이 쓰는 타입이 전부 인식되어야 한다.
    /// 남는 것이 있으면 그것이 곧 M4에서 빠뜨린 목록이다.
    func testNoUnsupportedParticleTypesInOwnedScenes() throws {
        guard let root, let assets = try assetsStore() else {
            throw XCTSkip("환경변수 미설정")
        }
        var missing: Set<String> = []
        var broken: Set<String> = []
        for id in try FileManager.default.contentsOfDirectory(atPath: root.path)
            where id.allSatisfy(\.isNumber) {
            guard let reader = try scenePkg(id) else { continue }
            for layer in try SceneDocument.load(from: reader, assets: assets).layers {
                if case .particle(let preset, _) = layer.content {
                    missing.formUnion(preset.unsupportedNames)
                    broken.formUnion(preset.malformedNames)
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "인식 못 한 파티클 타입: \(missing.sorted())")
        // 이름은 아는데 필드 해석에 실패한 것. 실물에서 이게 나오면 파서가 틀린 것이므로
        // 지원 누락보다 급하다.
        XCTAssertTrue(broken.isEmpty, "필드 해석에 실패한 파티클 타입: \(broken.sorted())")
    }
```

- [ ] **Step 3: 실사용 검증**

```bash
./Scripts/bundle.sh
rm -f /tmp/wf-m4.log
./build/Wallflow.app/Contents/MacOS/Wallflow > /dev/null 2> /tmp/wf-m4.log &
```

메뉴에서 **`Hiyuki Wutherring Waves`** 를 고른다.

확인할 것:
1. **눈과 벚꽃이 실제로 날린다.** 정지 이미지가 아니다.
2. 로그에 `배경화면 적용 실패`가 없다.
3. 건너뛴 목록에서 `파티클은 M3에서 지원한다`가 사라졌다. 남는 것은 텍스트 2개뿐이어야 한다.

파티클이 안 보이면 무엇도 약화시키지 말고 BLOCKED로 로그와 함께 보고한다.
가장 흔한 원인 셋: 좌표계가 뒤집혀 화면 밖에 있음, 알파가 0, 블렌딩이 additive가 아님.

- [ ] **Step 4: 커밋**

---

## M4 완료 조건

- `swift test`가 환경변수 유무 양쪽에서 통과. 클린 빌드 경고 0건.
- assets의 `.tex` 전부(LUT 제외)가 파싱된다.
- 보유 씬의 파티클 프리셋에서 인식 못 한 타입이 0개.
- `3714517753`에 **눈과 벚꽃이 실제로 날린다.**

## M4가 의도적으로 하지 않는 것

- 스프라이트 시트 애니메이션. 존재를 인식해 잔여 바이트를 남기지 않되, 프레임을
  넘기지는 않는다. 목표 씬의 파티클 텍스처는 스프라이트 시트가 아니다.
- 텍스트·시계와 스크립팅 — M5.
- 커스텀 셰이더, FBO 이펙트 체인, 오디오 반응 — M6.
- `materials/lut/*.tex` — `TEXV` 매직이 없는 별개 포맷. 이펙트에서 쓰이므로 M6.
- 파티클의 GPU 시뮬레이션. CPU로 충분하다 — 실물 프리셋의 `maxcount` 최대가 300이다.
