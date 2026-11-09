# Wallflow

Wallpaper Engine 창작마당(Steam Workshop)의 배경화면을 **macOS에서 네이티브로 재생하는 엔진**.
Swift 6 + Metal + AppKit으로 쓰고, 외부 의존성이 없다.

Wallpaper Engine은 윈도우 전용이라 맥에서는 받아 둔 배경화면을 쓸 수 없다. 이 앱은 그
`.pkg` 씬 파일을 직접 읽어 Metal로 그린다 — 창작마당에서 고르고 받는 것부터 씬 스크립트를
돌리는 것까지 한 앱 안에서 한다.

```
메뉴바 아이콘 → 창작마당 둘러보기 → 검색·정렬·필터 → 받기 → 바로 배경화면
```

## 지금 되는 것

- **창작마당 창** — WE 브라우저처럼 세 칸: 종류·등급·해상도·장르 필터 사이드바, 끝없이 이어지는
  격자(지금 쓰는 배경화면에 "사용 중" 표시), 상세 패널. 설치됨/창작마당 탭, 검색, 정렬 8종, 받기,
  지우기(원본까지 삭제)
- **내 동영상** — 메뉴바 "동영상 추가…"로 mp4·mov를 골라 바로 배경화면으로 건다(원본은 복사, 첫 프레임
  미리보기). 내가 넣은 영상은 메뉴에서 지운다
- **화면마다 다른 배경** — 모니터가 둘 이상이면 메뉴 맨 위 "적용할 화면"에서 고른 화면에만 건다.
  화면은 UUID로 기억해 다시 꽂아도 그 배경이 돌아온다. 화면이 하나면 메뉴가 예전과 같다
- **자동으로 바꾸기** — 5분·15분·30분·1시간·하루마다 다음 배경으로. 순서대로/무작위, 배경마다 "빼기".
  메뉴의 "다음 배경으로"로 언제든 바로 넘긴다.
  바꾼 시각을 저장해 잠자기·재시작을 넘겨도 간격을 지킨다
- **소리** — 배경화면마다 소리 크기를 따로 둔다. 비디오는 크기를 준 것만 소리를 낸다
- **유휴 시 전체화면** — 자리를 비우면 배경을 모든 창 위로 올려 보여 주고, 입력이 들어오면 바로
  내린다. 다른 앱이 영상을 틀고 있어 화면 유지를 요청하면(QuickTime·Firefox 등) 띄우지 않는다.
  화면 켜 두기 유틸리티(Vorssaint·caffeinate 등)는 영상으로 치지 않는다. 네이티브 전체화면 앱 위에는 뜨지 않는다
- **바탕화면 아이콘 숨기기** — 메뉴바 토글(파인더가 한 번 다시 뜬다)
- **씬 배경화면** — 이미지·텍스트·도형 레이어, 32가지 색 섞기, 마우스 시차, 스프라이트 시트 이미지(GIF 씬)
- **화면 맞춤** — WE처럼 양옆·위아래를 잘라 채우는 것이 기본이고, 메뉴바 "화면 맞춤"에서
  배경화면마다 채우기 / 전체 보기 / 늘이기를 고른다
- **파티클** — 자식 시스템, 굴절, 제어점(마우스 추적·월드 좌표·덮어쓰기), 스프라이트 시트, 씬 배율,
  스프라이트 트레일·로프·로프 트레일 렌더러(이어지는 빛줄기)
  (`instanceoverride` — 공식 IParticleSystemInstance 뜻 그대로, 스크립트의 `layer.instance`까지),
  `starttime` 프리웜
- **이펙트 체인** — GLSL→MSL 번역기가 셰이더 452개를 전부 Metal에서 컴파일한다
- **씬 스크립트** — 씬 하나를 JSContext 하나에서 돌린다. 레이어 생성, 카메라 제어,
  재질 상수, 커서 이벤트, 오디오 버퍼까지 (`Sources/WallflowKit/Scripting/`)
