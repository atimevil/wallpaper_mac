# Wallflow — macOS 라이브 배경화면 엔진 설계

작성일: 2026-09-04

## 1. 목표

macOS에서 라이브 배경화면을 재생하는 네이티브 앱을 직접 만든다. 최종적으로
Wallpaper Engine 창작마당 콘텐츠(Video / Web / Scene)를 재생하는 것을 지향한다.

우선순위는 **매일 실사용**이다. 엔진이 완성될 때까지 기다리지 않고, 첫
마일스톤부터 실제로 배경화면을 쓸 수 있어야 한다.

### 성공 기준

- M1 완료 시점에 창작마당 Video/Web 타입 배경화면을 상시 사용할 수 있다.
- M3 완료 시점에 보유 씬 `3714517753`이 완전히 재생된다.
- 배터리·발열에 유의미한 악영향이 없다 (섹션 6).

### 비목표 (YAGNI)

- Wallpaper Engine 씬 포맷의 완전 호환. 상용 앱(Vivid Walls)조차 도달하지
  못한 롱테일이다. 보유 씬 4개가 기준이며, 그 밖은 깨져도 실패가 아니다.
- Mac App Store 배포. 데스크톱 윈도우 레이어링과 `steamcmd` 실행이 샌드박스와
  충돌한다. 개인 사용 목적이므로 서명 없이 로컬 설치한다.
- Intel Mac, macOS 13 이하 지원.
- Application 타입(실행 파일) 배경화면. Windows 바이너리라 원천적으로 불가.

## 2. 조사로 확정된 사실

설계 전 실물 검증을 마쳤다. 대상은 `~/Downloads/431960`의 씬 4개다.

| 확인 항목 | 결과 |
|---|---|
| `.pkg` 컨테이너 | 해결. `PKGV00XX` 헤더 + (이름, 오프셋, 길이) 엔트리 테이블 + 블롭. 파싱 성공 |
| `.tex` 텍스처 | `TEXV/TEXI/TEXB` 헤더 래퍼. 내용물은 JPEG / PNG / LZ4 압축 원시 픽셀 / **MP4** (아래 참조) |
| `scene.json` | 평범한 JSON. 2D 직교 카메라, 레이어 6~11개 |
| 셰이더 | 진짜 GLSL. 단 레거시 문법(`varying`, `texture2D`)이고 `#if COMBO` 전처리기와 JSON 주석 어노테이션을 씀 |
| 표준 셰이더 / `common.h` | **`.pkg`에 없음.** Wallpaper Engine 설치 폴더의 `assets/`에 존재 → 별도 반입 필요 |

### `.tex` 포맷 (M1 이후 실물 전수 해독, 잔여 바이트 0으로 검증)

```
"TEXV0005\0" "TEXI0001\0"
int32 format, flags, texWidth, texHeight, imgWidth, imgHeight, color
"TEXB0003\0" 또는 "TEXB0004\0"
int32 imageCount, freeImageFormat, [0004는 int32 하나 더], mipmapCount
밉맵마다: int32 width, height, isLZ4, decompressedSize, dataSize + 데이터
```

- `freeImageFormat`: `2`=JPEG, `13`=PNG, `-1`=원시 픽셀 또는 비디오
- `flags` 비트 `32`: **비디오 텍스처 — 데이터가 통째로 MP4(H.264) 파일**
- `format`: `0`=RGBA8888, `9`=R8(단일 채널, 마스크용)
- `isLZ4`: LZ4 블록 압축. macOS `Compression` 프레임워크의 `COMPRESSION_LZ4_RAW`로
  풀 수 있어 외부 의존성이 필요 없다.

보유 씬의 가장 큰 텍스처 두 개(각 226MB)가 전부 MP4였다. 즉 두 씬의 배경 레이어는
M1에서 이미 만든 AVFoundation 하드웨어 디코딩 경로를 그대로 쓴다.

### 보유 씬 4개 구성

| 씬 | 크기 | 구성 | 이펙트 | 커스텀 셰이더 |
|---|---|---|---|---|
| 3714517753 | 0.8MB | 이미지1 + 파티클3 + 텍스트2 | 0 | **0** |
| 3552439823 | 13MB | 이미지4 + 파티클3 + 텍스트3 | 4 | 4 |
| 3536506287 | 234MB | 이미지3 + 파티클1 + 텍스트3 + 사운드1 | 3 | 6 |
| 3616103296 | 227MB | 이미지6 + 텍스트5 | 1 | 2 |

4개 중 3개가 커스텀 GLSL과 오디오 반응(`Simple_Audio_Bars`)을 요구한다. 즉
"가볍게 만들어 일단 쓴다"가 되는 씬 서브셋은 `3714517753` 하나뿐이며, 이것이
M3의 목표가 된다.

## 3. 기술 선택

**Swift + AppKit + Metal**, 셰이더는 **glslang → SPIR-V → SPIRV-Cross → MSL**.

