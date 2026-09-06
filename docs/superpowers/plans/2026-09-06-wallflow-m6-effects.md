# M6: 이펙트 체인과 셰이더 번역

## 목표

씬이 레이어에 거는 이펙트를 실제로 그린다. 완료 조건은 **`lightshafts`가 걸린
레이어가 실물 미리보기와 같은 빛줄기로 보이는 것**이다.

지금은 이펙트를 통째로 무시하고 원본 텍스처만 그린다. 보유 라이브러리에서
**이펙트가 69곳에 걸려 있다** — 못 그리는 레이어 12개보다 훨씬 큰 숫자다.
즉 M6는 "빠진 레이어를 채우는 일"이 아니라 **거의 모든 씬의 그림을 바로잡는 일**이다.

## 착수 전 검증된 사실 (추측 아님)

실물 이펙트 파일과 assets 셰이더 466개를 전수 조사해 확인했다.

**이펙트는 패스의 나열이다.** `effects/<이름>/effect.json`:
```json
{ "passes": [
    { "material": "materials/effects/blur_downsample4.json",
      "target": "_rt_QuarterCompoBuffer1",
      "bind": [ { "name": "previous", "index": 0 } ] },
    ... ] }
```
- `target`이 없으면 화면(또는 상위 버퍼)에 그린다.
- `bind`의 `previous`는 **직전 결과**, `_rt_*`는 이름 붙은 렌더 타깃이다.
- 재질(`materials/.../x.json`)은 `shader`, `blending`, `depthtest`, `cullmode`를 준다.

**셰이더는 GLSL이다**(HLSL이 아니다). 확장자 `.frag`/`.vert`, `varying`/`attribute`/
`uniform`, `gl_FragColor`/`gl_Position`. WE 호환 계층이 `mul`·`frac`·`saturate`·
`texSample2D`·`CAST3` 같은 HLSL식 이름을 얹어 놓았다.

**구문은 유한하고 좁다.** 466개 파일 전수 집계:
| 전처리기 | include 208, if 1443, endif 1513, else 271, ifdef 65, define 175, elif 22, require 8 |
| 선언 | uniform 2200, varying 1018, attribute 511, const 66, discard 10 |
| 타입 | vec2 2294, float 1897, vec4 1669, vec3 1347, sampler2D 495, mat4 225, mat3 75 |
| 호출 상위 | texSample2D 1026, mul 318, mix 280, step 237, max 195, CAST3 144, CAST2 143, smoothstep 133, dot 130, saturate 116 |

`#if`/`#define`/`#include`은 **Metal의 전처리기가 그대로 처리한다.** 우리가 할 일은
`#include` 해석과 `#require` 제거뿐이다.

**WE 전용 헬퍼는 번역하지 않는다.** `CAST3`, `saturate`, `frac`, `mul`,
`texSample2D`, `rotateVec2`, `greyscale`, `hsv2rgb` 등은 **MSL 프리앰블로 한 번만**
써 두면 된다. 번역기는 선언과 진입점만 다룬다. `shaders/common.h`는 37줄뿐이다.

**유니폼 값의 출처는 셰이더 주석이다.**
```glsl
uniform vec3 g_EyeColor; // {"material":"color", "type":"color", "default":"1 1 1"}
```
씬은 `constantshadervalues`로 그 `material` 키에 값을 준다:
```json
{"combos": {"RAYMODE": 1}, "constantshadervalues": {"rayspeed": 0.39, "noiseamount": 0.33}}
```
즉 **주석이 곧 바인딩 표다.** `combos`는 `#define <이름> <값>`으로 앞에 붙인다.

**우리 라이브러리가 쓰는 이펙트는 30종·69회.** 상위: shimmer 8, waterwaves 7,
waterflow 6, lightshafts 5, waterripple 4, gradientopacity 4, blur 3.
그중 assets에 있는 16종이 쓰는 **고유 셰이더는 22개, 프래그먼트 합계 1,244줄**이다
(중앙값 40줄, 최대 lightshafts 138줄).

## Global Constraints

- 최소 macOS 14.0, Apple Silicon. 외부 SwiftPM 의존성 0개.
  **SPIRV-Cross·MoltenVK를 쓰지 않는다** — 이 제약이 이 저장소의 전제다.
- **번역기는 `WallflowKit`에 둔다.** 문자열 → 문자열이라 Metal 없이 전수 테스트된다.
  Metal 컴파일 검증만 `WallflowApp`에서 한다.
- 셰이더는 **창작마당에서 온 신뢰할 수 없는 텍스트다.** 번역기가 죽거나 무한 루프에
  빠지면 배경화면이 멈춘다. 길이·중첩 깊이·include 깊이에 상한을 둔다.
  컴파일 실패는 그 레이어를 이펙트 없이 그리는 것으로 되돌린다 — 씬 전체를 버리지 않는다.
- 클린 빌드 경고 0건. 기존 308개 테스트는 계속 통과해야 한다.
- **"테스트 N개 통과"는 완료 근거가 아니다.** 구현을 일부러 망가뜨려 실패를 확인한다.
- 커밋 메시지는 한국어, 끝에 트레일러 두 줄.

