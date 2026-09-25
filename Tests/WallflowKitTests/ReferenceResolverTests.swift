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

    /// .pkg가 우선이므로, 이 둘에 같은 이름이 있되 .pkg는 깨진 JSON이고 assets는 정상이어도,
    /// json()은 nil을 반환해야 한다. 배경화면 작가의 오류가 표준 에셋을 가리지 않게 하려는 것이다.
    func testPkgWinsEvenWhenMalformed() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("models/x.json", Data("not json".utf8)),
        ]))
        try writeAsset("models/x.json", #"{"from":"assets"}"#)
        let resolver = ReferenceResolver(pkg: pkg, assets: AssetsStore(root: assetsRoot))
        XCTAssertNotNil(resolver.data(for: "models/x.json"), ".pkg 바이트는 존재한다")
        XCTAssertNil(resolver.json(for: "models/x.json"), ".pkg 깨진 JSON이므로 nil")
    }

    /// `firstData`는 철자 후보 전부를 pkg로 먼저 훑어야 한다. 첫 철자가 pkg에
    /// 없고 두 번째 철자가 pkg에 있는데, Assets에는 첫 철자로 다른 내용이 있으면
    /// (실물 1493910771 waterwaves — 씬은 `shaders/effects/waterwaves.frag`로
    /// 담았는데 첫 후보 `effects/waterwaves/shaders/effects/waterwaves.frag`가
    /// Assets에만 있었다) pkg의 두 번째 철자가 이겨야 한다.
    func testFirstDataPrefersPkgAcrossAllCandidatesOverAssetsFirstCandidate() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("shaders/effects/waterwaves.frag", Data("pkg version".utf8)),
        ]))
        try writeAsset(
            "effects/waterwaves/shaders/effects/waterwaves.frag", "assets version")
        let resolver = ReferenceResolver(pkg: pkg, assets: AssetsStore(root: assetsRoot))
        let candidates = [
            "effects/waterwaves/shaders/effects/waterwaves.frag",
            "shaders/effects/waterwaves.frag",
        ]
        let data = try XCTUnwrap(resolver.firstData(of: candidates))
        XCTAssertEqual(String(data: data, encoding: .utf8), "pkg version")
    }

    /// 어느 철자도 pkg에 없으면 그제야 Assets를 본다(순서대로).
    func testFirstDataFallsBackToAssetsWhenNoCandidateIsInPkg() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data("{}".utf8)),
        ]))
        try writeAsset("effects/blur/shaders/effects/blur.frag", "assets version")
        let resolver = ReferenceResolver(pkg: pkg, assets: AssetsStore(root: assetsRoot))
        let candidates = [
            "effects/blur/shaders/effects/blur.frag",
            "shaders/effects/blur.frag",
        ]
        let data = try XCTUnwrap(resolver.firstData(of: candidates))
        XCTAssertEqual(String(data: data, encoding: .utf8), "assets version")
    }

    func testFirstDataNilWhenNoCandidateExistsAnywhere() throws {
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data("{}".utf8)),
        ]))
        let resolver = ReferenceResolver(pkg: pkg, assets: AssetsStore(root: assetsRoot))
        XCTAssertNil(resolver.firstData(of: ["a/x.frag", "x.frag"]))
    }
}
