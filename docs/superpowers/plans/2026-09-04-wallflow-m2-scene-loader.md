# Wallflow M2 — 씬 로더와 2D 컴포지터 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wallpaper Engine `scene.pkg`를 열어 텍스처를 디코딩하고, 씬의 이미지 레이어를 Metal로 화면에 그린다. 완료 시 보유 씬 `3714517753`의 배경 이미지가 올바른 크기와 위치로 데스크톱에 뜬다.

**Architecture:** 파싱 전부를 `WallflowKit`의 `ScenePackage` 계층에 가둔다. 이 계층은 Metal도 AppKit도 import하지 않으므로 GPU 없이 단위 테스트할 수 있고, 리버스 엔지니어링의 불확실성이 전부 여기 갇힌다. 렌더링은 `WallflowApp`의 `SceneRenderer`가 M1의 `WallpaperRenderer` 프로토콜을 구현해 맡는다.

**Tech Stack:** Swift 6 / Metal / MetalKit / ImageIO / Compression(LZ4) / AVFoundation. 외부 의존성 0개.

**Spec:** `docs/superpowers/specs/2026-09-04-wallflow-design.md`

## Global Constraints

- 최소 지원 macOS 14.0, Apple Silicon. `Package.swift`는 이미 `.macOS(.v14)`.
- 외부 SwiftPM 의존성 0개. LZ4는 macOS `Compression` 프레임워크의 `COMPRESSION_LZ4_RAW`를 쓴다.
- `WallflowKit`은 Metal·AppKit·MetalKit을 import하지 않는다. M1의 Task 3 리뷰가 이 경계를 확인했고 M2도 유지한다. `Foundation`, `CoreGraphics`, `ImageIO`, `Compression`까지만 허용한다.
- Metal 셰이더는 `.metal` 파일이 아니라 `device.makeLibrary(source:)`로 런타임 컴파일한다. SwiftPM 리소스 번들 설정을 피하고, M4에서 사용자 셰이더를 같은 경로로 처리하게 된다.
- 실물 씬은 `~/Downloads/431960`에 있다. 용량이 커서 저장소에 커밋하지 않는다. 테스트는 환경변수 `WALLFLOW_TEST_SCENES`로 경로를 주입받고, 미설정 시 해당 테스트를 건너뛴다.
- M1의 35개 테스트는 계속 통과해야 한다.
- 커밋 메시지는 한국어로 쓰고 본문 끝에 다음 두 줄을 넣는다.
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
  ```

## 스펙과의 의도적 차이

스펙 9절의 M2는 "표준 이미지 셰이더"를 포함한다고 적었는데, 그것은 Wallpaper Engine의
`genericimage4`를 뜻하고 아직 반입되지 않은 `assets/`에 있다. 이 계획은 대신 텍스처
쿼드를 그리는 최소 MSL 셰이더를 직접 쓴다. 결과는 이미지 레이어에 한해 동일하고,
**M2가 `assets/` 반입을 기다리지 않아도 된다.** WE 셰이더 수용은 M4로 미룬다.

## 검증된 포맷 (추측이 아니라 실측)

**`.pkg` 컨테이너**
```
int32 len + "PKGV00NN"        버전 문자열
int32 entryCount
엔트리마다: int32 len + 이름, int32 offset, int32 length
그 뒤부터 블롭. offset은 이 지점 기준 상대값.
```

**`.tex` 컨테이너** — 밉맵 체인까지 파싱해 잔여 바이트 0으로 검증했다.
```
"TEXV0005\0" "TEXI0001\0"
int32 format, flags, texWidth, texHeight, imgWidth, imgHeight, color
"TEXB0003\0" 또는 "TEXB0004\0"
int32 imageCount, freeImageFormat, [0004면 int32 하나 더], mipmapCount
밉맵마다: int32 width, height, isLZ4, decompressedSize, dataSize + dataSize 바이트
```
- `freeImageFormat`: `2`=JPEG, `13`=PNG, `-1`=원시 픽셀 또는 비디오
- `flags & 32` != 0: **비디오 텍스처. 데이터가 통째로 MP4(H.264) 파일**
- `format`: `0`=RGBA8888, `9`=R8(단일 채널 마스크)
- `isLZ4` == 1: LZ4 블록 압축, `decompressedSize`가 원본 크기

**실측 표본**

| 텍스처 | flags | format | freeFmt | 내용 |
|---|---|---|---|---|
| `HFRvNK5aIAA7Q24` | 2 | 0 | 2 | JPEG, 밉맵 4단, 2048x1164 |
| `弗洛洛SYziyv1` | 34 | 0 | -1 | MP4 226MB, 3200x1800 |
| `Utool-2025...` | 35 | 0 | -1 | MP4 226MB, 3840x2160 |
| `waterripplenormal` | 0 | 0 | -1 | RAW RGBA + LZ4, 256x256, 원본 262144 |
| `waterripple_mask` | 2 | 9 | -1 | RAW R8 + LZ4, 1600x900, 원본 1440000 |

**씬 그래프** — M2 목표 씬 `3714517753`
```json
"general": { "orthogonalprojection": { "width": 2048, "height": 1164 },
             "clearcolor": "0.70000 0.70000 0.70000", "clearenabled": true }
"objects": [{ "id": 33, "name": "HFRvNK5aIAA7Q24",
              "image": "models/HFRvNK5aIAA7Q24.json",
              "origin": "1024.00000 582.00000 0.00000",
              "size": "2048.00000 1164.00000" }]
```
참조 사슬: `object.image` → `models/X.json`의 `material` → `materials/Y.json`의
`passes[0].textures[0]` → `materials/<그 이름>.tex`.

`origin`은 오브젝트의 **중심**이고 직교 공간 좌표다. 위 씬은 원점이
(1024, 582) = 2048x1164 공간의 정중앙이다.

## File Structure

```
Sources/WallflowKit/ScenePackage/
  PkgReader.swift          .pkg 컨테이너 → 이름별 바이트
  TexHeader.swift          .tex 헤더 파싱 (순수 구조체)
  TexDecoder.swift         .tex → 디코딩된 텍스처 표현
  TextureData.swift        디코딩 결과 타입
  SceneDocument.swift      scene.json + models + materials → 해석된 레이어 목록
  SceneLayer.swift         레이어 모델
Sources/WallflowApp/
  SceneRenderer.swift      WallpaperRenderer 구현
  MetalCompositor.swift    직교 투영 + 텍스처 쿼드 렌더러
  SceneShaders.swift       런타임 컴파일용 MSL 소스 문자열
Tests/WallflowKitTests/
  PkgReaderTests.swift
  TexDecoderTests.swift
  SceneDocumentTests.swift
  RealScenesTests.swift    실물 씬 대상. WALLFLOW_TEST_SCENES 없으면 건너뜀
```

---

### Task 1: `.pkg` 컨테이너 리더

**Files:**
- Create: `Sources/WallflowKit/ScenePackage/PkgReader.swift`
- Create: `Tests/WallflowKitTests/Fixtures.swift` (이후 태스크가 함께 쓰는 픽스처 빌더)
- Test: `Tests/WallflowKitTests/PkgReaderTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `struct PkgReader` — `init(data: Data) throws`, `var version: String`, `var names: [String]`, `func data(for name: String) throws -> Data`, `func contains(_ name: String) -> Bool`
  - `enum PkgError: Error, Equatable { case truncated; case badVersionString; case entryOutOfBounds(String); case missingEntry(String) }`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class PkgReaderTests: XCTestCase {
    func testReadsVersionAndEntryNames() throws {
        let pkg = buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data("{}".utf8)),
            ("materials/a.tex", Data([1, 2, 3])),
        ])
        let reader = try PkgReader(data: pkg)
        XCTAssertEqual(reader.version, "PKGV0023")
        XCTAssertEqual(Set(reader.names), ["scene.json", "materials/a.tex"])
    }

    func testReturnsEntryBytesExactly() throws {
        let payload = Data([9, 8, 7, 6, 5])
        let pkg = buildPkg(version: "PKGV0022", entries: [
            ("first", Data("hello".utf8)),
            ("second", payload),
        ])
        let reader = try PkgReader(data: pkg)
        XCTAssertEqual(try reader.data(for: "second"), payload)
        XCTAssertEqual(try reader.data(for: "first"), Data("hello".utf8))
    }

    func testContainsReportsMembership() throws {
        let pkg = buildPkg(version: "PKGV0023", entries: [("only", Data([0]))])
        let reader = try PkgReader(data: pkg)
        XCTAssertTrue(reader.contains("only"))
        XCTAssertFalse(reader.contains("absent"))
    }

    func testMissingEntryThrows() throws {
        let pkg = buildPkg(version: "PKGV0023", entries: [("only", Data([0]))])
        let reader = try PkgReader(data: pkg)
        XCTAssertThrowsError(try reader.data(for: "nope")) { error in
            XCTAssertEqual(error as? PkgError, .missingEntry("nope"))
        }
    }

    func testTruncatedHeaderThrows() {
        XCTAssertThrowsError(try PkgReader(data: Data([1, 2]))) { error in
            XCTAssertEqual(error as? PkgError, .truncated)
        }
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try PkgReader(data: Data())) { error in
            XCTAssertEqual(error as? PkgError, .truncated)
        }
    }

    /// 손상된 파일이 길이를 거짓말할 수 있다. 범위를 넘으면 크래시가 아니라 오류여야 한다.
    func testEntryClaimingBytesBeyondEndThrows() {
        func i32(_ v: Int32) -> Data {
            var x = v
            return withUnsafeBytes(of: &x) { Data($0) }
        }
        var pkg = i32(8) + Data("PKGV0023".utf8)
        pkg += i32(1)
        pkg += i32(4) + Data("evil".utf8)
        pkg += i32(0)
        pkg += i32(1_000_000)   // 실제로는 그만큼 없다
        XCTAssertThrowsError(try PkgReader(data: pkg)) { error in
            XCTAssertEqual(error as? PkgError, .entryOutOfBounds("evil"))
        }
    }

    func testNegativeLengthThrows() {
        func i32(_ v: Int32) -> Data {
            var x = v
            return withUnsafeBytes(of: &x) { Data($0) }
        }
        var pkg = i32(8) + Data("PKGV0023".utf8)
        pkg += i32(1)
        pkg += i32(4) + Data("evil".utf8)
        pkg += i32(0)
        pkg += i32(-5)
        XCTAssertThrowsError(try PkgReader(data: pkg))
    }
}
```

`Tests/WallflowKitTests/Fixtures.swift`에 빌더를 둔다. Task 2~4가 함께 쓴다.

```swift
import Foundation

