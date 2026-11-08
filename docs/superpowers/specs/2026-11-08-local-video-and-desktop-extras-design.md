# Wallflow: 로컬 영상 + 데스크톱 편의 기능 (dynamicwallpaper 대체)

작성 2026-11-08 · 상태: 설계(승인 전)

## 왜 (intent)

사용자가 상용 앱 **dynamicwallpaper**(`com.zhou.dynamicwallpaper`, 7일 전체 기능
체험 후 구매 유도)를 쓰고 있었다. 그 앱 기능 대부분은 Wallflow가 이미 하거나 더
잘한다(동영상·webm 재생, 멀티 모니터, 로그인 자동 실행, 라이브러리 창=창작마당,
절전/배터리 규칙, 검색). **비어 있는 것**만 Wallflow에 채워 상용 앱을 버리게 하는 것이
목표다. 라이선스 우회가 아니라 **자기 앱으로 대체**다.

dynamicwallpaper의 "예쁜 영상 갤러리"는 그 회사 서버 콘텐츠(iCloud·하루 20개
다운로드 제한 문구가 증거)라 **복제하지 않는다** — Wallflow의 창작마당(Steam
Workshop)이 그 역할이고 영상 수가 훨씬 많다.

## 범위 (goals)

사용자가 고른 네 가지:

1. **로컬 영상 추가·삭제** (핵심) — 내 mp4/mov를 바로 배경화면으로.
2. **유휴 시 전체화면** — 자리 비우면 배경을 화면 꽉 채워 감상 모드로.
3. **바탕화면 아이콘 숨기기** — 메뉴바 토글.
4. **배경별 볼륨 슬라이더** — 지금 전역인 볼륨을 배경화면마다 따로.

## 범위 밖 (non-goals / anti-goals)

- dynamicwallpaper의 영상 **갤러리/서버 콘텐츠 복제·스크래핑** — 하지 않는다.
- dynamicwallpaper 체험판/라이선스 **우회·패치** — 하지 않는다.
- 광고·피드백·멤버십·리뷰 유도 등 그 앱의 장사용 UI — 가져오지 않는다.
- 앱 **재배포/푸시/릴리스** — 이 작업 범위 밖. 로컬 브랜치까지만, 승인 후 병합.
- 실패 조건: 기존 729 테스트 중 하나라도 깨지거나, 창작마당/씬 재생에 회귀가
  생기면 실패. 기존 `WallflowKit`의 경계(AppKit·Metal·AVFoundation 미import)를
  깨면 실패.

## 제약 (constraints)

- **경계:** `WallflowKit`은 AppKit·Metal·AVFoundation을 import하지 않는다.
  → 순수 파일/JSON 로직은 Kit, AVFoundation(썸네일)·AppKit(패널·창)은 App에.
- **라이브러리 삭제 주의**(`wallflow-library-links-caution`): `Library/`는 창작마당
  심볼릭 링크다. 패턴 삭제 금지. 기존 `WorkshopInstaller`는 **실제 폴더면 안 지운다**.
  로컬 영상은 실제 폴더이므로 **전용 마커 기반 삭제 경로**로만 지운다.
- 기존 구조를 유지: 항목은 `LibraryStore.scan()`이 `<root>/<id>/project.json`으로
  발견한다. 새 렌더 경로를 만들지 않는다 — 로컬 영상은 기존 `.video` 경로를 탄다.

## 설계 (how)

### 공통 — 라이브러리 경로
`~/Library/Application Support/Wallflow/Library/<id>/project.json` 이 단위.
로컬 영상은 `id = "local-<uuid>"`, project.json에 `"wallflow_local": true` 마커.

### F1. 로컬 영상 추가·삭제 (핵심)

**추가 — `WallflowKit/LocalVideoImporter.swift` (순수 Foundation, 테스트됨):**
- `importVideo(from source: URL, title: String?, into root: URL) throws -> WallpaperItem`
  1. `root/local-<uuid>/` 생성
  2. 원본을 폴더 안으로 **복사**(`video.<확장자>`). 원본을 옮기거나 지우지 않는다.
  3. `project.json` 작성: `{type:"video", file:"video.<ext>", title:<title 또는 파일명>, wallflow_local:true}`
  4. `WallpaperItem.load(from:)`로 즉시 로드해 반환(기존 로더 재사용 = 검증)
- 썸네일(preview.jpg)은 **App 계층**에서 생성(AVFoundation). 없으면 기존처럼
  preview 없이도 목록에 뜬다 — 선택.

**추가 UI — App 계층:**
- 메뉴바에 `동영상 추가…` 항목(창작마당 둘러보기 근처). `NSOpenPanel`,
  `allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]`, 다중 선택 허용.
- 고르면: (App) 썸네일 먼저 구움 → `LocalVideoImporter.importVideo` 호출 →
  `refreshLibrary()` → 새 항목 `select`.

**삭제 — `LocalVideoImporter.deleteLocal(_ item:) throws`:**
- **안전 가드 전부 통과해야 지움:** (a) 항목 폴더가 심볼릭 링크가 **아님**(실제 폴더),
  (b) `project.json`에 `wallflow_local == true`, (c) 폴더가 Library root 바로 아래.
  하나라도 아니면 `throw`(창작마당 링크·사용자 수동 폴더를 절대 안 건드림).
- UI: 로컬 항목에 한해 삭제. 기존 창작마당 창 삭제 경로는 실제 폴더를 거부하므로
  재사용 불가 → 메뉴바에서 로컬 항목 전용 삭제 제공. **기본 설계:** `동영상 추가…`
  아래 `로컬 영상 관리…`(또는 현재 걸린 항목이 로컬이면 `이 로컬 영상 삭제`).
  확인 대화상자 1회(`정말 삭제?`). *(이 UI 배치는 내 기본값 — 리뷰에서 조정 가능)*

