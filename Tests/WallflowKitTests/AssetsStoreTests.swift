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
        // Leading slash is caught early by the guard.
        XCTAssertThrowsError(try store.data(for: "/etc/passwd")) { error in
            guard case AssetsError.escapesRoot = error else {
                return XCTFail("expected escapesRoot, got \(error)")
            }
        }
        // Paths that normalize to absolute reach the prefix check.
        XCTAssertThrowsError(try store.data(for: "foo/bar/../../../../../../etc/passwd")) { error in
            guard case AssetsError.escapesRoot = error else {
                return XCTFail("expected escapesRoot, got \(error)")
            }
        }
    }

    func testEmptyNameIsRejected() throws {
        let store = AssetsStore(root: root)
        XCTAssertThrowsError(try store.data(for: "")) { error in
            XCTAssertEqual(error as? AssetsError, .escapesRoot(""))
        }
    }

    /// 디렉터리를 파일처럼 읽으려 하면 오류여야 한다.
    func testDirectoryIsNotAFile() throws {
        try write("models/util/x.json", "{}")
        let store = AssetsStore(root: root)
        XCTAssertFalse(store.contains("models/util"))
        XCTAssertThrowsError(try store.data(for: "models/util")) { error in
            XCTAssertEqual(error as? AssetsError, .notFound("models/util"))
        }
    }

    func testMissingRootYieldsNotFoundRatherThanCrash() throws {
        let store = AssetsStore(root: root.appendingPathComponent("does-not-exist"))
        XCTAssertFalse(store.contains("anything.json"))
        XCTAssertThrowsError(try store.data(for: "anything.json"))
    }

    /// standardizedFileURL은 심볼릭 링크를 해석하지 않는다.
    /// 에셋 폴더 안의 링크가 밖을 가리키면 접두사 검사만으로는 막지 못한다.
    func testSymlinkPointingOutsideRootIsRejected() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("루트 밖의 내용".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("leak"), withDestinationURL: outside)

        let store = AssetsStore(root: root)
        XCTAssertFalse(store.contains("leak"), "심링크가 루트 밖을 가리키면 없는 것으로 봐야 한다")
        XCTAssertThrowsError(try store.data(for: "leak")) { error in
            XCTAssertEqual(error as? AssetsError, .escapesRoot("leak"))
        }
    }
}