func le32(_ v: Int32) -> Data {
    var x = v
    return withUnsafeBytes(of: &x) { Data($0) }
}

/// 길이 접두 문자열. .pkg가 쓰는 형식이다.
func lengthPrefixed(_ s: String) -> Data {
    le32(Int32(s.utf8.count)) + Data(s.utf8)
}

/// 실물과 같은 레이아웃으로 최소 .pkg를 만든다.
func buildPkg(version: String, entries: [(String, Data)]) -> Data {
    var header = lengthPrefixed(version)
    header += le32(Int32(entries.count))
    var offset: Int32 = 0
    var blobs = Data()
    for (name, payload) in entries {
        header += lengthPrefixed(name)
        header += le32(offset)
        header += le32(Int32(payload.count))
        offset += Int32(payload.count)
        blobs += payload
    }
    return header + blobs
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter PkgReaderTests`
Expected: FAIL — `cannot find 'PkgReader' in scope`

- [ ] **Step 3: 구현 작성**

```swift
import Foundation

public enum PkgError: Error, Equatable {
    case truncated
    case badVersionString
    case entryOutOfBounds(String)
    case missingEntry(String)
}

/// Wallpaper Engine의 scene.pkg 컨테이너를 읽는다.
///
/// 레이아웃 (실물 파일에서 확인, 잔여 바이트 0):
///   int32 길이 + "PKGV00NN"
///   int32 엔트리 수
///   엔트리마다: int32 길이 + 이름, int32 오프셋, int32 길이
///   그 뒤부터 블롭. 오프셋은 블롭 시작 기준 상대값.
public struct PkgReader: Sendable {
    private let data: Data
    private let entries: [String: Range<Int>]

    public let version: String

    public var names: [String] { Array(entries.keys) }

    public init(data: Data) throws {
        self.data = data
        var cursor = Cursor(data)

        version = try cursor.readString()
        guard version.hasPrefix("PKGV") else { throw PkgError.badVersionString }

        let count = try cursor.readInt32()
        guard count >= 0 else { throw PkgError.truncated }

        var raw: [(String, Int, Int)] = []
        raw.reserveCapacity(Int(count))
        for _ in 0..<count {
            let name = try cursor.readString()
            let offset = Int(try cursor.readInt32())
            let length = Int(try cursor.readInt32())
            raw.append((name, offset, length))
        }

        // 남은 전부가 블롭이다.
        let base = cursor.offset
        var table: [String: Range<Int>] = [:]
        for (name, offset, length) in raw {
            guard offset >= 0, length >= 0 else { throw PkgError.entryOutOfBounds(name) }
            let start = base + offset
            let end = start + length
            guard start <= data.count, end <= data.count, start <= end else {
                throw PkgError.entryOutOfBounds(name)
            }
            table[name] = start..<end
        }
        entries = table
    }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func data(for name: String) throws -> Data {
        guard let range = entries[name] else { throw PkgError.missingEntry(name) }
        // 호출자가 슬라이스를 넘기면 startIndex가 0이 아니다. 항상 기준을 더한다.
        let lower = data.startIndex + range.lowerBound
        let upper = data.startIndex + range.upperBound
        return data.subdata(in: lower..<upper)
    }
}

/// 범위를 벗어나면 크래시 대신 오류를 던지는 리틀엔디언 커서.
/// 손상된 배경화면 파일이 앱을 죽여서는 안 된다.
struct Cursor {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func readInt32() throws -> Int32 {
        guard offset + 4 <= data.count else { throw PkgError.truncated }
        defer { offset += 4 }
        let start = data.startIndex + offset
        return data[start..<(start + 4)].withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self).littleEndian
        }
    }

    mutating func readString() throws -> String {
        let length = Int(try readInt32())
        guard length >= 0, offset + length <= data.count else { throw PkgError.truncated }
        defer { offset += length }
        let start = data.startIndex + offset
        return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else { throw PkgError.truncated }
        offset += count
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw PkgError.truncated }
        defer { offset += count }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + count))
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter PkgReaderTests`
Expected: PASS (8개)

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/PkgReader.swift Tests/WallflowKitTests/PkgReaderTests.swift Tests/WallflowKitTests/Fixtures.swift
git commit -m "$(cat <<'MSG'
feat: scene.pkg 컨테이너 리더 추가

이름별로 엔트리 바이트를 꺼낸다. 손상된 파일이 길이를 거짓말해도
크래시 대신 오류를 던지도록 커서가 범위를 검사한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 2: `.tex` 헤더 파서

디코딩과 헤더 해석을 분리한다. 헤더만으로 텍스처의 정체(JPEG인지 MP4인지)를 알 수 있어야 하고, 그 판단은 픽셀 없이 테스트할 수 있어야 한다.

**Files:**
- Create: `Sources/WallflowKit/ScenePackage/TexHeader.swift`
- Modify: `Tests/WallflowKitTests/Fixtures.swift` (`buildTex` 추가)
- Test: `Tests/WallflowKitTests/TexHeaderTests.swift`

**Interfaces:**
- Consumes: `Cursor` (Task 1)
- Produces:
  - `enum TexPayloadKind: Equatable, Sendable { case jpeg, png, rawPixels, video }`
  - `enum TexPixelFormat: Int32, Sendable { case rgba8888 = 0, r8 = 9 }`
  - `struct TexMipmap: Equatable, Sendable` — `width: Int`, `height: Int`, `isLZ4: Bool`, `decompressedSize: Int`, `range: Range<Int>`
  - `struct TexHeader: Equatable, Sendable` — `version: String`, `format: Int32`, `flags: Int32`, `textureWidth/Height: Int`, `imageWidth/Height: Int`, `freeImageFormat: Int32`, `mipmaps: [TexMipmap]`, `var kind: TexPayloadKind`, `var pixelFormat: TexPixelFormat?`, `var isVideo: Bool`; `static func parse(_ data: Data) throws -> TexHeader`
  - `enum TexError: Error, Equatable { case badMagic(String); case unsupportedContainer(String); case truncated; case noMipmaps }`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class TexHeaderTests: XCTestCase {
    func testParsesTEXB0004WithJPEGPayload() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 100)
        let tex = buildTex(mips: [(2048, 1164, 0, 0, jpeg)])
        let header = try TexHeader.parse(tex)

        XCTAssertEqual(header.version, "TEXV0005")
        XCTAssertEqual(header.imageWidth, 2048)
        XCTAssertEqual(header.imageHeight, 1164)
        XCTAssertEqual(header.freeImageFormat, 2)
        XCTAssertEqual(header.kind, .jpeg)
        XCTAssertFalse(header.isVideo)
        XCTAssertEqual(header.mipmaps.count, 1)
        XCTAssertEqual(header.mipmaps[0].width, 2048)
    }

    /// TEXB0003은 int32 하나가 적다. 이걸 틀리면 이후 전부가 어긋난다.
    func testParsesTEXB0003WhichHasOneFewerField() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0, count: 40)
        let tex = buildTex(
            container: "TEXB0003", freeImageFormat: 13,
            size: (2048, 512), mips: [(1920, 313, 0, 0, png)]
        )
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .png)
        XCTAssertEqual(header.mipmaps.count, 1)
        XCTAssertEqual(header.mipmaps[0].width, 1920)
        XCTAssertEqual(header.mipmaps[0].height, 313)
    }

    /// flags 비트 32가 비디오 텍스처를 뜻한다. 실물 226MB 텍스처 두 개가 이 경우였다.
    func testFlagBit32MeansVideo() throws {
        let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 40)
        let tex = buildTex(
            flags: 34, freeImageFormat: -1,
            size: (3200, 1800), mips: [(3200, 1800, 0, 0, mp4)]
        )
        let header = try TexHeader.parse(tex)
        XCTAssertTrue(header.isVideo)
        XCTAssertEqual(header.kind, .video)
    }

    func testFlag35IsAlsoVideo() throws {
        let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)
        let tex = buildTex(flags: 35, freeImageFormat: -1, mips: [(3840, 2160, 0, 0, mp4)])
        XCTAssertTrue(try TexHeader.parse(tex).isVideo)
    }

    func testFreeFormatMinusOneWithoutVideoFlagIsRawPixels() throws {
        let raw = Data(repeating: 7, count: 64)
        let tex = buildTex(flags: 0, freeImageFormat: -1, size: (256, 256),
                          mips: [(256, 256, 1, 262144, raw)])
        let header = try TexHeader.parse(tex)
        XCTAssertEqual(header.kind, .rawPixels)
        XCTAssertFalse(header.isVideo)
        XCTAssertTrue(header.mipmaps[0].isLZ4)
        XCTAssertEqual(header.mipmaps[0].decompressedSize, 262144)
    }

    func testPixelFormatMapping() throws {
        let raw = Data(repeating: 0, count: 16)
        let rgba = try TexHeader.parse(
            buildTex(format: 0, flags: 0, freeImageFormat: -1, mips: [(4, 4, 0, 64, raw)])
        )
        XCTAssertEqual(rgba.pixelFormat, .rgba8888)

        let r8 = try TexHeader.parse(
            buildTex(format: 9, flags: 2, freeImageFormat: -1, mips: [(4, 4, 0, 16, raw)])
        )
        XCTAssertEqual(r8.pixelFormat, .r8)
    }

    func testParsesFullMipmapChain() throws {
        let mips: [(Int32, Int32, Int32, Int32, Data)] = [
            (2048, 1164, 0, 0, Data([0xFF, 0xD8, 0xFF] + Array(repeating: 0, count: 20))),
            (1024, 582, 0, 0, Data(repeating: 1, count: 15)),
            (512, 291, 0, 0, Data(repeating: 2, count: 10)),
            (256, 145, 0, 0, Data(repeating: 3, count: 5)),
        ]
        let header = try TexHeader.parse(buildTex(mips: mips))
        XCTAssertEqual(header.mipmaps.map(\.width), [2048, 1024, 512, 256])
        XCTAssertEqual(header.mipmaps.map(\.height), [1164, 582, 291, 145])
    }

    func testBadMagicThrows() {
        let junk = Data("NOTATEXTURE\0".utf8) + Data(repeating: 0, count: 80)
        XCTAssertThrowsError(try TexHeader.parse(junk)) { error in
            guard case TexError.badMagic = error else {
                return XCTFail("expected badMagic, got \(error)")
            }
        }
    }

    func testUnknownContainerThrows() {
        let tex = buildTex(container: "TEXB9999", mips: [(4, 4, 0, 0, Data([1, 2, 3]))])
        XCTAssertThrowsError(try TexHeader.parse(tex)) { error in
            guard case TexError.unsupportedContainer(let name) = error else {
                return XCTFail("expected unsupportedContainer, got \(error)")
            }
            XCTAssertEqual(name, "TEXB9999")
        }
    }

    func testTruncatedMipmapDataThrows() {
        var tex = buildTex(mips: [(2048, 1164, 0, 0, Data(repeating: 0, count: 100))])
        tex = tex.prefix(tex.count - 50)   // 데이터 절반을 잘라낸다
        XCTAssertThrowsError(try TexHeader.parse(tex))
    }
}
```

