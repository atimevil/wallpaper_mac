import Foundation

public enum MDLError: Error, Equatable {
    case badMagic(String)
    case truncated(String)
    case tooLarge(String)
    case badIndex(Int, vertexCount: Int)
}

/// Wallpaper Engine의 3D 메시(`.mdl`, `MDLV0023`).
///
/// 형식 문서가 없어 실물 둘(`prism.mdl` 3199B, `sphere.mdl` 32696B)의 바이트를
/// 읽어 알아냈다. 두 파일 모두 이 배치로 끝까지 맞아떨어진다:
///
/// ```
/// "MDLV0023\0"                      9B
/// int32 flags(15) · materialCount · 1
/// materialCount × 널 종료 문자열     재질 JSON 경로. `skin`이 이 배열의 번호다.
/// int32 boneCount(0)                 퍼펫 워프 뼈대. 실물 둘 다 0이다.
/// float32 × 6                        경계 상자 min·max
/// int32 vertexFormat(15) · vertexBytes
/// vertexBytes                        정점 48B: pos3 · normal3 · tangent4 · uv2
/// int32 indexBytes                   uint16 색인. 사각형을 삼각형 둘로 쪼갠 꼴
/// 7B                                 0으로 채워진 꼬리
/// ```
///
/// 첫 정점을 읽으면 법선이 단위 길이이고 접선의 w가 ±1이라 이 해석이 맞다.
/// 창작마당 파일이라 믿을 수 없다 — 크기와 색인 범위를 전부 검사한다.
public struct MDLModel: Equatable, Sendable {
    public static let magic = "MDLV0023"
    /// 정점 하나의 바이트. pos3 + normal3 + tangent4 + uv2 = 12 float.
    public static let vertexStride = 48
    /// 정점 버퍼 상한. 실물 최대가 26KB이고, 1GB짜리 창작마당 파일이 와도
    /// 메모리를 통째로 잡지 않게 한다.
    public static let maxVertexBytes = 64 * 1024 * 1024
    public static let maxIndexBytes = 64 * 1024 * 1024

    public let materials: [String]
    public let boneCount: Int
    public let boundsMin: Vec3
    public let boundsMax: Vec3
    /// 48바이트 정점이 이어진 원본 바이트. 그대로 GPU 버퍼에 올린다.
    public let vertexData: Data
    public let indices: [UInt16]

    public var vertexCount: Int { vertexData.count / Self.vertexStride }

    public init(materials: [String], boneCount: Int, boundsMin: Vec3, boundsMax: Vec3,
                vertexData: Data, indices: [UInt16]) {
        self.materials = materials
        self.boneCount = boneCount
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.vertexData = vertexData
        self.indices = indices
    }

    /// 단위 사각형(-0.5..0.5, z=0). 재질 셰이더로 이미지를 그릴 때 메시 대신 쓴다.
    ///
    /// 법선은 +Z, 접선은 +X, uv는 왼쪽 위가 (0,0)이다 — 이미지 쿼드 경로와
    /// 같은 방향이어야 같은 그림이 같은 쪽을 본다.
    public static func unitQuad() -> MDLModel {
        var floats: [Float] = []
        for (x, y) in [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)] as [(Float, Float)] {
            floats += [x, y, 0,  0, 0, 1,  1, 0, 0, 1,  x + 0.5, 0.5 - y]
        }
        let data = floats.withUnsafeBytes { Data($0) }
        return MDLModel(
            materials: [], boneCount: 0,
            boundsMin: Vec3(x: -0.5, y: -0.5, z: 0), boundsMax: Vec3(x: 0.5, y: 0.5, z: 0),
            vertexData: data, indices: [0, 1, 2, 0, 2, 3])
    }

    public static func parse(_ data: Data) throws -> MDLModel {
        var cursor = Cursor(data: data)
        let magic = try cursor.string(maxLength: 16)
        guard magic == Self.magic else { throw MDLError.badMagic(magic) }
        _ = try cursor.int32()          // flags(15). 뜻은 모른다 — 정점 형식과 같은 값이다.
        let materialCount = try cursor.int32()
        _ = try cursor.int32()          // 1. 메시 수로 보이지만 실물이 전부 1이다.
        guard materialCount >= 0, materialCount <= 64 else {
            throw MDLError.tooLarge("재질 \(materialCount)개")
        }
        var materials: [String] = []
        for _ in 0..<materialCount {
            materials.append(try cursor.string(maxLength: 1024))
        }
        let boneCount = try cursor.int32()
        guard boneCount >= 0, boneCount <= 4096 else { throw MDLError.tooLarge("뼈 \(boneCount)개") }
        let bounds = try (0..<6).map { _ in try cursor.float32() }
        let vertexFormat = try cursor.int32()
        let vertexBytes = try cursor.int32()
        guard vertexBytes > 0, vertexBytes <= Self.maxVertexBytes,
              vertexBytes % Self.vertexStride == 0 else {
            throw MDLError.tooLarge("정점 \(vertexBytes)바이트 (형식 \(vertexFormat))")
        }
        let vertexData = try cursor.bytes(vertexBytes)
        let indexBytes = try cursor.int32()
        guard indexBytes >= 0, indexBytes <= Self.maxIndexBytes, indexBytes % 2 == 0 else {
            throw MDLError.tooLarge("색인 \(indexBytes)바이트")
        }
        let indexData = try cursor.bytes(indexBytes)
        let vertexCount = vertexBytes / Self.vertexStride
        var indices = [UInt16](repeating: 0, count: indexBytes / 2)
        indexData.withUnsafeBytes { raw in
            for i in indices.indices {
                indices[i] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            }
        }
        // 정점 밖을 가리키는 색인은 GPU에서 정의되지 않은 읽기다. 여기서 막는다.
        if let bad = indices.first(where: { Int($0) >= vertexCount }) {
            throw MDLError.badIndex(Int(bad), vertexCount: vertexCount)
        }
        return MDLModel(
            materials: materials, boneCount: boneCount,
            boundsMin: Vec3(x: Double(bounds[0]), y: Double(bounds[1]), z: Double(bounds[2])),
            boundsMax: Vec3(x: Double(bounds[3]), y: Double(bounds[4]), z: Double(bounds[5])),
            vertexData: vertexData, indices: indices)
    }

    /// 앞에서부터 읽는 커서. 끝을 넘으면 던진다 — 잘린 파일이 trap이 되면 안 된다.
    private struct Cursor {
        let data: Data
        var offset = 0

        init(data: Data) { self.data = data }

        mutating func int32() throws -> Int {
            guard offset + 4 <= data.count else { throw MDLError.truncated("int32 @\(offset)") }
            let value = data.withUnsafeBytes {
                Int32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int32.self))
            }
            offset += 4
            return Int(value)
        }

        mutating func float32() throws -> Float {
            guard offset + 4 <= data.count else { throw MDLError.truncated("float @\(offset)") }
            let bits = data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            offset += 4
            let value = Float(bitPattern: bits)
            return value.isFinite ? value : 0
        }

        mutating func string(maxLength: Int) throws -> String {
            guard let end = data[offset...].firstIndex(of: 0), end - offset <= maxLength else {
                throw MDLError.truncated("문자열 @\(offset)")
            }
            let text = String(decoding: data[offset..<end], as: UTF8.self)
            offset = end + 1
            return text
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else {
                throw MDLError.truncated("\(count)바이트 @\(offset)")
            }
            let slice = data.subdata(in: offset..<offset + count)
            offset += count
            return slice
        }
    }
}