## Task 1: MSL 프리앰블

**Files:** `Sources/WallflowKit/Shaders/ShaderPrelude.swift`, 테스트

`vec2`→`float2` 같은 타입 별칭과 WE 헬퍼를 MSL로 한 번 써 둔다.
`shaders/common.h`(37줄)의 함수들도 여기 넣는다 — 매번 번역하지 않는다.

주의할 것 둘:
- `mul(v, m)`은 **행벡터 관례**다. MSL에서 `v * m`이지 `m * v`가 아니다. 뒤집으면
  모든 변환이 전치되어 그림이 어긋난다.
- `texSample2D(s, uv)`는 텍스처와 샘플러가 MSL에선 **분리된 인자**다.
  매크로가 둘을 함께 넘기게 만든다.

## Task 2: 번역기

**Files:** `Sources/WallflowKit/Shaders/GLSLTranslator.swift`, 테스트

1. `#include "x.h"`를 해석해 펼친다(깊이 상한, 순환 방지). `#require`는 지운다.
2. `uniform` 선언을 모아 유니폼 구조체와 텍스처/샘플러 인자를 만든다.
   `sampler2D`는 버퍼가 아니라 텍스처 인자다.
3. `varying`을 정점 출력 / 프래그먼트 입력 구조체로 바꾼다.
   `attribute`는 정점 입력 구조체가 된다.
4. `void main()`을 진입점으로 감싼다. `gl_Position`은 정점 출력의 `position`,
   `gl_FragColor`는 프래그먼트 반환값이다.
5. `#if`/`#define`은 **손대지 않는다.** Metal이 처리한다.

**완료 조건:** 실물 셰이더 22개가 전부 Metal에서 컴파일된다. 이건 객관적 기준이라
"번역했다"는 자기 보고와 다르다.

## Task 3: 이펙트 패스 파이프라인

**Files:** `Sources/WallflowApp/EffectChain.swift`, `SceneRenderer.swift`

- 렌더 타깃을 이름으로 잡아 두고(`_rt_*`), 패스마다 바인딩해 그린다.
- `previous`는 직전 패스의 결과다. 첫 패스의 `previous`는 레이어 원본이다.
- 크기 접두사를 지킨다(`_rt_Quarter*`는 1/4 해상도다). 무시하면 흐림이 안 흐려진다.
- **상시 구동 예산을 지킨다.** 패스마다 전체 화면을 다시 그린다 — 파티클 예산에서
  배운 대로, 이펙트가 몇 개까지 붙을 수 있는지 먼저 재고 상한을 둔다.

## Task 4: 씬 연결과 실물 검증

- 레이어의 `effects[].passes[].combos`를 `#define`으로, `constantshadervalues`를
  유니폼으로 넘긴다. 매핑 근거는 셰이더 주석의 `"material"` 키다.
- 컴파일이나 해석이 실패하면 그 이펙트만 건너뛰고 레이어는 그대로 그린다.

**완료 조건:** `lightshafts`가 걸린 레이어를 배경화면 창만 캡처해 미리보기와 비교한다.

## M6가 의도적으로 하지 않는 것

- 오디오 반응(`registerAudioBuffers`)은 시스템 오디오 캡처가 먼저다. 별개 작업이다.
- 원근 투영 씬(스크립트로 제어되는 카메라, `Mat4`)은 여전히 미리보기 폴백이다.
- 편집기 UI(주석의 `label`/`range`가 정의하는 것)는 만들지 않는다.

---

## Task 1·2 결과 (2026-09-06)

**번역기 완료. 실물 셰이더 346개 중 339개(98%)가 Metal에서 컴파일된다.**
`Scripts/verify-shaders.sh`가 이 수치를 다시 잰다.

번역률이 아니라 **컴파일률**로 재기로 한 것이 이 작업의 핵심이었다. 번역은 처음부터
346개 전부 "성공"했지만 실제로 컴파일된 것은 203개였다. 나머지를 하나씩 갈랐다:

| 원인 | 개수 | 답 |
|---|---|---|
| `main` 앞 헬퍼가 유니폼·텍스처를 못 봄 | 53 | 셰이더 전체를 구조체에 담아 전역을 멤버로 |
| `hsv2rgb` 재정의 | 67 | 프리앰블이 담은 `common.h`는 다시 안 펼침 |
| `in`/`out`/`inout` 인자 한정자 | 28 | `thread T&`로 |
| 콤보가 값으로도 쓰임(`ApplyBlending(BLENDMODE,…)`) | 35 | 주석의 기본값을 `#ifndef`로 |
| 배열 varying(`v_TexCoord[13]`) | 19 | 경계에서 성분으로 펼치고 안에서는 배열 |
| `#if` 가지마다 다른 배열 크기 | 22 | 가장 큰 것을 남김 |
| `saturate`·`atan2` 재정의로 모호 | 12 | Metal 내장을 씀 |
| HLSL식 암묵적 절단(샘플링 결과) | 2 | 그 형태만 명시적 스위즐로 |