`Fixtures.swift`에 `.tex` 빌더를 더한다.

```swift
/// 널 종료 문자열. .tex가 쓰는 형식이다 (.pkg의 길이 접두와 다르다).
func nullTerminated(_ s: String) -> Data { Data(s.utf8) + Data([0]) }

/// 실물 레이아웃대로 .tex를 합성한다.
/// mips는 (width, height, isLZ4, decompressedSize, payload).
func buildTex(
    container: String = "TEXB0004",
    format: Int32 = 0,
    flags: Int32 = 2,
    freeImageFormat: Int32 = 2,
    size: (Int32, Int32) = (2048, 1164),
    mips: [(Int32, Int32, Int32, Int32, Data)]
) -> Data {
    var d = nullTerminated("TEXV0005") + nullTerminated("TEXI0001")
    d += le32(format) + le32(flags)
    d += le32(size.0) + le32(size.1) + le32(size.0) + le32(size.1)
    d += le32(0)                       // color
    d += nullTerminated(container)
    d += le32(1)                       // imageCount
    d += le32(freeImageFormat)
    if container == "TEXB0004" { d += le32(0) }
    d += le32(Int32(mips.count))
    for (w, h, lz4, decomp, payload) in mips {
        d += le32(w) + le32(h) + le32(lz4) + le32(decomp) + le32(Int32(payload.count))
        d += payload
    }
    return d
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter TexHeaderTests`
Expected: FAIL — `cannot find 'TexHeader' in scope`

- [ ] **Step 3: 구현 작성**

```swift
import Foundation

public enum TexError: Error, Equatable {
    case badMagic(String)
    case unsupportedContainer(String)
    case truncated
    case noMipmaps
}

/// .tex 안에 실제로 무엇이 들어 있는지.
public enum TexPayloadKind: Equatable, Sendable {
    case jpeg
    case png
    case rawPixels
    /// 데이터가 통째로 MP4(H.264) 파일이다. 실물 226MB 텍스처 두 개가 이 경우였다.
    case video
}

public enum TexPixelFormat: Int32, Sendable {
    case rgba8888 = 0
    /// 단일 채널. 마스크에 쓰인다.
    case r8 = 9
}

public struct TexMipmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let isLZ4: Bool
    public let decompressedSize: Int
    /// 원본 .tex 데이터 안에서 이 밉맵의 바이트 범위.
    public let range: Range<Int>
}

/// .tex 컨테이너의 헤더. 픽셀을 건드리지 않고 정체만 알아낸다.
///
/// 레이아웃 (실물 파일에서 확인, 잔여 바이트 0):
///   "TEXV0005\0" "TEXI0001\0"
///   int32 format, flags, texW, texH, imgW, imgH, color
///   "TEXB0003\0" 또는 "TEXB0004\0"
///   int32 imageCount, freeImageFormat, [0004면 하나 더], mipmapCount
///   밉맵마다: int32 w, h, isLZ4, decompressedSize, dataSize + 데이터
public struct TexHeader: Equatable, Sendable {
    /// flags의 이 비트가 서면 데이터가 MP4다.
    static let videoFlag: Int32 = 32

    public let version: String
    public let format: Int32
    public let flags: Int32
    public let textureWidth: Int
    public let textureHeight: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public let freeImageFormat: Int32
    public let mipmaps: [TexMipmap]

    public var isVideo: Bool { flags & Self.videoFlag != 0 }

    public var pixelFormat: TexPixelFormat? { TexPixelFormat(rawValue: format) }

    public var kind: TexPayloadKind {
        if isVideo { return .video }
        switch freeImageFormat {
        case 2: return .jpeg
        case 13: return .png
        default: return .rawPixels
        }
    }

    public static func parse(_ data: Data) throws -> TexHeader {
        var cursor = Cursor(data)

        let version = try cursor.readCString()
        guard version.hasPrefix("TEXV") else { throw TexError.badMagic(version) }
        let imageMagic = try cursor.readCString()
        guard imageMagic.hasPrefix("TEXI") else { throw TexError.badMagic(imageMagic) }

        let format = try cursor.readInt32()
        let flags = try cursor.readInt32()
        let texW = Int(try cursor.readInt32())
        let texH = Int(try cursor.readInt32())
        let imgW = Int(try cursor.readInt32())
        let imgH = Int(try cursor.readInt32())
        _ = try cursor.readInt32()          // color. 쓰이지 않는다.

        let container = try cursor.readCString()
        let extraField: Bool
        switch container {
        case "TEXB0004": extraField = true
        case "TEXB0003": extraField = false
        default: throw TexError.unsupportedContainer(container)
        }

        _ = try cursor.readInt32()          // imageCount. 실물은 항상 1이었다.
        let freeImageFormat = try cursor.readInt32()
        if extraField { _ = try cursor.readInt32() }
        let mipCount = try cursor.readInt32()
        guard mipCount > 0 else { throw TexError.noMipmaps }

        var mipmaps: [TexMipmap] = []
        mipmaps.reserveCapacity(Int(mipCount))
        for _ in 0..<mipCount {
            let w = Int(try cursor.readInt32())
            let h = Int(try cursor.readInt32())
            let lz4 = try cursor.readInt32()
            let decompressed = Int(try cursor.readInt32())
            let size = Int(try cursor.readInt32())
            guard size >= 0, cursor.offset + size <= data.count else {
                throw TexError.truncated
            }
            let start = cursor.offset
            try cursor.skip(size)
            mipmaps.append(TexMipmap(
                width: w, height: h, isLZ4: lz4 == 1,
                decompressedSize: decompressed, range: start..<(start + size)
            ))
        }

        return TexHeader(
            version: version, format: format, flags: flags,
            textureWidth: texW, textureHeight: texH,
            imageWidth: imgW, imageHeight: imgH,
            freeImageFormat: freeImageFormat, mipmaps: mipmaps
        )
    }
}
```

