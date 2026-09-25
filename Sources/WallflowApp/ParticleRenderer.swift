import Metal
import simd
import WallflowKit

/// GPU에 넘기는 파티클 하나. MSL의 `ParticleInstance`와 배치가 **정확히** 같아야 한다.
///
/// MSL 쪽은 `packed_float3`(12바이트)를 쓰는데 Swift의 `SIMD3<Float>`는 16바이트로
/// 정렬된다. 그래서 위치와 회전을 개별 `Float`로 편다. 여기서 어긋나면 컴파일은
/// 통과하고 파티클만 엉뚱한 자리·크기로 나온다.
///
/// 배치: position 0..<12, size 12..<16, rotation 16..<28, frame 28..<32, color 32..<48,
/// velocity 48..<60, localSpeed 60..<64.
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
    /// spritetrail이 속도 방향으로 늘여 그리는 데 쓴다(레이어 배율이 걸려 있다 —
    /// 화면에서 실제로 보이는 방향·거울상 여부가 이 값에 반영돼야 한다).
    /// sprite/rope/ropetrail은 셰이더가 이 값을 무시한다(회전 기반 축으로
    /// 그대로 그린다).
    var velocityX: Float
    var velocityY: Float
    var velocityZ: Float
    /// **레이어 배율을 적용하기 전** 속력. WE의 `ComputeParticleTrailTangents`는
    /// 로컬(모델 변환 이전) 공간에서 clamp를 계산하고, 그 결과가 나중에
    /// `size`(이미 배율이 걸려 있다)에 곱해져 화면에 나온다. `velocity*layerScale`의
    /// 크기를 그대로 clamp에 쓰면 배율이 두 번(여기서 한 번, size에서 또 한 번)
    /// 걸려 레이어 배율이 1이 아닌 씬(실물 0.44~9.0배)에서 트레일 길이가
    /// 완전히 틀어진다.
    var localSpeed: Float

    /// MSL 구조체와 같은 64바이트여야 한다.
    static let expectedStride = 64
}

/// 정점 셰이더에 넘기는 파티클 공통 값.
struct ParticleUniforms {
    /// 화면 맞춤(T6)이 캔버스에서 실제로 보이는 사각형. `QuadUniforms`의
    /// visibleOrigin/visibleSize와 같은 뜻이다.
    var visibleOrigin: SIMD2<Float>
    var visibleSize: SIMD2<Float>
    /// 프레임 한 장이 시트에서 차지하는 비율. 시트가 아니면 (1,1).
    var frameScale: SIMD2<Float>
    var textureRatio: Float
    var framesPerRow: Float
    /// 원근 씬이면 1. MSL 쪽 `useTransform`과 같은 자리다.
    var useTransform: Float = 0
    /// spritetrail이면 1(트레일 축 계산), 아니면 0(회전 기반 축). MSL 쪽에서
    /// `padding`이었던 자리를 그대로 쓴다.
    var isTrail: Float = 0
    /// `g_RenderVar0`(length, maxlength, minlength). isTrail이 0이면 안 쓴다.
    var trailLength: Float = 0
    var trailMaxLength: Float = 0
    var trailMinLength: Float = 0
    /// 레이어 세계 변환 × 뷰·투영. 직교 씬에서는 쓰지 않는다.
    var transform: simd_float4x4 = matrix_identity_float4x4

    /// MSL의 ParticleUniforms와 같은 128바이트여야 한다: float2 3개(visibleOrigin·
    /// visibleSize·frameScale, 24) + float 7개(textureRatio·framesPerRow·
    /// useTransform·isTrail·trailLength·trailMaxLength·trailMinLength, 28) = 52 +
    /// 암묵 패딩(12, float4x4 정렬) + transform(64) = 128. init(device:library:...)이
    /// 이 값을 실제로 검증한다 — ParticleInstance.expectedStride와 같은 이유다.
    static let expectedStride = 128
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
    /// 레이어의 크기 배율. 파티클의 위치와 크기에 함께 곱해진다.
    ///
    /// 무시하면 씬이 의도한 것보다 크거나 작게 날린다. 실물 레이어의 배율이
    /// 0.44부터 9.0까지 있어서 차이가 크다. 음수는 좌우 반전이라 위치에는
    /// 부호를 그대로 쓰고, 크기에는 절댓값을 쓴다.
    private let layerScale: SIMD3<Float>
    /// 빌보드 크기에 곱할 배율. 축마다 다른 배율을 하나로 줄여야 해서 평균을 쓴다.
    private let sizeScale: Float

