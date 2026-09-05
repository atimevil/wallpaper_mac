import Metal
import WallflowKit

/// GPU에 넘기는 파티클 하나. MSL의 `ParticleInstance`와 배치가 **정확히** 같아야 한다.
///
/// MSL 쪽은 `packed_float3`(12바이트)를 쓰는데 Swift의 `SIMD3<Float>`는 16바이트로
/// 정렬된다. 그래서 위치와 회전을 개별 `Float`로 편다. 여기서 어긋나면 컴파일은
/// 통과하고 파티클만 엉뚱한 자리·크기로 나온다.
///
/// 배치: position 0..<12, size 12..<16, rotation 16..<28, _pad 28..<32, color 32..<48.
struct ParticleInstance {
    var positionX: Float
    var positionY: Float
    var positionZ: Float
    var size: Float
    var rotationX: Float
    var rotationY: Float
    var rotationZ: Float
    /// 스프라이트 시트의 프레임 번호. 시트가 아니면 0이다.
    var frame: Float
    var color: SIMD4<Float>

    /// MSL 구조체와 같은 48바이트여야 한다.
    static let expectedStride = 48
}

/// 정점 셰이더에 넘기는 파티클 공통 값.
struct ParticleUniforms {
    var projection: SIMD2<Float>
    /// 프레임 한 장이 시트에서 차지하는 비율. 시트가 아니면 (1,1).
    var frameScale: SIMD2<Float>
    var textureRatio: Float
    var framesPerRow: Float
    var padding: SIMD2<Float> = .zero
}

/// 텍스처가 스프라이트 시트일 때의 배치. `rosepetals.tex`가 512x128에 102x128
/// 프레임 5장이다. 시트를 그대로 샘플링하면 꽃잎 하나가 다섯 장을 뭉개 그린다.
struct ParticleSpriteSheet {
    var frameCount: Int
    var framesPerRow: Int
    var frameScale: SIMD2<Float>
    /// 프레임 한 장의 세로/가로. 빌보드 보정은 시트가 아니라 프레임 비율을 써야 한다.
    var frameRatio: Float
}

/// 파티클을 인스턴싱으로 그린다. 파티클마다 정점 4개(삼각형 스트립)를 펼친다.
///
/// 인스턴스 버퍼는 `maxCount`만큼 한 번만 잡고 매 프레임 덮어쓴다. 배경화면은
/// 상시 구동이라 프레임마다 `makeBuffer`를 부르면 할당이 계속 쌓인다.
final class ParticleRenderer {
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let instanceBuffer: MTLBuffer
    private let capacity: Int
    private let texture: MTLTexture
    /// 레이어의 직교 공간 원점. 프리셋의 이미터 좌표는 이 원점을 기준으로 한
    /// 상대 좌표라, 그리기 전에 더해야 화면의 제자리에 나온다.
    private let layerOrigin: SIMD3<Float>

    private var instanceCount = 0
    private var textureRatio: Float = 1
    private let sheet: ParticleSpriteSheet?

