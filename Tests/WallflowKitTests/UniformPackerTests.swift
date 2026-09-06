import XCTest
@testable import WallflowKit

/// 유니폼 버퍼가 셰이더의 `struct Uniforms`와 바이트 단위로 같아야 한다.
/// 여기가 틀리면 **컴파일도 되고 그리기도 되는데 값만 어긋난다** — 색이 이상하거나
/// 속도가 엉뚱해지고, 화면만 봐서는 원인을 못 찾는다.
final class UniformPackerTests: XCTestCase {
    /// MSL에서 `float3`는 12바이트가 아니라 **16바이트**를 차지한다.
    /// 12로 세면 뒤따르는 멤버가 전부 4바이트씩 밀린다 — 가장 자주 틀리는 곳이다.
    func testVec3OccupiesSixteenBytes() {
        let layout = UniformPacker.layout(for: [("a", "vec3", nil), ("b", "float", nil)])
        XCTAssertEqual(layout.field(named: "a")?.offset, 0)
        XCTAssertEqual(layout.field(named: "b")?.offset, 16, "vec3를 12로 셌다")
        XCTAssertEqual(layout.size, 32, "전체 크기는 최대 정렬(16)의 배수로 올림한다")
    }

    /// 각 멤버는 자기 크기만큼 정렬된다. `float` 다음의 `vec2`는 4가 아니라 8에 온다.
    func testMembersAreAlignedToTheirOwnSize() {
        let layout = UniformPacker.layout(for: [
            ("t", "float", nil), ("scale", "vec2", nil), ("flag", "float", nil), ("color", "vec4", nil),
        ])
        XCTAssertEqual(layout.field(named: "t")?.offset, 0)
        XCTAssertEqual(layout.field(named: "scale")?.offset, 8)
        XCTAssertEqual(layout.field(named: "flag")?.offset, 16)
        XCTAssertEqual(layout.field(named: "color")?.offset, 32)
        XCTAssertEqual(layout.size, 48)
    }

    func testMatrixSizes() {
        XCTAssertEqual(UniformPacker.layout(for: [("m", "mat4", nil)]).size, 64)
        XCTAssertEqual(UniformPacker.layout(for: [("m", "mat3", nil)]).size, 48)
    }

    /// 모르는 타입이 나오면 **거기서 멈춘다.** 크기를 모르면 뒤따르는 멤버의 자리를
    /// 알 수 없으므로, 건너뛰고 계속하면 그 뒤가 전부 조용히 어긋난다.
    func testUnknownTypeStopsTheLayout() {
        let layout = UniformPacker.layout(for: [
            ("a", "float", nil), ("weird", "sampler3D", nil), ("b", "float", nil),
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
        let layout = UniformPacker.layout(for: [("t", "float", nil), ("color", "vec3", nil)])
        let bytes = UniformPacker.pack(["t": [0.5], "color": [1, 2, 3]], into: layout)
        XCTAssertEqual(bytes.count, 32)
        XCTAssertEqual(readFloat(bytes, at: 0), 0.5)
        XCTAssertEqual(readFloat(bytes, at: 16), 1)
        XCTAssertEqual(readFloat(bytes, at: 20), 2)
        XCTAssertEqual(readFloat(bytes, at: 24), 3)
    }

    /// `mat3`는 열마다 16바이트씩 차지한다. 성분 9개를 연속으로 쓰면 행렬이 뒤틀린다.
    func testMat3ColumnsArePadded() {
        let layout = UniformPacker.layout(for: [("m", "mat3", nil)])
        let bytes = UniformPacker.pack(["m": [1, 2, 3, 4, 5, 6, 7, 8, 9]], into: layout)
        XCTAssertEqual(readFloat(bytes, at: 0), 1)
        XCTAssertEqual(readFloat(bytes, at: 8), 3)
        XCTAssertEqual(readFloat(bytes, at: 16), 4, "둘째 열이 16바이트에서 시작해야 한다")
        XCTAssertEqual(readFloat(bytes, at: 32), 7, "셋째 열이 32바이트에서 시작해야 한다")
    }

    /// 값을 안 준 멤버는 0이다. 쓰레기 값이 들어가면 그 픽셀이 사라질 수 있다.
    func testUnsetFieldsAreZero() {
        let layout = UniformPacker.layout(for: [("a", "float", nil), ("b", "float", nil)])
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

    /// 배열 유니폼. 오디오 스펙트럼이 `uniform float g_AudioSpectrum32Left[32]`로 온다.
    /// 배열을 모르면 배치가 거기서 멈춰, 뒤따르는 유니폼이 전부 사라진다.
    func testArrayUniformTakesElementTimesSize() {
        let layout = UniformPacker.layout(for: [
            ("bars", "float", 16), ("color", "vec3", nil),
        ])
        XCTAssertEqual(layout.field(named: "bars")?.offset, 0)
        XCTAssertEqual(layout.field(named: "bars")?.count, 16)
        // 16 * 4바이트 = 64, 그 다음 vec3는 16 정렬이라 64에 온다.
        XCTAssertEqual(layout.field(named: "color")?.offset, 64)
        XCTAssertEqual(layout.size, 80)
    }

    func testArrayValuesLandInOrder() {
        let layout = UniformPacker.layout(for: [("bars", "float", 4)])
        let bytes = UniformPacker.pack(["bars": [1, 2, 3, 4]], into: layout)
        XCTAssertEqual(readFloat(bytes, at: 0), 1)
        XCTAssertEqual(readFloat(bytes, at: 12), 4)
    }

    /// 셰이더는 창작마당에서 온 텍스트다. `float x[999999999]` 하나가
    /// 버퍼를 통째로 부풀리면 안 된다.
    func testAbsurdArrayLengthStopsTheLayout() {
        let layout = UniformPacker.layout(for: [
            ("huge", "float", 999_999_999), ("after", "float", nil),
        ])
        XCTAssertTrue(layout.fields.isEmpty)
        XCTAssertNil(layout.field(named: "after"))
    }

    /// 필드가 차지하는 바이트. 타입만 보고 재면 `float x[32]`가 4바이트로
    /// 계산되어, 덮어쓸 때 첫 원소만 바뀐다 — 오디오 스펙트럼이 통째로 0으로
    /// 남는 원인이었다.
    func testFieldByteCountCoversTheWholeArray() {
        let layout = UniformPacker.layout(for: [
            ("bars", "float", 32), ("color", "vec3", nil), ("m", "mat3", nil),
        ])
        XCTAssertEqual(layout.field(named: "bars")?.byteCount, 128)
        // `float3`는 12를 쓰지만 **16바이트를 차지한다.** 덮어쓸 때 그 자리가
        // 다음 필드를 침범하지 않는지가 여기 달려 있다.
        XCTAssertEqual(layout.field(named: "color")?.byteCount, 16)
        // mat3는 열마다 16바이트라 48이다.
        XCTAssertEqual(layout.field(named: "m")?.byteCount, 48)
    }

    /// 값은 공백으로도 쉼표로도 나뉜다. 공백만 보면 `"0.0, 1.0"`이 성분 하나로
    /// 읽혀 벡터가 스칼라가 된다 — 실물 주석 기본값이 이 꼴이다.
    func testCommaSeparatedValuesParse() {
        XCTAssertEqual(EffectConstant.parse("0.02, 0.02"), .vector([0.02, 0.02]))
        XCTAssertEqual(EffectConstant.parse("0.0, 360.0"), .vector([0, 360]))
        XCTAssertEqual(EffectConstant.parse("1 1 1"), .vector([1, 1, 1]))
    }
}
