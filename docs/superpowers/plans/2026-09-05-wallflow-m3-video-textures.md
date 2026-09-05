# Wallflow M3 — 움직이는 배경 (assets 참조 + 비디오 텍스처)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `.pkg`에 없는 참조를 Wallpaper Engine의 `assets/`에서 해석하고, `.tex` 안에 들어 있는 MP4를 매 프레임 Metal 텍스처로 올려 그린다. 완료 시 보유 씬 `3536506287`과 `3616103296`이 정지 preview가 아니라 3200x1800·3840x2160 애니메이션 배경을 재생한다.

**Architecture:** M2가 만든 `ScenePackage` 계층에 `AssetsStore`를 더해 참조 해석을 2단(`.pkg` → `assets/`)으로 만든다. 비디오는 `WallflowApp`의 `VideoTexture`가 AVFoundation에서 `CVPixelBuffer`를 받아 `CVMetalTextureCache`로 `MTLTexture`를 만들고, 컴포지터가 매 프레임 그것을 그린다.

**Tech Stack:** Swift 6 / Metal / AVFoundation / CoreVideo. 외부 의존성 0개.

**Spec:** `docs/superpowers/specs/2026-09-04-wallflow-design.md`

## Global Constraints

- 최소 지원 macOS 14.0, Apple Silicon. 외부 SwiftPM 의존성 0개.
- `WallflowKit`은 Metal·MetalKit·AppKit·AVFoundation을 import하지 않는다. M2까지 지켜온 경계이고 M3도 유지한다. `Foundation`, `CoreGraphics`, `ImageIO`, `Compression`까지만 허용한다.
- 클린 빌드 경고 0건. 현재 0건이고 그대로 유지한다.
- **파일에서 온 값은 전부 적대적으로 다룬다.** 할당을 결정하게 하지 말고, 무검사 변환이나 맨 산술을 쓰지 말고, 강제 언랩하지 마라. M2에서 이 부류의 Critical 결함이 8건 나왔다.
- 실물 씬은 `~/Downloads/431960`, WE 에셋은 `~/Library/Application Support/Wallflow/Assets`. 테스트는 환경변수 `WALLFLOW_TEST_SCENES`와 `WALLFLOW_TEST_ASSETS`로 경로를 주입받고, 미설정 시 건너뛴다. 설정됐는데 경로가 없으면 **실패**한다.
- M2의 95개 테스트는 계속 통과해야 한다.
- 커밋 메시지는 한국어로 쓰고 본문 끝에 다음 두 줄을 넣는다.
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
  ```

## 착수 전 검증된 사실 (추측 아님)

**비디오 텍스처 경로는 성립한다.** `.tex`에서 꺼낸 MP4(H.264, 3200x1800, 60fps, 15초)를
`AVPlayerItemVideoOutput` → `copyPixelBuffer` → `CVMetalTextureCacheCreateTextureFromImage`로
넘겨 `MTLTexture 3200x1800` 생성에 성공했다. 6초에 59프레임을 받았다.

**함정: `AVPlayerLooper`와 `AVPlayerItemVideoOutput`은 함께 쓸 수 없다.**
루퍼는 템플릿 아이템의 *복사본*을 재생하므로, 템플릿에 붙인 비디오 출력은 프레임을
한 장도 받지 못한다. 실제로 이 구성에서 0프레임을 관측했고, 루퍼를 빼자 59프레임이
나왔다. M1의 `VideoRenderer`는 루퍼를 쓰지만 그것은 `AVPlayerLayer` 경로라 무관하다.
씬 비디오 텍스처는 `AVPlayerItem.didPlayToEndTimeNotification`을 관찰해 0으로 되감는
방식으로 루프한다.

**assets 반입 완료.** `~/Library/Application Support/Wallflow/Assets`, 85MB, 2935개.

**M2 로그가 알려준 것.** `3616103296`의 이미지 레이어들이
`models/workshop/3187908708/solid_instance_model_*.json` 참조로 실패한다. 이는 `.pkg`에
없고 `assets/`에서 해석되어야 한다. `models/util/solidlayer.json`은 셰이더 `flat`에
텍스처가 없는 **단색 레이어**이고, `models/util/composelayer.json`은 텍스처가
`_rt_FullFrameBuffer`인 **렌더 타깃 참조**로 M6의 몫이다.

## File Structure

```
Sources/WallflowKit/ScenePackage/
  AssetsStore.swift        assets/ 디렉터리에서 참조 해석
  ReferenceResolver.swift  .pkg → assets/ 2단 해석
  SceneLayer.swift         (수정) LayerContent에 solidColor, video 추가
  SceneDocument.swift      (수정) 리졸버 사용, solidlayer/composelayer 구분
Sources/WallflowApp/
  VideoTexture.swift       AVFoundation → CVMetalTextureCache → MTLTexture
  MetalCompositor.swift    (수정) 매 프레임 갱신되는 텍스처와 단색 레이어
  SceneRenderer.swift      (수정) 비디오 레이어 구동, 연속 렌더
Tests/WallflowKitTests/
  AssetsStoreTests.swift
  ReferenceResolverTests.swift
  RealScenesTests.swift    (수정) assets 있는 경우의 해석 검증