    private var instanceCount = 0
    /// 굴절 파티클의 법선 지도. 없으면 보통 파티클이다.
    private let normalMap: MTLTexture?
    /// 재질이 정한 미는 정도(`ui_editor_properties_refract_amount`). 기본 0.05.
    /// 실물 유리창 비는 -0.1이다 — 음수면 반대로 민다.
    private let refractAmount: Float
    /// 이 레이어 뒤에 이미 그려진 화면. 굴절이 이걸 밀어 읽는다.
    /// 매 프레임 컴포지터가 넣어 준다.
    private var background: MTLTexture?

    /// 뒤 화면이 필요한지. 컴포지터가 이걸 보고 인코더를 끊어 화면을 떠 준다.
    var needsBackground: Bool { normalMap != nil }

    func setBackground(_ texture: MTLTexture?) { background = texture }
    private var textureRatio: Float = 1
    private let sheet: ParticleSpriteSheet?
    /// 시트를 훑을지, 한 장을 골라 고정할지.
    private let animationMode: ParticleAnimationMode
    /// spritetrail의 (length, maxlength, minlength). rope/ropetrail은 아직 이
    /// 렌더러가 못 그려서(T8이 한다) nil로 두고 오늘의 스프라이트 경로로
    /// 그대로 그린다 — sprite와 다르지 않다.
    private let trailParams: (length: Float, maxLength: Float, minLength: Float)?

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
        layerScale: SIMD3<Float>,
        sheet: ParticleSpriteSheet?,
        animationMode: ParticleAnimationMode,
        renderKind: ParticleRenderKind = .sprite,
        normalMap: MTLTexture? = nil,
        refractAmount: Float = 0.05
    ) throws {
        self.normalMap = normalMap
        self.refractAmount = refractAmount
        self.layerOrigin = layerOrigin
        self.layerScale = layerScale
        self.animationMode = animationMode
        if case .spriteTrail(let length, let maxLength, let minLength) = renderKind {
            trailParams = (Float(length), Float(maxLength), Float(minLength))
        } else {
            // rope/ropetrail은 T8까지 오늘의 스프라이트로 그대로 그린다.
            trailParams = nil
        }
        // 빌보드는 정사각형 하나라 축별 배율을 표현할 수 없다. 평균이 가장 덜 틀린다.
        let averaged = (abs(layerScale.x) + abs(layerScale.y)) / 2
        self.sizeScale = averaged.isFinite && averaged > 0 ? averaged : 1
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
        guard MemoryLayout<ParticleUniforms>.stride == ParticleUniforms.expectedStride else {
            throw CompositorError.pipelineFailed(
                "ParticleUniforms 배치가 MSL과 다르다: "
                + "\(MemoryLayout<ParticleUniforms>.stride)바이트, "
                + "\(ParticleUniforms.expectedStride)여야 한다")
        }

        // maxCount가 0인 프리셋이 있을 수 있다(깨진 파일을 0으로 죄었을 때).
        // 0바이트 버퍼는 만들 수 없으므로 최소 1을 잡는다.
        capacity = max(1, maxCount)
        self.texture = texture
        self.sampler = sampler

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "particle_vertex")
        // 굴절이면 법선 지도로 화면을 밀어 읽는 프래그먼트를 쓴다.
        descriptor.fragmentFunction = library.makeFunction(
            name: normalMap == nil ? "particle_fragment" : "particle_refract_fragment")
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
        update(particles: system.particles, textureRatio: textureRatio)
    }

    /// 파티클 배열을 그대로 올린다.
    ///
    /// 자식 시스템은 여러 벌이 한 렌더러를 함께 쓴다 — 불꽃 하나가 터질 때마다
    /// 새 시스템이 생기는데, 그때마다 렌더러를 만들면 파이프라인과 버퍼가
    /// 프레임마다 새로 잡힌다.
    func update(particles live: [Particle], textureRatio: Float) {
        self.textureRatio = textureRatio
        let count = min(live.count, capacity)
        let pointer = instanceBuffer.contents().bindMemory(
            to: ParticleInstance.self, capacity: capacity)
        for i in 0..<count {
            let p = live[i]
            pointer[i] = ParticleInstance(
                positionX: layerOrigin.x + Float(p.position.x) * layerScale.x,
                positionY: layerOrigin.y + Float(p.position.y) * layerScale.y,
                positionZ: layerOrigin.z + Float(p.position.z) * layerScale.z,
                size: Float(p.size) * sizeScale,
                rotationX: Float(p.rotation.x),
                rotationY: Float(p.rotation.y),
                rotationZ: Float(p.rotation.z),
                frame: frameIndex(for: p),
                color: SIMD4(Float(p.color.x), Float(p.color.y), Float(p.color.z),
                             Float(p.alpha)),
                // 방향(거울상 포함)은 배율이 걸린 속도로 — 벡터라 origin은 안 더한다.
                velocityX: Float(p.velocity.x) * layerScale.x,
                velocityY: Float(p.velocity.y) * layerScale.y,
                velocityZ: Float(p.velocity.z) * layerScale.z,
                // clamp 크기는 배율 걸기 **전** 속력. size가 이미 배율을 지녀서
                // 여기서까지 곱하면 두 번 걸린다(위 필드 주석 참고).
                localSpeed: Float((p.velocity.x * p.velocity.x + p.velocity.y * p.velocity.y
                    + p.velocity.z * p.velocity.z).squareRoot())
            )
        }
        instanceCount = count
    }

    /// 어느 칸을 그릴지.
    ///
    /// 기본은 사는 동안 칸을 훑는 것이다 — 꽃잎이 도는 것처럼 보이게 하는 용도다.
    /// 하지만 화면에 맺힌 빗방울 프리셋은 `animationmode: randomframe`이라
    /// **파티클마다 한 장을 골라 고정**해야 한다. 훑으면 방울이 모양을 바꾸며
    /// 깜빡인다(실물에서 확인). 시트가 아니면 항상 0이다.
    private func frameIndex(for p: Particle) -> Float {
        guard let sheet, sheet.frameCount > 1 else { return 0 }
        switch animationMode {
        case .randomFrame:
            let seed = min(max(p.frameSeed, 0), 0.999)
            return Float(Int(seed * Double(sheet.frameCount)))
        case .sequence:
            guard p.lifetime > 0 else { return 0 }
            let progress = min(max(p.age / p.lifetime, 0), 0.999)
            return Float(Int(progress * Double(sheet.frameCount)))
        }
    }

    /// 살아 있는 파티클이 없으면 아무것도 인코딩하지 않는다.
    /// `instanceCount: 0`으로 draw를 부르는 것은 낭비다.
    /// - Parameter transform: 원근 씬이면 레이어 세계 변환 × 뷰·투영. 직교면 nil.
    func encode(into encoder: MTLRenderCommandEncoder, visibleOrigin: SIMD2<Float>,
                visibleSize: SIMD2<Float>, transform: simd_float4x4? = nil) {
        guard instanceCount > 0 else { return }
        var uniforms = ParticleUniforms(
            visibleOrigin: visibleOrigin, visibleSize: visibleSize,
            frameScale: sheet?.frameScale ?? SIMD2(1, 1),
            textureRatio: sheet?.frameRatio ?? textureRatio,
            framesPerRow: Float(max(1, sheet?.framesPerRow ?? 1)),
            useTransform: transform == nil ? 0 : 1,
            isTrail: trailParams == nil ? 0 : 1,
            trailLength: trailParams?.length ?? 0,
            trailMaxLength: trailParams?.maxLength ?? 0,
            trailMinLength: trailParams?.minLength ?? 0,
            transform: transform ?? matrix_identity_float4x4)
        encoder.setRenderPipelineState(pipeline)
        // index 2·3을 쓴다. index 0은 컴포지터가 루프 밖에서 묶어 둔 쿼드 정점
        // 버퍼이고 루프 안에서 다시 묶지 않는다. 여기서 0을 덮으면 파티클 다음에
        // 오는 일반 레이어가 인스턴스 배열을 정점으로 읽는다.
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 3)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        if let normalMap {
            // 뒤 화면이 아직 없으면 이 프레임은 건너뛴다. 안 묶고 그리면
            // Metal이 그 draw를 버리고, 그 이유는 화면에 안 나온다.
            guard let background else { return }
            encoder.setFragmentTexture(normalMap, index: 1)
            encoder.setFragmentTexture(background, index: 2)
            var screen = SIMD3<Float>(
                Float(background.width), Float(background.height), refractAmount)
            encoder.setFragmentBytes(
                &screen, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        }
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
    }
}
