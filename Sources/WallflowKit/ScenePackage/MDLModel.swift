import Foundation
import simd

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
/// int32 indexBytes                   색인. 사각형을 삼각형 둘로 쪼갠 꼴
/// 7B                                 0으로 채워진 꼬리
/// ```
///
/// 첫 정점을 읽으면 법선이 단위 길이이고 접선의 w가 ±1이라 이 해석이 맞다.
/// 창작마당 파일이라 믿을 수 없다 — 크기와 색인 범위를 전부 검사한다.
///
/// **색인 폭은 정점 수를 본다.** 실물 대부분(프리즘 60정점 등)은 색인이
/// `uint16`이지만, `球体01.mdl`(토성 몸체, 정점 849,202개)은 `uint32`다 —
/// `uint16`으로는 65,536개를 넘는 정점을 가리킬 수 없어서다. 형식에 이를 밝히는
/// 별도 필드는 못 찾았다(플래그·정점 형식이 둘 다 두 파일에서 같은 값 15다) —
/// 직접 바이트를 맞춰 확인했다: 정점 수를 `uint16` 상한(65,535) 아래로 가정하고
/// 읽으면 색인이 `(0,0),(1,0),(2,0)`처럼 짝수 자리만 값을 갖고 홀수 자리는 늘
/// 0인 꼴로 나온다 — 사실은 각 색인이 4바이트(`uint32`)인데 그걸 2바이트씩 둘로
/// 쪼개 읽은 것이다. `uint32`로 다시 읽으면 색인 최댓값이 정점 수 - 1과 정확히
/// 맞아떨어진다. 그래서 정점이 65,536개 이상이면 색인도 4바이트로 읽는다 —
/// 색인 버퍼를 통째로 4바이트 폭으로 통일해 두면(`indices: [UInt32]`) 렌더러가
/// 폭을 따로 안 가려도 된다.
public struct MDLModel: Equatable, Sendable {
    public static let magic = "MDLV0023"
    /// 정점 하나의 바이트. pos3 + normal3 + tangent4 + uv2 = 12 float.
    public static let vertexStride = 48
    /// 정점 버퍼 상한. 실물 `陨石.mdl`(3589454154 씬의 운석밭, 정점 3,144,456개 ×
    /// 48B ≈ 144MiB)이 진짜로 이만큼 크다 — 색인 12.8MB·꼬리 7B까지 파일 끝과
    /// 정확히 맞아떨어져 misparse가 아님을 확인했다. 총 GPU 메모리는 버텍스+색인
    /// 합쳐 160MB 안팎으로, Apple Silicon 통합 메모리에서 메시 하나로는 무리가
    /// 아니다. 200MiB로 올려 이 실물에 여유를 두면서도, 창작마당의 지어낸 값(예:
    /// 1GB)은 여전히 막는다.
    public static let maxVertexBytes = 200 * 1024 * 1024
    public static let maxIndexBytes = 64 * 1024 * 1024

    public let materials: [String]
    public let boneCount: Int
    public let boundsMin: Vec3
    public let boundsMax: Vec3
    /// 48바이트 정점이 이어진 원본 바이트. 그대로 GPU 버퍼에 올린다.
    public let vertexData: Data
    public let indices: [UInt32]
    /// 다중 서브메시(`MDLV0017`·`MDLV0023` 둘 다 있을 수 있다 — 실물 `scene.mdl`은
    /// `MDLV0023`인데 서브메시 5개다)의 둘째 이후. 서브메시가 하나뿐인 파일은
    /// 늘 빈 배열이다.
    public let extraSubmeshes: [Submesh]

    public var vertexCount: Int { vertexData.count / Self.vertexStride }