```

---

### Task 1: `AssetsStore` — assets 디렉터리에서 참조 해석

`.pkg`에 없는 참조를 Wallpaper Engine 에셋 폴더에서 찾는다. 파일 시스템만 다루므로
그래픽 의존성이 없고, 임시 디렉터리로 전부 테스트할 수 있다.

**Files:**
- Create: `Sources/WallflowKit/ScenePackage/AssetsStore.swift`
- Test: `Tests/WallflowKitTests/AssetsStoreTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `struct AssetsStore: Sendable` — `init(root: URL)`, `var root: URL`, `func contains(_ name: String) -> Bool`, `func data(for name: String) throws -> Data`
  - `enum AssetsError: Error, Equatable { case notFound(String); case escapesRoot(String); case unreadable(String) }`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class AssetsStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ body: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(body.utf8).write(to: url)
    }

    func testReadsNestedFile() throws {
        try write("models/util/solidlayer.json", #"{"material":"materials/util/solidlayer.json"}"#)
        let store = AssetsStore(root: root)
        XCTAssertTrue(store.contains("models/util/solidlayer.json"))
        let data = try store.data(for: "models/util/solidlayer.json")
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"material":"materials/util/solidlayer.json"}"#)
    }

    func testMissingFileThrowsNotFound() throws {
        let store = AssetsStore(root: root)
        XCTAssertFalse(store.contains("nope.json"))
        XCTAssertThrowsError(try store.data(for: "nope.json")) { error in
            XCTAssertEqual(error as? AssetsError, .notFound("nope.json"))
        }
    }

    /// 참조 문자열은 씬 파일에서 온다 — 적대적 입력이다.
    /// ../ 를 타고 에셋 폴더 밖을 읽게 두면 안 된다.
    func testPathTraversalIsRejected() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("secret-\(UUID().uuidString).txt")
        try Data("비밀".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let store = AssetsStore(root: root)
        let escape = "../\(outside.lastPathComponent)"
        XCTAssertFalse(store.contains(escape))
        XCTAssertThrowsError(try store.data(for: escape)) { error in
            XCTAssertEqual(error as? AssetsError, .escapesRoot(escape))
        }
    }

    func testDeepTraversalIsRejected() throws {
        let store = AssetsStore(root: root)
        XCTAssertThrowsError(try store.data(for: "models/../../etc/passwd")) { error in
            guard case AssetsError.escapesRoot = error else {
                return XCTFail("expected escapesRoot, got \(error)")
            }
        }
    }

    func testAbsolutePathIsRejected() throws {
        let store = AssetsStore(root: root)
        XCTAssertThrowsError(try store.data(for: "/etc/passwd")) { error in
            guard case AssetsError.escapesRoot = error else {
                return XCTFail("expected escapesRoot, got \(error)")
            }
        }
    }

    func testEmptyNameIsRejected() throws {
        let store = AssetsStore(root: root)
        XCTAssertThrowsError(try store.data(for: ""))
    }

    /// 디렉터리를 파일처럼 읽으려 하면 오류여야 한다.
    func testDirectoryIsNotAFile() throws {
        try write("models/util/x.json", "{}")
        let store = AssetsStore(root: root)
        XCTAssertFalse(store.contains("models/util"))
    }

    func testMissingRootYieldsNotFoundRatherThanCrash() throws {
        let store = AssetsStore(root: root.appendingPathComponent("does-not-exist"))
        XCTAssertFalse(store.contains("anything.json"))
        XCTAssertThrowsError(try store.data(for: "anything.json"))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter AssetsStoreTests`
Expected: FAIL — `cannot find 'AssetsStore' in scope`

- [ ] **Step 3: 구현 작성**

```swift
import Foundation

public enum AssetsError: Error, Equatable {
    case notFound(String)
    case escapesRoot(String)
    case unreadable(String)
}

/// Wallpaper Engine 설치 폴더의 `assets/` 디렉터리를 읽는다.
/// `.pkg`에 들어 있지 않은 표준 셰이더·기본 모델·파티클 텍스처가 여기 있다.
///
/// 참조 문자열은 씬 파일에서 오므로 적대적 입력이다. `../`로 에셋 폴더 밖을
/// 읽지 못하게 경로를 정규화한 뒤 루트 안에 있는지 확인한다.
public struct AssetsStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// 참조 이름을 루트 안의 실제 경로로 바꾼다. 밖으로 나가면 nil.
    private func resolve(_ name: String) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
        let candidate = root.appendingPathComponent(name).standardizedFileURL
        // standardized가 ../를 접은 뒤에도 루트 밑에 있어야 한다.
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    public func contains(_ name: String) -> Bool {
        guard let url = resolve(name) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return !isDir.boolValue
    }

    public func data(for name: String) throws -> Data {
        guard let url = resolve(name) else { throw AssetsError.escapesRoot(name) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw AssetsError.notFound(name)
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AssetsError.unreadable(name)
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AssetsStoreTests`
Expected: PASS (8개)

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/AssetsStore.swift Tests/WallflowKitTests/AssetsStoreTests.swift
git commit -m "$(cat <<'MSG'
feat: assets 디렉터리 참조 해석 추가

.pkg에 없는 표준 모델·셰이더·파티클 텍스처를 Wallpaper Engine 에셋
폴더에서 읽는다.

참조 문자열은 씬 파일에서 오는 적대적 입력이라, 경로를 정규화한 뒤
루트 안에 있는지 확인해 ../로 폴더 밖을 읽지 못하게 막는다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 2: 2단 참조 해석과 레이어 종류 확장

`.pkg`에 없으면 `assets/`에서 찾는다. 그리고 M2가 뭉뚱그려 실패시키던 `solidlayer`와
`composelayer`를 구분한다 — 전자는 단색 레이어이고 후자는 렌더 타깃 참조로 M6의 몫이다.

**Files:**
- Create: `Sources/WallflowKit/ScenePackage/ReferenceResolver.swift`
- Modify: `Sources/WallflowKit/ScenePackage/SceneLayer.swift` (`LayerContent`에 케이스 추가)
- Modify: `Sources/WallflowKit/ScenePackage/SceneDocument.swift` (`load(from:assets:)`)
- Test: `Tests/WallflowKitTests/ReferenceResolverTests.swift`

**Interfaces:**
- Consumes: `PkgReader` (M2 Task 1), `AssetsStore` (Task 1)
- Produces:
  - `struct ReferenceResolver: Sendable` — `init(pkg: PkgReader, assets: AssetsStore?)`, `func data(for name: String) -> Data?`, `func json(for name: String) -> [String: Any]?`
  - `LayerContent`에 추가: `case solidColor(Vec3)`, `case video(texturePath: String)`
  - `SceneDocument.load(from reader: PkgReader, assets: AssetsStore?) throws -> SceneDocument`
    (기존 `load(from:)`은 `assets: nil`로 위임하는 오버로드로 남긴다 — M2 테스트가 쓴다)

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class ReferenceResolverTests: XCTestCase {
    private var assetsRoot: URL!

    override func setUpWithError() throws {
        assetsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: assetsRoot)
    }

    private func writeAsset(_ path: String, _ body: String) throws {
        let url = assetsRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
    }

    func testPkgWinsOverAssets() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("models/x.json", Data(#"{"from":"pkg"}"#.utf8)),
        ]))
        try writeAsset("models/x.json", #"{"from":"assets"}"#)
        let resolver = ReferenceResolver(pkg: pkg, assets: AssetsStore(root: assetsRoot))
        let json = try XCTUnwrap(resolver.json(for: "models/x.json"))
        XCTAssertEqual(json["from"] as? String, "pkg", "패키지 안의 것이 우선이어야 한다")
    }

    func testFallsBackToAssets() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data("{}".utf8)),
        ]))
        try writeAsset("models/util/solidlayer.json", #"{"material":"materials/util/solidlayer.json"}"#)
        let resolver = ReferenceResolver(pkg: pkg, assets: AssetsStore(root: assetsRoot))
        let json = try XCTUnwrap(resolver.json(for: "models/util/solidlayer.json"))
        XCTAssertEqual(json["material"] as? String, "materials/util/solidlayer.json")
    }

    func testMissingEverywhereYieldsNil() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data("{}".utf8)),
        ]))
        let resolver = ReferenceResolver(pkg: pkg, assets: AssetsStore(root: assetsRoot))
        XCTAssertNil(resolver.data(for: "models/nope.json"))
        XCTAssertNil(resolver.json(for: "models/nope.json"))
    }

    /// assets가 없어도(M2와 같은 상태) 동작해야 한다.
    func testWorksWithoutAssets() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("models/x.json", Data(#"{"from":"pkg"}"#.utf8)),
        ]))
        let resolver = ReferenceResolver(pkg: pkg, assets: nil)
        XCTAssertNotNil(resolver.json(for: "models/x.json"))
        XCTAssertNil(resolver.json(for: "models/util/solidlayer.json"))
    }

    func testMalformedJSONYieldsNil() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("models/bad.json", Data("not json".utf8)),
        ]))
        let resolver = ReferenceResolver(pkg: pkg, assets: nil)
        XCTAssertNotNil(resolver.data(for: "models/bad.json"), "바이트는 있다")
        XCTAssertNil(resolver.json(for: "models/bad.json"), "JSON으로는 못 읽는다")
    }
}
```

`SceneDocumentTests`에 다음 세 테스트를 더한다.

```swift
    /// solidlayer는 텍스처가 없는 단색 레이어다. 못 찾은 것이 아니라 원래 없다.
    func testSolidLayerBecomesSolidColor() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Second", "image": "models/util/solidlayer.json",
                          "origin": "50 50 0", "size": "10 10",
                          "color": "1.00000 0.50000 0.25000"}]}
            """,
            extras: [
                "models/util/solidlayer.json":
                    #"{"material":"materials/util/solidlayer.json","solidlayer":true}"#,
                "materials/util/solidlayer.json":
                    #"{"passes":[{"shader":"flat","cullmode":"nocull"}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.layers[0].content, .solidColor(Vec3(x: 1.0, y: 0.5, z: 0.25)))
    }

    /// composelayer는 렌더 타깃을 참조한다. M6의 몫이고, 이유가 구분되어야 한다.
    func testComposeLayerIsUnsupportedForRenderTargetReason() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Green", "image": "models/util/composelayer.json",
                          "origin": "50 50 0", "size": "10 10"}]}
            """,
            extras: [
                "models/util/composelayer.json":
                    #"{"material":"materials/util/composelayer.json","passthrough":true}"#,
                "materials/util/composelayer.json":
                    #"{"passes":[{"shader":"composelayer","textures":["_rt_FullFrameBuffer"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .unsupported(let reason) = doc.layers[0].content else {
            return XCTFail("렌더 타깃 참조는 unsupported여야 한다")
        }
        XCTAssertTrue(reason.contains("렌더 타깃"),
                      "텍스처를 못 찾은 것과 구분되는 이유여야 한다: \(reason)")
    }

    func testSolidColorDefaultsToWhiteWhenColorMissing() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "S", "image": "models/util/solidlayer.json",
                          "origin": "50 50 0", "size": "10 10"}]}
            """,
            extras: [
                "models/util/solidlayer.json": #"{"material":"materials/util/solidlayer.json"}"#,
                "materials/util/solidlayer.json": #"{"passes":[{"shader":"flat"}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.layers[0].content, .solidColor(Vec3(x: 1, y: 1, z: 1)))
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter ReferenceResolverTests`
Expected: FAIL — `cannot find 'ReferenceResolver' in scope`

- [ ] **Step 3: `ReferenceResolver` 작성**

```swift
import Foundation

/// 씬의 참조를 두 단계로 해석한다. 배경화면이 들고 온 것이 먼저이고,
/// 없으면 Wallpaper Engine의 표준 에셋에서 찾는다.
public struct ReferenceResolver: Sendable {
    private let pkg: PkgReader
    private let assets: AssetsStore?

    public init(pkg: PkgReader, assets: AssetsStore?) {
        self.pkg = pkg
        self.assets = assets
    }

    /// 어느 쪽에도 없으면 nil. 참조가 끊긴 것은 정상 상태이므로 던지지 않는다.
    public func data(for name: String) -> Data? {
        if let data = try? pkg.data(for: name) { return data }
        guard let assets, assets.contains(name) else { return nil }
        return try? assets.data(for: name)
    }

    public func json(for name: String) -> [String: Any]? {
        guard let data = data(for: name),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}
```

- [ ] **Step 4: `LayerContent` 확장**

`SceneLayer.swift`의 `LayerContent`를 다음으로 바꾼다.

```swift
public enum LayerContent: Equatable, Sendable {
    /// .pkg 또는 assets 안의 텍스처 경로.
    case image(texturePath: String)
    /// 텍스처가 MP4인 레이어. 매 프레임 갱신된다.
    case video(texturePath: String)
    /// 셰이더 `flat` 기반의 단색 사각형. 텍스처가 없다.
    case solidColor(Vec3)
    /// 그리지 못하는 레이어. 이유를 남겨 나중에 무엇을 만들지 알 수 있게 한다.
    case unsupported(reason: String)
}
```

- [ ] **Step 5: `SceneDocument` 수정**

`load(from:)`을 `load(from:assets:)`로 바꾸고, 기존 시그니처는 위임 오버로드로 남긴다.

```swift
    public static func load(from reader: PkgReader) throws -> SceneDocument {
        try load(from: reader, assets: nil)
    }

    public static func load(
        from reader: PkgReader, assets: AssetsStore?
    ) throws -> SceneDocument {
        let resolver = ReferenceResolver(pkg: reader, assets: assets)
        ...
    }
```

`makeLayer`와 `resolveTexture`가 `PkgReader` 대신 `ReferenceResolver`를 받게 바꾸고,
텍스처 해석 결과를 세 갈래로 나눈다.

```swift
    /// 머티리얼을 읽어 이 레이어가 무엇인지 판정한다.
    private static func resolveContent(
        modelPath: String, object: [String: Any], resolver: ReferenceResolver
    ) -> LayerContent {
        guard let model = resolver.json(for: modelPath),
              let materialPath = model["material"] as? String,
              let material = resolver.json(for: materialPath),
              let passes = material["passes"] as? [[String: Any]],
              let pass = passes.first else {
            return .unsupported(reason: "참조를 따라갈 수 없다: \(modelPath)")
        }

        let textures = pass["textures"] as? [Any]
        // 셰이더 flat은 텍스처 없이 색만 칠한다. 못 찾은 것이 아니라 원래 없다.
        if (pass["shader"] as? String) == "flat" || textures == nil {
            let color = (object["color"] as? String).flatMap(Vec3.parse)
                ?? Vec3(x: 1, y: 1, z: 1)
            return .solidColor(color)
        }
        guard let name = textures?.first as? String else {
            return .unsupported(reason: "머티리얼의 첫 텍스처가 없다: \(materialPath)")
        }
        // _rt_ 접두는 파일이 아니라 렌더 타깃이다. FBO 체인이 필요하다.
        if name.hasPrefix("_rt_") {
            return .unsupported(reason: "렌더 타깃 참조라 M6의 이펙트 체인이 필요하다: \(name)")
        }
        return .image(texturePath: "materials/\(name).tex")
    }
```

`.image`를 `.video`로 승격하는 판정은 **텍스처를 실제로 열어봐야** 알 수 있고
(`TexHeader.isVideo`), `SceneDocument`는 텍스처를 디코딩하지 않는다. 따라서 승격은
렌더러가 한다 — Task 5에서 다룬다. 여기서는 `.image`로 두고, `LayerContent.video`
케이스만 준비해 둔다.

**부수 효과 하나를 알고 있어야 한다.** M3 이후 `SceneRenderer`는 `TexDecoder.decode`의
결과가 `.video`인지 직접 분기하고 `MetalCompositor.makeTexture`에 넘기지 않는다.
따라서 M2에서 추가한 `CompositorError.videoTextureNotSupported`는 **도달 불가가 된다.**
Task 5에서 그 사실을 확인하고, 도달 불가로 남길지 지울지 보고하라. 임의로 지우지 마라 —
`makeTexture`는 공개 진입점이라 다른 호출자가 생길 수 있다.

- [ ] **Step 6: 전체 테스트 통과 확인**

Run: `swift test`
Expected: PASS. M2의 95개 + 새 8개(Task 1) + 5개(리졸버) + 3개(씬) = 111개.
숫자는 직접 확인한다.

- [ ] **Step 7: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/ReferenceResolver.swift Sources/WallflowKit/ScenePackage/SceneLayer.swift Sources/WallflowKit/ScenePackage/SceneDocument.swift Tests/WallflowKitTests/ReferenceResolverTests.swift Tests/WallflowKitTests/SceneDocumentTests.swift
git commit -m "$(cat <<'MSG'
feat: 2단 참조 해석과 단색·렌더타깃 레이어 구분

배경화면이 들고 온 것을 먼저 보고 없으면 표준 에셋에서 찾는다.

M2가 뭉뚱그려 실패시키던 두 경우를 나눈다. solidlayer는 셰이더 flat에
텍스처가 없는 단색 레이어라 그릴 수 있고, composelayer는 _rt_ 접두의
렌더 타깃 참조라 이펙트 체인이 필요하다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 3: `VideoTexture` — MP4를 매 프레임 Metal 텍스처로

`.tex`에서 꺼낸 MP4 바이트를 재생하며 프레임마다 `MTLTexture`를 내놓는다.
GPU와 AVFoundation을 다루므로 `WallflowApp`에 둔다. 단위 테스트는 없고 Task 5에서
실물로 검증한다.

**Files:**
- Create: `Sources/WallflowApp/VideoTexture.swift`

**Interfaces:**
- Consumes: `TextureData.video(Data)` (M2 Task 3)
- Produces:
  - `@MainActor final class VideoTexture` — `init(mp4: Data, device: MTLDevice) throws`, `func currentTexture() -> MTLTexture?`, `func play()`, `func pause()`, `func stop()`, `var isPlaying: Bool`
  - `enum VideoTextureError: Error { case cacheCreationFailed; case temporaryFileFailed(String); case assetNotPlayable }`

- [ ] **Step 1: 구현 작성**

```swift
import AVFoundation
import CoreVideo
import Metal
import Foundation

enum VideoTextureError: Error {
    case cacheCreationFailed
    case temporaryFileFailed(String)
    case assetNotPlayable
}

/// .tex 안에 들어 있던 MP4를 재생하며 프레임마다 Metal 텍스처를 내놓는다.
///
/// 검증된 사실 두 가지가 이 구현을 규정한다.
///
/// 1) AVPlayerItemVideoOutput → copyPixelBuffer → CVMetalTextureCache 경로는 동작한다.
///    3200x1800 H.264에서 MTLTexture 생성을 확인했다.
/// 2) **AVPlayerLooper와 함께 쓸 수 없다.** 루퍼는 템플릿 아이템의 복사본을
///    재생하므로 템플릿에 붙인 출력은 프레임을 한 장도 받지 못한다. 실측에서
///    0프레임이었다. 그래서 루프는 didPlayToEndTime 알림에서 되감아 처리한다.
@MainActor
final class VideoTexture {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let cache: CVMetalTextureCache
    private let temporaryURL: URL
    /// CVMetalTexture를 살려둬야 그것이 감싼 MTLTexture가 유효하다.
    private var retainedFrame: CVMetalTexture?
    private var endObserver: NSObjectProtocol?

    private(set) var isPlaying = false

    init(mp4: Data, device: MTLDevice) throws {
        // AVAsset은 URL을 요구한다. 메모리에서 직접 읽으려면
        // AVAssetResourceLoaderDelegate가 필요한데, M3는 단순한 임시 파일로 간다.
        // 226MB짜리가 있으므로 M4 이후 리소스 로더로 바꿀 여지를 남긴다.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-video-\(UUID().uuidString).mp4")
        do {
            try mp4.write(to: url, options: .atomic)
        } catch {
            throw VideoTextureError.temporaryFileFailed("\(error)")
        }
        temporaryURL = url

        var created: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &created) == kCVReturnSuccess,
              let cache = created else {
            try? FileManager.default.removeItem(at: url)
            throw VideoTextureError.cacheCreationFailed
        }
        self.cache = cache

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)

        player = AVPlayer(playerItem: item)
        player.isMuted = true          // 배경화면은 소리를 내지 않는다
        player.actionAtItemEnd = .none

        // 루퍼를 쓸 수 없으므로 끝에서 되감는다.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            MainActor.assumeIsolated {
                player?.seek(to: .zero)
                player?.play()
            }
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.pause()
        isPlaying = false
        retainedFrame = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    /// 지금 보여줄 프레임. 새 프레임이 없으면 직전 것을 그대로 돌려준다.
    func currentTexture() -> MTLTexture? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else {
            return retainedFrame.flatMap(CVMetalTextureGetTexture)
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var created: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &created)
        guard result == kCVReturnSuccess, let created else {
            return retainedFrame.flatMap(CVMetalTextureGetTexture)
        }
        retainedFrame = created
        return CVMetalTextureGetTexture(created)
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `rm -rf .build && swift build 2>&1 | grep -c warning:`
Expected: `0`

- [ ] **Step 3: 커밋**

```bash
git add Sources/WallflowApp/VideoTexture.swift
git commit -m "$(cat <<'MSG'
feat: MP4 텍스처를 매 프레임 Metal 텍스처로 올리는 경로 추가

.tex 안에 들어 있던 H.264를 재생하며 CVMetalTextureCache로 텍스처를 만든다.

AVPlayerLooper는 쓸 수 없다. 루퍼가 템플릿 아이템의 복사본을 재생해서
템플릿에 붙인 비디오 출력이 프레임을 한 장도 받지 못한다(실측 0프레임).
대신 didPlayToEndTime에서 되감아 루프한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 4: 컴포지터에 동적 텍스처와 단색 레이어

M2의 컴포지터는 레이어를 `(QuadInstance, MTLTexture)` 쌍으로 한 번 받고 고정한다.
비디오는 매 프레임 텍스처가 바뀌고, 단색 레이어는 텍스처가 아예 없다.

**Files:**
- Modify: `Sources/WallflowApp/SceneShaders.swift` (단색 프래그먼트 셰이더 추가)
- Modify: `Sources/WallflowApp/MetalCompositor.swift`

**Interfaces:**
- Consumes: `QuadInstance`, `CompositorError` (M2 Task 6)
- Produces:
  - `enum LayerSource` — `case fixed(MTLTexture)`, `case dynamic(() -> MTLTexture?)`, `case solid(SIMD4<Float>)`
  - `MetalCompositor.setLayers(_ layers: [(QuadInstance, LayerSource)])`

- [ ] **Step 1: 단색 셰이더 추가**

`SceneShaders.source`의 끝에 프래그먼트 함수를 하나 더한다.

```metal
    fragment float4 solid_fragment(
        VertexOut in [[stage_in]],
        constant float4 &color [[buffer(0)]]
    ) {
        return color;
    }
```

- [ ] **Step 2: `LayerSource` 도입과 파이프라인 분리**

```swift
/// 레이어가 무엇으로 칠해지는지.
enum LayerSource {
    /// 한 번 만들어 두고 바뀌지 않는 텍스처.
    case fixed(MTLTexture)
    /// 매 프레임 물어보는 텍스처. 비디오가 이 경우다.
    case dynamic(() -> MTLTexture?)
    /// 텍스처 없이 단색으로 칠한다. 셰이더 flat 레이어가 이 경우다.
    case solid(SIMD4<Float>)
}
```

`MetalCompositor`에 단색용 파이프라인을 하나 더 만든다 (`quad_vertex` + `solid_fragment`,
같은 정점 디스크립터와 블렌딩). `draw(in:)`은 레이어 종류에 따라 파이프라인을 바꿔
건다.

```swift
        for (quad, source) in layers {
            var uniforms = QuadUniforms(
                origin: quad.origin, size: quad.size, projection: projection)

            switch source {
            case .solid(var color):
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            case .fixed(let texture):
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
            case .dynamic(let provider):
                // 프레임이 아직 없으면 이 레이어만 건너뛴다. 씬 전체를 멈추지 않는다.
                guard let texture = provider() else { continue }
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
```

`setLayers`의 시그니처가 `[(QuadInstance, LayerSource)]`로 바뀐다.

- [ ] **Step 3: 빌드 확인**

Run: `rm -rf .build && swift build 2>&1 | grep -c warning:`
Expected: `0`

- [ ] **Step 4: 커밋**

```bash
git add Sources/WallflowApp/SceneShaders.swift Sources/WallflowApp/MetalCompositor.swift
git commit -m "$(cat <<'MSG'
feat: 컴포지터에 동적 텍스처와 단색 레이어 지원

레이어를 고정 텍스처·매 프레임 텍스처·단색 셋으로 나눈다.
비디오는 프레임이 아직 없으면 그 레이어만 건너뛰고 씬 전체는 계속 그린다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 5: `SceneRenderer` 연결과 실사용 검증

에셋 폴더를 찾아 리졸버에 넘기고, 비디오 텍스처를 만들어 구동하며, 정적 씬이 아닐
때는 연속 렌더로 전환한다. M3의 완료가 여기서 판정된다.

**Files:**
- Modify: `Sources/WallflowApp/SceneRenderer.swift`
- Modify: `Tests/WallflowKitTests/RealScenesTests.swift`

**Interfaces:**
- Consumes: `AssetsStore`, `ReferenceResolver` (Task 1~2), `VideoTexture` (Task 3), `LayerSource` (Task 4)
- Produces: 없음 (통합 지점)

- [ ] **Step 1: 에셋 폴더 위치를 한 곳에 둔다**

`SceneRenderer`에 정적 프로퍼티로 둔다. M5 이후 다른 렌더러도 쓴다.

```swift
    /// Wallpaper Engine의 표준 에셋. 사용자가 윈도우 설치 폴더에서 반입한다.
    /// 없으면 nil이고, 그 경우 표준 모델을 참조하는 레이어만 unsupported가 된다.
    static func defaultAssetsStore() -> AssetsStore? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallflow/Assets")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return AssetsStore(root: url)
    }
```

- [ ] **Step 2: 비디오를 담을 저장 프로퍼티를 더한다**

`SceneRenderer`에는 지금 이 프로퍼티가 없다. 렌더러가 살아 있는 동안 비디오도
살아 있어야 하므로 강한 참조로 들고 있는다. `.dynamic` 클로저는 `[weak video]`로
잡으므로 순환 참조가 생기지 않는다.

```swift
    /// 이 씬이 재생 중인 비디오 텍스처들. 렌더러가 소유한다.
    private var videos: [VideoTexture] = []
```

- [ ] **Step 3: `start()`에서 비디오 레이어를 구동한다**

`SceneDocument.load(from:assets:)`로 바꾸고, `.image` 레이어의 텍스처를 디코딩할 때
`TextureData.video`가 나오면 `VideoTexture`를 만들어 `.dynamic` 소스로 넣는다.
`.solidColor`는 `.solid`로 넣는다.

```swift
        var videos: [VideoTexture] = []
        var drawable: [(QuadInstance, LayerSource)] = []

        for layer in document.layers where layer.visible {
            let quad = QuadInstance(
                origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                size: SIMD2(Float(layer.size.x), Float(layer.size.y)))

            switch layer.content {
            case .solidColor(let c):
                drawable.append((quad, .solid(SIMD4(Float(c.x), Float(c.y), Float(c.z), 1))))

            case .image(let path), .video(let path):
                guard let raw = resolver.data(for: path) else {
                    skipped.append("\(layer.name): 텍스처를 찾을 수 없다: \(path)")
                    continue
                }
                do {
                    let decoded = try TexDecoder.decode(raw)
                    if case .video(let mp4) = decoded {
                        let video = try VideoTexture(mp4: mp4, device: device)
                        video.play()
                        videos.append(video)
                        drawable.append((quad, .dynamic { [weak video] in video?.currentTexture() }))
                    } else {
                        let texture = try compositor.makeTexture(from: decoded)
                        drawable.append((quad, .fixed(texture)))
                    }
                } catch {
                    skipped.append("\(layer.name): 텍스처 로드 실패 \(error)")
                }

            case .unsupported(let reason):
                skipped.append("\(layer.name): \(reason)")
            }
        }
        self.videos = videos
```

- [ ] **Step 4: 비디오가 있으면 연속 렌더로 전환한다**

M2의 씬은 정적이라 `isPaused = true`, `enableSetNeedsDisplay = true`였다. 비디오가
있으면 매 프레임 그려야 한다.

```swift
        if !videos.isEmpty {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            // 전력 정책이 30fps를 지시한다. 60fps 소스라도 그 이상 그리지 않는다.
            view.preferredFramesPerSecond = PowerPolicy.normalFPS
        }
```

`apply(_:)`도 비디오가 있을 때는 달라진다. 정적 씬은 `.paused`가 no-op이지만
(M2에서 검은 화면을 막으려고 그렇게 했다), 비디오는 실제로 멈춰야 전력이 절약된다.
**단 뷰를 숨기지는 않는다** — 마지막 프레임이 화면에 남아야 한다.

```swift
    func apply(_ directive: PlaybackDirective) {
        switch directive {
        case .paused:
            // 뷰를 숨기지 않는다. 마지막 프레임이 남아야 검은 화면이 되지 않는다.
            // 정적 씬은 애초에 그릴 것이 없어 이 분기가 아무 일도 하지 않는다.
            for video in videos { video.pause() }
            view?.isPaused = true
        case .playing(let fps):
            view?.isHidden = false
            for video in videos { video.play() }
            if !videos.isEmpty {
                view?.isPaused = false
                view?.preferredFramesPerSecond = fps
            }
            view?.needsDisplay = true
        }
    }
```

`stop()`에서 비디오를 정리한다.

```swift
    func stop() {
        for video in videos { video.stop() }
        videos.removeAll()
        compositor = nil
        view?.delegate = nil
    }
```

- [ ] **Step 5: 실물 회귀 테스트 보강**

`RealScenesTests.swift`에 다음을 더한다. 에셋 경로는 `WALLFLOW_TEST_ASSETS`로 받고,
미설정이면 건너뛴다. 설정됐는데 경로가 없으면 실패한다 — M2의 씬 경로와 같은 규칙이다.

```swift
    private func assetsStore() throws -> AssetsStore? {
        guard let path = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"] else {
            return nil
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            XCTFail("WALLFLOW_TEST_ASSETS가 가리키는 경로가 없다: \(url.path)")
            throw MissingSceneError()
        }
        return AssetsStore(root: url)
    }

    /// assets가 있으면 M2에서 참조가 끊겼던 레이어들이 해석되어야 한다.
    func testAssetsResolveSolidInstanceModels() throws {
        guard let reader = try scenePkg("3616103296") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }

        let without = try SceneDocument.load(from: reader, assets: nil)
        let with = try SceneDocument.load(from: reader, assets: assets)

        func unsupportedCount(_ doc: SceneDocument) -> Int {
            doc.layers.filter { if case .unsupported = $0.content { return true } else { return false } }.count
        }
        XCTAssertLessThan(unsupportedCount(with), unsupportedCount(without),
                          "assets를 주면 해석되는 레이어가 늘어야 한다")
    }

    /// composelayer는 assets가 있어도 렌더 타깃이라 그릴 수 없다. 이유가 구분되어야 한다.
    func testComposeLayerReportsRenderTargetEvenWithAssets() throws {
        guard let reader = try scenePkg("3552439823") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let doc = try SceneDocument.load(from: reader, assets: assets)
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "Audio Visualizer" })
        guard case .unsupported(let reason) = layer.content else {
            return XCTFail("렌더 타깃 레이어는 여전히 unsupported여야 한다")
        }
        XCTAssertTrue(reason.contains("렌더 타깃"), "이유: \(reason)")
    }
