import Metal
import MetalKit
import WallflowKit

enum CompositorError: Error {
    case noDevice
    case libraryCompilationFailed(String)
    case pipelineFailed(String)
    case textureCreationFailed
    /// M2는 비디오 텍스처를 그리지 않는다. 진짜 실패와 구분해야
    /// "왜 이 레이어가 안 그려졌나"를 사용자에게 정확히 말할 수 있다.
    case videoTextureNotSupported
    case commandQueueFailed
    case bufferAllocationFailed
    case samplerCreationFailed
}

/// 정점 셰이더에 넘기는 쿼드 하나의 배치 정보.
struct QuadUniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var projection: SIMD2<Float>
    /// 레이어의 color와 alpha. MSL의 float4와 배치가 같아야 한다.
    var color: SIMD4<Float>
    var rotation: Float
    var padding: (Float, Float, Float) = (0, 0, 0)
}

struct QuadInstance {
    /// 직교 공간에서의 중심.
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    /// 씬이 정한 색과 투명도. 기본은 흰색·불투명.
    var color: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    /// 화면 평면 회전(라디안).
    var rotation: Float = 0
    /// 마우스 시차에서 이 레이어가 밀리는 정도.
    var parallaxDepth: Float = 0
    /// 아래 화면과 섞는 방식(WE의 `colorBlendMode`). 0이면 보통 알파 합성이다.
    var blendMode: Int32 = 0
    /// 원근 씬에서의 세계 변환. 직교 씬에서는 쓰지 않는다(항등).
    /// 단위 쿼드(-0.5..0.5)를 세계 단위 크기로 늘리고 돌리고 옮긴 것이다.
    var world: simd_float4x4 = matrix_identity_float4x4
}

/// MSL의 `Quad3DUniforms`와 같은 배치.
struct Quad3DUniforms {
    var model: simd_float4x4
    var viewProjection: simd_float4x4
    var color: SIMD4<Float>
}

/// 레이어가 무엇으로 칠해지는지.
enum LayerSource {
    /// 한 번 만들어 두고 바뀌지 않는 텍스처.
    case fixed(MTLTexture)
    /// 매 프레임 물어보는 텍스처. 비디오가 이 경우다.
    /// VideoTexture가 @MainActor라 페이로드도 격리해야 한다. draw(in:)이 이미
    /// @MainActor이므로 호출 측은 문제없다. nonisolated로 우회하지 마라 —
    /// 실제 스레딩 가정을 표현하는 대신 숨기게 된다.
    case dynamic(@MainActor () -> MTLTexture?)
    /// 3D 메시. 렌더러가 자기 draw를 인코딩한다.
    case model(ModelRenderer)
    /// 텍스처 없이 단색으로 칠한다. 셰이더 flat 레이어가 이 경우다.
    case solid(SIMD4<Float>)
    /// 파티클. 쿼드 하나가 아니라 인스턴싱으로 직접 그린다.
    case particles(ParticleRenderer)
    /// 합성 레이어. 그 지점까지 그려진 화면을 받아 이펙트를 걸고 그 결과를 그린다.
    /// 값은 레이어 번호다 — 렌더러가 그 번호로 어느 체인인지 안다.
    case composition(Int)
}

