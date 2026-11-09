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

**추가 — 실패·가장자리 (레드팀 경미4 반영):**
- `project.json`은 **맨 마지막에 쓴다**(복사 성공 후). 중간 실패 시 `local-<uuid>`
  폴더를 통째로 정리 — 깨진 폴더를 남기지 않는다.
- 확장자 없는 파일: `source.pathExtension`이 비면 `.mp4`로 가정(AVFoundation이
  대개 연다). 열 수 없으면 import 자체가 실패로 끝난다.
- webm import: `.video`로 저장되면 재생은 ffmpeg 변환 경로로 됨. 단 썸네일
  (AVAssetImageGenerator)은 webm을 못 열므로 **썸네일 실패를 조용히 삼키고**
  미리보기 없이 진행(로더가 허용).

**삭제 — `LocalVideoImporter.deleteLocal(_ item:) throws`:**
- **안전 가드 전부 통과해야 지움:** (a) 항목 폴더가 심볼릭 링크가 **아님**(실제 폴더),
  (b) `project.json`에 `wallflow_local == true`, (c) 폴더가 Library root 바로 아래.
  하나라도 아니면 `throw`(창작마당 링크·사용자 수동 폴더를 절대 안 건드림).
  *(레드팀 확인: 이 가드는 구멍 없음. `local-` 접두사 id는 숫자 workshop id와 안 겹침.)*
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

**⚠️ 레드팀 심각1 반영 — 종료 신호를 창에서 못 받는다:** `WallpaperWindow`는
`ignoresMouseEvents = true`(WallpaperWindow.swift:41) + `[.borderless]`라 마우스·키
이벤트를 **아예 받지 않는다**(키 윈도우도 못 됨). 창 레벨을 올려도 자기 입력으로
종료를 못 잡는다. 그리고 전역 이벤트 모니터(`NSEvent.addGlobalMonitor…`)는
**입력 모니터링 권한 프롬프트**를 띄워 이 앱의 권한 절약 원칙을 깬다 — 금지.

**통합 규칙(수정판):**
- 토글 **켜짐** + 유휴 `threshold`(기본 60초) 도달 → 배경 창을 **전체화면 위로 올림**
  (기존 `WallpaperWindow` window level 데스크톱→최상위; 새 렌더러 없음 = lazy). 렌더 계속.
- **종료 감지:** 전체화면이 떠 있는 **동안에만** 도는 **빠른 타이머(0.2~0.3초)**로
  `idleSeconds()`(`CGEventSource.secondsSinceLastEventType`, **권한 불요**, 이미 유휴
  읽는 경로)를 폴링 → 임계 아래로 떨어지면 즉시 창 레벨 복귀·종료. 기존 5초 폴링으론
  마우스 움직여도 최대 5초 안 사라져 먹통처럼 느껴짐(레드팀 지적) → 빠른 타이머 필수.
  평소엔 안 돌려 전력 낭비 없음.
- **유휴 일시정지 보류(레드팀 경미3):** `PowerPolicy`(Kit, 순수)는 **안 건드린다.**
  App의 `PowerMonitor`에서 전체화면 활성 플래그가 켜져 있으면 idle-pause 분기를
  건너뛴다(한 곳에서만 — 플래그 on이면 `.paused` directive 무시). 단일 진실원천 유지.
- 멀티 모니터: 각 화면의 배경 창을 동시에 올린다.
- **영상 재생 중에는 안 뜬다(실물에서 찾은 결함을 고침):** 영상을 볼 때는 입력이 없어
  유휴가 쌓이므로, 그냥 두면 보던 영상을 덮는다. 다른 앱이 화면 유지 전원 어서션
  (`PreventUserIdleDisplaySleep`, `NoDisplaySleepAssertion`)을 들고 있으면 안 띄우고, 떠 있으면
  내린다(`IdleFullscreen.otherAppKeepsDisplayAwake`, 자기 PID·자기 대신 만든 것 제외, 시스템
  잠자기만 막는 것과 powerd 내부용 `InternalPreventDisplaySleep`은 세지 않음). 플레이어는
  영상이 **보일 때만** 이 어서션을 건다 — 감상 모드가 이미 덮은 뒤 시작된 영상은 비켜 주지 않는다.
- **네이티브 전체화면 앱(별도 Space) 위에는 안 뜬다.** `.fullScreenNone` 그대로 둔다 —
  전체화면 게임·영상·발표를 덮지 않는 쪽이 안전하고, 전력 규칙도 전체화면 앱을 "사용자 집중"으로
  보고 멈춘다. 덮게 하려면 올릴 때만 `.fullScreenAuxiliary`를 붙이면 된다.

**실물 확인(2026-11-09, macOS 26, 1728×1117 한 화면):** 일반 화면에선 메뉴바까지 전부 덮고 재생 계속.
30초 반복 4회 모두 입력 후 199~258ms에 내려감. 어서션을 잡으면 585ms에 내려가고, 잡는 동안 유휴가
쌓여도 안 올라가며, 놓으면 874ms에 다시 올라옴. 실제 QuickTime 재생 중 12초 유휴에도 안 올라감.
Firefox 재생 중에는 `NoDisplaySleepAssertion "video-playing"`이 잡히는 것까지 확인(그 상태로 감상
모드를 띄워 보진 않음). 같은 설정의 시험 창을 TextEdit 전체화면 위에서 올리면 안 보이고, 일반
화면에선 다 덮음(대조군). AVPlayer는 기본으로 화면 유지 어서션을 걸지 않음
(`preventsDisplaySleepDuringVideoPlayback=false`) — Wallflow 영상 배경은 디스플레이 잠자기를 막지 않는다.
- 토글: 메뉴바 `유휴 시 전체화면` + 설정 창에 분(threshold) 입력. 기본 **꺼짐**.