```

- [ ] **Step 6: 빌드와 테스트**

Run: `rm -rf .build && swift build 2>&1 | grep -c warning:` → `0`
Run: `WALLFLOW_TEST_SCENES=~/Downloads/431960 WALLFLOW_TEST_ASSETS=~/Library/Application\ Support/Wallflow/Assets swift test`
Expected: 전부 통과. 개수는 직접 확인한다.
Run: `swift test` (환경변수 없이) → 실물 테스트는 건너뛰고 나머지 통과.

- [ ] **Step 7: 실사용 검증**

```bash
./Scripts/bundle.sh
rm -f /tmp/wf-m3.log
./build/Wallflow.app/Contents/MacOS/Wallflow > /dev/null 2> /tmp/wf-m3.log &
```

메뉴에서 **`Chisa Wuthering Waves`** (3616103296)를 고른다. 3840x2160 MP4가 배경이다.

확인할 것:
1. 배경이 **움직인다.** 정지 이미지가 아니다.
2. `/tmp/wf-m3.log`에 `배경화면 적용 실패`가 **없다.** 있으면 폴백한 것이다.
3. 건너뛴 레이어 목록에서 `videoTextureNotSupported`가 **사라졌다.**
4. `solid_instance_model` 참조 실패가 **사라졌거나 줄었다.**
5. 데스크톱 아이콘이 배경 위에 보인다.

그다음 **`【鸣潮】「Wuthering Waves 弗洛洛Phrolova」`** (3536506287)도 고른다.
M2에서 `noDrawableLayers`로 폴백하던 씬이다. 이제 3200x1800 MP4가 재생되어야 하고
`배경화면 적용 실패`가 나오면 안 된다.

전력 정책도 확인한다. 전체화면 앱을 띄웠다가 돌아왔을 때 비디오가 멈췄다 재개되고,
**멈춘 동안 화면이 검게 되지 않아야 한다** (마지막 프레임이 남는다).

종료: 메뉴에서 종료.

- [ ] **Step 8: 커밋**

```bash
git add Sources/WallflowApp/SceneRenderer.swift Tests/WallflowKitTests/RealScenesTests.swift
git commit -m "$(cat <<'MSG'
feat: 비디오 텍스처를 씬 렌더러에 연결해 M3 완성