/// 직교 투영 공간에 텍스처 쿼드를 겹쳐 그린다.
/// 씬의 레이어 순서가 그리는 순서다.
@MainActor
final class MetalCompositor {
    /// 이펙트 체인이 자기 파이프라인을 만들려면 같은 장치가 필요하다.
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// 원근 씬용. 카메라가 있으면 쿼드를 이 파이프라인으로 그린다.
    private let pipeline3D: MTLRenderPipelineState
    /// 원근 씬의 뷰·투영. nil이면 직교 씬이다.
    private var viewProjection: simd_float4x4?
    /// 아래 화면을 읽어 직접 섞는 파이프라인. 못 만드는 기기에서는 nil이다.
    /// `WALLFLOW_BLEND_FORCE`로 준 진단용 섞기 방식.
    static let forcedBlendMode: Int32? = ProcessInfo.processInfo
        .environment["WALLFLOW_BLEND_FORCE"].flatMap { Int32($0) }
    private let blendPipeline: MTLRenderPipelineState?
    /// 섞기 파이프라인을 못 만든 이유. 만들었으면 nil이다.
    /// 조용히 보통 합성으로 그리면 사용자는 시계가 왜 하얗게 뜨는지 알 수 없다.
    let blendUnavailableReason: String?
    private let solidBlendPipeline: MTLRenderPipelineState?
    /// 합성 레이어가 읽을 그림을 레이어 좌표계로 떠내는 파이프라인.
    private let compositionPipeline: MTLRenderPipelineState?
    /// 그 그림을 담는 텍스처. 레이어마다 크기가 달라 번호로 들고 있는다.
    private var compositionSources: [Int: MTLTexture] = [:]
    private let solidPipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let sampler: MTLSamplerState
    /// 메시 렌더러가 같은 샘플러를 쓴다. 텍스처마다 따로 만들 이유가 없다.
    var sharedSampler: MTLSamplerState { sampler }
    private let library: MTLLibrary

    private var projection = SIMD2<Float>(1, 1)
    private var layers: [(QuadInstance, LayerSource)] = []
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    /// 지금 프레임의 시차 밀림(직교 단위). 레이어마다 깊이를 곱해 쓴다.
    private var parallax = SIMD2<Float>(0, 0)

