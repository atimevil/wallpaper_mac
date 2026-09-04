# Wallflow M1 — 셸과 비디오/웹 배경화면 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 데스크톱에 라이브 배경화면을 띄우는 메뉴바 앱을 만들고, Wallpaper Engine 창작마당의 Video/Web 타입 배경화면을 실제로 상시 사용할 수 있게 한다.

**Architecture:** 단일 프로세스 `LSUIElement` 앱. 순수 로직(라이브러리 스캔, 전력 정책, steamcmd 인자 구성)은 `WallflowKit` 라이브러리에 넣어 GUI 없이 테스트하고, AppKit/AVKit/WebKit에 의존하는 부분만 `WallflowApp` 실행 타깃에 둔다. 디스플레이 1개당 데스크톱 아이콘 아래 레벨의 `NSWindow` 1개를 띄우고, 그 안에 `WallpaperRenderer` 프로토콜 구현체를 붙인다.

**Tech Stack:** Swift 6 / SwiftPM / AppKit / AVFoundation / WebKit / IOKit. 테스트는 XCTest. 빌드 산출물은 스크립트로 `.app` 번들로 조립한다.

**Spec:** `docs/superpowers/specs/2026-09-04-wallflow-design.md`

## Global Constraints

- 최소 지원: macOS 14.0, Apple Silicon 전용. `Package.swift`의 플랫폼은 `.macOS(.v14)`.
- 전체 Xcode 필요. `swift test`가 XCTest를 찾으려면 `xcode-select -s /Applications/Xcode.app`가 되어 있어야 한다.
- 외부 SwiftPM 의존성 0개. M1은 시스템 프레임워크만 쓴다.
- 샌드박스 비활성. App Store 배포하지 않는다.
- 앱 번들 ID는 `dev.timevil.wallflow`. 이미 설치된 `dev.3xhaust.WorkshopWallpaperBridge`와 충돌하지 않아야 한다.
- 사용자 데이터 경로는 `~/Library/Application Support/Wallflow/`. 배경화면 라이브러리는 그 아래 `Library/`.
- Wallpaper Engine Steam AppID는 `431960`.
- `project.json`의 `type` 값은 대소문자가 제각각이다 (실물에서 `"scene"`과 `"Scene"` 둘 다 확인됨). 항상 소문자로 정규화해 비교한다.
- 커밋 메시지는 한국어로 쓰고, 본문 끝에 다음 두 줄을 넣는다.
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
  ```

## File Structure

```
Package.swift
Sources/
  WallflowKit/                          그래픽·GUI 의존성 없음. 전부 테스트 대상
    WallpaperType.swift                 project.json의 type 판별
    WallpaperItem.swift                 배경화면 1개의 모델
    LibraryStore.swift                  라이브러리 디렉터리 스캔
    PlaybackDirective.swift             재생 지시(정지 / fps)
    PowerSignals.swift                  전력 정책의 입력 신호 구조체
    PowerPolicy.swift                   신호 -> 지시. 순수 함수
    SteamCmdClient.swift                steamcmd 인자 구성과 실행
Sources/
  WallflowApp/                          AppKit 의존. 눈으로 검증
    main.swift
    AppCoordinator.swift
    MenuBarController.swift
    WallpaperWindow.swift
    DisplayManager.swift
    WallpaperRenderer.swift             렌더러 프로토콜
    VideoRenderer.swift
    WebRenderer.swift
    SystemPowerSignals.swift            실제 시스템에서 신호 수집
Tests/
  WallflowKitTests/
    WallpaperTypeTests.swift
    LibraryStoreTests.swift
    PowerPolicyTests.swift
    SteamCmdClientTests.swift
Scripts/
  bundle.sh                             .app 번들 조립
```

---

### Task 1: 패키지 골격과 배경화면 타입 판별

`project.json`을 읽어 배경화면 종류를 알아내는 것이 라이브러리의 출발점이다. 실물 파일에서 `type`이 `"scene"`과 `"Scene"` 두 가지로 나온 것이 확인됐으므로 정규화가 필수다.

**Files:**
- Create: `Package.swift`
- Create: `Sources/WallflowKit/WallpaperType.swift`
- Test: `Tests/WallflowKitTests/WallpaperTypeTests.swift`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces:
  - `enum WallpaperType: String { case video, web, scene, unsupported }`
  - `static func WallpaperType.from(projectJSON: Data) throws -> WallpaperType`
  - `enum WallpaperError: Error { case malformedProjectJSON, missingField(String), notADirectory(URL) }`

- [ ] **Step 1: `Package.swift` 작성**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallflow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WallflowKit"),
        .executableTarget(name: "WallflowApp", dependencies: ["WallflowKit"]),
        .testTarget(name: "WallflowKitTests", dependencies: ["WallflowKit"]),
    ]
)
```

`Sources/WallflowApp/main.swift`를 `print("wallflow")` 한 줄로 만들어 두어야 패키지가 빌드된다.

