# M5: 스크립팅과 텍스트

## 목표

보유한 실물 씬의 텍스트 레이어 13개를 그린다. 그중 12개가 `"text": {"script": ...}`라
스크립팅이 먼저다. 완료 조건은 **배경화면에 현재 시각이 실제로 보이는 것**이다.

## 착수 전 검증된 사실 (추측 아님)

실물 씬 4개를 전수 조사해 확인했다.

**스크립트가 붙는 속성은 유한하다:** `text`, `origin`, `visible`, `alpha`, `scale`, `color`.
그 밖은 없다.

**스크립트는 ES 모듈 모양이고 진입점이 하나다.**
```js
'use strict';
export let __workshopId = '3692599672';
export var scriptProperties = createScriptProperties()
    .addCheckbox({ name: 'use24hFormat', label: '...', value: true })
    ...
/** @param {String} value (for property 'text') */
export function update(value) {
    let time = new Date();
    ...
    return value;
}
```
- `update(value)`가 현재 값을 받아 새 값을 돌려준다. 이게 전부다.
- `scriptProperties`는 레이어의 `scriptproperties` JSON이 실제 값을 준다
  (예: `{delimiter: ":", showSeconds: 0, showToD: 1, use24hFormat: 1}`).
  스크립트 안의 `createScriptProperties()...`는 편집기 UI 정의라 값이 아니다.
  **덮어써야 한다** — 안 그러면 빌더 객체가 그대로 남아 `scriptProperties.delimiter`가
  undefined가 되고 시계가 `12undefined34`처럼 나온다.

**폰트는 전부 확보된다.** `ReferenceResolver`의 pkg → assets 2단 해석이 그대로 통한다.
| 씬 | 폰트 | 위치 |
|---|---|---|
| 3714517753 | `fonts/workshop/3692599672/Monocraft.otf` | pkg |
| 3552439823 | `fonts/workshop/3184554659/{Quicksand-Bold,Anurati-Regular}.otf` | pkg |
| 3536506287 | `fonts/{CursedTimerUlil-Aznm,8bitOperatorPlus8-Regular}.ttf` | assets |
| 3616103296 | `fonts/Monofur-PK7og.ttf` | assets |
예외 하나: `systemfont_arial`은 파일이 아니라 시스템 폰트 이름이다. 대체가 필요하다.

**텍스트 레이어의 오브젝트 필드:** `font`, `color`(0~1 실수 3개), `size`(직교 공간 폭·높이),
`text.value`(스크립트가 없을 때의 고정 문자열).

## Global Constraints

- 최소 macOS 14.0, Apple Silicon. 외부 SwiftPM 의존성 0개.
- `WallflowKit`은 Metal·MetalKit·AppKit·AVFoundation을 import하지 않는다.
  **JavaScriptCore와 CoreText는 허용한다** — 둘 다 GPU와 윈도우 서버 없이 동작하고,
  이 계층의 존재 이유가 "헤드리스로 테스트 가능"이기 때문이다. 스크립트와 글자 배치는
  전수 테스트할 수 있어야 한다.
- **스크립트는 신뢰할 수 없는 제3자 코드다.** 창작마당 `.pkg`에서 온다.
  무한 루프·거대 문자열·예외가 배경화면을 죽이면 안 된다. 시간 제한과 길이 제한을 둔다.
- 클린 빌드 경고 0건. M4의 180개 테스트는 계속 통과해야 한다.
- **"테스트 N개 통과"는 완료 근거가 아니다.** 결함을 잡으려는 테스트는 구현을 일부러
  망가뜨려 실패하는 것을 확인한다(M4에서 가짜 테스트가 통과 목록에 섞여 있었다).
- 실물 검증에 환경변수를 반드시 건다. 빼면 실물 테스트가 조용히 건너뛰어진다.
- 커밋 메시지는 한국어, 끝에 트레일러 두 줄.

## Task 1: 스크립트 엔진