    public init(materials: [String], boneCount: Int, boundsMin: Vec3, boundsMax: Vec3,
                vertexData: Data, indices: [UInt32], extraSubmeshes: [Submesh] = []) {
        self.materials = materials
        self.boneCount = boneCount
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.vertexData = vertexData
        self.indices = indices
        self.extraSubmeshes = extraSubmeshes
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

    /// 경계 상자 6개 float(24B)가 있는 버전. `MDLV0016`은 이 자리 자체가 없다 —
    /// 실물 `Hollow Cylinder.mdl`을 바이트로 맞춰 확인했다: `boneCount` 바로
    /// 뒤에 (경계 없이) `vertexFormat`이 바로 온다. 없으면 정점 위치에서 직접
    /// 계산한다. `MDLV0017`도 경계가 있다 — 실물 `space boi.mdl`로 확인했다.
    static let versionsWithBounds: Set<String> = ["MDLV0023", "MDLV0017"]
    /// 지원하는 매직 전부. `MDLV0016`은 경계 상자만 빠지고 나머지 배치는 같다
    /// (같은 flags=15·정점 48B·꼬리 없음). `materialCount·1` 자리의 "1"이 사실은
    /// 서브메시 수다(`MDLV0017`인 `space boi.mdl`은 2, `MDLV0023`인 `scene.mdl`은
    /// 5) — 둘 다 다중 서브메시일 수 있다. 첫 서브메시는 여느 버전과 같은 배치
    /// (재질 배열 → boneCount → 경계 → 정점 → 색인)지만, 둘째부터는 재질이
    /// 배열이 아니라 널 종료 문자열 하나씩이고 그 뒤로 boneCount·경계·정점·
    /// 색인이 되풀이된다. **`MDLV0023`은 그 재질 문자열 앞에 0으로 채운
    /// 6바이트 여백이 더 낀다**(`MDLV0017`은 없다) — `readMeshBlock` 주석 참고.
    static let supportedMagics: Set<String> = versionsWithBounds.union(["MDLV0016"])
    /// 서브메시 상한. 실물 최대가 5고, 창작마당 파일의 미친 값에 못 당하게 막는다.
    static let maxSubmeshes = 64

    /// 둘째 이후 서브메시(`MDLV0017`·`MDLV0023` 둘 다 있을 수 있다). 재질이 서로
    /// 다를 수 있어 따로 그린다.
    public struct Submesh: Equatable, Sendable {
        public let materialPath: String
        public let vertexData: Data
        public let indices: [UInt32]
        public var vertexCount: Int { vertexData.count / MDLModel.vertexStride }
    }

    public static func parse(_ data: Data) throws -> MDLModel {
        var cursor = Cursor(data: data)
        let magic = try cursor.string(maxLength: 16)
        guard Self.supportedMagics.contains(magic) else { throw MDLError.badMagic(magic) }
        _ = try cursor.int32()          // flags(15). 뜻은 모른다 — 정점 형식과 같은 값이다.
        let materialCount = try cursor.int32()
        // `MDLV0016`·`MDLV0023`은 늘 1이라 메시 수로 보였지만, `MDLV0017`
        // 실물(`space boi.mdl`)에서 2가 나와 서브메시 수임을 알았다.
        let submeshCount = try cursor.int32()
        guard materialCount >= 0, materialCount <= 64 else {
            throw MDLError.tooLarge("재질 \(materialCount)개")
        }
        guard submeshCount >= 1, submeshCount <= Self.maxSubmeshes else {
            throw MDLError.tooLarge("서브메시 \(submeshCount)개")
        }
        var materials: [String] = []
        for _ in 0..<materialCount {
            materials.append(try cursor.string(maxLength: 1024))
        }
        let hasBounds = Self.versionsWithBounds.contains(magic)
        let first = try readMeshBlock(&cursor, hasBounds: hasBounds)

        // 둘째 이후 서브메시 앞의 여백. `MDLV0023`은 재질 문자열 앞에 0으로 채운
        // 6바이트가 끼어 있다(실물 `scene.mdl`, 서브메시 5개 — 이 여백을 안
        // 건너뛰면 빈 문자열을 재질로 읽고 그 뒤로 커서가 통째로 밀려, 다음
        // 필드 자리에서 문자열 조각이 `vertexFormat`으로 읽힌다 — 로그의
        // `tooLarge("정점 …바이트 (형식 1702125933)")`가 그 증거다: 1702125933을
        // 리틀엔디언 4바이트로 풀면 "mate"다). `MDLV0017`은 이 여백이 없다
        // (실물 `space boi.mdl`로 확인). 뜻은 모른다 — 6바이트 전부 0이다.
        let submeshGap = magic == "MDLV0023" ? 6 : 0
        var extraSubmeshes: [Submesh] = []
        for _ in 1..<submeshCount {
            if submeshGap > 0 { _ = try cursor.bytes(submeshGap) }
            let materialPath = try cursor.string(maxLength: 1024)
            let block = try readMeshBlock(&cursor, hasBounds: hasBounds)
            extraSubmeshes.append(Submesh(
                materialPath: materialPath, vertexData: block.vertexData, indices: block.indices))
        }

        return MDLModel(
            materials: materials, boneCount: first.boneCount,
            boundsMin: first.boundsMin, boundsMax: first.boundsMax,
            vertexData: first.vertexData, indices: first.indices, extraSubmeshes: extraSubmeshes)
    }

    /// boneCount(선택) → 경계(있으면) → 정점 형식·바이트 → 정점 → 색인. 첫
    /// 서브메시와 둘째 이후 서브메시가 이 자리부터 같은 모양이다.
    private static func readMeshBlock(
        _ cursor: inout Cursor, hasBounds: Bool
    ) throws -> (boneCount: Int, boundsMin: Vec3, boundsMax: Vec3, vertexData: Data, indices: [UInt32]) {
        let boneCount = try cursor.int32()
        guard boneCount >= 0, boneCount <= 4096 else { throw MDLError.tooLarge("뼈 \(boneCount)개") }
        let bounds = hasBounds ? try (0..<6).map { _ in try cursor.float32() } : nil
        let vertexFormat = try cursor.int32()
        let vertexBytes = try cursor.int32()
        guard vertexBytes > 0, vertexBytes <= Self.maxVertexBytes,
              vertexBytes % Self.vertexStride == 0 else {
            throw MDLError.tooLarge("정점 \(vertexBytes)바이트 (형식 \(vertexFormat))")
        }
        let vertexData = try cursor.bytes(vertexBytes)
        let vertexCount = vertexBytes / Self.vertexStride
        // 정점이 65,536개를 넘으면 `uint16` 색인으로는 전부를 못 가리킨다 —
        // 그 이상이면 파일도 색인을 4바이트로 낸다(위 문서 주석 참고).
        let indexElementSize = vertexCount > 0xFFFF ? 4 : 2
        let indexBytes = try cursor.int32()
        guard indexBytes >= 0, indexBytes <= Self.maxIndexBytes,
              indexBytes % indexElementSize == 0 else {
            throw MDLError.tooLarge("색인 \(indexBytes)바이트")
        }
        let indexData = try cursor.bytes(indexBytes)
        var indices = [UInt32](repeating: 0, count: indexBytes / indexElementSize)
        indexData.withUnsafeBytes { raw in
            for i in indices.indices {
                if indexElementSize == 2 {
                    indices[i] = UInt32(
                        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                } else {
                    indices[i] = UInt32(
                        littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                }
            }
        }
        // 정점 밖을 가리키는 색인은 GPU에서 정의되지 않은 읽기다. 여기서 막는다.
        if let bad = indices.first(where: { Int($0) >= vertexCount }) {
            throw MDLError.badIndex(Int(bad), vertexCount: vertexCount)
        }
        let boundsMin: Vec3
        let boundsMax: Vec3
        if let bounds {
            boundsMin = Vec3(x: Double(bounds[0]), y: Double(bounds[1]), z: Double(bounds[2]))
            boundsMax = Vec3(x: Double(bounds[3]), y: Double(bounds[4]), z: Double(bounds[5]))
        } else {
            (boundsMin, boundsMax) = Self.computedBounds(vertexData)
        }
        return (boneCount, boundsMin, boundsMax, vertexData, indices)
    }

    /// 경계 상자가 파일에 없는 버전(`MDLV0016`)을 위해 정점 위치에서 직접 잰다.
    private static func computedBounds(_ vertexData: Data) -> (min: Vec3, max: Vec3) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let count = vertexData.count / Self.vertexStride
        vertexData.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = i * Self.vertexStride
                let p = SIMD3<Float>(
                    raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        guard count > 0 else { return (Vec3(x: 0, y: 0, z: 0), Vec3(x: 0, y: 0, z: 0)) }
        return (Vec3(x: Double(lo.x), y: Double(lo.y), z: Double(lo.z)),
                Vec3(x: Double(hi.x), y: Double(hi.y), z: Double(hi.z)))
    }

    /// 앞에서부터 읽는 커서. 끝을 넘으면 던진다 — 잘린 파일이 trap이 되면 안 된다.
    struct Cursor {
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