- [ ] **Step 2: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class WallpaperTypeTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testParsesVideoType() throws {
        let d = json(#"{"type":"video","file":"bg.mp4","title":"t"}"#)
        XCTAssertEqual(try WallpaperType.from(projectJSON: d), .video)
    }

    func testParsesWebType() throws {
        let d = json(#"{"type":"web","file":"index.html","title":"t"}"#)
        XCTAssertEqual(try WallpaperType.from(projectJSON: d), .web)
    }

    // 실물 창작마당 파일에서 "scene"과 "Scene"이 모두 관측됐다.
    func testTypeComparisonIsCaseInsensitive() throws {
        let lower = json(#"{"type":"scene","file":"scene.json"}"#)
        let upper = json(#"{"type":"Scene","file":"scene.json"}"#)
        XCTAssertEqual(try WallpaperType.from(projectJSON: lower), .scene)
        XCTAssertEqual(try WallpaperType.from(projectJSON: upper), .scene)
    }

    func testUnknownTypeBecomesUnsupported() throws {
        let d = json(#"{"type":"application","file":"a.exe"}"#)
        XCTAssertEqual(try WallpaperType.from(projectJSON: d), .unsupported)
    }

    func testMissingTypeFieldThrows() {
        let d = json(#"{"file":"bg.mp4"}"#)
        XCTAssertThrowsError(try WallpaperType.from(projectJSON: d)) { error in
            guard case WallpaperError.missingField(let f) = error else {
                return XCTFail("expected missingField, got \(error)")
            }
            XCTAssertEqual(f, "type")
        }
    }

    func testMalformedJSONThrows() {
        let d = json("not json at all")
        XCTAssertThrowsError(try WallpaperType.from(projectJSON: d)) { error in
            guard case WallpaperError.malformedProjectJSON = error else {
                return XCTFail("expected malformedProjectJSON, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 3: 테스트가 실패하는지 확인**

Run: `swift test --filter WallpaperTypeTests`
Expected: FAIL — `cannot find 'WallpaperType' in scope`

- [ ] **Step 4: 최소 구현 작성**

```swift
import Foundation

public enum WallpaperError: Error, Equatable {
    case malformedProjectJSON
    case missingField(String)
    case notADirectory(URL)
}

public enum WallpaperType: String, Sendable, Equatable {
    case video
    case web
    case scene
    case unsupported

    /// project.json의 `type` 필드를 읽는다.
    /// 창작마당 실물 파일에서 "scene"과 "Scene"이 모두 관측되므로 소문자로 정규화한다.
    public static func from(projectJSON data: Data) throws -> WallpaperType {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw WallpaperError.malformedProjectJSON
        }
        guard let raw = dict["type"] as? String else {
            throw WallpaperError.missingField("type")
        }
        return WallpaperType(rawValue: raw.lowercased()) ?? .unsupported
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter WallpaperTypeTests`
Expected: PASS (6개 테스트)

- [ ] **Step 6: 커밋**

```bash
git add Package.swift Sources/WallflowKit/WallpaperType.swift Sources/WallflowApp/main.swift Tests/WallflowKitTests/WallpaperTypeTests.swift
git commit -m "$(cat <<'MSG'
feat: 패키지 골격과 배경화면 타입 판별 추가

project.json의 type 필드를 읽어 video/web/scene을 구분한다.
창작마당 실물 파일에서 대소문자가 섞여 있어 소문자로 정규화한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 2: 배경화면 모델과 라이브러리 스캔

디스크의 배경화면 폴더를 읽어 목록을 만든다. 창작마당 폴더 구조는 `<라이브러리>/<워크샵ID>/{project.json, preview.jpg, 실제파일}`이다.

**Files:**
- Create: `Sources/WallflowKit/WallpaperItem.swift`
- Create: `Sources/WallflowKit/LibraryStore.swift`
- Test: `Tests/WallflowKitTests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: `WallpaperType.from(projectJSON:)`, `WallpaperError` (Task 1)
- Produces:
  - `struct WallpaperItem: Identifiable, Equatable, Sendable` — 프로퍼티 `id: String`, `title: String`, `type: WallpaperType`, `directory: URL`, `contentURL: URL`, `previewURL: URL?`
  - `static func WallpaperItem.load(from directory: URL) throws -> WallpaperItem`
  - `struct LibraryStore` — `init(root: URL)`, `func scan() throws -> [WallpaperItem]`, `var root: URL`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class LibraryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 창작마당 폴더 하나를 흉내낸다.
    @discardableResult
    private func makeItem(id: String, json: String, files: [String] = []) throws -> URL {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        for f in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    func testLoadsVideoItem() throws {
        let dir = try makeItem(
            id: "111",
            json: #"{"type":"video","file":"bg.mp4","title":"My Video"}"#,
            files: ["bg.mp4", "preview.jpg"]
        )
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.id, "111")
        XCTAssertEqual(item.title, "My Video")
        XCTAssertEqual(item.type, .video)
        XCTAssertEqual(item.contentURL.lastPathComponent, "bg.mp4")
        XCTAssertEqual(item.previewURL?.lastPathComponent, "preview.jpg")
    }

    /// 실물에서 preview가 .gif인 경우가 있었다(3536506287).
    func testFindsGifPreview() throws {
        let dir = try makeItem(
            id: "222",
            json: #"{"type":"web","file":"index.html","title":"W"}"#,
            files: ["index.html", "preview.gif"]
        )
        XCTAssertEqual(try WallpaperItem.load(from: dir).previewURL?.lastPathComponent, "preview.gif")
    }

    func testMissingPreviewIsNil() throws {
        let dir = try makeItem(
            id: "333",
            json: #"{"type":"video","file":"bg.mp4","title":"V"}"#,
            files: ["bg.mp4"]
        )
        XCTAssertNil(try WallpaperItem.load(from: dir).previewURL)
    }

    func testTitleFallsBackToDirectoryName() throws {
        let dir = try makeItem(
            id: "444",
            json: #"{"type":"video","file":"bg.mp4"}"#,
            files: ["bg.mp4"]
        )
        XCTAssertEqual(try WallpaperItem.load(from: dir).title, "444")
    }

    func testMissingFileFieldThrows() throws {
        let dir = try makeItem(id: "555", json: #"{"type":"video","title":"V"}"#)
        XCTAssertThrowsError(try WallpaperItem.load(from: dir)) { error in
            guard case WallpaperError.missingField(let f) = error else {
                return XCTFail("expected missingField, got \(error)")
            }
            XCTAssertEqual(f, "file")
        }
    }

    func testScanReturnsItemsSortedByTitle() throws {
        try makeItem(id: "b", json: #"{"type":"video","file":"a.mp4","title":"Zebra"}"#, files: ["a.mp4"])
        try makeItem(id: "a", json: #"{"type":"video","file":"a.mp4","title":"Apple"}"#, files: ["a.mp4"])
        let items = try LibraryStore(root: root).scan()
        XCTAssertEqual(items.map(\.title), ["Apple", "Zebra"])
    }

    /// 손상된 폴더 하나가 라이브러리 전체를 못 쓰게 만들면 안 된다.
    func testScanSkipsUnreadableDirectories() throws {
        try makeItem(id: "good", json: #"{"type":"video","file":"a.mp4","title":"Good"}"#, files: ["a.mp4"])
        try makeItem(id: "bad", json: "garbage")
        let items = try LibraryStore(root: root).scan()
        XCTAssertEqual(items.map(\.title), ["Good"])
    }

    func testScanIgnoresLooseFiles() throws {
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try makeItem(id: "good", json: #"{"type":"video","file":"a.mp4","title":"Good"}"#, files: ["a.mp4"])
        XCTAssertEqual(try LibraryStore(root: root).scan().count, 1)
    }

    func testScanOnMissingRootReturnsEmpty() throws {
        let missing = root.appendingPathComponent("nope")
        XCTAssertEqual(try LibraryStore(root: missing).scan(), [])
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter LibraryStoreTests`
Expected: FAIL — `cannot find 'WallpaperItem' in scope`

- [ ] **Step 3: `WallpaperItem` 구현**

```swift
import Foundation

public struct WallpaperItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let type: WallpaperType
    public let directory: URL
    /// project.json의 `file`이 가리키는 실제 콘텐츠. video면 mp4, web이면 html, scene이면 scene.json.
    public let contentURL: URL
    public let previewURL: URL?

    /// preview는 확장자가 제각각이라 알려진 이름을 순서대로 찾는다.
    private static let previewNames = [
        "preview.jpg", "preview.png", "preview.gif", "preview.jpeg", "preview.webp",
    ]

    public static func load(from directory: URL) throws -> WallpaperItem {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw WallpaperError.notADirectory(directory)
        }

        let jsonURL = directory.appendingPathComponent("project.json")
        let data = try Data(contentsOf: jsonURL)
        let type = try WallpaperType.from(projectJSON: data)

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw WallpaperError.malformedProjectJSON
        }
        guard let file = dict["file"] as? String, !file.isEmpty else {
            throw WallpaperError.missingField("file")
        }

        let id = directory.lastPathComponent
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id

        let preview = previewNames
            .map(directory.appendingPathComponent)
            .first { FileManager.default.fileExists(atPath: $0.path) }

        return WallpaperItem(
            id: id,
            title: title,
            type: type,
            directory: directory,
            contentURL: directory.appendingPathComponent(file),
            previewURL: preview
        )
    }
}
```

- [ ] **Step 4: `LibraryStore` 구현**

```swift
import Foundation

/// 배경화면 라이브러리 디렉터리를 읽는다.
/// 창작마당 구조는 <root>/<워크샵ID>/project.json 이다.
public struct LibraryStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 라이브러리를 스캔한다. 읽을 수 없는 항목은 건너뛴다.
    /// 배경화면 하나가 깨졌다고 목록 전체를 못 쓰게 만들지 않는다.
    public func scan() throws -> [WallpaperItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { try? WallpaperItem.load(from: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter LibraryStoreTests`
Expected: PASS (9개 테스트)

- [ ] **Step 6: 커밋**

```bash
git add Sources/WallflowKit/WallpaperItem.swift Sources/WallflowKit/LibraryStore.swift Tests/WallflowKitTests/LibraryStoreTests.swift
git commit -m "$(cat <<'MSG'
feat: 배경화면 모델과 라이브러리 스캔 추가

창작마당 폴더 구조를 읽어 배경화면 목록을 만든다.
손상된 항목은 건너뛰어 라이브러리 전체가 죽지 않게 한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 3: 전력 정책

배경화면은 항상 켜져 있으므로 전력 관리가 기능의 일부다. 스펙 6절의 정책을 순수 함수로 구현해 시스템 없이 전수 테스트한다.

**Files:**
- Create: `Sources/WallflowKit/PlaybackDirective.swift`
- Create: `Sources/WallflowKit/PowerSignals.swift`
- Create: `Sources/WallflowKit/PowerPolicy.swift`
- Test: `Tests/WallflowKitTests/PowerPolicyTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `enum PlaybackDirective: Equatable, Sendable { case paused; case playing(fps: Int) }`
  - `struct PowerSignals: Equatable, Sendable` — `isOccluded: Bool`, `isFullscreenAppActive: Bool`, `idleSeconds: TimeInterval`, `isOnBattery: Bool`, `isLowPowerMode: Bool`, `isThermallyPressured: Bool`; `static let active: PowerSignals` (전부 정상 상태의 기본값)
  - `enum PowerPolicy` — `static let normalFPS = 30`, `static let reducedFPS = 15`, `static let idlePauseSeconds: TimeInterval = 900`, `static func directive(for signals: PowerSignals) -> PlaybackDirective`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class PowerPolicyTests: XCTestCase {
    func testFullPowerIsThirtyFPS() {
        XCTAssertEqual(PowerPolicy.directive(for: .active), .playing(fps: 30))
    }

    func testOccludedDesktopPauses() {
        var s = PowerSignals.active
        s.isOccluded = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testFullscreenAppPauses() {
        var s = PowerSignals.active
        s.isFullscreenAppActive = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testIdleForFifteenMinutesPauses() {
        var s = PowerSignals.active
        s.idleSeconds = 900
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testJustUnderIdleThresholdKeepsPlaying() {
        var s = PowerSignals.active
        s.idleSeconds = 899
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 30))
    }

    func testBatteryHalvesFrameRate() {
        var s = PowerSignals.active
        s.isOnBattery = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }

    func testLowPowerModeHalvesFrameRate() {
        var s = PowerSignals.active
        s.isLowPowerMode = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }

    func testThermalPressureHalvesFrameRate() {
        var s = PowerSignals.active
        s.isThermallyPressured = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }

    /// 정지 조건은 프레임레이트 감쇠보다 우선한다.
    func testPauseWinsOverReducedFrameRate() {
        var s = PowerSignals.active
        s.isOnBattery = true
        s.isOccluded = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testMultipleReductionsStillFifteen() {
        var s = PowerSignals.active
        s.isOnBattery = true
        s.isLowPowerMode = true
        s.isThermallyPressured = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter PowerPolicyTests`
Expected: FAIL — `cannot find 'PowerPolicy' in scope`

- [ ] **Step 3: 구현 작성**

`PlaybackDirective.swift`:

```swift
/// 렌더러에게 내리는 재생 지시.
public enum PlaybackDirective: Equatable, Sendable {
    case paused
    case playing(fps: Int)
}
```

`PowerSignals.swift`:

```swift
import Foundation

/// 전력 정책의 입력. 시스템에서 수집하지만 테스트에서는 직접 만든다.
public struct PowerSignals: Equatable, Sendable {
    public var isOccluded: Bool
    public var isFullscreenAppActive: Bool
    public var idleSeconds: TimeInterval
    public var isOnBattery: Bool
    public var isLowPowerMode: Bool
    public var isThermallyPressured: Bool

    public init(
        isOccluded: Bool = false,
        isFullscreenAppActive: Bool = false,
        idleSeconds: TimeInterval = 0,
        isOnBattery: Bool = false,
        isLowPowerMode: Bool = false,
        isThermallyPressured: Bool = false
    ) {
        self.isOccluded = isOccluded
        self.isFullscreenAppActive = isFullscreenAppActive
        self.idleSeconds = idleSeconds
        self.isOnBattery = isOnBattery
        self.isLowPowerMode = isLowPowerMode
        self.isThermallyPressured = isThermallyPressured
    }

    /// 전원 연결, 화면 보임, 사용자 활동 중.
    public static let active = PowerSignals()
}
```

`PowerPolicy.swift`:

```swift
import Foundation

/// 프레임레이트와 정지 여부를 결정하는 단일 지점.
/// 렌더러는 이 결정을 따르기만 한다.
public enum PowerPolicy {
    public static let normalFPS = 30
    public static let reducedFPS = 15
    public static let idlePauseSeconds: TimeInterval = 900  // 15분

    public static func directive(for signals: PowerSignals) -> PlaybackDirective {
        // 보이지 않는 것을 그릴 이유가 없다. 정지가 감쇠보다 우선한다.
        if signals.isOccluded
            || signals.isFullscreenAppActive
            || signals.idleSeconds >= idlePauseSeconds {
            return .paused
        }

        let shouldReduce = signals.isOnBattery
            || signals.isLowPowerMode
            || signals.isThermallyPressured
        return .playing(fps: shouldReduce ? reducedFPS : normalFPS)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter PowerPolicyTests`
Expected: PASS (10개 테스트)

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowKit/PlaybackDirective.swift Sources/WallflowKit/PowerSignals.swift Sources/WallflowKit/PowerPolicy.swift Tests/WallflowKitTests/PowerPolicyTests.swift
git commit -m "$(cat <<'MSG'
feat: 전력 정책 추가

30fps 기본, 배터리·저전력·발열 시 15fps, 가림·전체화면·15분 무입력 시 정지.
시스템 의존 없는 순수 함수라 전수 테스트한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 4: steamcmd 클라이언트

창작마당 다운로드. 인자 구성은 순수 함수로 분리해 테스트하고, 실제 프로세스 실행은 얇게 감싼다. `steamcmd` 미설치는 정상 상태로 취급한다 — 수동 임포트가 항상 대안이다.

**Files:**
- Create: `Sources/WallflowKit/SteamCmdClient.swift`
- Test: `Tests/WallflowKitTests/SteamCmdClientTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `struct SteamCmdClient: Sendable` — `init(executable: URL?, installDirectory: URL)`, `var isAvailable: Bool`, `static let wallpaperEngineAppID = "431960"`, `static func arguments(login: String, workshopID: String, installDirectory: URL) -> [String]`, `static func locateExecutable(searching paths: [URL]) -> URL?`, `func download(workshopID: String, login: String) throws -> URL`
  - `enum SteamCmdError: Error, Equatable { case notInstalled, invalidWorkshopID(String), downloadFailed(exitCode: Int32, output: String) }`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class SteamCmdClientTests: XCTestCase {
    private let installDir = URL(fileURLWithPath: "/tmp/wf-install")

    func testArgumentsIncludeWallpaperEngineAppID() {
        let args = SteamCmdClient.arguments(
            login: "someuser", workshopID: "3714517753", installDirectory: installDir
        )
        XCTAssertTrue(args.contains("431960"))
        XCTAssertEqual(SteamCmdClient.wallpaperEngineAppID, "431960")
    }

    func testArgumentsAreInSteamCmdOrder() {
        let args = SteamCmdClient.arguments(
            login: "someuser", workshopID: "3714517753", installDirectory: installDir
        )
        XCTAssertEqual(args, [
            "+force_install_dir", "/tmp/wf-install",
            "+login", "someuser",
            "+workshop_download_item", "431960", "3714517753",
            "+quit",
        ])
    }

    /// force_install_dir는 login보다 먼저 와야 적용된다. steamcmd의 알려진 함정이다.
    func testInstallDirectoryPrecedesLogin() {
        let args = SteamCmdClient.arguments(
            login: "u", workshopID: "1", installDirectory: installDir
        )
        let dirIndex = args.firstIndex(of: "+force_install_dir")!
        let loginIndex = args.firstIndex(of: "+login")!
        XCTAssertLessThan(dirIndex, loginIndex)
    }

    func testUnavailableWhenExecutableIsNil() {
        let client = SteamCmdClient(executable: nil, installDirectory: installDir)
        XCTAssertFalse(client.isAvailable)
    }

    func testDownloadWithoutExecutableThrowsNotInstalled() {
        let client = SteamCmdClient(executable: nil, installDirectory: installDir)
        XCTAssertThrowsError(try client.download(workshopID: "123", login: "u")) { error in
            XCTAssertEqual(error as? SteamCmdError, .notInstalled)
        }
    }

    func testRejectsNonNumericWorkshopID() {
        let client = SteamCmdClient(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            installDirectory: installDir
        )
        XCTAssertThrowsError(try client.download(workshopID: "abc; rm -rf /", login: "u")) { error in
            XCTAssertEqual(error as? SteamCmdError, .invalidWorkshopID("abc; rm -rf /"))
        }
    }

    func testRejectsEmptyWorkshopID() {
        let client = SteamCmdClient(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            installDirectory: installDir
        )
        XCTAssertThrowsError(try client.download(workshopID: "", login: "u")) { error in
            XCTAssertEqual(error as? SteamCmdError, .invalidWorkshopID(""))
        }
    }

    func testLocateExecutableFindsExistingPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("steamcmd")
        try Data("#!/bin/sh\n".utf8).write(to: fake)

        let missing = dir.appendingPathComponent("nope/steamcmd")
        XCTAssertEqual(SteamCmdClient.locateExecutable(searching: [missing, fake]), fake)
    }

    func testLocateExecutableReturnsNilWhenNoneExist() {
        let missing = URL(fileURLWithPath: "/definitely/not/here/steamcmd")
        XCTAssertNil(SteamCmdClient.locateExecutable(searching: [missing]))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter SteamCmdClientTests`
Expected: FAIL — `cannot find 'SteamCmdClient' in scope`

- [ ] **Step 3: 구현 작성**

```swift
import Foundation

public enum SteamCmdError: Error, Equatable {
    case notInstalled
    case invalidWorkshopID(String)
    case downloadFailed(exitCode: Int32, output: String)
}

/// steamcmd를 감싸 창작마당 아이템을 받아온다.
/// 사용자가 Wallpaper Engine을 소유하고 있어야 하며, 본인 계정으로 로그인한다.
public struct SteamCmdClient: Sendable {
    public static let wallpaperEngineAppID = "431960"

    /// brew와 수동 설치의 통상 경로.
    public static let defaultSearchPaths = [
        URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
        URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
    ]

    public let executable: URL?
    public let installDirectory: URL

    public init(executable: URL?, installDirectory: URL) {
        self.executable = executable
        self.installDirectory = installDirectory
    }

    public var isAvailable: Bool { executable != nil }

    public static func locateExecutable(searching paths: [URL] = defaultSearchPaths) -> URL? {
        paths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// steamcmd는 인자 순서에 민감하다. force_install_dir가 login보다 앞서야 적용된다.
    public static func arguments(
        login: String, workshopID: String, installDirectory: URL
    ) -> [String] {
        [
            "+force_install_dir", installDirectory.path,
            "+login", login,
            "+workshop_download_item", wallpaperEngineAppID, workshopID,
            "+quit",
        ]
    }

    /// 창작마당 아이템을 받아 내려받은 폴더 경로를 돌려준다.
    /// Steam Guard가 걸려 있으면 실패한다. 그 경우 수동 폴더 임포트를 쓴다.
    @discardableResult
    public func download(workshopID: String, login: String) throws -> URL {
        guard let executable else { throw SteamCmdError.notInstalled }
        // 인자로 그대로 넘어가므로 숫자만 허용한다.
        guard !workshopID.isEmpty, workshopID.allSatisfy(\.isNumber) else {
            throw SteamCmdError.invalidWorkshopID(workshopID)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(
            login: login, workshopID: workshopID, installDirectory: installDirectory
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SteamCmdError.downloadFailed(
                exitCode: process.terminationStatus, output: output
            )
        }

        return installDirectory
            .appendingPathComponent("steamapps/workshop/content")
            .appendingPathComponent(Self.wallpaperEngineAppID)
            .appendingPathComponent(workshopID)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter SteamCmdClientTests`
Expected: PASS (9개 테스트)

- [ ] **Step 5: 전체 테스트 확인**

Run: `swift test`
Expected: PASS — Task 1~4의 34개 테스트 전부

- [ ] **Step 6: 커밋**

```bash
git add Sources/WallflowKit/SteamCmdClient.swift Tests/WallflowKitTests/SteamCmdClientTests.swift
git commit -m "$(cat <<'MSG'
feat: steamcmd 창작마당 다운로드 클라이언트 추가

인자 구성을 순수 함수로 분리해 테스트한다.
워크샵 ID는 숫자만 허용해 인자 주입을 막는다.
steamcmd 미설치는 정상 상태로 취급하고 수동 임포트로 대체한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 5: 데스크톱 윈도우와 앱 번들

여기서부터는 눈으로 검증한다. 스펙 10절이 지목한 최대 위험 요소 — 배경 윈도우가 데스크톱 아이콘 뒤에 제대로 깔리는가 — 를 가장 먼저 확인한다. 이 태스크는 빨간 배경 윈도우를 띄우는 것으로 끝난다. 렌더러는 다음 태스크다.

**Files:**
- Create: `Sources/WallflowApp/WallpaperWindow.swift`
- Modify: `Sources/WallflowApp/main.swift` (Task 1에서 만든 한 줄짜리를 교체)
- Create: `Scripts/bundle.sh`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `final class WallpaperWindow: NSWindow` — `init(screen: NSScreen)`, `func setContent(_ view: NSView)`, `var screenID: CGDirectDisplayID`

- [ ] **Step 1: `WallpaperWindow` 작성**

```swift
import AppKit

/// 화면 하나를 덮는 배경 윈도우.
/// 데스크톱 아이콘 바로 아래 레벨에 놓여 모든 스페이스에 머문다.
final class WallpaperWindow: NSWindow {
    let screenID: CGDirectDisplayID

    init(screen: NSScreen) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        screenID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // 데스크톱 아이콘 바로 아래. 이보다 높으면 아이콘을 가린다.
        level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        )

        // 모든 스페이스에 머물고, Mission Control과 창 순환에서 빠진다.
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenNone,
        ]

        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true   // 클릭은 데스크톱으로 통과시킨다
        isReleasedWhenClosed = false
        backgroundColor = .black
        setFrame(screen.frame, display: true)
    }

    /// 이 윈도우의 내용을 교체한다. 렌더러가 뷰를 넘긴다.
    func setContent(_ view: NSView) {
        view.frame = contentView?.bounds ?? frame
        view.autoresizingMask = [.width, .height]
        contentView = view
    }
}
```

- [ ] **Step 2: 임시 `main.swift`로 교체**

```swift
import AppKit

// Task 5 확인용 임시 진입점. Task 8에서 AppCoordinator로 교체한다.
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WallpaperWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        for screen in NSScreen.screens {
            let window = WallpaperWindow(screen: screen)
            let view = NSView(frame: window.frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemRed.cgColor
            window.setContent(view)
            window.orderFront(nil)
            windows.append(window)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dock에 뜨지 않는다
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 3: `Scripts/bundle.sh` 작성**

```bash
#!/bin/bash
# .app 번들을 조립한다. SwiftPM은 실행 파일만 만들기 때문에 필요하다.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Wallflow.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/WallflowApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wallflow"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wallflow</string>
    <key>CFBundleDisplayName</key><string>Wallflow</string>
    <key>CFBundleIdentifier</key><string>dev.timevil.wallflow</string>
    <key>CFBundleExecutable</key><string>Wallflow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 서명 없이는 일부 API가 막히므로 임시(ad-hoc) 서명을 한다.
codesign --force --deep --sign - "$APP"
echo "built: $APP"
```

- [ ] **Step 4: 빌드하고 실행해 눈으로 확인**

```bash
chmod +x Scripts/bundle.sh
./Scripts/bundle.sh
open build/Wallflow.app
```

확인할 것:
1. 모든 화면이 빨갛게 덮인다.
2. **데스크톱 아이콘이 빨간 배경 위에 그대로 보인다.** 아이콘이 가려지면 윈도우 레벨이 틀린 것이다.
3. Dock에 아이콘이 뜨지 않는다.
4. 다른 스페이스로 넘어가도 빨간 배경이 유지된다.
5. 데스크톱을 클릭하면 평소처럼 반응한다 (Finder가 활성화된다).

종료: `pkill -f Wallflow.app`

2번이 실패하면 `CGWindowLevelForKey(.desktopIconWindow) - 1` 대신
`CGWindowLevelForKey(.desktopWindow) + 1`을 시도하고, 결과를 코드 주석에 기록한다.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowApp/WallpaperWindow.swift Sources/WallflowApp/main.swift Scripts/bundle.sh
git commit -m "$(cat <<'MSG'
feat: 데스크톱 배경 윈도우와 앱 번들 스크립트 추가

데스크톱 아이콘 바로 아래 레벨에 보더리스 윈도우를 띄운다.
모든 스페이스에 머물고 마우스 이벤트는 통과시킨다.
SwiftPM이 .app을 만들지 못하므로 번들 조립 스크립트를 둔다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 6: 렌더러 프로토콜과 비디오 렌더러

**Files:**
- Create: `Sources/WallflowApp/WallpaperRenderer.swift`
- Create: `Sources/WallflowApp/VideoRenderer.swift`
- Modify: `Sources/WallflowApp/main.swift`

**Interfaces:**
- Consumes: `WallpaperItem` (Task 2), `PlaybackDirective` (Task 3), `WallpaperWindow.setContent(_:)` (Task 5)
- Produces:
  - `protocol WallpaperRenderer: AnyObject` — `func makeView() -> NSView`, `func start() throws`, `func apply(_ directive: PlaybackDirective)`, `func stop()`
  - `final class VideoRenderer: WallpaperRenderer` — `init(item: WallpaperItem)`
  - `enum RendererError: Error { case unsupportedType(WallpaperType), contentMissing(URL) }`

- [ ] **Step 1: 프로토콜 작성**

```swift
import AppKit
import WallflowKit

enum RendererError: Error {
    case unsupportedType(WallpaperType)
    case contentMissing(URL)
}

/// 배경화면 한 장을 그리는 것의 공통 인터페이스.
/// 소비자는 이것이 비디오인지 웹인지 씬인지 몰라도 된다.
protocol WallpaperRenderer: AnyObject {
    /// 윈도우에 붙일 뷰를 만든다. start() 전에 호출된다.
    func makeView() -> NSView
    func start() throws
    /// 전력 정책의 결정을 반영한다.
    func apply(_ directive: PlaybackDirective)
    func stop()
}
```

- [ ] **Step 2: `VideoRenderer` 작성**

```swift
import AppKit
import AVFoundation
import WallflowKit

/// mp4/mov 배경화면을 무한 루프로 재생한다.
/// AVPlayerLooper 대신 rate=0 감지 후 seek을 쓰지 않고, 끝 알림에서 되감는다.
final class VideoRenderer: WallpaperRenderer {
    private let item: WallpaperItem
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(item: WallpaperItem) {
        self.item = item
    }

    func makeView() -> NSView {
        PlayerLayerView(player: player)
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: item.contentURL.path) else {
            throw RendererError.contentMissing(item.contentURL)
        }
        let asset = AVURLAsset(url: item.contentURL)
        let template = AVPlayerItem(asset: asset)
        // AVPlayerLooper가 큐를 관리해 이음매 없는 반복을 만든다.
        looper = AVPlayerLooper(player: player, templateItem: template)
        player.isMuted = true              // 배경화면이 소리를 내면 안 된다
        player.actionAtItemEnd = .advance
        player.play()
    }

    func apply(_ directive: PlaybackDirective) {
        switch directive {
        case .paused:
            player.pause()
        case .playing:
            // 비디오는 소스 자체의 프레임레이트로 디코딩된다.
            // 임의로 낮추면 재생이 끊기므로 fps는 무시하고 재생/정지만 따른다.
            // 전력 절감은 정지 조건이 담당한다.
            if player.rate == 0 { player.play() }
        }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
    }
}

/// AVPlayerLayer를 담는 뷰. 화면을 꽉 채우도록 잘라 맞춘다.
private final class PlayerLayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill   // 여백 없이 채운다
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
```

- [ ] **Step 3: `main.swift`를 비디오 재생 확인용으로 교체**

```swift
import AppKit
import WallflowKit

// Task 6 확인용 임시 진입점. Task 8에서 AppCoordinator로 교체한다.
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WallpaperWindow] = []
    private var renderers: [WallpaperRenderer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["WALLFLOW_ITEM"] else {
            FileHandle.standardError.write(Data("WALLFLOW_ITEM 환경변수에 배경화면 폴더 경로를 넣어라\n".utf8))
            NSApp.terminate(nil)
            return
        }
        do {
            let item = try WallpaperItem.load(from: URL(fileURLWithPath: path))
            for screen in NSScreen.screens {
                let window = WallpaperWindow(screen: screen)
                let renderer: WallpaperRenderer = VideoRenderer(item: item)
                window.setContent(renderer.makeView())
                try renderer.start()
                window.orderFront(nil)
                windows.append(window)
                renderers.append(renderer)
            }
        } catch {
            FileHandle.standardError.write(Data("실패: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 4: 테스트용 비디오 배경화면을 만들어 눈으로 확인**

```bash
mkdir -p /tmp/wf-video-test
# 10초짜리 컬러바 영상을 만든다. ffmpeg이 없으면 brew install ffmpeg
ffmpeg -y -f lavfi -i "testsrc=size=1920x1080:rate=30" -t 10 \
  -pix_fmt yuv420p /tmp/wf-video-test/bg.mp4
cat > /tmp/wf-video-test/project.json <<'JSON'
{"type":"video","file":"bg.mp4","title":"Test Video"}
JSON

./Scripts/bundle.sh
WALLFLOW_ITEM=/tmp/wf-video-test open -a build/Wallflow.app
```

`open`은 환경변수를 전달하지 않으므로 직접 실행한다:

```bash
WALLFLOW_ITEM=/tmp/wf-video-test ./build/Wallflow.app/Contents/MacOS/Wallflow
```

확인할 것:
1. 데스크톱 배경에 컬러바 영상이 재생된다.
2. 데스크톱 아이콘이 영상 위에 보인다.
3. 10초 후 끊김 없이 처음부터 다시 재생된다.
4. 소리가 나지 않는다.

종료: `Ctrl-C`

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowApp/WallpaperRenderer.swift Sources/WallflowApp/VideoRenderer.swift Sources/WallflowApp/main.swift
git commit -m "$(cat <<'MSG'
feat: 렌더러 프로토콜과 비디오 렌더러 추가

AVPlayerLooper로 이음매 없이 반복 재생한다.
배경화면이 소리를 내지 않도록 항상 음소거한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 7: 웹 렌더러

**Files:**
- Create: `Sources/WallflowApp/WebRenderer.swift`
- Modify: `Sources/WallflowApp/main.swift:` (프로브에서 타입에 따라 렌더러를 고르게 한다)

**Interfaces:**
- Consumes: `WallpaperRenderer`, `RendererError` (Task 6), `WallpaperItem` (Task 2), `PlaybackDirective` (Task 3)
- Produces: `final class WebRenderer: WallpaperRenderer` — `init(item: WallpaperItem)`

- [ ] **Step 1: `WebRenderer` 작성**

```swift
import AppKit
import WebKit
import WallflowKit

/// HTML/JS 배경화면을 WKWebView로 렌더한다.
/// 정지는 페이지를 죽이지 않고 requestAnimationFrame을 멈추는 방식으로 한다.
final class WebRenderer: WallpaperRenderer {
    private let item: WallpaperItem
    private var webView: WKWebView?

    init(item: WallpaperItem) {
        self.item = item
    }

    func makeView() -> NSView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // 배경화면은 소리를 내면 안 된다.
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: config)
        // drawsBackground는 비공개 프로퍼티라 쓰지 않는다.
        // 배경 윈도우가 이미 불투명 검정이므로 이것으로 충분하다.
        view.underPageBackgroundColor = .black
        view.autoresizingMask = [.width, .height]
        webView = view
        return view
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: item.contentURL.path) else {
            throw RendererError.contentMissing(item.contentURL)
        }
        // 배경화면 폴더 전체를 읽기 허용해야 상대 경로 리소스가 로드된다.
        webView?.loadFileURL(item.contentURL, allowingReadAccessTo: item.directory)
    }

    func apply(_ directive: PlaybackDirective) {
        switch directive {
        case .paused:
            // 페이지를 언로드하지 않는다. 상태를 잃지 않으면서 그리기만 멈춘다.
            webView?.evaluateJavaScript("document.body && (document.body.style.animationPlayState='paused');")
            webView?.isHidden = true
        case .playing:
            webView?.isHidden = false
            webView?.evaluateJavaScript("document.body && (document.body.style.animationPlayState='running');")
        }
    }

    func stop() {
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
    }
}
```

- [ ] **Step 2: 프로브가 타입에 따라 렌더러를 고르게 수정**

`main.swift`의 렌더러 생성 부분을 다음으로 바꾼다:

```swift
let renderer: WallpaperRenderer
switch item.type {
case .video:
    renderer = VideoRenderer(item: item)
case .web:
    renderer = WebRenderer(item: item)
case .scene, .unsupported:
    throw RendererError.unsupportedType(item.type)
}
```

- [ ] **Step 3: 테스트용 웹 배경화면을 만들어 눈으로 확인**

```bash
mkdir -p /tmp/wf-web-test
cat > /tmp/wf-web-test/index.html <<'HTML'
<!doctype html>
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; background: #101020; }
  .orb {
    position: absolute; top: 40%; left: 40%;
    width: 20vw; height: 20vw; border-radius: 50%;
    background: radial-gradient(circle at 30% 30%, #7ad, #248);
    animation: drift 4s ease-in-out infinite alternate;
  }
  @keyframes drift { to { transform: translate(30vw, 20vh) scale(1.4); } }
</style>
<div class="orb"></div>
HTML
cat > /tmp/wf-web-test/project.json <<'JSON'
{"type":"web","file":"index.html","title":"Test Web"}
JSON

./Scripts/bundle.sh
WALLFLOW_ITEM=/tmp/wf-web-test ./build/Wallflow.app/Contents/MacOS/Wallflow
```

확인할 것:
1. 파란 구가 데스크톱 배경에서 움직인다.
2. 데스크톱 아이콘이 위에 보인다.
3. 클릭이 웹뷰에 먹히지 않고 데스크톱으로 통과한다.

종료: `Ctrl-C`

- [ ] **Step 4: 커밋**

```bash
git add Sources/WallflowApp/WebRenderer.swift Sources/WallflowApp/main.swift
git commit -m "$(cat <<'MSG'
feat: 웹 배경화면 렌더러 추가

WKWebView로 HTML/JS 배경화면을 렌더한다.
정지 시 페이지를 언로드하지 않아 상태를 잃지 않는다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 8: 시스템 전력 신호 수집

Task 3의 순수 정책에 실제 시스템 값을 물린다.

**Files:**
- Create: `Sources/WallflowApp/SystemPowerSignals.swift`

**Interfaces:**
- Consumes: `PowerSignals`, `PowerPolicy`, `PlaybackDirective` (Task 3)
- Produces:
  - `final class PowerMonitor` — `init(occlusionProvider: @escaping () -> Bool, onChange: @escaping (PlaybackDirective) -> Void)`, `func start()`, `func stop()`, `func poll()`

- [ ] **Step 1: 구현 작성**

```swift
import AppKit
import IOKit.ps
import WallflowKit

/// 시스템에서 전력 신호를 모아 PowerPolicy에 넣고, 결과가 바뀔 때만 알린다.
final class PowerMonitor {
    private let occlusionProvider: () -> Bool
    private let onChange: (PlaybackDirective) -> Void
    private var timer: Timer?
    private var last: PlaybackDirective?

    /// 가림 상태는 poll 시점에 DisplayManager에 물어본다.
    /// 밀어넣는 방식이면 실제로 가려지는 순간을 놓친다.
    init(
        occlusionProvider: @escaping () -> Bool,
        onChange: @escaping (PlaybackDirective) -> Void
    ) {
        self.occlusionProvider = occlusionProvider
        self.onChange = onChange
    }

    func start() {
        // 전력 상태는 급하게 변하지 않는다. 5초면 충분하고 그 자체로 저렴하다.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let signals = PowerSignals(
            isOccluded: occlusionProvider(),
            isFullscreenAppActive: Self.isFullscreenAppActive(),
            idleSeconds: Self.idleSeconds(),
            isOnBattery: Self.isOnBattery(),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isThermallyPressured: Self.isThermallyPressured()
        )
        let directive = PowerPolicy.directive(for: signals)
        guard directive != last else { return }
        last = directive
        onChange(directive)
    }

    /// 마지막 사용자 입력 이후 경과 시간.
    /// kCGAnyInputEventType은 Swift에서 CGEventType으로 안전하게 만들 수 없으므로
    /// 관심 있는 이벤트들 중 가장 최근 것을 고른다.
    private static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
            .keyDown, .flagsChanged, .scrollWheel,
        ]
        let elapsed = types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        return elapsed.min() ?? 0
    }

    private static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    private static func isThermallyPressured() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// 전체화면 앱이 데스크톱을 덮고 있는지 화면 목록으로 판단한다.
    private static func isFullscreenAppActive() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        guard let mainFrame = NSScreen.main?.frame else { return false }

        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // 메인 화면을 전부 덮는 일반 레이어 윈도우 = 전체화면으로 본다.
            if rect.width >= mainFrame.width && rect.height >= mainFrame.height {
                return true
            }
        }
        return false
    }
}
```

- [ ] **Step 2: 컴파일 확인**

Run: `swift build`
Expected: 성공. 경고가 나오면 고친다.

- [ ] **Step 3: 커밋**

```bash
git add Sources/WallflowApp/SystemPowerSignals.swift
git commit -m "$(cat <<'MSG'
feat: 시스템 전력 신호 수집기 추가

배터리·저전력·발열·무입력·전체화면 상태를 5초마다 모아
PowerPolicy에 넣고 결정이 바뀔 때만 알린다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 9: 디스플레이 관리자, 메뉴바, 앱 조립

지금까지의 조각을 하나의 앱으로 묶는다. 이 태스크가 끝나면 M1이 완료되고 실사용이 시작된다.

**Files:**
- Create: `Sources/WallflowApp/DisplayManager.swift`
- Create: `Sources/WallflowApp/MenuBarController.swift`
- Create: `Sources/WallflowApp/AppCoordinator.swift`
- Modify: `Sources/WallflowApp/main.swift` (프로브를 실제 진입점으로 교체)

**Interfaces:**
- Consumes: `LibraryStore`, `WallpaperItem` (Task 2), `PlaybackDirective` (Task 3), `SteamCmdClient` (Task 4), `WallpaperWindow` (Task 5), `WallpaperRenderer`, `VideoRenderer`, `RendererError` (Task 6), `WebRenderer` (Task 7), `PowerMonitor` (Task 8)
- Produces:
  - `final class DisplayManager` — `init()`, `func rebuildWindows()`, `func assign(_ item: WallpaperItem, toDisplay id: CGDirectDisplayID?) throws`, `func apply(_ directive: PlaybackDirective)`, `func stopAll()`, `var isOccluded: Bool { get }`
  - `final class MenuBarController` — `init(onSelect:onRefresh:onQuit:)`, `func setItems(_ items: [WallpaperItem])`
  - `final class AppCoordinator: NSObject, NSApplicationDelegate`

- [ ] **Step 1: `DisplayManager` 작성**

```swift
import AppKit
import WallflowKit

/// 화면별 배경 윈도우와 렌더러를 소유한다.
/// 디스플레이가 붙고 떨어질 때 윈도우를 재구성하고 배정을 유지한다.
final class DisplayManager {
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var renderers: [CGDirectDisplayID: WallpaperRenderer] = [:]
    /// 어떤 화면에 어떤 배경화면이 배정됐는지. 재구성 후 복원에 쓴다.
    private var assignments: [CGDirectDisplayID: WallpaperItem] = [:]
    private var lastDirective: PlaybackDirective = .playing(fps: PowerPolicy.normalFPS)

    /// 배경 윈도우가 전부 가려졌는지. PowerMonitor가 poll 시점에 읽는다.
    var isOccluded: Bool {
        guard !windows.isEmpty else { return false }
        // 하나라도 보이면 그린다.
        return !windows.values.contains { $0.occlusionState.contains(.visible) }
    }

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensChanged() {
        rebuildWindows()
    }

    func rebuildWindows() {
        let live = Set(NSScreen.screens.compactMap(Self.displayID(of:)))

        // 사라진 화면을 정리한다.
        for id in windows.keys where !live.contains(id) {
            renderers[id]?.stop()
            renderers[id] = nil
            windows[id]?.orderOut(nil)
            windows[id] = nil
        }

        // 새 화면에 윈도우를 만든다.
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: true)
                continue
            }
            let window = WallpaperWindow(screen: screen)
            window.orderFront(nil)
            windows[id] = window

            // 이 화면에 배정이 있었으면 복원한다.
            if let item = assignments[id] {
                try? attach(item, to: id)
            }
        }
    }

    /// 배경화면을 배정한다. displayID가 nil이면 모든 화면에 건다.
    func assign(_ item: WallpaperItem, toDisplay id: CGDirectDisplayID?) throws {
        let targets = id.map { [$0] } ?? Array(windows.keys)
        guard !targets.isEmpty else { return }
        for target in targets {
            assignments[target] = item
            try attach(item, to: target)
        }
    }

    private func attach(_ item: WallpaperItem, to id: CGDirectDisplayID) throws {
        guard let window = windows[id] else { return }

        renderers[id]?.stop()
        renderers[id] = nil

        let renderer: WallpaperRenderer
        switch item.type {
        case .video:
            renderer = VideoRenderer(item: item)
        case .web:
            renderer = WebRenderer(item: item)
        case .scene, .unsupported:
            // M1은 씬을 렌더하지 않는다. preview로 대신한다.
            showPreview(item, in: window)
            throw RendererError.unsupportedType(item.type)
        }

        window.setContent(renderer.makeView())
        try renderer.start()
        renderer.apply(lastDirective)
        renderers[id] = renderer
    }

    /// 렌더가 불가능하거나 실패했을 때의 폴백. 배경이 검게 남지 않게 한다.
    private func showPreview(_ item: WallpaperItem, in window: WallpaperWindow) {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        if let url = item.previewURL, let image = NSImage(contentsOf: url) {
            view.image = image
        }
        window.setContent(view)
    }

    func apply(_ directive: PlaybackDirective) {
        lastDirective = directive
        for renderer in renderers.values {
            renderer.apply(directive)
        }
    }

    func stopAll() {
        for renderer in renderers.values { renderer.stop() }
        renderers.removeAll()
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
```

- [ ] **Step 2: `MenuBarController` 작성**

```swift
import AppKit
import WallflowKit

/// 메뉴바 아이콘과 배경화면 목록 메뉴.
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onSelect: (WallpaperItem) -> Void
    private let onRefresh: () -> Void
    private let onQuit: () -> Void
    private var items: [WallpaperItem] = []

    init(
        onSelect: @escaping (WallpaperItem) -> Void,
        onRefresh: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onRefresh = onRefresh
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Wallflow"
        )
        rebuildMenu()
    }

    func setItems(_ items: [WallpaperItem]) {
        self.items = items
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if items.isEmpty {
            let empty = NSMenuItem(title: "배경화면 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, item) in items.enumerated() {
                let menuItem = NSMenuItem(
                    title: "\(item.title)  (\(item.type.rawValue))",
                    action: #selector(select(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.tag = index
                // M1은 씬을 재생하지 못한다. 고를 수 없게 둔다.
                menuItem.isEnabled = (item.type == .video || item.type == .web)
                menu.addItem(menuItem)
            }
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "라이브러리 새로고침", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect(items[sender.tag])
    }

    @objc private func refresh() { onRefresh() }
    @objc private func quit() { onQuit() }
}
```

- [ ] **Step 3: `AppCoordinator` 작성**

```swift
import AppKit
import WallflowKit

/// 앱 전체를 조립하고 수명을 관리한다.
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let displays = DisplayManager()
    private var menuBar: MenuBarController?
    private var power: PowerMonitor?
    private let library: LibraryStore

    override init() {
        let root = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallflow/Library")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LibraryStore(root: root)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        displays.rebuildWindows()

        let power = PowerMonitor(
            occlusionProvider: { [weak self] in self?.displays.isOccluded ?? false },
            onChange: { [weak self] directive in self?.displays.apply(directive) }
        )
        power.start()
        self.power = power

        menuBar = MenuBarController(
            onSelect: { [weak self] item in self?.select(item) },
            onRefresh: { [weak self] in self?.refreshLibrary() },
            onQuit: { NSApp.terminate(nil) }
        )
        refreshLibrary()
    }

    func applicationWillTerminate(_ notification: Notification) {
        power?.stop()
        displays.stopAll()
    }

    private func refreshLibrary() {
        let items = (try? library.scan()) ?? []
        menuBar?.setItems(items)
    }

    private func select(_ item: WallpaperItem) {
        do {
            try displays.assign(item, toDisplay: nil)
        } catch {
            // 배경화면은 항상 켜져 있어야 한다. 실패해도 앱을 죽이지 않는다.
            FileHandle.standardError.write(Data("배경화면 적용 실패: \(error)\n".utf8))
        }
    }
}
```

- [ ] **Step 4: `main.swift`를 최종 진입점으로 교체**

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 메뉴바 전용. Dock에 뜨지 않는다.
let coordinator = AppCoordinator()
app.delegate = coordinator
app.run()
```

- [ ] **Step 5: 빌드하고 실사용 검증**

```bash
./Scripts/bundle.sh
mkdir -p ~/Library/Application\ Support/Wallflow/Library
cp -R /tmp/wf-video-test ~/Library/Application\ Support/Wallflow/Library/video-test
cp -R /tmp/wf-web-test ~/Library/Application\ Support/Wallflow/Library/web-test
open build/Wallflow.app
```

확인할 것:
1. 메뉴바에 사진 아이콘이 뜬다.
2. 메뉴에 `Test Video (video)`와 `Test Web (web)`이 보인다.
3. 각각을 고르면 데스크톱 배경이 바뀐다.
4. 다른 앱을 전체화면으로 띄우면 재생이 멈춘다 (배터리 소모가 멈추는지는 활성 상태 보기로 확인).
5. 전원을 뽑으면 15fps로 떨어진다.
6. 외부 모니터를 연결/해제해도 앱이 죽지 않는다.
7. 종료 메뉴로 깨끗이 종료된다.

- [ ] **Step 6: 실제 창작마당 콘텐츠로 최종 검증**

`steamcmd`를 설치하고 Video 타입 배경화면을 실제로 받아 본다.

```bash
brew install --cask steamcmd
```

Wallpaper Engine 창작마당에서 **Video 타입** 배경화면 하나를 골라 ID를 확인한 뒤, 앱이 아니라 먼저 손으로 검증한다:

```bash
steamcmd +force_install_dir ~/Library/Application\ Support/Wallflow/steam \
  +login <스팀아이디> \
  +workshop_download_item 431960 <워크샵ID> \
  +quit
```

받아진 폴더를 라이브러리로 복사하고 메뉴에서 고른다. 실패하면 `SteamCmdError`
케이스 중 무엇이었는지 기록한다. Steam Guard로 막히면 스펙 10절대로 수동
임포트를 정상 경로로 삼고, 이 단계는 실패가 아니다.

- [ ] **Step 7: 전체 테스트와 커밋**

Run: `swift test`
Expected: PASS (34개)

```bash
git add Sources/WallflowApp/DisplayManager.swift Sources/WallflowApp/MenuBarController.swift Sources/WallflowApp/AppCoordinator.swift Sources/WallflowApp/main.swift
git commit -m "$(cat <<'MSG'
feat: 디스플레이 관리자와 메뉴바로 M1 완성

화면별 배경 윈도우와 렌더러를 관리하고 디스플레이 변경 시 배정을 복원한다.
메뉴바에서 라이브러리를 고르면 즉시 적용된다.
렌더 불가 항목은 preview 정지 이미지로 폴백해 배경이 검게 남지 않는다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

## M1 완료 조건

- `swift test`가 전부 통과한다 (34개).
- `open build/Wallflow.app` 후 메뉴바에서 Video/Web 배경화면을 골라 상시 사용한다.
- 전체화면 앱을 띄우면 재생이 멈추고, 배터리에서 15fps로 떨어진다.
- 외부 모니터 연결/해제에서 앱이 살아남는다.

## M1이 의도적으로 하지 않는 것

- 씬 재생. 메뉴에 회색으로 표시되고 preview 이미지만 뜬다. M2~M4의 몫이다.
- 앱 내 창작마당 브라우징 UI. M1은 ID를 직접 넣는 수준이면 충분하다.
- 화면별 개별 배정 UI. `DisplayManager.assign(_:toDisplay:)`가 이미 지원하지만
  M1의 메뉴는 모든 화면에 같은 것을 건다.
- 로그인 정보 저장. 매번 입력한다. 키체인 연동은 나중이다.