`Cursor`에 널 종료 문자열 읽기를 더한다. `.pkg`는 길이 접두 문자열을,
`.tex`는 널 종료 문자열을 쓴다.

```swift
extension Cursor {
    /// .tex는 길이 접두가 아니라 널 종료 문자열을 쓴다.
    mutating func readCString() throws -> String {
        var bytes: [UInt8] = []
        while true {
            let byte = try readBytes(1)[0]
            if byte == 0 { break }
            bytes.append(byte)
            guard bytes.count < 64 else { throw TexError.badMagic(String(decoding: bytes, as: UTF8.self)) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
```

`Cursor`의 `readBytes`는 `Data`를 돌려주므로 `[0]` 첨자가 0 기반이 아닐 수 있다.
`readBytes` 안에서 `subdata`를 쓰면 인덱스가 0부터 시작하므로 안전하다. Task 1의
구현이 이미 `subdata`를 쓴다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter TexHeaderTests`
Expected: PASS (10개)

- [ ] **Step 5: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/TexHeader.swift Tests/WallflowKitTests/TexHeaderTests.swift Tests/WallflowKitTests/Fixtures.swift
git commit -m "$(cat <<'MSG'
feat: .tex 헤더 파서 추가

픽셀을 건드리지 않고 텍스처의 정체만 알아낸다.
TEXB0003과 TEXB0004는 필드가 하나 다르고, flags 비트 32는 MP4를 뜻한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 3: `.tex` 디코더

헤더가 알아낸 정체에 따라 실제 픽셀(또는 MP4 바이트)을 꺼낸다.

**Files:**
- Create: `Sources/WallflowKit/ScenePackage/TextureData.swift`
- Create: `Sources/WallflowKit/ScenePackage/TexDecoder.swift`
- Test: `Tests/WallflowKitTests/TexDecoderTests.swift`

**Interfaces:**
- Consumes: `TexHeader`, `TexMipmap`, `TexPayloadKind`, `TexPixelFormat`, `TexError` (Task 2)
- Produces:
  - `enum TextureData: Sendable` — `case image(CGImage)`, `case pixels(bytes: Data, width: Int, height: Int, format: TexPixelFormat)`, `case video(Data)`
  - `enum TexDecoder` — `static func decode(_ data: Data) throws -> TextureData`
  - `TexError`에 케이스 추가: `case imageDecodeFailed`, `case lz4Failed`, `case unsupportedPixelFormat(Int32)`

- [ ] **Step 1: 실패하는 테스트 작성**

Task 1~2에서 만든 `Fixtures.swift`의 `buildTex`를 그대로 쓴다.
`import Compression`, `import CoreGraphics`, `import ImageIO`가 필요하다.

```swift
import Compression
import CoreGraphics
import ImageIO
import XCTest
@testable import WallflowKit

final class TexDecoderTests: XCTestCase {
    /// 실제 JPEG 바이트를 만들어야 ImageIO가 디코딩할 수 있다.
    private func realJPEG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testDecodesJPEGToImage() throws {
        let jpeg = try realJPEG(width: 64, height: 32)
        let tex = buildTex(freeImageFormat: 2, size: (64, 32), mips: [(64, 32, 0, 0, jpeg)])
        guard case .image(let cg) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .image")
        }
        XCTAssertEqual(cg.width, 64)
        XCTAssertEqual(cg.height, 32)
    }

    func testDecodesOnlyTheLargestMipmap() throws {
        // 밉맵이 여러 개여도 0번(최대 해상도)만 쓴다.
        let big = try realJPEG(width: 64, height: 32)
        let small = try realJPEG(width: 32, height: 16)
        let tex = buildTex(freeImageFormat: 2, size: (64, 32), mips: [
            (64, 32, 0, 0, big), (32, 16, 0, 0, small),
        ])
        guard case .image(let cg) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .image")
        }
        XCTAssertEqual(cg.width, 64)
    }

    func testVideoTextureReturnsRawMP4Bytes() throws {
        let mp4 = Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8) + Data(repeating: 0xAB, count: 64)
        let tex = buildTex(flags: 34, freeImageFormat: -1, size: (320, 240),
                          mips: [(320, 240, 0, 0, mp4)])
        guard case .video(let bytes) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .video")
        }
        XCTAssertEqual(bytes, mp4, "MP4는 손대지 않고 그대로 넘겨야 AVFoundation이 읽는다")
    }

    func testDecompressesLZ4RawPixels() throws {
        let original = Data((0..<(8 * 8 * 4)).map { UInt8($0 % 251) })
        let compressed = try XCTUnwrap(lz4RawCompress(original))
        let tex = buildTex(
            format: 0, flags: 0, freeImageFormat: -1, size: (8, 8),
            mips: [(8, 8, 1, Int32(original.count), compressed)]
        )
        guard case .pixels(let bytes, let w, let h, let fmt) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .pixels")
        }
        XCTAssertEqual(bytes, original)
        XCTAssertEqual(w, 8)
        XCTAssertEqual(h, 8)
        XCTAssertEqual(fmt, .rgba8888)
    }

    func testUncompressedRawPixelsPassThrough() throws {
        let raw = Data(repeating: 0x5A, count: 4 * 4 * 4)
        let tex = buildTex(format: 0, flags: 0, freeImageFormat: -1, size: (4, 4),
                          mips: [(4, 4, 0, raw.count32, raw)])
        guard case .pixels(let bytes, _, _, _) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .pixels")
        }
        XCTAssertEqual(bytes, raw)
    }

    func testSingleChannelMaskFormat() throws {
        let raw = Data(repeating: 0xFF, count: 16 * 16)
        let tex = buildTex(format: 9, flags: 2, freeImageFormat: -1, size: (16, 16),
                          mips: [(16, 16, 0, raw.count32, raw)])
        guard case .pixels(_, _, _, let fmt) = try TexDecoder.decode(tex) else {
            return XCTFail("expected .pixels")
        }
        XCTAssertEqual(fmt, .r8)
    }

    func testUnknownPixelFormatThrows() {
        let raw = Data(repeating: 0, count: 16)
        let tex = buildTex(format: 77, flags: 0, freeImageFormat: -1, size: (2, 2),
                          mips: [(2, 2, 0, 16, raw)])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .unsupportedPixelFormat(77))
        }
    }

    func testCorruptImageBytesThrowRatherThanCrash() {
        let notAnImage = Data(repeating: 0x41, count: 128)
        let tex = buildTex(freeImageFormat: 2, size: (8, 8), mips: [(8, 8, 0, 0, notAnImage)])
        XCTAssertThrowsError(try TexDecoder.decode(tex)) { error in
            XCTAssertEqual(error as? TexError, .imageDecodeFailed)
        }
    }
}
```

테스트가 쓰는 두 헬퍼를 테스트 파일에 함께 둔다.

```swift
extension Data {
    var count32: Int32 { Int32(count) }
}

