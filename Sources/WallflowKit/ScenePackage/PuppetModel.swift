import Foundation
import simd

/// 퍼펫 워프 메시(`*_puppet.mdl`). 이미지 레이어 위에 뼈대를 심어 흔드는 WE의 2D 스키닝이다.
///
/// 형식 문서가 없어 실물 셋(눈 깜빡임 41KB, 후광 65KB, 원피스 55KB)의 바이트를 읽어
/// 알아냈다. 세 파일 모두 이 배치로 마지막 바이트까지 맞아떨어진다:
///
/// ```
/// "MDLV0023\0" · int32 flags(0x1800009) · materialCount · 1 · 재질 경로들
/// int32 0 · float32 × 6 (전부 0)
/// int32 vertexFormat(0x180000f) · vertexBytes
/// 정점 80B: pos3 · normal3 · tangent4 · int32 뼈 번호 4 · float 가중치 4 · uv2
/// int32 indexBytes · uint16 색인
/// 꼬리(길이 가변) … "MDLS0004\0"
///   int32 다음 청크 오프셋 · int32 boneCount
///   뼈마다: 널 종료 이름 · int32 1 · int32 parent(-1이면 뿌리) · int32 64
///           float32 × 16 열 우선 4x4 바인드 행렬 · 널 종료 JSON(물리 제약, 빈 문자열 가능)
///   (뼈마다 float32 × 19 보조 행렬 등 — 그리기에 필요 없어 읽지 않는다)
/// "MDLA0006\0"
///   int32 파일 끝 오프셋 · int32 animationCount
///   애니메이션마다: int32 id · int32 0 · 널 종료 이름 · 널 종료 모드("loop")
///           float32 fps · int32 frames · int32 0 · int32 trackCount
///           트랙마다: int32 0 · int32 bytes · (frames+1) × 9 float
///                     (위치 3 · 회전 라디안 3 · 배율 3). 트랙은 뼈 순서다 —
///                     앞의 int32는 실물 셋 모두 0이라 뼈 번호가 아니다.
/// ```
///
/// 정점 좌표는 **이미지 중심이 원점이고 y가 위인 텍스처 픽셀**이다 — 4000x3000 그림의
/// uv (0.691, 0.271)인 정점이 (764, 687)에 있다. 첫 키프레임은 바인드 자세와 같다.
/// 실물 눈 깜빡임은 뼈 하나의 scale.y만 1 → 0.86으로 줄인다.
///
/// 창작마당 파일이라 믿을 수 없다 — 개수·길이·색인을 전부 검사한다.
public struct PuppetModel: Equatable, Sendable {
    public static let skinnedVertexStride = 80
    public static let maxBones = 1024
    public static let maxKeyframes = 1_000_000

    public struct Vertex: Equatable, Sendable {
        public var position: SIMD2<Float>
        public var uv: SIMD2<Float>
        public var bones: SIMD4<Int32>
        public var weights: SIMD4<Float>
    }

    /// 뼈 하나의 자세. 2D라 회전은 z 하나다.
    public struct Transform: Equatable, Sendable {
        public var position: SIMD2<Float>
        public var rotation: Float
        public var scale: SIMD2<Float>

        public static let identity = Transform(position: .zero, rotation: 0, scale: SIMD2(1, 1))

        /// 열 우선 3x3 아핀: T · R · S.
        public var matrix: simd_float3x3 {
            let c = cos(rotation), s = sin(rotation)
            return simd_float3x3(
                SIMD3(c * scale.x, s * scale.x, 0),
                SIMD3(-s * scale.y, c * scale.y, 0),
                SIMD3(position.x, position.y, 1))
        }

        static func lerp(_ a: Transform, _ b: Transform, _ t: Float) -> Transform {
            Transform(position: a.position + (b.position - a.position) * t,
                      rotation: a.rotation + (b.rotation - a.rotation) * t,
                      scale: a.scale + (b.scale - a.scale) * t)
        }
    }

    public struct Bone: Equatable, Sendable {
        public var name: String
        /// 부모 번호. 뿌리면 -1.
        public var parent: Int
        /// 부모 기준 바인드 자세.
        public var bind: Transform
    }

    public struct Animation: Equatable, Sendable {
        public var id: Int
        public var name: String
        public var loops: Bool
        public var fps: Float
        public var frameCount: Int
        /// 뼈 번호 → 키프레임들(frames + 1개).
        public var tracks: [Int: [Transform]]
    }

    public let materials: [String]
    public let vertices: [Vertex]
    public let indices: [UInt16]
    public let bones: [Bone]
    public let animations: [Animation]

    public init(materials: [String], vertices: [Vertex], indices: [UInt16],
                bones: [Bone], animations: [Animation]) {
        self.materials = materials
        self.vertices = vertices
        self.indices = indices
        self.bones = bones
        self.animations = animations
    }

    public func animation(id: Int) -> Animation? { animations.first { $0.id == id } }