- **Metal (Vulkan/MoltenVK 아님).** 만들 것은 2D 스프라이트 컴포지터다. Vulkan은
  같은 결과에 보일러플레이트가 자릿수로 많다. MoltenVK가 내부에서 쓰는 것이
  SPIRV-Cross이므로, 그것을 직접 호출하면 셰이더 이득만 취하고 렌더러는 Metal로
  유지할 수 있다.
- **WebGL2/WKWebView 렌더러 아님.** 셰이더 이식 거리는 짧지만 배터리가 불리하고
  네이티브 파이프라인과 이중 구조가 된다. 단 Web 타입 배경화면 재생에는 WKWebView를
  그대로 쓴다.
- **glslang/SPIRV-Cross는 CLI 바이너리로 번들.** 정적 링크 대신 앱 번들 안의 실행
  파일을 호출한다. Swift/C++ 상호운용을 피한다.
- **셰이더 변환은 임포트 시점.** 배경화면은 사용자가 나중에 받아오므로 빌드 시점
  변환이 불가능하다. 임포트할 때 변환해 `Application Support`에 MSL을 캐시한다.
- **빌드는 SwiftPM + 번들 조립 스크립트.** 이 머신에 전체 Xcode가 없고 Command Line
  Tools만 있다. `.app` 번들은 스크립트로 조립한다.

## 4. 아키텍처

단일 프로세스, `LSUIElement`(메뉴바 전용) 앱. 디스플레이 1개당 배경 윈도우 1개.

```
                    ┌──────────────┐
                    │  MenuBar UI  │
                    └──────┬───────┘
                           │
        ┌──────────────────▼──────────────────┐
        │           AppCoordinator            │
        └──┬───────────┬───────────┬──────────┘
           │           │           │
   ┌───────▼──┐ ┌──────▼─────┐ ┌───▼──────────┐
   │ Library  │ │ PowerPolicy│ │ DisplayMgr   │
   │  Store   │ │            │ │ (NSScreen당) │
   └───┬──────┘ └────────────┘ └───┬──────────┘
       │                            │
  ┌────▼──────┐              ┌──────▼────────┐
  │ SteamCmd  │              │ WallpaperWindow│
  │  Client   │              └──────┬────────┘
  └───────────┘                     │
                     ┌──────────────▼──────────────┐
                     │  WallpaperRenderer (프로토콜) │
                     └──┬───────────┬──────────┬───┘
                        │           │          │
                  ┌─────▼───┐ ┌─────▼───┐ ┌────▼─────┐
                  │ Video   │ │  Web    │ │  Scene   │
                  │ (AVKit) │ │(WKWebView)│ │ (Metal) │
                  └─────────┘ └─────────┘ └────┬─────┘
                                               │
                          ┌────────────────────▼───────┐
                          │ ScenePackage (그래픽 의존 0) │
                          │  PkgReader / TexDecoder /   │
                          │  SceneModel / ShaderCompiler│
                          └─────────────────────────────┘
```

### 모듈 경계

**`ScenePackage`** — `.pkg`를 읽어 순수 데이터 모델로 변환한다. Metal도 AppKit도
import하지 않는다. GPU 없이 단위 테스트가 가능해야 하며, 보유 씬 4개를 픽스처로
쓴다. 리버스 엔지니어링의 불확실성이 전부 이 모듈 안에 갇힌다.

- `PkgReader` — 컨테이너 → 이름별 바이트 슬라이스
- `TexDecoder` — `.tex` → 픽셀 버퍼 또는 BC 블록 + 포맷 서술
- `SceneModel` — `scene.json` → 레이어 트리, 머티리얼, 파티클, 텍스트
- `ShaderCompiler` — GLSL 전처리(COMBO 해석, `varying`→`in/out`, `texture2D`→`texture`) → glslang → SPIRV-Cross → MSL. 결과는 디스크에 캐시

**`WallpaperRenderer`** — 세 렌더러의 공통 인터페이스. 소비자는 어느 구현인지
몰라도 된다.

```swift
protocol WallpaperRenderer: AnyObject {
    func attach(to view: NSView) throws
    func play()
    func pause()
    func setTargetFrameRate(_ fps: Int)
    func detach()
}
```

**`WallpaperWindow`** — 화면 하나를 덮는 `NSWindow`. 윈도우 레벨을 데스크톱 아이콘
아래로 두고(`CGWindowLevelForKey(.desktopIconWindow) - 1`), `canJoinAllSpaces`와
`stationary`를 설정하며, 마우스 이벤트를 통과시킨다. 마우스 패럴랙스는 윈도우
이벤트가 아니라 전역 모니터로 좌표를 받는다.

**`PowerPolicy`** — 목표 프레임레이트와 정지 여부를 계산해 방송하는 단일 지점.
렌더러는 이 결정을 따르기만 한다.

**`LibraryStore` / `SteamCmdClient`** — 배경화면 디렉터리 스캔과 창작마당 다운로드.
`steamcmd`는 사용자 계정으로 로그인해 보유 중인 Wallpaper Engine 창작마당 아이템을
받는다. `steamcmd` 미설치 시 기능을 숨기고, 수동 폴더 임포트는 항상 동작한다.

## 5. 데이터 흐름