/// 테스트 픽스처용 LZ4 압축. 구현부의 압축 해제와 짝을 이룬다.
func lz4RawCompress(_ input: Data) -> Data? {
    let capacity = input.count + 1024
    var output = Data(count: capacity)
    let written = output.withUnsafeMutableBytes { dst -> Int in
        input.withUnsafeBytes { src -> Int in
            compression_encode_buffer(
                dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                nil, COMPRESSION_LZ4_RAW
            )
        }
    }
    guard written > 0 else { return nil }
    return output.prefix(written)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter TexDecoderTests`
Expected: FAIL — `cannot find 'TexDecoder' in scope`

- [ ] **Step 3: `TextureData` 작성**

```swift
import CoreGraphics
import Foundation

/// .tex에서 꺼낸 결과. 세 가지 중 하나다.
public enum TextureData: Sendable {
    /// JPEG/PNG를 ImageIO로 디코딩한 것.
    case image(CGImage)
    /// 원시 픽셀. LZ4였다면 이미 풀린 상태다.
    case pixels(bytes: Data, width: Int, height: Int, format: TexPixelFormat)
    /// MP4 파일 바이트 그대로. AVFoundation이 읽는다.
    case video(Data)
}
```

- [ ] **Step 4: `TexDecoder` 작성**

```swift
import Compression
import CoreGraphics
import Foundation
import ImageIO

/// .tex를 실제로 디코딩한다.
/// 밉맵 체인이 있어도 0번(최대 해상도)만 쓴다. 화면을 채우는 것이 목적이라
/// 축소본은 필요 없고, 메모리만 더 쓴다.
public enum TexDecoder {
    public static func decode(_ data: Data) throws -> TextureData {
        let header = try TexHeader.parse(data)
        guard let mip = header.mipmaps.first else { throw TexError.noMipmaps }
        // mip.range는 0 기준 오프셋이다. 슬라이스가 넘어올 수 있으므로 기준을 더한다.
        let lower = data.startIndex + mip.range.lowerBound
        let upper = data.startIndex + mip.range.upperBound
        let payload = data.subdata(in: lower..<upper)

        switch header.kind {
        case .video:
            // 손대지 않는다. AVFoundation이 통째로 읽는다.
            return .video(payload)

        case .jpeg, .png:
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw TexError.imageDecodeFailed
            }
            return .image(image)

        case .rawPixels:
            guard let format = header.pixelFormat else {
                throw TexError.unsupportedPixelFormat(header.format)
            }
            let bytes = mip.isLZ4
                ? try decompressLZ4(payload, expecting: mip.decompressedSize)
                : payload
            return .pixels(bytes: bytes, width: mip.width, height: mip.height, format: format)
        }
    }

    /// macOS Compression 프레임워크의 LZ4_RAW를 쓴다. 외부 의존성이 필요 없다.
    private static func decompressLZ4(_ input: Data, expecting size: Int) throws -> Data {
        guard size > 0 else { throw TexError.lz4Failed }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == size else { throw TexError.lz4Failed }
        return output
    }
}
```

`TexError`에 케이스를 더한다.

```swift
public enum TexError: Error, Equatable {
    case badMagic(String)
    case unsupportedContainer(String)
    case truncated
    case noMipmaps
    case imageDecodeFailed
    case lz4Failed
    case unsupportedPixelFormat(Int32)
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter TexDecoderTests`
Expected: PASS (8개)

- [ ] **Step 6: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/TextureData.swift Sources/WallflowKit/ScenePackage/TexDecoder.swift Tests/WallflowKitTests/TexDecoderTests.swift
git commit -m "$(cat <<'MSG'
feat: .tex 디코더 추가

JPEG/PNG는 ImageIO로, 원시 픽셀은 Compression 프레임워크의 LZ4_RAW로 풀고,
비디오 텍스처는 MP4 바이트를 손대지 않고 그대로 넘긴다.

밉맵은 0번만 쓴다. 화면을 채우는 것이 목적이라 축소본은 메모리만 더 쓴다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 4: 씬 그래프 모델

`scene.json`과 `models/`, `materials/`를 따라가 "무엇을 어디에 그릴지"의 목록으로 바꾼다.

**Files:**
- Create: `Sources/WallflowKit/ScenePackage/SceneLayer.swift`
- Create: `Sources/WallflowKit/ScenePackage/SceneDocument.swift`
- Test: `Tests/WallflowKitTests/SceneDocumentTests.swift`

**Interfaces:**
- Consumes: `PkgReader`, `PkgError` (Task 1)
- Produces:
  - `struct Vec3: Equatable, Sendable` — `x, y, z: Double`; `static func parse(_ s: String) -> Vec3?`
  - `struct Vec2: Equatable, Sendable` — `x, y: Double`; `static func parse(_ s: String) -> Vec2?`
  - `enum LayerContent: Equatable, Sendable { case image(texturePath: String); case unsupported(reason: String) }`
  - `struct SceneLayer: Equatable, Sendable` — `id: Int`, `name: String`, `visible: Bool`, `origin: Vec3`, `size: Vec2`, `content: LayerContent`
  - `struct SceneDocument: Sendable` — `orthoWidth: Int`, `orthoHeight: Int`, `clearColor: Vec3`, `clearEnabled: Bool`, `layers: [SceneLayer]`; `static func load(from reader: PkgReader) throws -> SceneDocument`
  - `enum SceneError: Error, Equatable { case malformedSceneJSON; case missingField(String) }`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

final class SceneDocumentTests: XCTestCase {
    /// scene.json과 참조 파일들을 담은 최소 .pkg를 만든다.
    private func makeScenePkg(
        scene: String,
        extras: [String: String] = [:]
    ) throws -> PkgReader {
        var entries: [(String, Data)] = [("scene.json", Data(scene.utf8))]
        for (name, body) in extras { entries.append((name, Data(body.utf8))) }
        return try PkgReader(data: buildPkg(version: "PKGV0023", entries: entries))
    }

    func testParsesOrthographicProjectionAndClearColor() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 2048, "height": 1164},
                     "clearcolor": "0.70000 0.70000 0.70000", "clearenabled": true},
         "objects": []}
        """)
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.orthoWidth, 2048)
        XCTAssertEqual(doc.orthoHeight, 1164)
        XCTAssertEqual(doc.clearColor, Vec3(x: 0.7, y: 0.7, z: 0.7))
        XCTAssertTrue(doc.clearEnabled)
    }

    /// 실물 씬 3714517753의 실제 참조 사슬을 그대로 재현한다.
    func testResolvesImageLayerThroughModelAndMaterial() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 2048, "height": 1164}},
             "objects": [{"id": 33, "name": "HFRvNK5aIAA7Q24",
                          "image": "models/HFRvNK5aIAA7Q24.json",
                          "origin": "1024.00000 582.00000 0.00000",
                          "size": "2048.00000 1164.00000"}]}
            """,
            extras: [
                "models/HFRvNK5aIAA7Q24.json":
                    #"{"autosize": true, "material": "materials/HFRvNK5aIAA7Q24.json"}"#,
                "materials/HFRvNK5aIAA7Q24.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["HFRvNK5aIAA7Q24"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 1)
        let layer = try XCTUnwrap(doc.layers.first)
        XCTAssertEqual(layer.id, 33)
        XCTAssertEqual(layer.name, "HFRvNK5aIAA7Q24")
        XCTAssertEqual(layer.origin, Vec3(x: 1024, y: 582, z: 0))
        XCTAssertEqual(layer.size, Vec2(x: 2048, y: 1164))
        XCTAssertEqual(layer.content, .image(texturePath: "materials/HFRvNK5aIAA7Q24.tex"))
    }

    func testVisibleDefaultsToTrueAndFalseIsHonored() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "shown", "particle": "p.json"},
                     {"id": 2, "name": "hidden", "particle": "p.json", "visible": false}]}
        """)
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.map(\.visible), [true, false])
    }

    /// M2는 이미지 레이어만 그린다. 나머지는 이유를 달아 남긴다.
    func testNonImageLayersBecomeUnsupportedRatherThanDisappearing() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Snow", "particle": "particles/snow.json"},
                     {"id": 2, "name": "Time", "text": "12:00"}]}
        """)
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 2)
        for layer in doc.layers {
            guard case .unsupported = layer.content else {
                return XCTFail("\(layer.name)이 unsupported가 아니다")
            }
        }
    }

    /// origin이나 scale이 문자열이 아니라 스크립트 객체인 씬이 실제로 있다.
    /// 파싱이 통째로 실패하면 안 되고, 해당 레이어만 unsupported가 되어야 한다.
    func testScriptedOriginDoesNotBreakTheWholeScene() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "scripted", "image": "models/m.json",
                          "origin": {"script": "return 0;"}, "size": "10.0 10.0"},
                         {"id": 2, "name": "plain", "image": "models/m.json",
                          "origin": "5.0 5.0 0.0", "size": "10.0 10.0"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json": #"{"passes": [{"textures": ["t"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertEqual(doc.layers[1].content, .image(texturePath: "materials/t.tex"))
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("스크립트 origin 레이어는 unsupported여야 한다")
        }
    }

    func testMissingModelFileMakesLayerUnsupportedNotFatal() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "dangling", "image": "models/missing.json",
                      "origin": "0 0 0", "size": "1 1"}]}
        """)
        let doc = try SceneDocument.load(from: reader)
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("참조가 끊긴 레이어는 unsupported여야 한다")
        }
    }

    func testNullTextureEntryIsUnsupported() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "nulltex", "image": "models/m.json",
                          "origin": "0 0 0", "size": "1 1"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                // waterripple의 실제 머티리얼이 이런 모양이다.
                "materials/m.json": #"{"passes": [{"textures": [null, null, "effects/n"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("첫 텍스처가 null이면 unsupported여야 한다")
        }
    }

    func testMalformedSceneJSONThrows() throws {
        let reader = try makeScenePkg(scene: "not json")
        XCTAssertThrowsError(try SceneDocument.load(from: reader)) { error in
            XCTAssertEqual(error as? SceneError, .malformedSceneJSON)
        }
    }

    func testMissingOrthographicProjectionThrows() throws {
        let reader = try makeScenePkg(scene: #"{"general": {}, "objects": []}"#)
        XCTAssertThrowsError(try SceneDocument.load(from: reader)) { error in
            XCTAssertEqual(error as? SceneError, .missingField("orthogonalprojection"))
        }
    }

    func testVectorParsing() {
        XCTAssertEqual(Vec3.parse("1.5 -2.0 3.25"), Vec3(x: 1.5, y: -2.0, z: 3.25))
        XCTAssertEqual(Vec2.parse("2048.00000 1164.00000"), Vec2(x: 2048, y: 1164))
        XCTAssertNil(Vec3.parse("1.0 2.0"))
        XCTAssertNil(Vec3.parse("a b c"))
        XCTAssertNil(Vec2.parse(""))
    }
}
```

`buildPkg`는 Task 1에서 만든 `Tests/WallflowKitTests/Fixtures.swift`의 것을 그대로 쓴다.

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: FAIL — `cannot find 'SceneDocument' in scope`

- [ ] **Step 3: `SceneLayer` 작성**

```swift
import Foundation

public struct Vec3: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    /// Wallpaper Engine은 벡터를 "1.00000 2.00000 3.00000" 문자열로 쓴다.
    public static func parse(_ string: String) -> Vec3? {
        let parts = string.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return Vec3(x: parts[0], y: parts[1], z: parts[2])
    }
}

public struct Vec2: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x; self.y = y
    }

    public static func parse(_ string: String) -> Vec2? {
        let parts = string.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return Vec2(x: parts[0], y: parts[1])
    }
}

/// 레이어가 무엇을 그리는지.
public enum LayerContent: Equatable, Sendable {
    /// .pkg 안의 텍스처 경로. 예: "materials/HFRvNK5aIAA7Q24.tex"
    case image(texturePath: String)
    /// M2가 그리지 못하는 레이어. 이유를 남겨 나중에 무엇을 만들지 알 수 있게 한다.
    case unsupported(reason: String)
}

/// 씬의 레이어 하나. origin은 오브젝트의 중심이고 직교 공간 좌표다.
public struct SceneLayer: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let visible: Bool
    public let origin: Vec3
    public let size: Vec2
    public let content: LayerContent
}
```

- [ ] **Step 4: `SceneDocument` 작성**

```swift
import Foundation

public enum SceneError: Error, Equatable {
    case malformedSceneJSON
    case missingField(String)
}

/// scene.json과 그것이 참조하는 models/·materials/를 따라가
/// "무엇을 어디에 그릴지"의 목록으로 바꾼다.
///
/// 참조 사슬 (실물에서 확인):
///   object.image → models/X.json의 "material"
///                → materials/Y.json의 passes[0].textures[0]
///                → materials/<그 이름>.tex
public struct SceneDocument: Sendable {
    public let orthoWidth: Int
    public let orthoHeight: Int
    public let clearColor: Vec3
    public let clearEnabled: Bool
    public let layers: [SceneLayer]

    public static func load(from reader: PkgReader) throws -> SceneDocument {
        let raw = try reader.data(for: "scene.json")
        guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw SceneError.malformedSceneJSON
        }

        let general = root["general"] as? [String: Any] ?? [:]
        guard let ortho = general["orthogonalprojection"] as? [String: Any],
              let width = ortho["width"] as? Int,
              let height = ortho["height"] as? Int else {
            throw SceneError.missingField("orthogonalprojection")
        }

        let clearColor = (general["clearcolor"] as? String).flatMap(Vec3.parse)
            ?? Vec3(x: 0, y: 0, z: 0)
        let clearEnabled = general["clearenabled"] as? Bool ?? true

        let objects = root["objects"] as? [[String: Any]] ?? []
        let layers = objects.enumerated().map { index, object in
            makeLayer(object, fallbackID: index, reader: reader)
        }

        return SceneDocument(
            orthoWidth: width, orthoHeight: height,
            clearColor: clearColor, clearEnabled: clearEnabled,
            layers: layers
        )
    }

    /// 레이어 하나가 해석되지 않아도 씬 전체를 버리지 않는다.
    /// 그릴 수 없는 것은 이유를 달아 unsupported로 남긴다.
    private static func makeLayer(
        _ object: [String: Any], fallbackID: Int, reader: PkgReader
    ) -> SceneLayer {
        let id = object["id"] as? Int ?? fallbackID
        let name = object["name"] as? String ?? "object\(fallbackID)"
        let visible = object["visible"] as? Bool ?? true

        // origin/scale이 문자열이 아니라 {"script": ...} 객체인 씬이 실제로 있다.
        let origin = (object["origin"] as? String).flatMap(Vec3.parse)
        let size = (object["size"] as? String).flatMap(Vec2.parse)

        func unsupported(_ reason: String) -> SceneLayer {
            SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                size: size ?? Vec2(x: 0, y: 0),
                content: .unsupported(reason: reason)
            )
        }

        guard let modelPath = object["image"] as? String else {
            if object["particle"] != nil { return unsupported("파티클은 M3에서 지원한다") }
            if object["text"] != nil { return unsupported("텍스트는 M3에서 지원한다") }
            if object["sound"] != nil { return unsupported("사운드는 M4에서 지원한다") }
            return unsupported("알 수 없는 레이어 종류")
        }
        guard let origin, let size else {
            return unsupported("origin이나 size가 스크립트다. 스크립팅은 M4에서 지원한다")
        }
        guard let texturePath = resolveTexture(modelPath: modelPath, reader: reader) else {
            return unsupported("텍스처 참조를 따라갈 수 없다: \(modelPath)")
        }

        return SceneLayer(
            id: id, name: name, visible: visible,
            origin: origin, size: size,
            content: .image(texturePath: texturePath)
        )
    }

    private static func resolveTexture(modelPath: String, reader: PkgReader) -> String? {
        guard let modelData = try? reader.data(for: modelPath),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = try? reader.data(for: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let passes = material["passes"] as? [[String: Any]],
              let textures = passes.first?["textures"] as? [Any],
              // 첫 항목이 null인 머티리얼이 실제로 있다 (waterripple).
              let name = textures.first as? String
        else { return nil }

        return "materials/\(name).tex"
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: PASS (10개)

- [ ] **Step 6: 커밋**

```bash
git add Sources/WallflowKit/ScenePackage/SceneLayer.swift Sources/WallflowKit/ScenePackage/SceneDocument.swift Tests/WallflowKitTests/SceneDocumentTests.swift
git commit -m "$(cat <<'MSG'
feat: 씬 그래프 모델 추가

scene.json에서 models/, materials/를 따라가 텍스처 경로까지 해석한다.
레이어 하나가 해석되지 않아도 씬 전체를 버리지 않고 이유를 달아 남긴다.
origin이 스크립트인 씬이 실제로 있어 그 경우도 여기서 걸러진다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 5: 실물 씬 회귀 테스트

합성 픽스처가 통과해도 실물이 통과한다는 보장은 없다. 보유 씬 4개를 그대로 먹인다.

**Files:**
- Create: `Tests/WallflowKitTests/RealScenesTests.swift`

**Interfaces:**
- Consumes: `PkgReader`, `TexDecoder`, `TexHeader`, `SceneDocument` (Task 1~4)
- Produces: 없음 (테스트 전용)

- [ ] **Step 1: 테스트 작성**

```swift
import XCTest
@testable import WallflowKit

/// 보유한 실물 창작마당 씬을 그대로 파싱한다.
/// 용량이 커서 저장소에 넣지 않는다. 경로는 환경변수로 주입한다:
///   WALLFLOW_TEST_SCENES=~/Downloads/431960 swift test
/// 미설정이면 전부 건너뛴다.
final class RealScenesTests: XCTestCase {
    private var root: URL?

    override func setUp() {
        super.setUp()
        if let path = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"] {
            root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
    }

    private func scenePkg(_ id: String) throws -> PkgReader? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(id).appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PkgReader(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// M2의 목표 씬. 커스텀 셰이더가 없는 유일한 씬이다.
    func testTargetSceneResolvesToOneImageLayer() throws {
        guard let reader = try scenePkg("3714517753") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.orthoWidth, 2048)
        XCTAssertEqual(doc.orthoHeight, 1164)

        let images = doc.layers.filter {
            if case .image = $0.content { return true } else { return false }
        }
        XCTAssertEqual(images.count, 1, "이미지 레이어가 정확히 하나여야 한다")
        let layer = try XCTUnwrap(images.first)
        XCTAssertEqual(layer.content, .image(texturePath: "materials/HFRvNK5aIAA7Q24.tex"))
        XCTAssertEqual(layer.size, Vec2(x: 2048, y: 1164))
        XCTAssertEqual(layer.origin, Vec3(x: 1024, y: 582, z: 0))
    }

    func testTargetSceneTextureDecodesToExpectedSize() throws {
        guard let reader = try scenePkg("3714517753") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let data = try reader.data(for: "materials/HFRvNK5aIAA7Q24.tex")
        guard case .image(let cg) = try TexDecoder.decode(data) else {
            return XCTFail("JPEG 텍스처여야 한다")
        }
        XCTAssertEqual(cg.width, 2048)
        XCTAssertEqual(cg.height, 1164)
    }

    /// 226MB 텍스처 두 개가 MP4였다. 이 판정이 틀리면 두 씬이 통째로 깨진다.
    func testLargeTexturesAreDetectedAsVideo() throws {
        let cases = [
            ("3536506287", "materials/弗洛洛SYziyv1.tex"),
            ("3616103296", "materials/Utool-20251201-195920953.tex"),
        ]
        for (id, texture) in cases {
            guard let reader = try scenePkg(id) else {
                throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
            }
            let data = try reader.data(for: texture)
            let header = try TexHeader.parse(data)
            XCTAssertTrue(header.isVideo, "\(id)의 \(texture)는 비디오여야 한다")

            guard case .video(let bytes) = try TexDecoder.decode(data) else {
                return XCTFail("\(id): .video여야 한다")
            }
            // MP4 파일은 4바이트 크기 뒤에 'ftyp' 박스가 온다.
            XCTAssertEqual(bytes.subdata(in: 4..<8), Data("ftyp".utf8))
        }
    }

    func testLZ4MaskDecompressesToExactExpectedSize() throws {
        guard let reader = try scenePkg("3536506287") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let data = try reader.data(for: "materials/masks/waterripple_mask_caee43da.tex")
        guard case .pixels(let bytes, let w, let h, let format) = try TexDecoder.decode(data) else {
            return XCTFail("원시 픽셀이어야 한다")
        }
        XCTAssertEqual(format, .r8, "마스크는 단일 채널이다")
        XCTAssertEqual(w, 1600)
        XCTAssertEqual(h, 900)
        XCTAssertEqual(bytes.count, 1600 * 900, "R8이면 픽셀당 1바이트다")
    }

    /// 어떤 씬도 파싱 중에 던지거나 크래시하지 않아야 한다.
    func testAllOwnedScenesParseWithoutThrowing() throws {
        guard let root else { throw XCTSkip("WALLFLOW_TEST_SCENES 미설정") }
        let ids = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.allSatisfy(\.isNumber) }
        XCTAssertFalse(ids.isEmpty, "테스트할 씬이 없다")

        for id in ids {
            guard let reader = try scenePkg(id) else { continue }
            let doc = try SceneDocument.load(from: reader)
            XCTAssertGreaterThan(doc.layers.count, 0, "\(id)에 레이어가 없다")
            XCTAssertGreaterThan(doc.orthoWidth, 0, "\(id)의 직교 폭이 0이다")

            // 모든 .tex가 헤더 파싱은 되어야 한다.
            for name in reader.names where name.hasSuffix(".tex") {
                let data = try reader.data(for: name)
                XCTAssertNoThrow(try TexHeader.parse(data), "\(id)/\(name) 헤더 파싱 실패")
            }
        }
    }
}
```

- [ ] **Step 2: 실물 씬으로 실행**

Run: `WALLFLOW_TEST_SCENES=~/Downloads/431960 swift test --filter RealScenesTests`
Expected: PASS (5개). 실패하면 그것이 곧 포맷 이해의 오류이므로 Task 1~4를 고친다.

- [ ] **Step 3: 환경변수 없이도 통과하는지 확인**

Run: `swift test`
Expected: PASS. `RealScenesTests`는 건너뛴다(skipped).

- [ ] **Step 4: 커밋**

```bash
git add Tests/WallflowKitTests/RealScenesTests.swift
git commit -m "$(cat <<'MSG'
test: 실물 씬 4개 회귀 테스트 추가

합성 픽스처가 통과해도 실물이 통과한다는 보장은 없다.
용량 때문에 저장소에 넣지 않고 WALLFLOW_TEST_SCENES로 경로를 주입받으며,
미설정 시 건너뛴다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 6: Metal 2D 컴포지터

여기서부터 GPU다. 직교 투영 공간에 텍스처 쿼드를 그린다.

**Files:**
- Create: `Sources/WallflowApp/SceneShaders.swift`
- Create: `Sources/WallflowApp/MetalCompositor.swift`

**Interfaces:**
- Consumes: `SceneDocument`, `SceneLayer`, `LayerContent`, `TextureData`, `Vec2`, `Vec3` (Task 3~4)
- Produces:
  - `enum SceneShaders` — `static let source: String`
  - `struct QuadInstance` — `origin: SIMD2<Float>`, `size: SIMD2<Float>`
  - `final class MetalCompositor` — `init(device: MTLDevice) throws`, `func setProjection(width: Int, height: Int)`, `func setLayers(_ layers: [(QuadInstance, MTLTexture)])`, `func setClearColor(_ color: MTLClearColor)`, `func draw(in view: MTKView)`
  - `enum CompositorError: Error { case noDevice, libraryCompilationFailed(String), pipelineFailed(String), textureCreationFailed }`

- [ ] **Step 1: MSL 셰이더 소스 작성**

```swift
/// 런타임에 device.makeLibrary(source:)로 컴파일한다.
/// .metal 파일을 쓰면 SwiftPM 리소스 번들 설정이 필요하고,
/// M4에서 사용자 셰이더를 처리할 때도 어차피 런타임 컴파일 경로를 쓴다.
enum SceneShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct QuadUniforms {
        // 직교 공간에서의 중심과 크기
        float2 origin;
        float2 size;
        // 직교 공간의 전체 크기
        float2 projection;
    };