    /// 화면과 오프스크린이 같은 포맷이어야 한다. 다르면 raw 복사에서 채널이
    /// 뒤바뀌고(bgra↔rgba), 파이프라인도 첨부물 포맷이 맞지 않는다.
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw CompositorError.commandQueueFailed }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: SceneShaders.source, options: nil)
        } catch {
            throw CompositorError.libraryCompilationFailed("\(error)")
        }
        self.library = library

        // 단위 쿼드. 삼각형 스트립 4정점.
        let vertices: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5),
            SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5),
        ]
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
            options: []
        ) else { throw CompositorError.bufferAllocationFailed }
        vertexBuffer = buffer

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        descriptor.colorAttachments[0].pixelFormat = Self.colorPixelFormat

        // 씬 머티리얼의 기본 블렌딩이 translucent다.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        descriptor.vertexDescriptor = vertexDescriptor

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

        // 원근 쿼드. 프래그먼트는 같고 정점만 세계·카메라 행렬을 곱한다.
        descriptor.vertexFunction = library.makeFunction(name: "quad3d_vertex")
        do {
            pipeline3D = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")

        // 단색 레이어용 파이프라인 (같은 정점, 다른 프래그먼트)
        descriptor.fragmentFunction = library.makeFunction(name: "solid_fragment")
        do {
            solidPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

        // 색 섞기 파이프라인. 프래그먼트가 아래 화면을 직접 읽으므로 **고정
        // 블렌딩을 끈다** — 켜 두면 우리가 섞은 것을 GPU가 한 번 더 섞는다.
        //
        // 타일 메모리를 읽는 것은 Apple GPU의 기능이다. 없는 기기(인텔 맥)에서는
        // 파이프라인 생성이 실패하므로, 던지지 않고 nil로 두고 보통 합성으로
        // 그린다 — 섞기 하나 때문에 배경화면 전체가 안 뜨면 안 된다.
        descriptor.colorAttachments[0].isBlendingEnabled = false
        descriptor.fragmentFunction = library.makeFunction(name: "quad_blend_fragment")
        var blendFailure: String?
        do {
            blendPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            blendPipeline = nil
            blendFailure = "\(error)"
        }
        blendUnavailableReason = blendFailure
        descriptor.fragmentFunction = library.makeFunction(name: "solid_blend_fragment")
        solidBlendPipeline = try? device.makeRenderPipelineState(descriptor: descriptor)

        // 합성 레이어가 읽을 그림을 떠내는 패스. 목적지를 통째로 덮으므로
        // 블렌딩이 필요 없다.
        descriptor.colorAttachments[0].isBlendingEnabled = false
        descriptor.fragmentFunction = library.makeFunction(name: "composition_extract_fragment")
        compositionPipeline = try? device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        // 씬이 clampuvs를 켜 두는 경우가 많고, 배경화면은 타일링하지 않는다.
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw CompositorError.samplerCreationFailed
        }
        self.sampler = sampler
    }

    /// 파티클 레이어 하나에 붙일 렌더러를 만든다.
    /// 셰이더 라이브러리를 재사용해 레이어마다 MSL을 다시 컴파일하지 않는다.
    func makeParticleRenderer(
        maxCount: Int, blend: ParticleBlendMode, texture: MTLTexture,
        layerOrigin: SIMD3<Float>, layerScale: SIMD3<Float>,
        sheet: ParticleSpriteSheet?, animationMode: ParticleAnimationMode,
        normalMap: MTLTexture? = nil, refractAmount: Float = 0.05
    ) throws -> ParticleRenderer {
        try ParticleRenderer(
            device: device, library: library, maxCount: maxCount,
            blend: blend, texture: texture, sampler: sampler, layerOrigin: layerOrigin,
            layerScale: layerScale, sheet: sheet, animationMode: animationMode,
            normalMap: normalMap, refractAmount: refractAmount)
    }

    /// 씬의 직교 공간 크기를 정한다.
    /// 첫 draw 전에 반드시 불러야 한다. 기본값 (1,1)로 그리면 지오메트리가
    /// 클립 공간 밖으로 밀려나 아무것도 보이지 않는다.
    func setProjection(width: Int, height: Int) {
        projection = SIMD2(Float(width), Float(height))
    }

    /// 원근 씬의 카메라. 매 프레임 바뀔 수 있다(스크립트가 움직인다).
    /// nil로 두면 직교 씬처럼 그린다.
    func setCamera(viewProjection: simd_float4x4?, eye: SIMD3<Float> = .zero) {
        self.viewProjection = viewProjection
        self.cameraEye = eye
    }
    /// 카메라 눈. 유리 메시 셰이더가 시선 방향을 만드는 데 쓴다.
    private(set) var cameraEye: SIMD3<Float> = .zero

    /// 마우스 시차 밀림을 정한다. 매 프레임 바뀐다.
    func setParallax(_ offset: SIMD2<Float>) {
        parallax = offset.x.isFinite && offset.y.isFinite ? offset : .zero
    }

    func setClearColor(_ color: MTLClearColor) {
        clearColor = color
    }

    func setLayers(_ layers: [(QuadInstance, LayerSource)]) {
        self.layers = layers
    }

    /// 레이어를 합성하기 **전에** 부른다. 이펙트 체인이 여기서 자기 텍스처를 그린다.
    ///
    /// 같은 커맨드 버퍼에 넣어야 순서가 보장된다 — 따로 제출하면 이번 프레임의
    /// 이펙트 결과가 다음 프레임에야 보이거나, 반쯤 그려진 것이 합성될 수 있다.
    var prepare: ((MTLCommandBuffer) -> Void)?

    /// 합성이 **끝난 화면**을 받아 후처리한 결과를 돌려준다.
    ///
    /// 후처리 레이어는 자기 그림이 없고 그 아래까지 합성된 화면을 입력으로 받는다.
    /// 그래서 레이어를 화면에 바로 그리지 않고 별도 텍스처에 그린 뒤, 이 손잡이가
    /// 돌려준 것을 화면에 옮긴다. nil을 돌려주면 원래 화면을 그대로 쓴다.
    var postProcess: (@MainActor (MTLCommandBuffer, MTLTexture) -> MTLTexture?)?

    /// 합성 레이어 하나를 처리한다. 그 지점까지 그려진 화면을 받아 결과를 돌려준다.
    /// nil이면 그 레이어를 건너뛴다.
    var composite: (@MainActor (Int, MTLCommandBuffer, MTLTexture) -> MTLTexture?)?

    /// 합성 레이어가 있으면 화면이 아니라 텍스처에 그려야 한다 — 그 지점까지의
    /// 화면을 셰이더가 읽어야 하는데, 표시용 드로어블은 읽을 수 없다.
    private var needsOffscreen: Bool {
        if postProcess != nil { return true }
        return layers.contains {
            switch $0.1 {
            case .composition: return true
            // 굴절 파티클도 뒤 화면을 읽어야 한다. 드로어블은 읽을 수 없다.
            case .particles(let renderer): return renderer.needsBackground
            // 프리즘 같은 유리 메시도 `_rt_FullFrameBuffer`를 읽는다.
            case .model(let renderer): return renderer.needsBackground
            default: return false
            }
        }
    }

    /// 후처리가 있을 때 레이어를 모아 그리는 곳.
    private var frameTexture: MTLTexture?
    /// 굴절이 읽을 "여기까지 그려진 화면"의 사본.
    ///
    /// 그리는 중인 텍스처를 그대로 읽을 수는 없다 — 같은 텍스처를 읽으면서
    /// 쓰면 결과가 정의되지 않는다. 그래서 한 장 떠 놓고 그것을 읽는다.
    private var backdropTexture: MTLTexture?

    /// 합성 레이어가 읽을 그림을 레이어 좌표계로 떠낸다.
    ///
    /// 크기는 그 상자가 화면에서 차지하는 픽셀 수다. 너무 크면 죈다 —
    /// 창작마당 씬이 4551x2560짜리 레이어를 두기도 한다.
    private func extractComposition(
        id: Int, quad: QuadInstance, uniforms: QuadUniforms,
        from frame: MTLTexture, commands: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let compositionPipeline, projection.x > 0, projection.y > 0 else { return nil }
        let scaleX = Double(frame.width) / Double(projection.x)
        let scaleY = Double(frame.height) / Double(projection.y)
        let width = Int((Double(abs(quad.size.x)) * scaleX).rounded())
        let height = Int((Double(abs(quad.size.y)) * scaleY).rounded())
        let bounded = (
            Swift.min(Swift.max(width, 1), frame.width),
            Swift.min(Swift.max(height, 1), frame.height))
        var target = compositionSources[id]
        if target == nil || target?.width != bounded.0 || target?.height != bounded.1 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.colorPixelFormat,
                width: bounded.0, height: bounded.1, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            target = device.makeTexture(descriptor: descriptor)
            compositionSources[id] = target
        }
        guard let target else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(compositionPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        // 목적지를 꽉 채우는 쿼드. 배치는 목적지 기준이라 회전 없이 그린다.
        var fill = QuadUniforms(
            origin: SIMD2(Float(bounded.0) / 2, Float(bounded.1) / 2),
            size: SIMD2(Float(bounded.0), Float(bounded.1)),
            projection: SIMD2(Float(bounded.0), Float(bounded.1)),
            color: SIMD4(1, 1, 1, 1), rotation: 0)
        encoder.setVertexBytes(&fill, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        // 읽을 자리는 원래 레이어의 배치다.
        var source = uniforms
        encoder.setFragmentBytes(&source, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return target
    }

    private func backdrop(width: Int, height: Int) -> MTLTexture? {
        if let backdropTexture, backdropTexture.width == width,
           backdropTexture.height == height {
            return backdropTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorPixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        backdropTexture = device.makeTexture(descriptor: descriptor)
        return backdropTexture
    }

    private func frame(width: Int, height: Int) -> MTLTexture? {
        if let frameTexture, frameTexture.width == width, frameTexture.height == height {
            return frameTexture
        }
        // **화면과 같은 포맷이어야 한다.** 다른 포맷에 그린 뒤 raw로 복사하면
        // 채널 순서가 뒤바뀐다(bgra↔rgba) — 빨강이 파랑 자리로 가서 색이 죽는다.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorPixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        frameTexture = device.makeTexture(descriptor: descriptor)
        return frameTexture
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        prepare?(commands)

        // 후처리가 있으면 화면이 아니라 텍스처에 모아 그린다.
        let offscreen = needsOffscreen
            ? frame(width: drawable.texture.width, height: drawable.texture.height) : nil
        if let offscreen {
            descriptor.colorAttachments[0].texture = offscreen
            descriptor.colorAttachments[0].storeAction = .store
        }
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].loadAction = .clear

        // 합성 레이어를 만나면 인코더를 끊고 그 지점까지의 화면을 셰이더에 넘겨야
        // 한다. 그래서 인코더를 다시 열 수 있게 만들어 둔다 — 다시 열 때는
        // 지금까지 그린 것을 지우면 안 되므로 `.load`다.
        func startEncoder(clear: Bool) -> MTLRenderCommandEncoder? {
            descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
            guard let new = commands.makeRenderCommandEncoder(descriptor: descriptor)
            else { return nil }
            new.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            return new
        }
        guard var encoder = startEncoder(clear: true) else { return }

        for (quad, source) in layers {
            // 스크립트가 숨긴 레이어. 알파 0으로 그려도 보이지 않지만, 메시·파티클은
            // 알파와 무관하게 그리므로 아예 건너뛴다.
            if quad.color.w <= 0.001 { continue }
            var uniforms = QuadUniforms(
                origin: quad.origin + parallax * quad.parallaxDepth,
                size: quad.size, projection: projection,
                color: quad.color, rotation: quad.rotation)

            // 섞기 파이프라인이 없는 기기면 보통 합성으로 그린다.
            var mode = blendPipeline == nil ? 0 : quad.blendMode
            // 진단용: 모든 레이어에 같은 방식을 강제한다. 실물 씬에서 섞기가
            // 걸린 레이어는 숨어 있는 위젯이거나 결과가 보통과 거의 같아서,
            // 화면만 봐서는 이 경로가 도는지 알 수 없다. 2(곱하기)를 주면
            // 검은 바탕과 곱해져 화면이 통째로 어두워진다.
            if let forced = Self.forcedBlendMode { mode = forced }

            switch source {
            case .solid(var color):
                if mode != 0, let solidBlendPipeline {
                    encoder.setRenderPipelineState(solidBlendPipeline)
                    encoder.setVertexBytes(
                        &uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 0)
                    encoder.setFragmentBytes(
                        &color, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    break
                }
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            case .fixed(let texture):
                if let viewProjection {
                    // 원근 씬. 색 섞기는 아직 직교 경로에만 있다.
                    encoder.setRenderPipelineState(pipeline3D)
                    var u3 = Quad3DUniforms(model: quad.world, viewProjection: viewProjection,
                                            color: quad.color)
                    encoder.setVertexBytes(&u3, length: MemoryLayout<Quad3DUniforms>.stride, index: 1)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    break
                }
                encoder.setRenderPipelineState(
                    mode != 0 ? (blendPipeline ?? pipeline) : pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                if mode != 0 {
                    encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 0)
                }
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
            case .dynamic(let provider):
                // 프레임이 아직 없으면 이 레이어만 건너뛴다. 씬 전체를 멈추지 않는다.
                guard let texture = provider() else { continue }
                if let viewProjection {
                    encoder.setRenderPipelineState(pipeline3D)
                    var u3 = Quad3DUniforms(model: quad.world, viewProjection: viewProjection,
                                            color: quad.color)
                    encoder.setVertexBytes(&u3, length: MemoryLayout<Quad3DUniforms>.stride, index: 1)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    continue
                }
                // 이펙트가 걸린 레이어와 비디오가 이 경로다. **실물에서 섞기가
                // 걸린 레이어는 대개 이쪽이다** — 여기를 빼먹으면 아무 일도
                // 일어나지 않고, 화면만 봐서는 왜인지 알 수 없다.
                encoder.setRenderPipelineState(
                    mode != 0 ? (blendPipeline ?? pipeline) : pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                if mode != 0 {
                    encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 0)
                }
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
            case .composition(let id):
                // 그 지점까지 그려진 화면이 이 레이어의 입력이다. 인코더를 끊어
                // 지금까지 그린 것을 텍스처에 확정한 뒤 넘긴다.
                encoder.endEncoding()
                // 이펙트가 상자를 화면 삼아 돌도록, 상자 자리의 그림을 레이어
                // 좌표계로 떠서 넘긴다. 화면 전체를 넘기면 오디오 막대가
                // 화면 아래에 그려지고 상자에는 배경만 비친다.
                let source = offscreen.flatMap {
                    extractComposition(id: id, quad: quad, uniforms: uniforms,
                                       from: $0, commands: commands)
                }
                let result = source.flatMap { composite?(id, commands, $0) }
                guard let restarted = startEncoder(clear: false) else { return }
                encoder = restarted
                guard let result else { continue }
                encoder.setRenderPipelineState(
                    mode != 0 ? (blendPipeline ?? pipeline) : pipeline)
                encoder.setVertexBytes(
                    &uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                if mode != 0 {
                    encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 0)
                }
                encoder.setFragmentTexture(result, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
            case .model(let renderer):
                guard let viewProjection else { continue }
                if renderer.needsBackground, let offscreen,
                   let copy = backdrop(width: offscreen.width, height: offscreen.height) {
                    // 유리 메시는 뒤 화면을 읽는다. 굴절 파티클과 같은 길이다.
                    encoder.endEncoding()
                    if let blit = commands.makeBlitCommandEncoder() {
                        blit.copy(from: offscreen, to: copy)
                        blit.endEncoding()
                    }
                    guard let restarted = startEncoder(clear: false) else { return }
                    encoder = restarted
                    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                    renderer.setBackground(copy)
                }
                renderer.encode(into: encoder, world: quad.world, viewProjection: viewProjection,
                                alpha: quad.color.w, time: Float(CACurrentMediaTime()))
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                continue

            case .particles(let renderer):
                if renderer.needsBackground {
                    // 굴절은 **뒤에 이미 그려진 화면**을 읽는다. 그리는 중인
                    // 텍스처를 그대로 읽을 수는 없으므로, 인코더를 끊어 지금까지
                    // 그린 것을 확정하고 한 장 떠서 넘긴다.
                    if let offscreen,
                       let copy = backdrop(width: offscreen.width, height: offscreen.height) {
                        encoder.endEncoding()
                        if let blit = commands.makeBlitCommandEncoder() {
                            blit.copy(from: offscreen, to: copy)
                            blit.endEncoding()
                        }
                        guard let restarted = startEncoder(clear: false) else { return }
                        encoder = restarted
                        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                        renderer.setBackground(copy)
                    } else {
                        // 오프스크린이 없으면 읽을 화면도 없다. 이 프레임은 건너뛴다.
                        renderer.setBackground(nil)
                    }
                }
                // 파티클은 자기 draw를 인코딩한다. 아래 공통 drawPrimitives까지
                // 실행되면 파티클 위에 정체불명의 쿼드가 한 장 더 그려진다.
                renderer.encode(into: encoder, projection: projection,
                                transform: viewProjection.map { $0 * quad.world })
                // 파티클 파이프라인이 정점 버퍼 결합을 바꿨을 수 있으므로
                // 다음 쿼드 레이어를 위해 index 0을 되돌린다.
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                continue
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()

        if let offscreen {
            // 후처리 결과를 화면으로 옮긴다. 후처리가 실패하면 원래 화면을 쓴다.
            let result = postProcess?(commands, offscreen) ?? offscreen
            // **복사가 아니라 그린다.** raw 복사는 포맷이 다르면 채널 순서를
            // 뒤바꾸고 감마도 어긋난다. 샘플링해서 그리면 Metal이 변환을 맡는다.
            let present = MTLRenderPassDescriptor()
            present.colorAttachments[0].texture = drawable.texture
            present.colorAttachments[0].loadAction = .clear
            present.colorAttachments[0].clearColor = clearColor
            present.colorAttachments[0].storeAction = .store
            if let encoder = commands.makeRenderCommandEncoder(descriptor: present) {
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setRenderPipelineState(pipeline)
                // 화면을 꽉 채우는 쿼드. 시차는 이미 반영돼 있으므로 0이다.
                var uniforms = QuadUniforms(
                    origin: projection * 0.5, size: projection, projection: projection,
                    color: SIMD4(1, 1, 1, 1), rotation: 0)
                encoder.setVertexBytes(
                    &uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentTexture(result, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
        }
        commands.present(drawable)
        commands.commit()
    }

    /// 디코딩된 텍스처를 Metal 텍스처로 올린다.
    func makeTexture(from data: TextureData) throws -> MTLTexture {
        switch data {
        case .image(let cgImage):
            let loader = MTKTextureLoader(device: device)
            return try loader.newTexture(cgImage: cgImage, options: [
                .SRGB: false as NSNumber,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue as NSNumber,
            ])

        case .pixels(let bytes, let width, let height, let format):
            // TextureData.pixels는 public case라 누구나 만들 수 있다. TexDecoder가
            // 보장하는 "0이 아닌 정확한 크기의 버퍼"라는 불변조건은 이 타깃에서는
            // 검증된 적이 없으므로, 여기서 실제로 필요한 조건을 직접 확인한다.
            // TexDecoder의 세 디코드 분기 모두 16384 상한(TexHeader.maxTextureDimension)을
            // 지키므로 width/height 자체는 막힌다고 봐도 되지만, 그 보장이 이 코드에까지
            // 닿는다고 그냥 믿지 않는다.
            guard width > 0, height > 0 else { throw CompositorError.textureCreationFailed }
            // 크기 산술은 포맷이 안다. 블록 압축은 4x4 단위라 픽셀 곱셈이 성립하지 않는다.
            guard let expectedTotal = format.byteCount(width: width, height: height),
                  bytes.count == expectedTotal else {
                throw CompositorError.textureCreationFailed
            }

            let pixelFormat: MTLPixelFormat
            switch format {
            case .rgba8888: pixelFormat = .rgba8Unorm
            case .r8: pixelFormat = .r8Unorm
            case .rg88: pixelFormat = .rg8Unorm
            case .dxt5, .dxt1:
                // Apple Silicon은 BC를 직접 지원한다(M1 Max에서 확인). CPU 디코더를
                // 짤 필요가 없고, 그러면 디코더가 틀릴 위험도 없다. 지원하지 않는
                // GPU에서는 조용히 이상하게 그리지 말고 실패시킨다.
                guard device.supportsBCTextureCompression else {
                    throw CompositorError.textureCreationFailed
                }
                pixelFormat = format == .dxt1 ? .bc1_rgba : .bc3_rgba
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw CompositorError.textureCreationFailed
            }
            let bytesPerRow = format.bytesPerRow(width: width)
            var replaceFailed = false
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    replaceFailed = true
                    return
                }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
            guard !replaceFailed else { throw CompositorError.textureCreationFailed }
            return texture

        case .video:
            // M2는 비디오 텍스처를 그리지 않는다. M3에서 AVFoundation과 잇는다.
            throw CompositorError.videoTextureNotSupported
        }
    }
}