**Files:** `Sources/WallflowKit/Scripting/ScriptEngine.swift`,
`Tests/WallflowKitTests/ScriptEngineTests.swift`

`JSContext` 하나에 스크립트를 올리고 `update(value)`를 부른다.

- `export`를 떼어낸다. JavaScriptCore의 `evaluateScript`는 ES 모듈을 모른다.
  `export function f` → `function f`, `export let/var/const x` → `let/var/const x`.
  줄 맨 앞의 `export`만 지운다 — 문자열 안의 "export"를 건드리면 안 된다.
- `createScriptProperties()`를 흉내 낸다. `.addCheckbox()`, `.addSlider()`,
  `.addTextInput()`, `.addCombo()`, `.addColorPicker()` 등 무엇이 와도 자기 자신을
  돌려주는 객체면 된다. 실제 값은 레이어가 준다.
- 레이어의 `scriptproperties`를 `scriptProperties` 전역에 **덮어쓴다.**
- `update`가 없으면 스크립트가 아니라고 보고 값을 그대로 둔다.
- **시간 제한.** `JSContext`에 워치독을 걸어 무한 루프가 배경화면을 멈추지 못하게 한다.
- **길이 제한.** 돌려받은 문자열이 터무니없이 길면 자른다. 글자 하나가 텍스처가 된다.
- 예외는 값을 바꾸지 않고 이유를 남긴다.

## Task 2: 씬 문서의 텍스트와 스크립트

**Files:** `SceneLayer.swift`, `SceneDocument.swift`, 테스트

- `LayerContent`에 `case text(TextLayer)` 추가. `TextLayer`는 `value`, `fontPath`,
  `color`, `script`, `scriptProperties`를 담는다.
- 스크립트가 붙은 `origin`/`visible`/`alpha`/`scale`/`color`도 더 이상 `.unsupported`가
  아니다. 레이어가 스크립트를 함께 나른다.
- 지금 `"origin이 스크립트다"`로 떨구던 자리를 실제 해석으로 바꾼다.

## Task 3: 글자 래스터화

**Files:** `Sources/WallflowKit/Text/TextRasterizer.swift`, 테스트

CoreText로 문자열을 비트맵으로 굽는다. `TextureData.image`로 돌려주면 기존 Metal 경로가
그대로 받는다.

- 폰트는 `ReferenceResolver`가 준 바이트에서 `CTFontManagerCreateFontDescriptorFromData`로 만든다.
  시스템에 설치하지 않는다 — 사용자 시스템을 건드리지 않는다.
- `systemfont_*`는 파일이 아니라 이름이다. 시스템 폰트로 대체한다.
- 크기는 오브젝트의 `size`(직교 공간)에 맞춘다.
- 빈 문자열이면 텍스처를 만들지 않는다(0x0 텍스처는 Metal이 거부한다).

## Task 4: 통합과 실사용 검증

**Files:** `SceneRenderer.swift`, `RealScenesTests.swift`

- 텍스트 레이어마다 스크립트를 주기적으로 돌리고, **값이 바뀔 때만** 다시 굽는다.
  매 프레임 굽으면 상시 구동에서 CPU가 계속 돈다.
- 시계는 초 단위로 바뀐다. 1초에 한 번이면 충분하다.
- 스크립트가 붙은 `visible`/`alpha`/`origin`도 반영한다.

**완료 조건:** `Hiyuki Wutherring Waves`에서 **현재 시각이 화면에 보이고 1분 뒤 값이 바뀐다.**
배경화면 창만 캡처해 확인한다(전체 화면 캡처는 위에 뜬 다른 앱을 잰다).

## M5가 의도적으로 하지 않는 것

- 오디오 반응(`Audio visualizer`)은 M6이다.
- `controlpointattract`는 커서 추종이 필요하고 그것도 M6이다.
- 편집기 UI(`createScriptProperties`가 정의하는 것)는 만들지 않는다. 사용자가 값을
  바꾸는 화면은 이 마일스톤의 목표가 아니다.