    // MARK: - 읽기

    public static func parse(_ data: Data) throws -> PuppetModel {
        var cursor = MDLModel.Cursor(data: data)
        let magic = try cursor.string(maxLength: 16)
        guard magic == MDLModel.magic else { throw MDLError.badMagic(magic) }
        _ = try cursor.int32()
        let materialCount = try cursor.int32()
        _ = try cursor.int32()
        guard materialCount >= 0, materialCount <= 64 else {
            throw MDLError.tooLarge("재질 \(materialCount)개")
        }
        var materials: [String] = []
        for _ in 0..<materialCount { materials.append(try cursor.string(maxLength: 1024)) }
        _ = try cursor.int32()
        for _ in 0..<6 { _ = try cursor.float32() }
        let vertexFormat = try cursor.int32()
        let vertexBytes = try cursor.int32()
        let stride = (vertexFormat & 0x0100_0000) != 0 ? skinnedVertexStride : MDLModel.vertexStride
        guard vertexBytes > 0, vertexBytes <= MDLModel.maxVertexBytes, vertexBytes % stride == 0 else {
            throw MDLError.tooLarge("정점 \(vertexBytes)바이트 (형식 \(vertexFormat))")
        }
        let vertexCount = vertexBytes / stride
        var vertices: [Vertex] = []
        vertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let px = try cursor.float32(), py = try cursor.float32()
            _ = try cursor.float32()                       // z
            for _ in 0..<7 { _ = try cursor.float32() }    // normal3 · tangent4
            var bones = SIMD4<Int32>(0, 0, 0, 0)
            var weights = SIMD4<Float>(1, 0, 0, 0)
            if stride == skinnedVertexStride {
                for k in 0..<4 { bones[k] = Int32(clamping: try cursor.int32()) }
                for k in 0..<4 { weights[k] = try cursor.float32() }
            }
            let u = try cursor.float32(), v = try cursor.float32()
            vertices.append(Vertex(position: SIMD2(px, py), uv: SIMD2(u, v),
                                   bones: bones, weights: weights))
        }
        let indexBytes = try cursor.int32()
        guard indexBytes >= 0, indexBytes <= MDLModel.maxIndexBytes, indexBytes % 2 == 0 else {
            throw MDLError.tooLarge("색인 \(indexBytes)바이트")
        }
        let indexData = try cursor.bytes(indexBytes)
        var indices = [UInt16](repeating: 0, count: indexBytes / 2)
        indexData.withUnsafeBytes { raw in
            for i in indices.indices {
                indices[i] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            }
        }
        if let bad = indices.first(where: { Int($0) >= vertexCount }) {
            throw MDLError.badIndex(Int(bad), vertexCount: vertexCount)
        }

