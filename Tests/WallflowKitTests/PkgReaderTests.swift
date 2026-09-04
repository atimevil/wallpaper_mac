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
