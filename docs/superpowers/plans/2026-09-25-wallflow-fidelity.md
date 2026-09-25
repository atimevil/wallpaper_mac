# Wallflow 충실도 — 비율·이어지는 빛·끊김·GIF 씬 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. **같은 웨이브의 작업은 각자 워크트리에서 병렬로 돈다**(2026-09-25 사용자 지적: 독립 작업을 줄 세우지 말 것). 메인 세션이 통합 브랜치 `fidelity`에 하나씩 병합하고 **병합마다 전체 테스트**를 돌린다(T1·T4·T5가 `SceneRenderer.swift`를 함께 건드린다).

**Goal:** 받아 둔 배경화면 20개 전수 조사(2026-09-25)에서 드러난 충실도 결함을 원인부터 고친다 — 화면 비율, "빛이 안 이어짐"(파티클 로프·트레일), 글자 갱신 끊김, 멈춘 뒤 안 그려지는 씬, GIF 씬, 그리고 앞서 남긴 스크립트 `export`·제어점·비디오 변환.

**Architecture:** 대부분은 기존 경로의 빠진 분기를 메운다. 새 경로는 둘 — (1) 캔버스→화면 맞춤 변환 하나(`CanvasFit`, Kit)를 모든 직교 정점 함수·합성 추출·커서·스크립트 좌표가 같이 쓰고, 맞춤 방식은 배경화면마다 고른다. (2) 파티클 로프 띠를 Kit에서 기하로 만들고 앱이 새 파이프라인으로 그린다.

**Tech Stack:** Swift 6 / SwiftPM, XCTest, Metal, JavaScriptCore, (선택) 외부 `ffmpeg`