**테스트:** `LocalVideoImporterTests` — ffmpeg로 만든 1초 테스트 mp4
(`ffmpeg -f lavfi -i testsrc=d=1`)를 import → `<root>/local-*/project.json`이
`.video`로 발견됨; `deleteLocal`이 마커 폴더만 지우고 심볼릭 링크/마커 없는 폴더는
`throw`. **앱 번들의 DefaultWellPaper.mp4는 쓰지 않는다**(저작권).

### F2. 유휴 시 전체화면

**기존과의 충돌이 핵심:** Wallflow는 이미 유휴 15분(`PowerPolicy.idlePauseSeconds=900`)에
배경을 **일시정지**한다(절전). "유휴 전체화면"과 정면 충돌(정지 vs 보여주기).

**통합 규칙:**
- 유휴 전체화면 **켜짐**일 때: 유휴 `threshold`(기본 60초) 도달 →
  배경화면 창을 **전체화면 위로 올림**(기존 `WallpaperWindow`의 window level을
  데스크톱→화면 최상위로; 새 렌더러를 만들지 않는다 = lazy). 렌더링은 계속.
- 전체화면이 떠 있는 동안은 **유휴 일시정지를 보류**(정지되면 감상 모드가 얼어붙는다).
- 아무 입력(마우스 이동·키·클릭) → 즉시 창 level을 데스크톱으로 되돌리고 종료.
- 유휴 감지는 **기존 경로 재사용**(`PowerSignals.idleSeconds` / `PowerMonitor`),
  새 이벤트 모니터를 새로 만들지 않는다.
- 멀티 모니터: 각 화면의 배경 창을 동시에 올린다.
- **대안(통합 실패 시):** 별도 오버레이 창을 `.screenSaver` level로 띄워 같은 항목을
  다시 렌더. window-level 승격이 데스크톱 창에서 안정적이지 않으면 이쪽으로.
- 토글: 메뉴바 `유휴 시 전체화면` + 설정 창에 분(threshold) 입력. 기본 **꺼짐**
  (기능은 넣되 사용자가 켜야 작동 — 자리 비웠다고 갑자기 화면 덮으면 놀란다).

**테스트:** 유휴/활동 판정 로직(threshold 비교, 일시정지 보류 플래그)을 순수 함수로
빼서 단위 테스트. 실제 창 level 승격은 실물 확인(`shoot` 스크립트).

### F3. 바탕화면 아이콘 숨기기

- 메뉴바 토글 `바탕화면 아이콘 숨기기`. 상태 `UserDefaults`(`wallflow.hideDesktopIcons`).
- 적용: `defaults write com.apple.finder CreateDesktop -bool <!hidden>` 후
  `killall Finder`(macOS 공개 API 없음 — 표준 방식). App 계층의 작은 헬퍼
  `DesktopIcons.setHidden(_:)`.
- 토글 시에만 적용. 앱 시작/종료 때 강제하지 않는다(사용자 수동 상태 존중).
  `killall Finder` 부작용(파인더 창 재시작)은 알려진 비용 — 토글 설명 툴팁에 적음.

### F4. 배경별 볼륨 슬라이더

지금은 전역: `SceneRenderer.soundVolume`(`UserDefaults wallflow.soundVolume`),
메뉴바 프리셋(0/25/50/75/100%) + 설정 창 슬라이더가 이미 있다.

- **`VolumePreferencesStore`**(App, `CanvasFitPreferencesStore` 패턴 그대로):
  `wallflow.volumeByWallpaper` 사전, `volume(for id) / setVolume(_:for:)`.
  기존 전역 `wallflow.soundVolume`를 기본값(마이그레이션)으로.
- 적용: 배경 선택 시 그 id의 볼륨을 렌더러에 주입(화면맞춤이 `displays.applyCanvasFit`
  로 하는 것과 대칭 → `displays.applyVolume(_:toWallpaperID:)`). SceneRenderer는
  현재 걸린 배경의 볼륨을 쓴다.
- **비디오도 적용:** 지금 전역 볼륨은 씬 오디오에만 적용된다. 로컬 영상(=video)이
  소리를 내므로 `VideoRenderer`의 `AVPlayer.volume`에도 배경별 볼륨을 반영한다.
- UI: 설정 창 슬라이더·메뉴바 "소리 크기"를 **현재 배경 기준**으로(화면 맞춤처럼
  `currentItem` 게이트). 프리셋 유지 + 설정 창은 슬라이더.

**테스트:** `VolumePreferencesStore` per-id 저장/기본값 마이그레이션 단위 테스트.

## 빌더에게 남김 (left to builder)

- 로컬 영상 삭제 UI의 정확한 메뉴 문구·배치(위 기본값에서 조정 가능).
- 유휴 전체화면 기본 threshold(60초 제안)와 설정 창 입력 UI 세부.
- 썸네일 생성 실패 시 폴백(미리보기 없이 진행) — 이미 로더가 허용.
- window-level 승격 vs 오버레이 창 — 실물 확인 후 안정적인 쪽 채택.

## 작업 방식

- 브랜치 `feat/local-video-and-desktop-extras`(생성됨). main 안 건드림, 푸시/릴리스
  안 함.
- TDD(`superpowers:test-driven-development`), 기능별 커밋. 커밋에 Claude 서명·모델
  언급 안 넣음.
- 설계·계획 후 fork 레드팀(적대적 검토) 1회, 구현 후 코드 리뷰 1회.
- `rm -rf .build` 후 전체 빌드로 "경고 0"·테스트 수 확인.
