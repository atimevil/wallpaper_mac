import XCTest
@testable import WallflowKit

final class DXTTests: XCTestCase {
    /// 블록 압축은 4x4 블록 단위다. 픽셀 곱셈으로 크기를 구하면 어긋난다.
    func testBlockByteCount() {
        // 1024x1024 → 256x256 블록 × 16바이트
        XCTAssertEqual(TexPixelFormat.dxt5.byteCount(width: 1024, height: 1024), 1048576)
        // 16x16 → 4x4 블록 × 16
        XCTAssertEqual(TexPixelFormat.dxt5.byteCount(width: 16, height: 16), 256)
        // 4의 배수가 아니면 올림한다. 5x5 → 2x2 블록 × 16
        XCTAssertEqual(TexPixelFormat.dxt5.byteCount(width: 5, height: 5), 64)
    }

    func testBlockBytesPerRow() {
        XCTAssertEqual(TexPixelFormat.dxt5.bytesPerRow(width: 1024), 256 * 16)
        XCTAssertEqual(TexPixelFormat.dxt5.bytesPerRow(width: 5), 2 * 16)
        XCTAssertEqual(TexPixelFormat.rgba8888.bytesPerRow(width: 100), 400)
    }

    /// 치수는 파일에서 온다. 곱셈이 넘치면 트랩이 아니라 nil이어야 한다.
    func testOverflowReturnsNil() {
        XCTAssertNil(TexPixelFormat.dxt5.byteCount(width: Int.max, height: Int.max))
        XCTAssertNil(TexPixelFormat.rgba8888.byteCount(width: Int.max, height: Int.max))
        XCTAssertNil(TexPixelFormat.dxt5.byteCount(width: 0, height: 10))
        XCTAssertNil(TexPixelFormat.dxt5.byteCount(width: -1, height: 10))
    }

    /// DXT1은 블록당 8바이트다. DXT5와 같은 16으로 재면 크기가 두 배로 어긋난다.
    func testDXT1BlockByteCount() {
        // 실물 absbg.tex: 2560x1728 → 640x432 블록 × 8바이트
        XCTAssertEqual(TexPixelFormat.dxt1.byteCount(width: 2560, height: 1728), 2211840)
        XCTAssertEqual(TexPixelFormat.dxt1.bytesPerRow(width: 2560), 640 * 8)
        XCTAssertEqual(TexPixelFormat.dxt1.bytesPerBlock, 8)
        XCTAssertEqual(TexPixelFormat.dxt5.bytesPerBlock, 16)
        // 두 포맷이 같은 값을 내면 안 된다. 하나로 뭉개면 절반만 읽는다.
        XCTAssertNotEqual(
            TexPixelFormat.dxt1.byteCount(width: 256, height: 256),
            TexPixelFormat.dxt5.byteCount(width: 256, height: 256))
    }

    /// DXT3은 DXT5와 블록 크기(16바이트)가 같아 별도 case로 안 나누면 서로
    /// 뭉개진다. bytesPerBlock/bytesPerPixel이 각자 값을 내야 한다.
    func testDXT3BlockByteCount() {
        // 실물 3000562427의 VinylDisc.tex: 304x304 → 76x76 블록 × 16바이트
        XCTAssertEqual(TexPixelFormat.dxt3.byteCount(width: 304, height: 304), 92416)
        XCTAssertEqual(TexPixelFormat.dxt3.bytesPerBlock, 16)
        XCTAssertTrue(TexPixelFormat.dxt3.isBlockCompressed)
        XCTAssertEqual(TexPixelFormat(rawValue: 6), .dxt3)
    }

    /// 실물 DXT5 텍스처가 디코드되어야 한다. 이전에는 통째로 떨어졌다.
    func testRealDXTTexturesDecode() throws {
        guard let path = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"] else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let root = URL(fileURLWithPath: path)
        var checked = 0
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        for case let p as String in walker where p.hasSuffix(".tex") {
            guard let d = try? Data(contentsOf: root.appendingPathComponent(p)),
                  let h = try? TexHeader.parse(d), h.format == 4 else { continue }
            checked += 1
            guard case .pixels(let bytes, let w, let hh, let fmt) = try TexDecoder.decode(d) else {
                return XCTFail("\(p): 원시 픽셀이어야 한다")
            }
            XCTAssertEqual(fmt, .dxt5, p)
            XCTAssertEqual(bytes.count, TexPixelFormat.dxt5.byteCount(width: w, height: hh), p)
        }
        XCTAssertEqual(checked, 9, "실물 DXT5 텍스처 9개를 모두 확인해야 한다")
    }

    /// 실물 DXT3(format=6) 텍스처가 디코드되어야 한다.
    /// 워크숍 3000562427(Summer in the City)의 day_photoshop·night_photoshop·
    /// VinylDisc 3장이 이 포맷이다 — 전에는 unsupportedPixelFormat(6)으로 통째로 떨어졌다.
    func testRealDXT3TexturesDecode() throws {
        guard let scenesPath = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"] else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let root = URL(fileURLWithPath: NSString(string: scenesPath).expandingTildeInPath)
        var checked = 0
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let pkgURL = root.appendingPathComponent(dir).appendingPathComponent("scene.pkg")
            guard let pkgData = try? Data(contentsOf: pkgURL),
                  let reader = try? PkgReader(data: pkgData) else { continue }
            for name in reader.names where name.hasSuffix(".tex") {
                guard let d = try? reader.data(for: name),
                      let h = try? TexHeader.parse(d), h.format == 6 else { continue }
                checked += 1
                guard case .pixels(let bytes, let w, let hh, let fmt) = try TexDecoder.decode(d) else {
                    return XCTFail("\(dir)/\(name): 원시 픽셀이어야 한다")
                }
                XCTAssertEqual(fmt, .dxt3, "\(dir)/\(name)")
                XCTAssertEqual(bytes.count, TexPixelFormat.dxt3.byteCount(width: w, height: hh), "\(dir)/\(name)")
            }
        }
        XCTAssertEqual(checked, 3, "실물 DXT3 텍스처 3개(day/night/VinylDisc)를 모두 확인해야 한다")
    }
}