- **원근(3D) 씬** — 카메라, `.mdl` 메시, 재질 셰이더, 3D 파티클
- **퍼펫 워프** — `*_puppet.mdl`의 뼈대·애니메이션을 읽어 CPU 스키닝
- **프리셋 항목** — `dependency`+`preset`으로 다른 배경화면의 설정 묶음을 연다
- **설정 창**(⌘,) — 자동으로 바꾸기·감상 모드·소리(지금 배경 크기)·전력 정책·프레임을 한 화면에서,
  배경화면마다의 사용자 속성은 둘째 탭. 메뉴바에서 바꾼 값이 열린 창에도 바로 보인다
- **전력 정책** — 가려짐·전체화면·유휴·배터리·발열에 따라 낮추거나 멈춘다. 프레임은
  전원 연결 60, 배터리·저전력 30이 기본이고 메뉴바 "프레임"에서 바로 바꾼다

받아 둔 씬 46개(레이어 1,602개) 기준으로 미구현 파티클 연산자와 모르는 프리셋 항목이 **0개**이고,
그리지 못하는 레이어는 **7개**다 — 전부 재질이 가리키는 첫 텍스처가 없는 경우다.
숫자는 `swift test --filter CorpusCoverageProbe`가 센다(아래 "테스트"의 환경변수 필요).

## 필요한 것

- macOS 14 이상, Swift 6 (Xcode 도구 모음)
- Wallpaper Engine을 **소유한 Steam 계정** — 창작마당 콘텐츠를 받으려면 필요하다
- `steamcmd` — `brew install --cask steamcmd`
- WE의 공용 assets(셰이더·폰트·프리셋)를
  `~/Library/Application Support/Wallflow/Assets`에 둔다. 씬이 자기 파일 대신
  이쪽을 참조하는 경우가 많아서, 없으면 상당수 씬이 반만 그려진다.

### 창작마당 로그인

앱은 **자격 증명을 만지지 않는다.** steamcmd가 비밀번호와 Steam Guard를 대화식으로만
받으므로, 터미널에서 한 번 로그인해 캐시를 만들어 두면 그 뒤로는 앱이 비대화식으로 받는다.

```bash
steamcmd +login <계정이름>
```

앱은 `loginusers.vdf`에서 **계정 이름만** 읽어 입력란을 채운다.

## 빌드와 실행

```bash
./Scripts/make-dev-cert.sh     # 한 번만. 아래 "권한" 참고
./Scripts/bundle.sh            # build/Wallflow.app
open build/Wallflow.app
```

배포용 `.dmg`는 `./Scripts/dist.sh`. Developer ID가 있으면
`WALLFLOW_SIGN_IDENTITY="Developer ID Application: ..."`를 주고,
공증까지 하려면 `WALLFLOW_NOTARIZE=1 WALLFLOW_NOTARY_PROFILE=<프로필>`을 준다.
버전과 번들 ID는 `Scripts/version.sh` 한 곳에서 온다.

### 권한이 매번 다시 물어질 때

macOS는 **코드 서명으로 앱을 알아본다.** 임시(ad-hoc) 서명은 빌드마다 해시가 바뀌어서
화면 녹화·폴더 접근 권한을 처음부터 다시 묻는다. `make-dev-cert.sh`가 자체 서명 인증서를
하나 만들고 `bundle.sh`가 그것으로 서명하면 신원이 고정되어 한 번 허용한 것이 계속 간다.