        // 색인 뒤의 꼬리는 길이가 파일마다 다르다(42·26·90B). 뼈대 청크의 표식을 찾는다.
        var bones: [Bone] = []
        var animations: [Animation] = []
        if let skeletonAt = data.range(of: Data("MDLS0004\0".utf8), in: cursor.offset..<data.count) {
            cursor.offset = skeletonAt.upperBound
            let animationAt = try cursor.int32()
            let boneCount = try cursor.int32()
            guard boneCount >= 0, boneCount <= maxBones else { throw MDLError.tooLarge("뼈 \(boneCount)개") }
            for _ in 0..<boneCount {
                let name = try cursor.string(maxLength: 1024)
                _ = try cursor.int32()
                let parent = try cursor.int32()
                _ = try cursor.int32()
                var m = [Float](repeating: 0, count: 16)
                for k in 0..<16 { m[k] = try cursor.float32() }
                _ = try cursor.string(maxLength: 65536)  // 물리 제약 JSON
                // 부모 번호가 자기 뒤나 밖을 가리키면 뿌리로 본다 — 고리를 만들지 않는다.
                let safeParent = parent >= 0 && parent < bones.count ? parent : -1
                bones.append(Bone(name: name, parent: safeParent, bind: Self.transform(from: m)))
            }
            if animationAt > 0, animationAt + 9 <= data.count,
               data[animationAt..<animationAt + 9] == Data("MDLA0006\0".utf8) {
                cursor.offset = animationAt + 9
                _ = try cursor.int32()
                let animationCount = try cursor.int32()
                guard animationCount >= 0, animationCount <= 256 else {
                    throw MDLError.tooLarge("애니메이션 \(animationCount)개")
                }
                for _ in 0..<animationCount {
                    let id = try cursor.int32()
                    _ = try cursor.int32()
                    let name = try cursor.string(maxLength: 1024)
                    let mode = try cursor.string(maxLength: 64)
                    let fps = try cursor.float32()
                    let frames = try cursor.int32()
                    _ = try cursor.int32()
                    let trackCount = try cursor.int32()
                    guard frames >= 0, frames <= maxKeyframes, trackCount >= 0, trackCount <= maxBones
                    else { throw MDLError.tooLarge("애니메이션 \(id): 프레임 \(frames), 트랙 \(trackCount)") }
                    var tracks: [Int: [Transform]] = [:]
                    for bone in 0..<trackCount {
                        _ = try cursor.int32()
                        let bytes = try cursor.int32()
                        guard bytes >= 0, bytes % 36 == 0, bytes / 36 <= maxKeyframes + 1 else {
                            throw MDLError.tooLarge("트랙 \(bytes)바이트")
                        }
                        var keys: [Transform] = []
                        keys.reserveCapacity(bytes / 36)
                        for _ in 0..<(bytes / 36) {
                            var f = [Float](repeating: 0, count: 9)
                            for k in 0..<9 { f[k] = try cursor.float32() }
                            keys.append(Transform(position: SIMD2(f[0], f[1]), rotation: f[5],
                                                  scale: SIMD2(f[6], f[7])))
                        }
                        if bone >= 0, bone < bones.count, !keys.isEmpty { tracks[bone] = keys }
                    }
                    animations.append(Animation(
                        id: id, name: name, loops: mode != "once",
                        fps: fps.isFinite && fps > 0 ? fps : 30, frameCount: frames, tracks: tracks))
                }
            }
        }
        return PuppetModel(materials: materials, vertices: vertices, indices: indices,
                           bones: bones, animations: animations)
    }

    /// 열 우선 4x4의 2D 부분을 자세로 푼다. 회전은 첫 열의 방향이고 배율은 열의 길이다.
    static func transform(from m: [Float]) -> Transform {
        let col0 = SIMD2(m[0], m[1]), col1 = SIMD2(m[4], m[5])
        let sx = simd_length(col0), sy = simd_length(col1)
        return Transform(position: SIMD2(m[12], m[13]),
                         rotation: sx > 0 ? atan2(col0.y, col0.x) : 0,
                         scale: SIMD2(sx > 0 ? sx : 1, sy > 0 ? sy : 1))
    }

    // MARK: - 스키닝

    /// 뼈마다 부모를 합친 세계 행렬.
    func worldMatrices(_ locals: [Transform]) -> [simd_float3x3] {
        var world = [simd_float3x3](repeating: matrix_identity_float3x3, count: bones.count)
        for (i, bone) in bones.enumerated() {
            let local = (i < locals.count ? locals[i] : bone.bind).matrix
            world[i] = bone.parent >= 0 && bone.parent < i ? world[bone.parent] * local : local
        }
        return world
    }

    /// 시각 `time`(초)의 뼈마다 스킨 행렬(애니메이션 세계 × 바인드 세계⁻¹).
    ///
    /// - Parameters:
    ///   - rate: 재생 속도 배율. 씬의 `animationlayers[].rate`.
    ///   - blend: 바인드 자세(0)와 애니메이션(1) 사이. 씬의 `animationlayers[].blend`.
    public func skinMatrices(animationID: Int, time: Double, rate: Double = 1,
                             blend: Float = 1) -> [simd_float3x3] {
        let bindWorld = worldMatrices(bones.map(\.bind))
        guard let animation = animation(id: animationID), animation.frameCount > 0 else {
            return [simd_float3x3](repeating: matrix_identity_float3x3, count: bones.count)
        }
        var frame = time * Double(animation.fps) * rate
        let length = Double(animation.frameCount)
        if animation.loops {
            frame = frame.truncatingRemainder(dividingBy: length)
            if frame < 0 { frame += length }
        } else {
            frame = min(max(frame, 0), length)
        }
        let lower = Int(frame.rounded(.down))
        let fraction = Float(frame - Double(lower))
        var locals: [Transform] = []
        for (i, bone) in bones.enumerated() {
            guard let keys = animation.tracks[i], !keys.isEmpty else { locals.append(bone.bind); continue }
            let a = keys[min(lower, keys.count - 1)]
            let b = keys[min(lower + 1, keys.count - 1)]
            let animated = Transform.lerp(a, b, fraction)
            locals.append(blend >= 1 ? animated : Transform.lerp(bone.bind, animated, max(blend, 0)))
        }
        let animWorld = worldMatrices(locals)
        return (0..<bones.count).map { animWorld[$0] * bindWorld[$0].inverse }
    }

    /// 스킨 행렬로 정점을 옮긴 자리(텍스처 픽셀, 중심 원점, y 위).
    public func skinnedPositions(_ matrices: [simd_float3x3]) -> [SIMD2<Float>] {
        vertices.map { vertex in
            var out = SIMD2<Float>(0, 0)
            var total: Float = 0
            for k in 0..<4 {
                let w = vertex.weights[k]
                let b = Int(vertex.bones[k])
                guard w > 0, b >= 0, b < matrices.count else { continue }
                let p = matrices[b] * SIMD3(vertex.position.x, vertex.position.y, 1)
                out += SIMD2(p.x, p.y) * w
                total += w
            }
            return total > 0 ? out / total : vertex.position
        }
    }
}
