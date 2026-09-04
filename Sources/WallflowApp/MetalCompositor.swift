import Metal
import MetalKit
import WallflowKit

enum CompositorError: Error {
    case noDevice
    case libraryCompilationFailed(String)
    case pipelineFailed(String)
    case textureCreationFailed
}

/// 정점 셰이더에 넘기는 쿼드 하나의 배치 정보.
struct QuadUniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var projection: SIMD2<Float>
}

struct QuadInstance {
    /// 직교 공간에서의 중심.
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
}

/// 직교 투영 공간에 텍스처 쿼드를 겹쳐 그린다.
/// 씬의 레이어 순서가 그리는 순서다.
@MainActor
final class MetalCompositor {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let sampler: MTLSamplerState

    private var projection = SIMD2<Float>(1, 1)
    private var layers: [(QuadInstance, MTLTexture)] = []
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw CompositorError.noDevice }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: SceneShaders.source, options: nil)
        } catch {
            throw CompositorError.libraryCompilationFailed("\(error)")
        }

        // 단위 쿼드. 삼각형 스트립 4정점.
        let vertices: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5),
            SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5),
        ]
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
            options: []
        ) else { throw CompositorError.noDevice }
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

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        // 씬이 clampuvs를 켜 두는 경우가 많고, 배경화면은 타일링하지 않는다.
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw CompositorError.noDevice
        }
        self.sampler = sampler
    }

    func setProjection(width: Int, height: Int) {
        projection = SIMD2(Float(width), Float(height))
    }

    func setClearColor(_ color: MTLClearColor) {
        clearColor = color
    }

    func setLayers(_ layers: [(QuadInstance, MTLTexture)]) {
        self.layers = layers
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].loadAction = .clear

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)

        for (quad, texture) in layers {
            var uniforms = QuadUniforms(
                origin: quad.origin, size: quad.size, projection: projection
            )
            encoder.setVertexBytes(
                &uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1
            )
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
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
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format == .rgba8888 ? .rgba8Unorm : .r8Unorm,
                width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw CompositorError.textureCreationFailed
            }
            let bytesPerPixel = format == .rgba8888 ? 4 : 1
            bytes.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: width * bytesPerPixel
                )
            }
            return texture

        case .video:
            // M2는 비디오 텍스처를 그리지 않는다. M3에서 AVFoundation과 잇는다.
            throw CompositorError.textureCreationFailed
        }
    }
}