**테스트:** 유휴/활동 판정(threshold 비교, 일시정지 보류 플래그)을 순수 함수로 빼서
단위 테스트. 실제 창 레벨 승격·종료 반응은 실물 확인(`shoot` 스크립트).

### F3. 바탕화면 아이콘 숨기기

- 메뉴바 토글 `바탕화면 아이콘 숨기기`. 상태 `UserDefaults`(`wallflow.hideDesktopIcons`).
- 적용: `defaults write com.apple.finder CreateDesktop -bool <!hidden>` 후
  `killall Finder`(macOS 공개 API 없음 — 표준 방식). App 계층의 작은 헬퍼
  `DesktopIcons.setHidden(_:)` / `DesktopIcons.isHidden`.
- 토글 시에만 적용. 앱 시작/종료 때 강제하지 않는다(사용자 수동 상태 존중).
  `killall Finder` 부작용(파인더 창 재시작)은 알려진 비용 — 토글 설명 툴팁에 적음.
- **메뉴 체크 표시는 우리 bool이 아니라 실제 `defaults read com.apple.finder
  CreateDesktop`로 그린다(레드팀 경미5)** — 손으로 바꾸거나 다른 앱이 토글해도
  표시가 거짓말하지 않게.

### F4. 배경별 볼륨 슬라이더

지금은 전역: `SceneRenderer.soundVolume`(`UserDefaults wallflow.soundVolume`),
메뉴바 프리셋(0/25/50/75/100%) + 설정 창 슬라이더가 이미 있다.

**⚠️ 레드팀 심각2 반영 — 비디오는 일부러 음소거다:** `VideoRenderer.swift:36`
`player.isMuted = true // 배경화면이 소리를 내면 안 된다`. `DisplayManager.
applySoundSetting()`은 SceneRenderer에만 소리를 적용(비디오 제외). 전역 볼륨 기본은
100%라, per-id 기본을 전역에서 그냥 가져오면 **로컬 mp4를 추가하는 순간 바탕화면에서
소리 100% 폭발**(최악의 첫인상).

**수정판 — 전역을 들어내지 않고 그 위에 per-id를 얹는다:**
- **`VolumePreferencesStore`**(App, `CanvasFitPreferencesStore` 패턴): `wallflow.
  volumeByWallpaper` 사전, `volume(for id)` / `setVolume(_:for:)`. **전역 키
  `wallflow.soundVolume`는 그대로 둔다** — per-id 엔트리가 **없을 때의 seed(기본값)**.
  그러면 씬의 기존 동작과 `SoundVolumeTests`가 안 깨진다.
- **SceneRenderer 접점 1곳만:** 소리 적용부에서 `Self.soundVolume` → 현재 item 기준
  `VolumePreferencesStore.volume(for: item.id)`(없으면 전역). static 전역을 들어내지 않음.
- **비디오는 기본 음소거 유지.** per-id 슬라이더로 **사용자가 그 배경에 볼륨을
  명시적으로 준 경우에만 unmute**(opt-in). 로컬 영상 항목의 볼륨 슬라이더 기본은
  **음소거(0)**. 0 초과로 올리면 그때 `VideoRenderer`가 unmute + 그 볼륨 적용.
- 적용 주입: 화면맞춤이 `displays.applyCanvasFit`로 하는 것과 대칭 →
  `displays.applyVolume(_:toWallpaperID:)`.
- UI: 설정 창 슬라이더·메뉴바 "소리 크기"를 **현재 배경 기준**으로(화면 맞춤처럼
  `currentItem` 게이트).

**테스트:** `VolumePreferencesStore` per-id 저장 + **전역 seed 폴백**(엔트리 없으면
전역 값, 전역도 없으면 1.0) 단위 테스트. 기존 `SoundVolumeTests`가 그대로 통과함을 확인.

## 빌더에게 남김 (left to builder)

- 로컬 영상 삭제 UI의 정확한 메뉴 문구·배치(위 기본값에서 조정 가능).
- 유휴 전체화면 기본 threshold(60초 제안)와 설정 창 입력 UI 세부.
- 썸네일 생성 실패 시 폴백(미리보기 없이 진행) — 이미 로더가 허용.
- window-level 승격 vs 오버레이 창 — 실물 확인 후 안정적인 쪽 채택.

## 작업 방식

- **웨이브 순서(레드팀 권고): F1 → F4 → F3 → F2.** 값이 분명하고 안전한 것부터
  끝내 커밋하고, 가장 복잡·실물검증 부담 큰 유휴 전체화면(F2)을 마지막에.
- 브랜치 `feat/local-video-and-desktop-extras`(생성됨). main 안 건드림, 푸시/릴리스
  안 함.
- TDD(`superpowers:test-driven-development`), 기능별 커밋. 커밋에 Claude 서명·모델
  언급 안 넣음.
- 설계·계획 후 fork 레드팀(적대적 검토) 1회, 구현 후 코드 리뷰 1회.
- `rm -rf .build` 후 전체 빌드로 "경고 0"·테스트 수 확인.
