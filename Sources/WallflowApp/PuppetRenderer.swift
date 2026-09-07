import Metal
import simd
import WallflowKit

/// 퍼펫 워프 메시를 그린다. 뼈대는 CPU에서 움직인다 — 실물 메시가 정점 200~700개라
/// 프레임마다 다 옮겨도 미미하고, 셰이더에 뼈 행렬을 넘기는 길보다 훨씬 단순하다.
///
/// 정점은 이미지 중심 원점·y 위 텍스처 픽셀이다. 쿼드 파이프라인이 기대하는
/// 단위 공간(-0.5..0.5, +y가 화면 아래)으로 옮겨 쓰면, 레이어의 자리·크기·회전·
/// 시차를 쿼드와 똑같이 적용할 수 있다.
@MainActor
final class PuppetRenderer {
    /// 정점 하나: float2 자리 + float2 uv.
    static let vertexStride = 16

    private let model: PuppetModel
    private let spec: PuppetSpec
    private let imageSize: SIMD2<Float>
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let textureProvider: @MainActor () -> MTLTexture?
    private var lastTime: Double = -1

    init(device: MTLDevice, model: PuppetModel, spec: PuppetSpec, imageSize: SIMD2<Float>,
         texture: @escaping @MainActor () -> MTLTexture?) throws {
        self.model = model
        self.spec = spec
        self.imageSize = SIMD2(max(imageSize.x, 1), max(imageSize.y, 1))
        self.textureProvider = texture
        guard !model.vertices.isEmpty, !model.indices.isEmpty,
              let vb = device.makeBuffer(length: model.vertices.count * Self.vertexStride,
                                         options: .storageModeShared),
              let ib = model.indices.withUnsafeBytes({ raw in
                  device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: [])
              }) else {
            throw CompositorError.bufferAllocationFailed
        }
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = model.indices.count
        write(positions: model.vertices.map(\.position))
    }

    func texture() -> MTLTexture? { textureProvider() }

    /// 시각 `time`(초)의 자세로 정점을 다시 쓴다. 보이는 첫 애니메이션 레이어를 튼다.
    func update(time: Double) {
        guard time != lastTime else { return }
        lastTime = time
        guard let animation = spec.animations.first(where: \.visible),
              model.animation(id: animation.id) != nil else { return }
        let matrices = model.skinMatrices(
            animationID: animation.id, time: time, rate: animation.rate,
            blend: Float(animation.blend))
        write(positions: model.skinnedPositions(matrices))
    }

    private func write(positions: [SIMD2<Float>]) {
        let out = vertexBuffer.contents().bindMemory(to: Float.self, capacity: positions.count * 4)
        for (i, position) in positions.enumerated() where i < model.vertices.count {
            // 픽셀 → 단위 쿼드 공간. y는 뒤집는다(쿼드 공간은 +y가 화면 아래).
            out[i * 4] = position.x / imageSize.x
            out[i * 4 + 1] = -position.y / imageSize.y
            out[i * 4 + 2] = model.vertices[i].uv.x
            out[i * 4 + 3] = model.vertices[i].uv.y
        }
    }

    func encode(into encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
}
