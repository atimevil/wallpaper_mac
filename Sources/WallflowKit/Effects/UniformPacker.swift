import Foundation

/// 셰이더의 `struct Uniforms`와 **바이트 단위로 같은** 버퍼를 만든다.
///
/// 여기가 틀리면 컴파일도 되고 그리기도 되는데 **값만 어긋난다** — 색이 이상하거나
/// 속도가 엉뚱해지고, 원인을 화면만 보고는 못 찾는다. 그래서 정렬 규칙을 따로 두고
/// 전수로 테스트한다.
///
/// Metal 셰이딩 언어의 규칙(MSL 사양 §2.4): 각 멤버는 자기 크기만큼 정렬되고,
/// **`float3`는 16바이트를 차지한다**(12가 아니다). 구조체 전체 크기는 가장 큰
/// 정렬의 배수로 올림된다. 이 `float3` 규칙이 가장 자주 틀리는 곳이다.
public enum UniformPacker {
    /// 타입 하나의 크기와 정렬. 모르는 타입은 nil — 지어내면 그 뒤 멤버가 전부 밀린다.
    public static func layout(of type: String) -> (size: Int, alignment: Int, count: Int)? {
        switch type {
        case "float", "int", "bool": return (4, 4, 1)
        case "vec2", "ivec2": return (8, 8, 2)
        // float3는 12바이트를 쓰지만 16바이트로 정렬되고 16바이트를 차지한다.
        case "vec3", "ivec3": return (16, 16, 3)
        case "vec4", "ivec4": return (16, 16, 4)
        case "mat3": return (48, 16, 9)
        case "mat4": return (64, 16, 16)
        default: return nil
        }
    }

    public struct Field: Equatable, Sendable {
        public let name: String
        public let type: String
        public let offset: Int
        public let count: Int
    }

    public struct Layout: Equatable, Sendable {
        public let fields: [Field]
        public let size: Int

        public func field(named name: String) -> Field? {
            fields.first { $0.name == name }
        }
    }

    /// 선언 순서대로 자리를 잡는다. 모르는 타입이 나오면 **그 멤버만 건너뛰는 게
    /// 아니라 거기서 멈춘다** — 크기를 모르면 뒤따르는 멤버의 자리를 알 수 없다.
    public static func layout(
        for uniforms: [(name: String, type: String)]
    ) -> Layout {
        var fields: [Field] = []
        var offset = 0
        var maxAlignment = 4
        for uniform in uniforms {
            guard let info = layout(of: uniform.type) else { break }
            offset = align(offset, to: info.alignment)
            fields.append(Field(
                name: uniform.name, type: uniform.type,
                offset: offset, count: info.count))
            offset += info.size
            maxAlignment = Swift.max(maxAlignment, info.alignment)
        }
        // 빈 구조체는 MSL이 거부해서 번역기가 `float _unused;`를 넣는다. 크기를 맞춘다.
        return Layout(fields: fields, size: Swift.max(align(offset, to: maxAlignment), 4))
    }

    static func align(_ offset: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return offset }
        let remainder = offset % alignment
        return remainder == 0 ? offset : offset + (alignment - remainder)
    }

    /// 값을 채운 바이트 배열. 안 채운 자리는 0이다.
    ///
    /// `mat3`는 MSL에서 열마다 16바이트씩 차지한다(12가 아니다). 그래서 성분 9개를
    /// 연속으로 쓰면 안 되고 4개마다 한 칸을 띄운다. 이걸 놓치면 행렬이 뒤틀린다.
    public static func pack(_ values: [String: [Float]], into layout: Layout) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: layout.size)
        for field in layout.fields {
            guard let value = values[field.name] else { continue }
            let stride = field.type == "mat3" ? 4 : 1
            for (index, component) in value.prefix(field.count).enumerated() {
                let slot = field.type == "mat3"
                    ? (index / 3) * stride + (index % 3) : index
                let at = field.offset + slot * 4
                guard at + 4 <= bytes.count else { break }
                withUnsafeBytes(of: component.bitPattern.littleEndian) { raw in
                    for byte in 0..<4 { bytes[at + byte] = raw[byte] }
                }
            }
        }
        return bytes
    }
}
