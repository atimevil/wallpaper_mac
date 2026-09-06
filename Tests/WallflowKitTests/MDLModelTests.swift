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