**가장 큰 설계 판단:** 처음에는 `#define v_TexCoord varyings.v_TexCoord`로 이름만
묶었다. 이 방법은 `main` 앞에 정의된 헬퍼에서 무너진다 — 매크로가 진입점 안에만
있기 때문이다. 셰이더 전체를 구조체에 담자 53개가 한 번에 풀렸다. GLSL의 전역
가시성이 C++ 멤버 가시성으로 그대로 옮겨진 것이다.

**남은 7개**는 전부 HLSL식 암묵적 벡터 절단이 **대입문**에 나오는 형태다
(`vec3 x = <float4 표현식>`). 표현식을 이해하는 변환이 필요해 지금 범위를 넘는다.
우리가 쓰는 이펙트 중에는 `cloudmotion`(2회)과 `waterflow`(6회)가 여기 걸린다.
가장 많이 쓰는 `shimmer`(8회)는 통과한다.

**다음은 Task 3(패스 파이프라인)이다.** 번역기는 됐지만 아직 아무것도 화면에
그리지 않는다 — 렌더 타깃과 바인딩이 없다.

## Task 3 진행 (2026-09-06) — 기본 꺼짐

파이프라인을 만들었지만 **아직 기본으로 켜지 않는다.** `WALLFLOW_EFFECTS=1`로 켠다.
배경화면은 매일 쓰는 것이라, 고치는 중인 기능이 보이는 결함을 남기면 안 된다.

**된 것:** 이펙트 해석(라이브러리 69곳 전부, 95개 패스), 유니폼 배치(Metal의
`sizeof`와 대조해 일치 확인), 셰이더 컴파일, 렌더 타깃, 패스 실행, 레이어 연결,
`g_Time`이 있는 이펙트가 있으면 뷰를 깨우는 것.

**남은 결함:** 패스가 소스 텍스처를 샘플링한 결과에 자홍색 블록이 섞인다.
이분법으로 범위를 좁혔다 — 아래는 전부 **정상임을 확인**했다:
- 체인 배선: 패스를 건너뛰고 원본을 복사하면 화면이 깨끗하다
  (`WALLFLOW_EFFECT_PASSTHROUGH=1`).
- 파이프라인·정점·합성: 샘플링을 상수로 바꾸면 그 색이 레이어 전체에 제대로 나온다
  (`WALLFLOW_EFFECT_GREEN=1`).
- 텍스처 바인딩: 0번 슬롯에 흰색을 묶으면 화면이 흰색이다
  (`WALLFLOW_EFFECT_WHITE=1`).
- 유니폼: 타입이 전부 알려진 것들이라 배치가 완전하다(`WALLFLOW_EFFECT_DEBUG=1`).

즉 **소스 텍스처를 실제로 샘플링할 때만** 깨진다.

### 원인 (찾음)

진단을 더 밀어 알아냈다:
- 좌표를 고정해 샘플링하면 균일한 색이 나온다 → 텍스처는 정상.
- 샘플링 좌표를 색으로 그리면 깨끗한 0~1 그라데이션이다 → 좌표도 정상.
- **샘플의 알파를 회색조로 그리니 거의 전부 1인데, 자홍 자국과 똑같은 자리에만
  알파 0인 텍셀이 점점이 있었다.**

즉 **원본 그림의 완전 투명한 텍셀에 자홍색 RGB가 들어 있다.** 게임 아트에서
"여기는 절대 안 보인다"는 뜻으로 흔히 쓰는 관행이다. 컴포지터는 그 텍셀을 1:1로,
알파 0으로 그리므로 보이지 않았다. 이펙트는 **선형 필터로 좌표를 옮겨 가며**
다시 샘플링하므로, 그 자홍색이 이웃한 불투명 텍셀에 섞여 들어온다.
알파는 거의 1로 남는데 RGB만 오염되니 자홍 자국으로 보인다.

즉 이펙트 코드의 버그가 아니라 **직선 알파(straight alpha) 텍스처를 재샘플링할 때
생기는 고전적인 색 번짐**이다. 쓰는 포맷은 rgba8888·dxt5·r8이고 dxt1은 없다.

**고치는 방법과 그 무게:** 정석은 텍스처를 **미리 곱한 알파(premultiplied)**로
올리고 합성도 그에 맞추는 것이다. 그러면 투명 텍셀의 RGB가 0이 되어 번져도
아무 색을 더하지 않는다. 다만 이건 이펙트만이 아니라 **모든 레이어의 합성 방식을
바꾸는 변경**이라, 기존 26개 씬을 다시 눈으로 확인해야 한다. 다음 작업의 첫 항목이다.

**또 하나 남은 것:** 이펙트가 동작하면 `util/white` 단색 레이어를 건너뛰는 규칙
(`gradientopacity`가 모양을 만드는 그 레이어)을 되돌려야 한다. 지금은 이펙트를
못 걸어서 안 그리는 것이 맞지만, 걸 수 있게 되면 그려야 한다.
