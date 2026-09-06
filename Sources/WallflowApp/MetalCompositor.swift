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
    /// 텍스처 없이 단색으로 칠한다. 셰이더 flat 레이어가 이 경우다.
    case solid(SIMD4<Float>)
    /// 파티클. 쿼드 하나가 아니라 인스턴싱으로 직접 그린다.
    case particles(ParticleRenderer)
}

/// 직교 투영 공간에 텍스처 쿼드를 겹쳐 그린다.
/// 씬의 레이어 순서가 그리는 순서다.
@MainActor
final class MetalCompositor {
    /// 이펙트 체인이 자기 파이프라인을 만들려면 같은 장치가 필요하다.
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let solidPipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let sampler: MTLSamplerState
    private let library: MTLLibrary

    private var projection = SIMD2<Float>(1, 1)
    private var layers: [(QuadInstance, LayerSource)] = []
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    /// 지금 프레임의 시차 밀림(직교 단위). 레이어마다 깊이를 곱해 쓴다.
    private var parallax = SIMD2<Float>(0, 0)

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
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

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

        // 단색 레이어용 파이프라인 (같은 정점, 다른 프래그먼트)
        descriptor.fragmentFunction = library.makeFunction(name: "solid_fragment")
        do {
            solidPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

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
        sheet: ParticleSpriteSheet?
    ) throws -> ParticleRenderer {
        try ParticleRenderer(
            device: device, library: library, maxCount: maxCount,
            blend: blend, texture: texture, sampler: sampler, layerOrigin: layerOrigin,
            layerScale: layerScale, sheet: sheet)
    }

    /// 씬의 직교 공간 크기를 정한다.
    /// 첫 draw 전에 반드시 불러야 한다. 기본값 (1,1)로 그리면 지오메트리가
    /// 클립 공간 밖으로 밀려나 아무것도 보이지 않는다.
    func setProjection(width: Int, height: Int) {
        projection = SIMD2(Float(width), Float(height))
    }

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

    /// 후처리가 있을 때 레이어를 모아 그리는 곳.
    private var frameTexture: MTLTexture?

    private func frame(width: Int, height: Int) -> MTLTexture? {
        if let frameTexture, frameTexture.width == width, frameTexture.height == height {
            return frameTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
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
        let offscreen = postProcess == nil
            ? nil : frame(width: drawable.texture.width, height: drawable.texture.height)
        if let offscreen {
            descriptor.colorAttachments[0].texture = offscreen
            descriptor.colorAttachments[0].storeAction = .store
        }
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].loadAction = .clear

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        for (quad, source) in layers {
            var uniforms = QuadUniforms(
                origin: quad.origin + parallax * quad.parallaxDepth,
                size: quad.size, projection: projection,
                color: quad.color, rotation: quad.rotation)

            switch source {
            case .solid(var color):
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            case .fixed(let texture):
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
            case .dynamic(let provider):
                // 프레임이 아직 없으면 이 레이어만 건너뛴다. 씬 전체를 멈추지 않는다.
                guard let texture = provider() else { continue }
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
            case .particles(let renderer):
                // 파티클은 자기 draw를 인코딩한다. 아래 공통 drawPrimitives까지
                // 실행되면 파티클 위에 정체불명의 쿼드가 한 장 더 그려진다.
                renderer.encode(into: encoder, projection: projection)
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
            if let blit = commands.makeBlitCommandEncoder() {
                if result.width == drawable.texture.width,
                   result.height == drawable.texture.height {
                    blit.copy(from: result, to: drawable.texture)
                } else {
                    // 후처리는 작업 해상도를 죄므로 크기가 다를 수 있다.
                    // 그때는 후처리를 버리고 원래 화면을 낸다 — 늘려 그리는 것보다
                    // 원본이 낫고, 이 경로는 예산 상한에 걸렸을 때만 온다.
                    blit.copy(from: offscreen, to: drawable.texture)
                }
                blit.endEncoding()
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
