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