서명할 때 키체인 창이 뜨면 **"항상 허용"**을 한 번 누르면 된다. 미리 없애려면:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "<로그인 암호>" ~/Library/Keychains/login.keychain-db
```

시스템 오디오 캡처(화면 녹화 권한)는 **씬이 실제로 소리를 쓸 때만** 요청한다.

## 테스트

```bash
WALLFLOW_TEST_SCENES="$HOME/Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960" \
WALLFLOW_TEST_ASSETS="$HOME/Library/Application Support/Wallflow/Assets" \
swift test
```

**환경변수를 빼면 실물 씬으로 도는 테스트가 조용히 건너뛰어진다.** 지어낸 입력만으로는
형식을 잘못 읽은 것을 못 잡는다 — 이 저장소의 버그는 대부분 실물 파일이 잡았다.

## 구조

| 대상 | 하는 일 |
|---|---|
| `Sources/WallflowKit` | 순수 로직. **AppKit·Metal·AVFoundation을 import하지 않는다** |
| `Sources/WallflowApp` | 화면에 그리는 쪽. Metal 파이프라인, 창, 메뉴, 설정 |

이 경계를 지키면 형식 해석과 시뮬레이션을 전부 테스트로 검증할 수 있다. 깨는 변경은 되돌린다.

형식은 문서가 없어 실물 파일의 바이트를 읽어 알아냈다. 근거는 각 파일 머리 주석에 적혀 있다.

- `ScenePackage/PkgReader.swift` — `.pkg` 컨테이너
- `ScenePackage/TexDecoder.swift`·`TexHeader.swift` — `.tex`(LZ4, DXT, 비디오 포함)
- `ScenePackage/MDLModel.swift` — `.mdl` 3D 메시
- `ScenePackage/PuppetModel.swift` — 퍼펫 워프 뼈대·애니메이션
- `Shaders/GLSLTranslator.swift` — GLSL→Metal 번역기
- `Scripting/SceneScriptHost.swift` — 씬 스크립트 런타임

`docs/superpowers/plans/`에 단계별 작업 계획과 그때 내린 판단이 남아 있다.

## 도구

```bash
./Scripts/pkgdump.py <scene.pkg>            # 항목 목록
./Scripts/pkgdump.py <scene.pkg> --layers   # 레이어 요약
./Scripts/shoot-library.sh /tmp/shots 10    # 라이브러리 전부를 창 단위로 촬영
```

화면 전체 캡처는 위에 뜬 다른 앱을 재는 것이라 검증에 쓸 수 없다. 촬영 스크립트는
배경화면 창만 골라 찍고, 끝나면 원래 배경화면으로 되돌린다.

진단용 환경변수: `WALLFLOW_EFFECTS=0`(이펙트 끄기),
`WALLFLOW_EFFECT_{DEBUG,MAXPASS,PASSTHROUGH,GREEN,WHITE,FIXEDUV,SHOWUV,SHOWALPHA}`,
`WALLFLOW_SCRIPT_DEBUG`(스크립트가 바꾼 레이어 상태), `WALLFLOW_FRAME_DEBUG`(프레임 간격),
`WALLFLOW_AUDIO_{DEBUG,TEST}`, `WALLFLOW_BLEND_FORCE`, `WALLFLOW_REFLECTION`.

## 아직 안 되는 것

- **`.webm`/`.mkv` 비디오는 `ffmpeg`가 있어야 한다.** AVFoundation에 컨테이너 디먹서가 없어서,
  설치된 `ffmpeg`(`brew install ffmpeg`)로 백그라운드에서 MP4로 바꿔 재생한다
  (`~/Library/Caches/Wallflow/video`, 최대 2GB). 없으면 메뉴에 "(ffmpeg 필요)"로 표시한다.
- **조명 레이어**, **직교 씬의 커스텀 재질 셰이더** — 받아 둔 씬에 사례가 0개라,
  근거 없이 지어내지 않고 남겨 두었다.
- **Developer ID 서명** — 자체 서명은 이 맥에서만 통한다. 남에게 주려면 인증서가 필요하다.
- 움직이는 GIF를 사용자 그림으로 넣으면 첫 장만 그린다.
- 같은 씬을 두 화면에 걸면 소리가 화면마다 난다.

## 앱 아이콘

우타가와 히로시게 「아와 나루토의 소용돌이」(1853년경)의 소용돌이 부분이다. 메트로폴리탄 미술관
Open Access(퍼블릭 도메인, CC0) 이미지에서 잘랐다. 출처·자른 위치·다시 만드는 법은
`Resources/AppIcon-SOURCE.md`.

## 만든 이유

같은 일을 하는 유료 앱이 있지만 직접 만들기로 했다. 형식 문서가 없는 것을 실물 파일로
알아내는 일이 대부분이었고, 그래서 **모든 판단의 근거를 주석에 적어 두는 것**을 규칙으로 삼았다.
근거 없는 값은 넣지 않고, 못 그리는 것은 조용히 넘기지 않고 이유를 남긴다.
