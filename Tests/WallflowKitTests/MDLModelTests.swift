import XCTest
@testable import WallflowKit

/// `.mdl` 3D 메시. 문서가 없어 실물 둘의 바이트에서 배치를 알아냈다.
final class MDLModelTests: XCTestCase {
    /// 실물 배치대로 최소 파일을 합성한다.
    private func build(materials: [String] = ["materials/a.json"], bones: Int = 0,
                       vertices: [[Float]] = [[0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0]],
                       indices: [UInt16] = [0], tail: Int = 7) -> Data {
        var d = Data("MDLV0023".utf8); d.append(0)
        func i32(_ v: Int32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        i32(15); i32(Int32(materials.count)); i32(1)
        for m in materials { d.append(Data(m.utf8)); d.append(0) }
        i32(Int32(bones))
        for v in [-1, -2, -3, 1, 2, 3] as [Float] { f32(v) }
        i32(15); i32(Int32(vertices.count * 48))
        for v in vertices { for x in v { f32(x) } }
        i32(Int32(indices.count * 2))
        for i in indices { var x = i.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data(repeating: 0, count: tail))
        return d
    }

    func testParsesSyntheticModel() throws {
        let model = try MDLModel.parse(build(
            materials: ["materials/a.json", "materials/b.json"],
            vertices: [[0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0],
                       [1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0],
                       [0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 0, 1]],
            indices: [0, 1, 2]))
        XCTAssertEqual(model.materials, ["materials/a.json", "materials/b.json"])
        XCTAssertEqual(model.boneCount, 0)
        XCTAssertEqual(model.vertexCount, 3)
        XCTAssertEqual(model.indices, [0, 1, 2])
        XCTAssertEqual(model.boundsMin, Vec3(x: -1, y: -2, z: -3))
        XCTAssertEqual(model.boundsMax, Vec3(x: 1, y: 2, z: 3))
    }

    /// 정점이 65,536개를 넘으면 색인이 `uint16`이 아니라 `uint32`다.
    /// `uint16`으로 잘못 읽으면 두 색인마다 하나는 0으로 밀려나(`(0,0),(1,0),(2,0)`
    /// 꼴) 색인 수가 실제의 두 배가 되고 삼각형이 통째로 망가진다.
    func testVertexCountAbove65535UsesFourByteIndices() throws {
        let vertexCount = 70000
        var vertices: [[Float]] = []
        vertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount { vertices.append([0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0]) }
        var d = Data("MDLV0023".utf8); d.append(0)
        func i32(_ v: Int32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        i32(15); i32(1); i32(1)
        d.append(Data("materials/a.json".utf8)); d.append(0)
        i32(0)
        for v in [-1, -1, -1, 1, 1, 1] as [Float] { f32(v) }
        i32(15); i32(Int32(vertexCount * 48))
        for v in vertices { for x in v { f32(x) } }
        // 정점 65,536개를 막 넘긴 자리를 가리키는 uint32 색인 셋 — uint16이었다면
        // 이 값 자체를 담지도 못한다(최댓값 65,535).
        let indices: [UInt32] = [0, 65_536, 69_999]
        i32(Int32(indices.count * 4))
        for i in indices { var x = i.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        d.append(Data(repeating: 0, count: 7))

        let model = try MDLModel.parse(d)
        XCTAssertEqual(model.vertexCount, vertexCount)
        XCTAssertEqual(model.indices, indices)
    }

    /// 실물 토성 몸체(정점 849,202개, uint32 색인). 여기서 이 배치를 알아냈으므로
    /// 여기서 맞아야 한다 — `MDLError.tooLarge`로 통째로 못 읽던 게 회귀 기준이다.
    func testParsesRealSaturnBody() throws {
        let pkg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960/3589454154/scene.pkg")
        guard let data = try? Data(contentsOf: pkg) else { throw XCTSkip("토성 씬이 설치되어 있지 않다") }
        let reader = try PkgReader(data: data)
        let model = try MDLModel.parse(try reader.data(for: "models/球体01/球体01.mdl"))
        XCTAssertEqual(model.vertexCount, 849_202)
        XCTAssertEqual(model.indices.count, 3_121_152)
        XCTAssertEqual(model.indices.max(), 849_201, "마지막 정점을 가리켜야 한다")
        XCTAssertEqual(model.indices.count % 3, 0, "삼각형 목록이어야 한다")
    }

    /// 실물 `MDLV0016`(Hollow Cylinder, Three-Body 씬의 나침반). 이 버전은
    /// 경계 상자 24바이트가 통째로 없다 — `boneCount` 바로 뒤에 `vertexFormat`이
    /// 온다. 정점 위치에서 직접 잰 경계가 나와야 한다.
    func testParsesRealMDLV0016WithoutBoundsSection() throws {
        let pkg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960/3509243656/scene.pkg")
        guard let data = try? Data(contentsOf: pkg) else { throw XCTSkip("Three-Body 씬이 설치되어 있지 않다") }
        let reader = try PkgReader(data: data)
        let model = try MDLModel.parse(try reader.data(for: "models/Hollow Cylinder/Hollow Cylinder.mdl"))
        XCTAssertEqual(model.vertexCount, 258)
        XCTAssertEqual(model.indices.count, 768)
        XCTAssertEqual(model.indices.count % 3, 0, "삼각형 목록이어야 한다")
        // 정점에서 잰 경계라 원점 대칭에 가까워야 한다(원기둥이라 y만 짧다).
        XCTAssertEqual(model.boundsMin.z, -1.9, accuracy: 0.01)
        XCTAssertEqual(model.boundsMax.z, 1.9, accuracy: 0.01)
    }

    /// 실물 프리즘. 설치돼 있을 때만 — 여기서 배치를 알아냈으므로 여기서 맞아야 한다.
    func testParsesRealPrism() throws {
        let pkg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960/1979606285/scene.pkg")
        guard let data = try? Data(contentsOf: pkg) else { throw XCTSkip("원근 씬이 설치되어 있지 않다") }
        let reader = try PkgReader(data: data)
        let model = try MDLModel.parse(try reader.data(for: "models/prism/prism.mdl"))
        XCTAssertEqual(model.materials, ["materials/prism/prism.json", "materials/prism/prism_main.json"])
        XCTAssertEqual(model.vertexCount, 60)
        XCTAssertEqual(model.indices.count, 96, "192바이트 = uint16 96개")
        XCTAssertEqual(Array(model.indices.prefix(6)), [0, 1, 2, 0, 2, 3], "사각형을 삼각형 둘로")
        XCTAssertEqual(model.boundsMax.y, 10, accuracy: 0.01)
        // 첫 정점의 법선은 단위 길이여야 배치가 맞은 것이다.
        let n: [Float] = model.vertexData.withUnsafeBytes { raw in
            (3..<6).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        XCTAssertEqual((n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).squareRoot(), 1, accuracy: 0.001)
    }

    /// 단위 사각형은 48바이트 정점 넷과 삼각형 둘이다. 배치가 파서와 같아야
    /// 같은 렌더러가 그린다.
    func testUnitQuadMatchesTheVertexLayout() {
        let quad = MDLModel.unitQuad()
        XCTAssertEqual(quad.vertexCount, 4)
        XCTAssertEqual(quad.indices, [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(quad.vertexData.count, 4 * MDLModel.vertexStride)
        let v: [Float] = quad.vertexData.withUnsafeBytes { raw in
            (0..<12).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        XCTAssertEqual(Array(v[0..<3]), [-0.5, -0.5, 0])
        XCTAssertEqual(Array(v[3..<6]), [0, 0, 1], "법선은 +Z")
        XCTAssertEqual(Array(v[6..<10]), [1, 0, 0, 1], "접선은 +X")
        XCTAssertEqual(Array(v[10..<12]), [0, 1], "왼쪽 아래 꼭짓점의 uv는 (0,1)")
    }

    /// 실물 `MDLV0017`(space boi, 서브메시 둘). materialCount·1 자리의 "1"이
    /// 실은 서브메시 수 2다 — 둘째 서브메시는 자기 재질을 따로 들고 온다.
    func testParsesRealMultiSubmeshMDLV0017() throws {
        guard let root = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"] else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent("3047596375/scene.pkg")
        guard let raw = try? Data(contentsOf: url) else { throw XCTSkip("3047596375 없음") }
        let reader = try PkgReader(data: raw)
        let model = try MDLModel.parse(try reader.data(for: "models/space boi/space boi.mdl"))
        XCTAssertEqual(model.materials, ["materials/models/space boi/diffuse_0.json"])
        XCTAssertEqual(model.vertexCount, 21_860)
        XCTAssertEqual(model.indices.count, 98_784)
        XCTAssertEqual(model.extraSubmeshes.count, 1, "서브메시 수 2 = 첫째 + extraSubmeshes 하나")
        let extra = model.extraSubmeshes[0]
        XCTAssertEqual(extra.materialPath, "materials/models/space boi/diffuse_1.json")
        XCTAssertEqual(extra.vertexCount, 39_436)
        XCTAssertEqual(extra.indices.count, 143_208)
        XCTAssertEqual(extra.indices.count % 3, 0, "삼각형 목록이어야 한다")
        XCTAssertEqual(extra.indices.max().map(Int.init), extra.vertexCount - 1)
    }

    func testRejectsBadMagic() {
        var d = build(); d.replaceSubrange(0..<4, with: Data("XXXX".utf8))
        XCTAssertThrowsError(try MDLModel.parse(d)) { XCTAssertEqual($0 as? MDLError, .badMagic("XXXX0023")) }
    }

    /// 잘린 파일은 trap이 아니라 오류다. 창작마당 파일은 믿을 수 없다.
    func testTruncatedFileThrowsInsteadOfTrapping() {
        let whole = build(indices: [0, 0, 0, 0])
        // 꼬리 7바이트는 0으로 채워진 여백이라 없어도 읽힌다. 그 앞에서 잘리면 오류다.
        let body = whole.count - 7
        for cut in stride(from: 8, to: body, by: 7) {
            XCTAssertThrowsError(try MDLModel.parse(whole.prefix(cut)), "\(cut)바이트에서 잘림")
        }
        XCTAssertNoThrow(try MDLModel.parse(whole.prefix(body)), "여백만 없는 파일은 읽힌다")
    }

    /// 정점 밖을 가리키는 색인은 GPU에서 정의되지 않은 읽기다.
    func testOutOfRangeIndexIsRejected() {
        XCTAssertThrowsError(try MDLModel.parse(build(indices: [0, 7]))) {
            XCTAssertEqual($0 as? MDLError, .badIndex(7, vertexCount: 1))
        }
    }

    /// 크기 필드가 미친 값이어도 그만큼 잡지 않는다.
    func testAbsurdSizesAreRejected() {
        var d = build()
        // vertexBytes 자리: magic 9 + 12 + 문자열 17 + 4 + 24 + 4 = 70
        let at = 9 + 12 + ("materials/a.json".utf8.count + 1) + 4 + 24 + 4
        var huge = Int32(1 << 30).littleEndian
        d.replaceSubrange(at..<at + 4, with: Data(bytes: &huge, count: 4))
        XCTAssertThrowsError(try MDLModel.parse(d)) {
            guard case .tooLarge = $0 as? MDLError else { return XCTFail("\($0)") }
        }
    }
}