    /// - Parameters:
    ///   - library: 컴포지터가 이미 컴파일해 둔 셰이더 라이브러리. 파티클 레이어마다
    ///     MSL을 다시 컴파일하지 않으려고 받는다(계획의 `init(device:)`에서 벗어난 부분).
    ///   - blend: 머티리얼의 합성 방식. additive와 translucent가 실물에 둘 다 있다.
    init(
        device: MTLDevice,
        library: MTLLibrary,
        maxCount: Int,
        blend: ParticleBlendMode,
        texture: MTLTexture,
        sampler: MTLSamplerState,
        layerOrigin: SIMD3<Float>,
        sheet: ParticleSpriteSheet?
    ) throws {
        self.layerOrigin = layerOrigin
        self.sheet = sheet
        // 배치가 어긋나면 컴파일은 통과하고 파티클만 엉뚱한 자리·크기로 나온다.
        // 그건 셰이더 버그처럼 보여서 원인을 찾는 데 오래 걸린다. 차라리 여기서
        // 씬 로드에 실패하고 이유를 말한다.
        guard MemoryLayout<ParticleInstance>.stride == ParticleInstance.expectedStride else {
            throw CompositorError.pipelineFailed(
                "ParticleInstance 배치가 MSL과 다르다: "
                + "\(MemoryLayout<ParticleInstance>.stride)바이트, "
                + "\(ParticleInstance.expectedStride)여야 한다")
        }

        // maxCount가 0인 프리셋이 있을 수 있다(깨진 파일을 0으로 죄었을 때).
        // 0바이트 버퍼는 만들 수 없으므로 최소 1을 잡는다.
        capacity = max(1, maxCount)
        self.texture = texture
        self.sampler = sampler

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "particle_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "particle_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        switch blend {
        case .additive:
            // 색을 더한다. 배경이 비쳐 보이고 겹칠수록 밝아진다.
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        case .translucent:
            // 알파로 덮는다. 꽃잎처럼 불투명한 것에 쓴다.
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        }
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        // 파티클은 정점 버퍼 대신 vertex_id로 코너를 만든다. vertexDescriptor를 두면
        // 컴포지터가 index 0에 묶어 둔 쿼드 정점을 읽으려 해서 어긋난다.

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

        guard let buffer = device.makeBuffer(
            length: MemoryLayout<ParticleInstance>.stride * capacity,
            options: .storageModeShared
        ) else { throw CompositorError.bufferAllocationFailed }
        instanceBuffer = buffer
    }

    /// 시뮬레이션 상태를 인스턴스 버퍼로 옮긴다.
    /// `textureRatio`는 텍스처의 세로/가로 비율이다. 빌보드가 정사각형으로
    /// 찌그러지지 않게 세로를 보정한다.
    func update(from system: ParticleSystem, textureRatio: Float) {
        self.textureRatio = textureRatio
        let live = system.particles
        let count = min(live.count, capacity)
        let pointer = instanceBuffer.contents().bindMemory(
            to: ParticleInstance.self, capacity: capacity)
        for i in 0..<count {
            let p = live[i]
            pointer[i] = ParticleInstance(
                positionX: layerOrigin.x + Float(p.position.x),
                positionY: layerOrigin.y + Float(p.position.y),
                positionZ: layerOrigin.z + Float(p.position.z),
                size: Float(p.size),
                rotationX: Float(p.rotation.x),
                rotationY: Float(p.rotation.y),
                rotationZ: Float(p.rotation.z),
                frame: frameIndex(for: p),
                color: SIMD4(Float(p.color.x), Float(p.color.y), Float(p.color.z),
                             Float(p.alpha))
            )
        }
        instanceCount = count
    }

    /// 스프라이트 시트는 파티클이 사는 동안 프레임을 훑는다. 꽃잎이 도는 것처럼
    /// 보이게 하는 것이 시트의 용도다. 시트가 아니면 항상 0이다.
    private func frameIndex(for p: Particle) -> Float {
        guard let sheet, sheet.frameCount > 1, p.lifetime > 0 else { return 0 }
        let progress = min(max(p.age / p.lifetime, 0), 0.999)
        return Float(Int(progress * Double(sheet.frameCount)))
    }

    /// 살아 있는 파티클이 없으면 아무것도 인코딩하지 않는다.
    /// `instanceCount: 0`으로 draw를 부르는 것은 낭비다.
    func encode(into encoder: MTLRenderCommandEncoder, projection: SIMD2<Float>) {
        guard instanceCount > 0 else { return }
        var uniforms = ParticleUniforms(
            projection: projection,
            frameScale: sheet?.frameScale ?? SIMD2(1, 1),
            textureRatio: sheet?.frameRatio ?? textureRatio,
            framesPerRow: Float(max(1, sheet?.framesPerRow ?? 1)))
        encoder.setRenderPipelineState(pipeline)
        // index 2·3을 쓴다. index 0은 컴포지터가 루프 밖에서 묶어 둔 쿼드 정점
        // 버퍼이고 루프 안에서 다시 묶지 않는다. 여기서 0을 덮으면 파티클 다음에
        // 오는 일반 레이어가 인스턴스 배열을 정점으로 읽는다.
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 3)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
    }
}