**Spec:** `docs/superpowers/specs/2026-09-04-wallflow-design.md`. 근거: [WE Project Resolution](https://docs.wallpaperengine.io/en/scene/performance/resolution.html) — "Wallpaper Engine will cut off the sides of your wallpaper once you apply it to your desktop to make it fit to your screen." WE 자체 셰이더 `~/Library/Application Support/Wallflow/Assets/shaders/{genericparticle,genericropeparticle}.*`, `common_particles.h`.

## 조사 결과 (원인 확정)

| # | 증상 | 원인 | 근거 |
|---|---|---|---|
| A | 모든 직교 씬이 화면 비율대로 **늘어남**(이 맥 1.547:1 — 16:9는 세로 15%, 21:9는 54%) | 직교 정점 함수가 `world/projection`을 축마다 따로 NDC로 보냄. 커서·합성 추출도 같은 가정. `general.zoom`(1개 씬 1.08)도 안 씀 | `SceneShaders.swift:57-79`(quad), `particle_vertex`(:349-399), `puppet_vertex`, `composition_extract_fragment`(:300), `MetalCompositor.swift:335-381`(`extractComposition` scaleX/scaleY), `SceneRenderer.swift:373-381`(커서). 꽃 씬 미리보기 대조에서 늘이기 가설이 맞음 |
| B | **빛이 안 이어짐** — PS2 오브 꼬리, 소용돌이 궤적, 빗줄기가 점으로만 | 프리셋 `renderer`(`spritetrail`·`rope`·`ropetrail`)를 무시하고 전부 스프라이트로 그림 | `ParticlePreset.parse`는 `renderer` 무시, `ParticleRenderer.encode`는 항상 사각형 |
| C | starlight jet(3793500489) **검은 화면** | "계속 그려야 하나" 판정이 붙일 때(효과·스크립트·퍼펫 포함)와 `.playing` 재개 때(비디오·파티클·글자만)가 다름 | `SceneRenderer.swift:1621-1628` vs `:1649-1658` |
| D | Pixels·Project Zomboid **계속 끊김**(매초 56~211ms) | 글자가 바뀔 때마다 메인 스레드에서 256pt로 굽고 `MTKTextureLoader`로 텍스처를 새로 만듦 | `sample`: `makeTexture(from:)` 215샘플, CoreText 88샘플 / 4초 |
| E | Loading...(3795096226) **바둑판** | 이미지가 60프레임 스프라이트 시트(10×6, 프레임당 0.1초)인데 이미지 경로가 시트를 무시. `TexHeader`는 프레임 표(프레임당 32바이트)를 건너뜀 | `SceneDocument.swift:958-1014`, `TexHeader.swift:255-283` |
| F | DELTARUNE(3793923399) 파티클 **빠짐** | 머티리얼 `"textures": [null]` — WE 기본값은 `util/white`(`genericparticle.frag`의 `g_Texture0` 주석). 파티클 경로만 처리 없음 | `SceneDocument.swift:856-858`, `Assets/materials/util/white.tex` 있음 |
| G | 스크립트 한 줄에 `문장; export function …`이면 **조용히 등록 실패** | `stripModuleSyntax`가 줄 맨 앞 `export`만 지움 | `ScriptEngine.swift:199-215` |
| H | 제어점 덮어쓰기·이미터 제어점 **미지원**(앞으로 받을 씬 대비) | `ParticleOverride`에 `controlpointN` 없음, 이미터 `controlpoint` 안 읽음, 플래그 2·16을 모르는 것으로 취급 | 제어점 조사(플래그 1=커서, 2=월드, 4=부모 복사, 16=편집기 전용) |
| I | webm/mkv 비디오 **재생 불가**(코퍼스엔 없음, 사용자 요청) | `WallpaperItem`이 목록을 만들 때 이미 `.unsupported`로 분류 → 재생기까지 안 감 | `WallpaperItem.swift:152-153`, `DisplayManager.swift:122-126` |
| J | One Piece 오른쪽 끝 번짐 | 물 왜곡 효과가 [0,1] 밖 UV를 clampToEdge로 읽음 — A(채우기)면 21:9 씬 가장자리는 화면 밖으로 잘림. A 뒤에 다시 본다 | edge 조사 |

**다루지 않는 것:** 시작 직후 한 번 멈춤(재측정 47ms, 셰이더 캐시가 비었을 때만), DELTARUNE 초반 검은 화면(재현 안 됨).

## 사용자 결정 (2026-09-25)

- 비율: **WE처럼 잘라 채우기가 기본**, 메뉴바 "화면 맞춤"에서 **배경화면마다** 채우기 / 전체 보기(여백) / 늘이기를 고른다. (근거: 사용자 배경화면 3552439823은 채우기면 왼쪽 날짜가 잘리고, 세로형 3794448602는 위아래 26%가 잘려 얼굴이 끊긴다 — 배경화면마다 골라야 한다.)

## Global Constraints

- `WallflowKit`은 AppKit·Metal·AVFoundation을 import하지 않는다. 계산(맞춤 변환, 로프 기하, 트레일 탄젠트, 프레임 선택, ffmpeg 계획)은 **Kit의 순수 함수**로 두고 테스트한다.
- 실물 테스트: `WALLFLOW_TEST_SCENES="$HOME/Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960" WALLFLOW_TEST_ASSETS="$HOME/Library/Application Support/Wallflow/Assets" swift test` — 기준선 590 테스트, 실패 0, 건너뜀 6, **새로 빌드한 경고 0**(`rm -rf .build` 후 확인).
- Swift 6 엄격 동시성: 스레드를 건너가는 값은 `Sendable`(예: `CGImage` 대신 `Data` 픽셀 버퍼).
- 커밋 메시지는 한국어 "…한다" 문장, `Co-Authored-By`·`Claude-Session` 줄 **금지**. 주석은 한국어로 "왜".
- 서브에이전트는 앱을 띄우거나 화면을 찍지 않는다(T12만). 각자 `.worktrees/<task>`에서 `fidelity` 브랜치로부터 일한다.
- 기존 테스트가 새 동작 때문에 깨지면 무엇을 지키려던 테스트인지 먼저 읽고, 여전히 맞으면 코드를, 옛 해석이면 테스트를 고친 뒤 이유를 커밋에 쓴다.

## Review Focus

1. **맞춤 변환이 한 곳이라도 빠지면 레이어끼리 어긋난다** — 이미지·파티클·글자·합성 추출·퍼펫·커서·스크립트의 화면/캔버스 좌표가 모두 `CanvasFit`을 쓴다. 원근 씬은 그대로.
2. **로프 순서** — 슬롯 재사용 때문에 생성 순서가 아니다. `age` 내림차순 + **생성 순번**(새 필드)으로 잇는다(같은 프레임에 여럿 생기면 age가 같다). **자식 인스턴스·레이어끼리 합치지 않는다**(`renderableGroups`의 합치기를 쓰지 않는다).
3. **글자 갱신** — 백그라운드에서 굽고, 텍스처는 **매번 새로 만들어 픽셀만 올린다**(재사용하면 GPU가 읽는 중에 덮을 수 있다 — 진행 중 추적이 없다). 글자에 걸린 이펙트(`blurprecise`)가 새 텍스처를 읽는지 확인.
4. **스프라이트 시트 시간** — 프레임 길이(초)를 누적해 고르고, 전력 정책으로 멈췄다 재개할 때 튀지 않게 경과 시간을 쓴다.
5. **ffmpeg가 없거나 변환 실패** — 지금처럼 "열 수 없음" 사유를 보이고 반쪽 캐시를 남기지 않는다. 캐시에 상한, 변환은 낮은 우선순위.

---

## 웨이브 1 (병렬 6개 → 순서대로 병합, 병합마다 전체 테스트)

### Task 1: 계속 그리기 판정 하나로 (C)
**Files:** `Sources/WallflowApp/SceneRenderer.swift`
- [ ] `needsContinuousDrawing`(비디오 ∨ 파티클 ∨ 글자 ∨ 움직이는 효과 ∨ 스크립트 호스트 ∨ 퍼펫)을 한 속성으로 만들어 붙일 때와 `apply(.playing)` 둘 다 쓴다.
- [ ] 판정을 Kit 순수 함수(각 존재 여부 → 계속 그리기 여부)로 뽑아 테스트한다. 특히 "효과만 움직이는 씬"이 true.
- [ ] Commit: `멈췄다 재개할 때도 붙일 때와 같은 기준으로 계속 그릴지 정한다`

### Task 2: 파티클 머티리얼의 null 텍스처 (F)
**Files:** `Sources/WallflowKit/ScenePackage/SceneDocument.swift`(`resolveParticleContent`), 테스트
- [ ] `textures.first`가 `null`이면 `util/white`를 쓴다 — Kit 상수로 두고 `genericparticle.frag`의 `g_Texture0` 기본값 주석을 근거로 적는다(파티클은 GLSLTranslator를 거치지 않는다).
- [ ] 테스트: `[null]` 머티리얼 파티클이 `.particle`로 해석됨. 실물 DELTARUNE이 있으면 그 레이어가 unsupported가 아님.
- [ ] Commit: `파티클 머티리얼의 빈 텍스처를 셰이더 기본값(흰색)으로 채운다`

### Task 3: 한 줄 중간의 export (G)
**Files:** `Sources/WallflowKit/Scripting/ScriptEngine.swift`(`stripModuleSyntax`), `ScriptEngineTests.swift`
- [ ] 새 규칙: `;` 또는 `}` 뒤 같은 줄의 `export` + (`function`|`class`|`let`|`var`|`const`|`default`)에서 `export `를 지운다. 문자열 안의 드문 오탐은 받아들이고 주석에 적는다(지금 코드에 문자열 추적 규칙은 없다).
- [ ] 테스트: 한 줄 스크립트 `let done = false; export function update(v) { return v; }`가 등록되고 `update`가 불린다. 기존 형태 그대로.
- [ ] Commit: `한 줄 중간의 export도 모듈 문법으로 지운다`

### Task 4: 글자 갱신을 메인 스레드 밖으로 (D)
**Files:** `Sources/WallflowKit/Text/TextRasterizer.swift`(픽셀 버퍼 API — **필수**), `Sources/WallflowApp/SceneRenderer.swift`(`rasterize`, 글자 상태), `Sources/WallflowApp/MetalCompositor.swift`(`makeTexture`)
- [ ] Kit: `TextRasterizer`가 `Sendable` 픽셀 버퍼(`Data` BGRA8 premultiplied, width, height, bytesPerRow)를 돌려주는 API. 기존 `CGImage` API는 부르는 곳이 남으면 유지.
- [ ] App: 굽기를 직렬 백그라운드 큐로 옮기고 결과만 메인에서 반영한다. 같은 레이어의 이전 요청은 최신만 남긴다. 텍스처는 **매 갱신 새로** 만들고 `replace(region:…)`로 픽셀만 올린다(`MTKTextureLoader` 제거). 글자에 걸린 이펙트가 새 텍스처를 읽는지 확인.
- [ ] 테스트(Kit): 픽셀 버퍼 크기·바이트 수·premultiply(알파 0이면 RGB 0). 
- [ ] 검증 기준(T12): Pixels `WALLFLOW_FRAME_DEBUG=1` 최대 프레임 < 40ms.
- [ ] Commit: `글자는 백그라운드에서 굽고 텍스처 로더 없이 픽셀만 올린다`

### Task 5: 스프라이트 시트 이미지 레이어 (E)
**Files:** `Sources/WallflowKit/ScenePackage/TexHeader.swift`(프레임 표), `Sources/WallflowKit/ScenePackage/SceneDocument.swift`(이미지에 시트 정보), `Sources/WallflowApp/SceneRenderer.swift`·`SceneShaders.swift`(프레임 UV 사각형)
- [ ] `TEXS` 프레임 표(프레임당 32바이트, 조사에서 `[?, 길이(초), x, y, w, ?, ?, h]`로 보임)를 실물 여러 개로 확정해 `[Frame(rect, duration)]`으로. 모르는 필드는 주석에.
- [ ] 이미지 레이어의 텍스처가 시트면 경과 시간으로 프레임을 골라 UV 사각형만 바꿔 그린다. 파티클 쪽 `ParticleSpriteSheet`를 재사용할 수 있으면 쓴다. (T6이 `quad_vertex`의 NDC 줄을 바꾸므로 여기선 UV 쪽만 건드린다.)
- [ ] 테스트: 프레임 선택 순수 함수(누적 길이, 반복, 0길이 방어), 실물 Loading... 헤더가 60프레임·320×200 칸.
- [ ] Commit: `스프라이트 시트 이미지를 한 장씩 넘겨 그린다`

### Task 11: webm·mkv는 ffmpeg가 있으면 변환해 재생 (I)
**Files:** `Sources/WallflowKit/Workshop/WallpaperItem.swift`(분류), `Sources/WallflowApp/DisplayManager.swift`(경로), `Sources/WallflowApp/VideoTexture.swift`/`VideoRenderer.swift`, Kit에 변환 계획 순수 함수(새 파일)
- [ ] 컨테이너만 문제인 비디오는 `.unsupported`로 버리지 말고 비디오로 두되 "변환 필요"를 표시한다. 붙일 때 `ffmpeg`(`/opt/homebrew/bin`, `/usr/local/bin`, `PATH`)가 있으면 백그라운드(낮은 QoS)에서 H.264 MP4로 변환해 `~/Library/Caches/Wallflow/video/<원본 경로·크기·수정시각 해시>.mp4`에 두고 재생한다. 임시 파일에 쓰고 끝나면 이름을 바꾼다. 캐시 상한 2GB(오래된 것부터 지움). 없음·실패·변환 중은 한국어 사유 표시.
- [ ] 테스트(Kit): 캐시 키, ffmpeg 인자, 위치 탐색, 분류(컨테이너만 문제면 변환 대상).
- [ ] Commit: `열 수 없는 비디오를 ffmpeg가 있으면 MP4로 바꿔 재생한다`

## 웨이브 2 (웨이브 1 병합 후, 병렬 2개)

### Task 6: 화면 맞춤 — 채우기 기본, 배경화면마다 선택 (A)
**Files:** Kit `CanvasFit`(새 파일), `Sources/WallflowApp/MetalCompositor.swift`(투영 → 보이는 사각형; `extractComposition` :335-381), `Sources/WallflowApp/SceneShaders.swift`(`quad_vertex`, `particle_vertex`의 NDC 줄, `puppet_vertex`, `composition_extract_fragment` :300), `Sources/WallflowApp/ParticleRenderer.swift`(유니폼), `Sources/WallflowApp/SceneRenderer.swift`(`sceneCursorPosition`, 스크립트 화면·캔버스 좌표, 시차, 여백 색), `Sources/WallflowApp/MenuBarController.swift`·`AppCoordinator.swift`(메뉴 "화면 맞춤"), Kit 설정 저장(배경화면 id → 방식)
- [ ] `CanvasFit.visibleRect(canvas:screen:mode:zoom:)`: 채우기 `s = max(W비, H비)`, 전체 보기 `s = min(...)`, 늘이기는 축마다(지금 동작). `general.zoom`은 배율에 곱한다(1.08이면 8% 더 확대). 가운데 정렬. NDC = `(world − 보이는원점) / 보이는크기 × 2 − 1`(y 뒤집기 규칙 유지).
- [ ] 모든 직교 소비처가 같은 유니폼을 쓰고, 커서→씬 좌표는 같은 변환의 역을 쓴다. 전체 보기의 여백은 씬 `clearcolor`로 채운다. 원근 씬은 그대로.
- [ ] 메뉴바 "화면 맞춤": 채우기(기본)/전체 보기/늘이기, 지금 배경화면에만 저장·적용(재시작 없이).
- [ ] 테스트(Kit): 16:9→1.547(좌우 잘림), 21:9, 세로형 810×1080(위아래 잘림), 4:3 화면, 같은 비율, zoom 1.08, 세 방식, 역변환 왕복, 설정 저장·기본값.
- [ ] Commit: `직교 씬을 늘이지 않고 채우도록 맞추고, 배경화면마다 맞춤 방식을 고른다`

### Task 9: 제어점 덮어쓰기·이미터 제어점 (H)
**Files:** `Sources/WallflowKit/Particles/ParticlePreset.swift`(`ParticleControlPoint` 플래그 2·16, `ParticleOverride` 제어점, 이미터 `controlpoint`), `Sources/WallflowKit/Particles/ParticleSystem.swift`(`controlPointPosition`, 이미터가 제어점에서 뿌리기), `Sources/WallflowKit/ScenePackage/SceneDocument.swift`(월드 덮어쓰기용 원점·배율)
- [ ] 덮어쓰기 `controlpointN`(Vec3 문자열)은 프리셋 `offset`을 같은 로컬 좌표에서 대체. 월드 플래그(2)면 `(값 − 레이어 원점)/배율`. 16은 무시(편집기 전용). 4(부모 복사)는 지금처럼 미지원 보고.
- [ ] 이미터 `controlpoint`가 있으면 그 제어점 위치에서 뿌린다. 스크립트 `layer.instance.controlpointN`도 `ParticleOverride.apply`로.
- [ ] 테스트: 해석, 월드 변환, 이미터 위치, 스크립트 값. WE 자체 `previewdrippingwater`가 있으면 실물 테스트.
- [ ] Commit: `파티클 제어점 덮어쓰기와 이미터 제어점을 읽는다`

## 웨이브 3 (T6 병합 후)

### Task 7: 스프라이트 트레일 (B 일부)
**Files:** `Sources/WallflowKit/Particles/ParticlePreset.swift`(`renderer` 해석: `enum ParticleRenderKind { sprite, spriteTrail(length, maxLength, minLength), rope(subdivision, uvScale, uvScrolling), ropeTrail(subdivision, length, segments, fadeAlpha, uvScale, uvScrolling) }`, 기본 sprite), `Sources/WallflowApp/ParticleRenderer.swift`·`SceneShaders.swift`(`particle_vertex`, T6 이후 버전 위에)
- [ ] 인스턴스에 속도 추가: 48 → 64바이트(float3 속도 + 패딩 float 하나), 스트라이드 상수와 MSL 구조체를 함께.
- [ ] 탄젠트(`common_particles.h` `ComputeParticleTrailTangents`): 직교 시선 (0,0,1), `right = normalize(cross(eye, v))`, `up = normalize(v) × clamp(|v| × length, minLength, maxLength)`, 위치 = `pos + size·right·(u−.5) − size·up·(v−.5)·textureRatio`. 속도 0이면 스프라이트처럼.
- [ ] 테스트(Kit): 탄젠트 순수 함수(방향, clamp, 0 속도), `renderer` 해석(실물 rain 프리셋 범위).
- [ ] Commit: `스프라이트 트레일 파티클을 속도 방향으로 늘여 그린다`

### Task 10: 가장자리 번짐 재평가 (J)
- [ ] T6 병합 뒤 One Piece·Gilded Shore를 채우기로 찍어 오른쪽 띠가 남는지 본다. 전체 보기/늘이기에서만 남으면, 공유 샘플링 지점에서 [0,1] 밖 UV를 부드럽게 줄이는 수정을 별도 커밋으로. 안 남으면 기록만.

## 웨이브 4 (T7 병합 후)

### Task 8: 로프·로프 트레일 (B 나머지)
**Files:** Kit `RopeGeometry`(새 파일), `Sources/WallflowKit/Particles/ParticleSystem.swift`(입자에 생성 순번, **자식 인스턴스별** 로프 입력), `Sources/WallflowApp/ParticleRenderer.swift`(로프 파이프라인·버퍼), `SceneShaders.swift`(로프 정점·조각), `SceneRenderer.swift`(렌더러 선택)
- [ ] 한 시스템(자식 인스턴스별, 레이어끼리 섞지 않음)의 살아 있는 입자를 `age` 내림차순, 같으면 생성 순번 오름차순으로 잇는다. 기하: WE `genericropeparticle.vert/.geom`처럼 Catmull-Rom→베지어 제어점(장력 0.15)과 `subdivision`개 보간점(보간 매개변수에 smoothstep). 폭 = 입자 크기, 법선 = 선분 방향의 수직(직교 2D). UV `V = 1 − i/(n−1)`(꼬리 1, 머리 0), `uvscale` 반복.
- [ ] 로프 트레일: 같은 기하, `fadealpha`면 양 끝 알파를 사인 곡선으로 줄인다(`.vert`의 `trailFadeIn/Out`, `TRAILSCROLLALPHA` 분기). `segments`는 UV 정규화 값.
- [ ] 이미터 `flags` 비트 2(`one_per_frame`)를 읽어 한 프레임에 하나만 뿌린다.
- [ ] 테스트(Kit): 정점 수((n−1)(s+1)+1 점), UV 끝값, 순서(age·순번, 같은 프레임 여러 개), 입자 0·1개면 안 그림, fadealpha 양 끝 0, 인스턴스끼리 안 섞임.
- [ ] Commit: `로프와 로프 트레일 파티클을 이어진 띠로 그린다`

## Task 12: 실물 검증 (메인 세션)
- [ ] 전체 테스트, 새로 빌드 경고 0.
- [ ] 20개 전수 재촬영(조사 스크립트)과 이전 촬영 대조: 채우기 비율(꽃 씬 대조가 비율 유지 쪽으로 뒤집힘), 메뉴 "화면 맞춤" 세 방식, starlight jet이 보임, Loading...이 한 장씩 움직임, DELTARUNE 파티클, PS2 오브 꼬리·소용돌이 궤적·빗줄기, Pixels 최대 프레임 < 40ms, 테스트용 webm 재생(ffmpeg).
- [ ] 사용자 배경화면(Phrolova 4K) 맞춤 방식과 원래 선택 복원.
- [ ] 결과를 보고 v0.1.2 릴리스 여부를 사용자에게 묻는다.