.tex 안의 MP4를 재생해 매 프레임 그린다. 비디오가 있는 씬은 연속 렌더로
전환하고 전력 정책의 프레임레이트를 따른다.

일시정지는 재생만 멈추고 뷰는 숨기지 않는다. 마지막 프레임이 남아야
자리를 비운 사이 배경이 검게 되지 않는다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

## M3 완료 조건

- `swift test`가 환경변수 유무 양쪽에서 통과한다. 클린 빌드 경고 0건.
- `3616103296`과 `3536506287`이 **움직이는 배경**을 재생한다. 폴백이 아니다.
- 건너뛴 레이어 로그에서 `videoTextureNotSupported`가 사라진다.
- 전체화면 앱 전환 시 비디오가 멈췄다 재개되고, 멈춘 동안 검은 화면이 되지 않는다.

## M3가 의도적으로 하지 않는 것

- 파티클 — M4.
- 스크립팅과 텍스트/시계 — M5. 텍스트 레이어 13개 중 12개가 스크립트라 함께 가야 한다.
- 커스텀 셰이더, FBO 이펙트 체인(`_rt_FullFrameBuffer`), 오디오 반응 — M6.
- 비디오를 메모리에서 직접 재생하기. `AVAssetResourceLoaderDelegate`가 필요하고,
  M3는 임시 파일로 간다. 226MB짜리가 둘 있으므로 M4 이후 개선 여지로 남긴다.
- `start()`의 동기 로딩. M2에서 이미 기록한 항목이고 비디오가 더해지면 더 커진다.
  별도로 다룬다.