1. 사용자가 창작마당 ID를 입력하거나 폴더를 임포트한다.
2. `LibraryStore`가 `project.json`을 읽어 `type`을 판별한다 (video / web / scene).
3. scene이면 `ScenePackage`가 `.pkg`를 열고, 커스텀 셰이더를 MSL로 변환해 캐시한다.
   실패한 셰이더는 통째로 실패시키지 않고 해당 이펙트만 비활성화한 뒤 경고를 남긴다.
4. 사용자가 디스플레이에 배경화면을 배정한다.
5. `DisplayManager`가 타입에 맞는 렌더러를 만들어 그 화면의 `WallpaperWindow`에 붙인다.
6. `PowerPolicy`가 이후 프레임레이트와 재생/정지를 지휘한다.

## 6. 전력 관리

Vivid Walls의 공개된 정책을 그대로 채택한다. 검증된 값이고 다시 발명할 이유가 없다.

| 조건 | 동작 |
|---|---|
| 기본 | 30 fps |
| 배터리 전원 | 15 fps |
| 저전력 모드 / 발열 압력 | 15 fps |
| 데스크톱이 가려짐 (`occlusionState`) | 정지 |
| 앱 전체화면 | 정지 |
| 15분 무입력 | 정지 |

입력 신호는 `NSWindow.occlusionState`, `ProcessInfo.isLowPowerModeEnabled`,
`ProcessInfo.thermalState`, `IOPSCopyPowerSourcesInfo`,
`CGEventSourceSecondsSinceLastEventType`에서 얻는다.

## 7. 오류 처리

배경화면은 항상 켜져 있는 것이라, 실패해도 앱이 죽거나 화면이 검게 남아서는 안 된다.

- 셰이더 변환 실패 → 해당 이펙트만 끄고 나머지 씬을 렌더한다.
- 씬 로드 실패 → `preview.jpg`를 정지 이미지로 대신 표시한다.
- 렌더러 크래시 위험 지점 → 해당 디스플레이만 정지 이미지로 폴백한다.
- 디스플레이 연결/해제 → 윈도우를 재구성하고 배정을 유지한다.
- 모든 실패는 사용자에게 조용히 로그로 남기되, 메뉴바에 경고 표시를 띄운다.

## 8. 테스트 전략

- `ScenePackage`는 GPU 없이 전 계층 단위 테스트. 보유 씬 4개를 픽스처로 쓴다.
  용량이 크므로 저장소에 커밋하지 않고 경로를 환경변수로 주입한다.
- `ShaderCompiler`는 실제 `.frag`를 입력해 MSL 산출과 캐시 히트를 검증한다.
- `PowerPolicy`는 입력 신호를 주입 가능하게 만들어 순수 로직으로 테스트한다.
- 렌더링 정확성은 자동 검증하지 않는다. 눈으로 본다. 대신 렌더러가 던지는
  예외와 폴백 경로는 테스트한다.

## 9. 마일스톤

각 마일스톤은 그 자체로 쓸 수 있는 상태로 끝난다.

**M1 — 셸과 즉시 사용 가능한 배경화면**
데스크톱 윈도우 레이어링, 멀티모니터, 메뉴바 UI, `LibraryStore`, `PowerPolicy`,
`SteamCmdClient`, Video 렌더러, Web 렌더러.
*완료 조건: 창작마당 Video/Web 배경화면을 받아 상시 사용한다.*

**M2 — 씬을 화면에 띄운다**
`PkgReader`, `TexDecoder`, `SceneModel`, Metal 2D 컴포지터, 표준 이미지 셰이더.
*완료 조건: `3714517753`의 배경 이미지 레이어가 올바른 크기와 위치로 뜬다.*

**M3 — 첫 씬 완전 재생**
파티클 시스템(눈·비·벚꽃 프리셋), 텍스트/시계 레이어, 폰트 로딩.
*완료 조건: `3714517753`이 Wallpaper Engine과 육안으로 동등하게 재생된다.*

**M4 — 나머지 씬**
`ShaderCompiler` 파이프라인, FBO 이펙트 체인, 오디오 반응.
*완료 조건: 나머지 씬 3개가 재생된다. 개별 이펙트 누락은 허용한다.*

## 10. 위험 요소와 선행 조건

- **선행 조건: Wallpaper Engine `assets/` 폴더 반입.** M2부터 필수다. 윈도우 PC의
  Wallpaper Engine 설치 폴더에서 USB로 가져와야 한다. M1은 이것 없이 진행 가능하므로
  일정을 막지 않는다.
- **셰이더 롱테일.** 상용 앱도 씬 단위로 계속 패치 중이다. 비목표로 선언했으므로
  범위 문제이지 실패가 아니다.
- **`steamcmd` 로그인.** Steam Guard 때문에 비대화형 실행이 막힐 수 있다. 수동 폴더
  임포트를 항상 유지해 이 기능이 없어도 앱이 성립하게 한다.
- **데스크톱 윈도우 레벨.** macOS 버전에 따라 아이콘/스테이지 매니저와의 z-순서가
  달라질 수 있다. M1 착수 즉시 최소 프로토타입으로 확인한다.
