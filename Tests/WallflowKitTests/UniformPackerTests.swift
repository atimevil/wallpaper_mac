import XCTest
@testable import WallflowKit

/// 유니폼 버퍼가 셰이더의 `struct Uniforms`와 바이트 단위로 같아야 한다.
/// 여기가 틀리면 **컴파일도 되고 그리기도 되는데 값만 어긋난다** — 색이 이상하거나
/// 속도가 엉뚱해지고, 화면만 봐서는 원인을 못 찾는다.
final class UniformPackerTests: XCTestCase {
    /// MSL에서 `float3`는 12바이트가 아니라 **16바이트**를 차지한다.
    /// 12로 세면 뒤따르는 멤버가 전부 4바이트씩 밀린다 — 가장 자주 틀리는 곳이다.
    func testVec3OccupiesSixteenBytes() {
        let layout = UniformPacker.layout(for: [("a", "vec3"), ("b", "float")])
        XCTAssertEqual(layout.field(named: "a")?.offset, 0)
        XCTAssertEqual(layout.field(named: "b")?.offset, 16, "vec3를 12로 셌다")
        XCTAssertEqual(layout.size, 32, "전체 크기는 최대 정렬(16)의 배수로 올림한다")
    }

    /// 각 멤버는 자기 크기만큼 정렬된다. `float` 다음의 `vec2`는 4가 아니라 8에 온다.
    func testMembersAreAlignedToTheirOwnSize() {
        let layout = UniformPacker.layout(for: [
            ("t", "float"), ("scale", "vec2"), ("flag", "float"), ("color", "vec4"),
        ])
        XCTAssertEqual(layout.field(named: "t")?.offset, 0)
        XCTAssertEqual(layout.field(named: "scale")?.offset, 8)
        XCTAssertEqual(layout.field(named: "flag")?.offset, 16)
        XCTAssertEqual(layout.field(named: "color")?.offset, 32)
        XCTAssertEqual(layout.size, 48)
    }

    func testMatrixSizes() {
        XCTAssertEqual(UniformPacker.layout(for: [("m", "mat4")]).size, 64)
        XCTAssertEqual(UniformPacker.layout(for: [("m", "mat3")]).size, 48)
    }

    /// 모르는 타입이 나오면 **거기서 멈춘다.** 크기를 모르면 뒤따르는 멤버의 자리를
    /// 알 수 없으므로, 건너뛰고 계속하면 그 뒤가 전부 조용히 어긋난다.
    func testUnknownTypeStopsTheLayout() {
        let layout = UniformPacker.layout(for: [
            ("a", "float"), ("weird", "sampler3D"), ("b", "float"),
        ])
        XCTAssertEqual(layout.fields.map(\.name), ["a"])
        XCTAssertNil(layout.field(named: "b"))
    }

    /// 빈 구조체는 MSL이 거부해서 번역기가 `float _unused;`를 넣는다.
    /// 버퍼 크기가 0이면 Metal이 바인딩을 거부한다.
    func testEmptyLayoutStillHasSize() {
        XCTAssertEqual(UniformPacker.layout(for: []).size, 4)
    }

    func testPackedValuesLandAtTheirOffsets() {
        let layout = UniformPacker.layout(for: [("t", "float"), ("color", "vec3")])
        let bytes = UniformPacker.pack(["t": [0.5], "color": [1, 2, 3]], into: layout)
        XCTAssertEqual(bytes.count, 32)
        XCTAssertEqual(readFloat(bytes, at: 0), 0.5)
        XCTAssertEqual(readFloat(bytes, at: 16), 1)
        XCTAssertEqual(readFloat(bytes, at: 20), 2)
        XCTAssertEqual(readFloat(bytes, at: 24), 3)
    }

    /// `mat3`는 열마다 16바이트씩 차지한다. 성분 9개를 연속으로 쓰면 행렬이 뒤틀린다.
    func testMat3ColumnsArePadded() {
        let layout = UniformPacker.layout(for: [("m", "mat3")])
        let bytes = UniformPacker.pack(["m": [1, 2, 3, 4, 5, 6, 7, 8, 9]], into: layout)
        XCTAssertEqual(readFloat(bytes, at: 0), 1)
        XCTAssertEqual(readFloat(bytes, at: 8), 3)
        XCTAssertEqual(readFloat(bytes, at: 16), 4, "둘째 열이 16바이트에서 시작해야 한다")
        XCTAssertEqual(readFloat(bytes, at: 32), 7, "셋째 열이 32바이트에서 시작해야 한다")
    }

    /// 값을 안 준 멤버는 0이다. 쓰레기 값이 들어가면 그 픽셀이 사라질 수 있다.
    func testUnsetFieldsAreZero() {
        let layout = UniformPacker.layout(for: [("a", "float"), ("b", "float")])
        let bytes = UniformPacker.pack(["a": [7]], into: layout)
        XCTAssertEqual(readFloat(bytes, at: 4), 0)
    }

    /// 씬이 준 값이 셰이더가 기대하는 성분 수와 다를 수 있다.
    func testConstantsFitTheDeclaredComponentCount() {
        XCTAssertEqual(EffectConstant.vector([1, 2, 3, 4]).components(2), [1, 2])
        XCTAssertEqual(EffectConstant.vector([1, 2]).components(4), [1, 2, 0, 0])
    }

    /// 스칼라를 벡터 자리에 주는 씬이 있다. GLSL의 `vec3(x)`처럼 **모든 성분**에
    /// 같은 값이 들어가야 한다 — 0으로 채우면 색이 검게 죽는다.
    func testScalarFillsEveryComponent() {
        XCTAssertEqual(EffectConstant.scalar(0.5).components(3), [0.5, 0.5, 0.5])
    }

    /// 비유한값이 셰이더까지 흘러가면 그 픽셀이 통째로 사라진다.
    func testNonFiniteConstantsAreRejected() {
        XCTAssertNil(EffectConstant.parse("nan nan nan"))
        XCTAssertNil(EffectConstant.parse(Double.infinity))
        XCTAssertNil(EffectConstant.parse("글자"))
        XCTAssertNil(EffectConstant.parse([1, 2]))
    }

    func testConstantParsesScalarsAndVectors() {
        XCTAssertEqual(EffectConstant.parse(0.39), .scalar(0.39))
        XCTAssertEqual(EffectConstant.parse("0.66 1.01"), .vector([0.66, 1.01]))
        XCTAssertEqual(EffectConstant.parse("1"), .scalar(1))
    }

    /// 범위를 넘으면 트랩 대신 NaN을 돌려준다. 배치가 틀렸을 때 테스트가
    /// **죽어 버리면** 어느 단언이 왜 실패했는지 보고되지 않는다.
    private func readFloat(
        _ bytes: [UInt8], at offset: Int, file: StaticString = #filePath, line: UInt = #line
    ) -> Float {
        guard offset >= 0, offset + 4 <= bytes.count else {
            XCTFail("버퍼 밖을 읽었다: \(offset) / \(bytes.count)바이트", file: file, line: line)
            return .nan
        }
        var pattern: UInt32 = 0
        for index in 0..<4 { pattern |= UInt32(bytes[offset + index]) << (8 * index) }
        return Float(bitPattern: pattern)
    }
}
