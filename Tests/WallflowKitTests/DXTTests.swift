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
}