    // 단위 쿼드(-0.5..0.5)를 직교 공간에 배치하고 클립 공간으로 옮긴다.
    vertex VertexOut quad_vertex(
        VertexIn in [[stage_in]],
        constant QuadUniforms &u [[buffer(1)]]
    ) {
        float2 world = u.origin + in.position * u.size;
        // 직교 공간 원점은 좌상단, Y는 아래로 증가한다.
        float2 ndc = float2(
             (world.x / u.projection.x) * 2.0 - 1.0,
            1.0 - (world.y / u.projection.y) * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = in.position + 0.5;
        return out;
    }

    fragment float4 quad_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return tex.sample(samp, in.uv);
    }
    """
}
```

- [ ] **Step 2: `MetalCompositor` 작성**

```swift
import Metal
import MetalKit
import WallflowKit

enum CompositorError: Error {
    case noDevice
    case libraryCompilationFailed(String)
    case pipelineFailed(String)
    case textureCreationFailed
}

/// 정점 셰이더에 넘기는 쿼드 하나의 배치 정보.
struct QuadUniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var projection: SIMD2<Float>
}

struct QuadInstance {
    /// 직교 공간에서의 중심.
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
}

/// 직교 투영 공간에 텍스처 쿼드를 겹쳐 그린다.
/// 씬의 레이어 순서가 그리는 순서다.
@MainActor
final class MetalCompositor {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let sampler: MTLSamplerState

    private var projection = SIMD2<Float>(1, 1)
    private var layers: [(QuadInstance, MTLTexture)] = []
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw CompositorError.noDevice }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: SceneShaders.source, options: nil)
        } catch {
            throw CompositorError.libraryCompilationFailed("\(error)")
        }

        // 단위 쿼드. 삼각형 스트립 4정점.
        let vertices: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5),
            SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5),
        ]
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
            options: []
        ) else { throw CompositorError.noDevice }
        vertexBuffer = buffer

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // 씬 머티리얼의 기본 블렌딩이 translucent다.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        descriptor.vertexDescriptor = vertexDescriptor

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        // 씬이 clampuvs를 켜 두는 경우가 많고, 배경화면은 타일링하지 않는다.
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw CompositorError.noDevice
        }
        self.sampler = sampler
    }

    func setProjection(width: Int, height: Int) {
        projection = SIMD2(Float(width), Float(height))
    }

    func setClearColor(_ color: MTLClearColor) {
        clearColor = color
    }

    func setLayers(_ layers: [(QuadInstance, MTLTexture)]) {
        self.layers = layers
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].loadAction = .clear

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)

        for (quad, texture) in layers {
            var uniforms = QuadUniforms(
                origin: quad.origin, size: quad.size, projection: projection
            )
            encoder.setVertexBytes(
                &uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1
            )
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// 디코딩된 텍스처를 Metal 텍스처로 올린다.
    func makeTexture(from data: TextureData) throws -> MTLTexture {
        switch data {
        case .image(let cgImage):
            let loader = MTKTextureLoader(device: device)
            return try loader.newTexture(cgImage: cgImage, options: [
                .SRGB: false as NSNumber,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue as NSNumber,
            ])

        case .pixels(let bytes, let width, let height, let format):
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format == .rgba8888 ? .rgba8Unorm : .r8Unorm,
                width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw CompositorError.textureCreationFailed
            }
            let bytesPerPixel = format == .rgba8888 ? 4 : 1
            bytes.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: width * bytesPerPixel
                )
            }
            return texture

        case .video:
            // M2는 비디오 텍스처를 그리지 않는다. M3에서 AVFoundation과 잇는다.
            throw CompositorError.textureCreationFailed
        }
    }
}
```

- [ ] **Step 3: 빌드 확인**

Run: `swift build`
Expected: 성공, 경고 0. 경고가 나오면 고친다.

- [ ] **Step 4: 커밋**

```bash
git add Sources/WallflowApp/SceneShaders.swift Sources/WallflowApp/MetalCompositor.swift
git commit -m "$(cat <<'MSG'
feat: Metal 2D 컴포지터 추가

직교 투영 공간에 텍스처 쿼드를 겹쳐 그린다. 씬의 레이어 순서가 그리는 순서다.

셰이더는 .metal 파일이 아니라 런타임 컴파일한다. SwiftPM 리소스 번들 설정을
피하고, M4에서 사용자 셰이더를 처리할 때도 같은 경로를 쓰게 된다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

### Task 7: `SceneRenderer`와 앱 연결

M1의 렌더러 프로토콜에 씬 렌더러를 붙이고, 메뉴에서 씬을 고를 수 있게 한다.

**Files:**
- Create: `Sources/WallflowApp/SceneRenderer.swift`
- Modify: `Sources/WallflowApp/DisplayManager.swift` (`.scene` 분기를 `SceneRenderer`로)
- Modify: `Sources/WallflowApp/MenuBarController.swift` (씬 항목 활성화)

**Interfaces:**
- Consumes: `WallpaperRenderer`, `RendererError` (M1), `MetalCompositor`, `QuadInstance` (Task 6), `PkgReader`, `SceneDocument`, `TexDecoder` (Task 1~4)
- Produces: `final class SceneRenderer: WallpaperRenderer` — `init(item: WallpaperItem)`

- [ ] **Step 1: `SceneRenderer` 작성**

```swift
import AppKit
import Metal
import MetalKit
import WallflowKit

/// scene.pkg를 열어 이미지 레이어를 Metal로 그린다.
///
/// M2가 그리는 것은 이미지 레이어뿐이다. 파티클·텍스트·이펙트·비디오 텍스처는
/// SceneDocument가 unsupported로 표시하며, 여기서는 조용히 건너뛴다.
/// 그릴 수 있는 레이어가 하나도 없으면 start()가 던져 상위가 preview로 폴백한다.
@MainActor
final class SceneRenderer: NSObject, WallpaperRenderer {
    private let item: WallpaperItem
    private var view: MTKView?
    private var compositor: MetalCompositor?
    private var skipped: [String] = []

    init(item: WallpaperItem) {
        self.item = item
        super.init()
    }

    func makeView() -> NSView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.autoresizingMask = [.width, .height]
        view.isPaused = true                 // 정적 씬이라 필요할 때만 그린다
        view.enableSetNeedsDisplay = true
        view.delegate = self
        self.view = view
        return view
    }

    func start() throws {
        guard let view, let device = view.device else {
            throw RendererError.unsupportedType(.scene)
        }

        // project.json의 file은 scene.json을 가리키지만 실제 데이터는 scene.pkg에 있다.
        let raw = try Data(
            contentsOf: item.directory.appendingPathComponent("scene.pkg"),
            options: .mappedIfSafe
        )
        let reader = try PkgReader(data: raw)
        let document = try SceneDocument.load(from: reader)

        let compositor = try MetalCompositor(device: device)
        compositor.setProjection(width: document.orthoWidth, height: document.orthoHeight)
        if document.clearEnabled {
            compositor.setClearColor(MTLClearColor(
                red: document.clearColor.x, green: document.clearColor.y,
                blue: document.clearColor.z, alpha: 1
            ))
        }

        var drawable: [(QuadInstance, MTLTexture)] = []
        for layer in document.layers where layer.visible {
            guard case .image(let path) = layer.content else {
                if case .unsupported(let reason) = layer.content {
                    skipped.append("\(layer.name): \(reason)")
                }
                continue
            }
            do {
                let texture = try compositor.makeTexture(
                    from: try TexDecoder.decode(try reader.data(for: path))
                )
                drawable.append((
                    QuadInstance(
                        origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                        size: SIMD2(Float(layer.size.x), Float(layer.size.y))
                    ),
                    texture
                ))
            } catch {
                skipped.append("\(layer.name): 텍스처 로드 실패 \(error)")
            }
        }

        guard !drawable.isEmpty else {
            throw RendererError.unsupportedType(.scene)
        }

        compositor.setLayers(drawable)
        self.compositor = compositor

        if !skipped.isEmpty {
            FileHandle.standardError.write(Data(
                "씬 \(item.title)에서 건너뛴 레이어 \(skipped.count)개:\n  "
                    .appending(skipped.joined(separator: "\n  "))
                    .appending("\n").utf8
            ))
        }
        view.needsDisplay = true
    }

    func apply(_ directive: PlaybackDirective) {
        // M2의 씬은 정적이라 프레임레이트가 의미 없다. 정지 시 그리기만 멈춘다.
        switch directive {
        case .paused: view?.isHidden = true
        case .playing:
            view?.isHidden = false
            view?.needsDisplay = true
        }
    }

    func stop() {
        compositor = nil
        view?.delegate = nil
    }
}

extension SceneRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        compositor?.draw(in: view)
    }
}
```

- [ ] **Step 2: `DisplayManager`의 분기 교체**

`attach(_:to:)`의 switch에서 `.scene` 케이스를 바꾼다. 기존:

```swift
        case .scene, .unsupported:
            // M1은 씬을 렌더하지 않는다. preview로 대신한다.
            showPreview(item, in: window)
            throw RendererError.unsupportedType(item.type)
```

이것을 다음으로 바꾼다:

```swift
        case .scene:
            renderer = SceneRenderer(item: item)
        case .unsupported:
            showPreview(item, in: window)
            throw RendererError.unsupportedType(item.type)
```

`attach`는 이미 `renderer.start()` 실패 시 `showPreview`로 폴백하고 다시 던지므로,
그릴 수 있는 레이어가 없는 씬은 자동으로 preview 정지 이미지가 된다. 추가 처리가 필요 없다.

- [ ] **Step 3: 메뉴에서 씬을 고를 수 있게 한다**

`MenuBarController.rebuildMenu()`의 이 줄:

```swift
                // M1은 씬을 재생하지 못한다. 고를 수 없게 둔다.
                menuItem.isEnabled = (item.type == .video || item.type == .web)
```

이것을 다음으로 바꾼다:

```swift
                // 씬은 M2부터 이미지 레이어를 그린다. 못 그리면 preview로 폴백한다.
                menuItem.isEnabled = (item.type != .unsupported)
```

- [ ] **Step 4: 빌드하고 전체 테스트**

Run: `swift build && swift test`
Expected: 빌드 경고 0, 테스트 전부 통과

Run: `WALLFLOW_TEST_SCENES=~/Downloads/431960 swift test`
Expected: `RealScenesTests` 포함 전부 통과

- [ ] **Step 5: 실사용 검증**

```bash
./Scripts/bundle.sh
LIB=~/Library/Application\ Support/Wallflow/Library
ln -sfn ~/Downloads/431960/3714517753 "$LIB/3714517753"
open build/Wallflow.app
```

메뉴바에서 `3714517753`을 고른다.

확인할 것:
1. 배경에 캐릭터 일러스트가 뜬다 (`preview.jpg`와 같은 그림이어야 한다).
2. 그림이 화면을 채우고, 위아래나 좌우가 뒤집혀 있지 않다.
3. 데스크톱 아이콘이 그림 위에 보인다.
4. stderr에 건너뛴 레이어(파티클 3개, 텍스트 2개)가 보고된다.

그림이 상하로 뒤집혀 보이면 셰이더의 Y 변환이나 `MTKTextureLoader`의 원점 규약이
어긋난 것이다. 셰이더의 `out.uv`를 `float2(in.position.x + 0.5, 0.5 - in.position.y)`로
바꿔 확인하고, 어느 쪽이 맞았는지 주석으로 남긴다.

- [ ] **Step 6: 커밋**

```bash
git add Sources/WallflowApp/SceneRenderer.swift Sources/WallflowApp/DisplayManager.swift Sources/WallflowApp/MenuBarController.swift
git commit -m "$(cat <<'MSG'
feat: 씬 렌더러를 앱에 연결해 M2 완성

scene.pkg의 이미지 레이어를 Metal로 그린다. 그리지 못하는 레이어는
이유와 함께 건너뛰고, 그릴 것이 하나도 없으면 preview 정지 이미지로 폴백한다.

메뉴에서 씬을 고를 수 있게 한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GaezNUBvKv1iGd9gnzfFpS
MSG
)"
```

---

## M2 완료 조건

- `swift test`가 전부 통과하고, `WALLFLOW_TEST_SCENES`를 준 실행에서도 통과한다.
- 클린 빌드 경고 0건.
- 메뉴바에서 `3714517753`을 골랐을 때 배경 일러스트가 올바른 방향과 크기로 뜬다.
- 그리지 못한 레이어가 stderr에 이유와 함께 보고된다.

## M2가 의도적으로 하지 않는 것

- 파티클·텍스트·시계 — M3.
- 비디오 텍스처 렌더링 — 디코더는 MP4를 꺼내지만 화면에 그리지는 않는다. M3에서
  AVFoundation과 잇는다. 그때까지 그 두 씬은 preview 폴백이다.
- 커스텀 셰이더와 이펙트 패스 — M4. `assets/` 반입이 선행 조건이다.
- 오디오 반응, 마우스 패럴랙스, 스크립팅 — M4.
- 밉맵 활용. 0번만 쓴다.
