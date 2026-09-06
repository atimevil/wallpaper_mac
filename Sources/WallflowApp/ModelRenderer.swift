import Metal
import QuartzCore
import simd
import WallflowKit

/// 3D 메시 하나를 그 재질의 셰이더로 그린다.
///
/// 이펙트 체인이 전체 화면 사각형에 하는 일을 메시에 한다 — GLSL을 번역하고,
/// 유니폼을 주석의 `material` 키로 씬 값과 잇고, 텍스처를 묶는다. 다른 점은
/// 정점이다: 실물 `crystal.vert`가 `a_Position, a_Normal, a_TexCoord, a_Tangent4`를
/// 선언하고 번역기가 그 **선언 순서**로 번호를 매기므로, `.mdl`의 48바이트 정점
/// 안에서 이름마다 자리를 찾아 그 순서대로 묶는다. 이름만 보고 자리를 짐작하면
/// 법선 자리에서 접선을 읽어 조명이 뒤집힌다.
@MainActor
final class ModelRenderer {
    enum Failure: Error { case shaderMissing(String), badMaterial(String), noPipeline(String) }

    private let pipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    /// 메시에 없는 속성(`a_Color` 등)에 묶어 주는 0 버퍼. 안 묶으면 draw가 버려진다.
    private let zeroBuffer: MTLBuffer
    private let sampler: MTLSamplerState
    private let vertexLayout: UniformPacker.Layout
    private let fragmentLayout: UniformPacker.Layout
    private let vertexBytes: [UInt8]
    private let fragmentBytes: [UInt8]
    private let textures: [GLSLTranslator.Texture]
    private var bound: [Int: MTLTexture] = [:]
    /// `_rt_FullFrameBuffer`·`_rt_Reflection` 슬롯. 뒤 화면 사본이 들어간다.
    private let backgroundSlots: [Int]
    private var background: MTLTexture?
    private let placeholder: MTLTexture
    private let eyeProvider: () -> SIMD3<Float>

    var needsBackground: Bool { !backgroundSlots.isEmpty }
    func setBackground(_ texture: MTLTexture?) { background = texture }

    /// - Parameters:
    ///   - model: 읽어 둔 메시.
    ///   - materialPath: `skin`이 고른 재질 JSON 경로.
    ///   - eye: 카메라 눈 위치. 매 프레임 물어본다.
    init(
        device: MTLDevice, model: MDLModel, materialPath: String,
        resolver: ReferenceResolver, includes: [String: String],
        makeTexture: (TextureData) throws -> MTLTexture,
        sampler: MTLSamplerState, eye: @escaping () -> SIMD3<Float>
    ) throws {
        // 재질 셰이더는 텍스처가 **반복**된다고 본다. 실물 `ps2menu`가 `0.3/r`로
        // 0~1 밖을 읽어 터널을 만든다. 이미지 쿼드의 샘플러는 가장자리 고정이라
        // (씬이 `clampuvs`를 켠다) 그걸 그대로 쓰면 화면이 사분면으로 갈라진다.
        let wrapping = MTLSamplerDescriptor()
        wrapping.minFilter = .linear
        wrapping.magFilter = .linear
        wrapping.mipFilter = .notMipmapped
        wrapping.sAddressMode = .repeat
        wrapping.tAddressMode = .repeat
        self.sampler = device.makeSamplerState(descriptor: wrapping) ?? sampler
        self.eyeProvider = eye

        // 재질 → 셰이더·텍스처·상수. 값이 `{"value": …, "script": …}` 객체로도 온다.
        guard let material = resolver.json(for: materialPath),
              let passes = material["passes"] as? [[String: Any]],
              let pass = passes.first,
              let shaderName = pass["shader"] as? String else {
            throw Failure.badMaterial(materialPath)
        }
        var constants: [String: EffectConstant] = [:]
        for (key, raw) in pass["constantshadervalues"] as? [String: Any] ?? [:] {
            let unwrapped = (raw as? [String: Any])?["value"] ?? raw
            if let constant = EffectConstant.parse(unwrapped) { constants[key] = constant }
        }
        var combos: [String: Int] = [:]
        for (key, value) in pass["combos"] as? [String: Any] ?? [:] {
            if let n = (value as? NSNumber)?.intValue { combos[key] = n }
        }
        let sceneTextures = (pass["textures"] as? [Any] ?? []).map { $0 as? String }
        let blending = pass["blending"] as? String ?? "normal"

        // 셰이더 짝. 이펙트와 같은 자리 규칙이다.
        let paths = EffectDefinition.shaderPaths(for: shaderName, base: "")
        guard let vertexSource = paths.vertex.lazy.compactMap({ resolver.data(for: $0) }).first
                .map({ String(decoding: $0, as: UTF8.self) }),
              let fragmentSource = paths.fragment.lazy.compactMap({ resolver.data(for: $0) }).first
                .map({ String(decoding: $0, as: UTF8.self) }) else {
            throw Failure.shaderMissing(shaderName)
        }
        let vertex = try GLSLTranslator.translate(
            vertexSource, stage: .vertex, entryPoint: "vertexMain", includes: includes)
        let fragment = try GLSLTranslator.translate(
            fragmentSource, stage: .fragment, entryPoint: "fragmentMain", includes: includes)

        // 씬이 텍스처를 준 슬롯의 콤보를 켠다(노멀맵 등). 이펙트와 같은 규칙이다.
        for texture in fragment.textures {
            guard let combo = texture.comboName, texture.index < sceneTextures.count,
                  sceneTextures[texture.index] != nil else { continue }
            combos[combo] = 1
        }
        let defines = combos.sorted { $0.key < $1.key }
            .map { "#define \($0.key) \($0.value)\n" }.joined()
        let vertexLibrary = try device.makeLibrary(source: defines + vertex.source, options: nil)
        let fragmentLibrary = try device.makeLibrary(source: defines + fragment.source, options: nil)
        guard let vertexFunction = vertexLibrary.makeFunction(name: "vertexMain"),
              let fragmentFunction = fragmentLibrary.makeFunction(name: "fragmentMain") else {
            throw Failure.noPipeline("진입점을 못 찾음: \(shaderName)")
        }

        // 정점 버퍼. 번역기가 매긴 번호 순서대로, 이름마다 48바이트 안의 자리.
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = MetalCompositor.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor =
            blending == "additive" ? .one : .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let vertexDescriptor = MTLVertexDescriptor()
        var usesZero = false
        for attribute in vertex.attributes {
            if let (format, offset) = Self.meshAttribute(attribute.name) {
                vertexDescriptor.attributes[attribute.slot].format = format
                vertexDescriptor.attributes[attribute.slot].offset = offset
                vertexDescriptor.attributes[attribute.slot].bufferIndex = 1
            } else {
                // 메시에 없는 속성. 0으로 채운 버퍼를 한 자리에서 계속 읽게 한다.
                vertexDescriptor.attributes[attribute.slot].format = .float4
                vertexDescriptor.attributes[attribute.slot].offset = 0
                vertexDescriptor.attributes[attribute.slot].bufferIndex = 2
                usesZero = true
            }
        }
        vertexDescriptor.layouts[1].stride = MDLModel.vertexStride
        if usesZero {
            vertexDescriptor.layouts[2].stride = 16
            vertexDescriptor.layouts[2].stepFunction = .constant
            vertexDescriptor.layouts[2].stepRate = 0
        }
        descriptor.vertexDescriptor = vertexDescriptor
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        guard let vb = model.vertexData.withUnsafeBytes({ raw in
                  device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: []) }),
              let ib = model.indices.withUnsafeBytes({ raw in
                  device.makeBuffer(bytes: raw.baseAddress!, length: max(raw.count, 2), options: []) }),
              let zero = device.makeBuffer(length: 16, options: []) else {
            throw CompositorError.bufferAllocationFailed
        }
        memset(zero.contents(), 0, 16)
        vertexBuffer = vb
        indexBuffer = ib
        zeroBuffer = zero
        indexCount = model.indices.count

        // 유니폼: 씬 값(재질 상수)과 주석 기본값. 엔진 값은 그릴 때 덮는다.
        vertexLayout = UniformPacker.layout(for: vertex.uniforms.map { ($0.name, $0.type, $0.count) })
        fragmentLayout = UniformPacker.layout(for: fragment.uniforms.map { ($0.name, $0.type, $0.count) })
        func packed(_ uniforms: [GLSLTranslator.Uniform], _ layout: UniformPacker.Layout) -> [UInt8] {
            var values: [String: [Float]] = [:]
            for uniform in uniforms {
                guard let field = layout.field(named: uniform.name) else { continue }
                let constant = uniform.materialKey.flatMap { constants[$0] }
                    ?? uniform.defaultValue.flatMap { EffectConstant.parse($0) }
                if let constant { values[uniform.name] = constant.components(field.count) }
            }
            return UniformPacker.pack(values, into: layout)
        }
        vertexBytes = packed(vertex.uniforms, vertexLayout)
        fragmentBytes = packed(fragment.uniforms, fragmentLayout)

        // 텍스처. 씬이 준 것 → 주석 기본값 → 흰색. `_rt_*`는 뒤 화면 사본이다.
        textures = fragment.textures
        guard let white = Self.makeWhitePixel(device: device) else {
            throw CompositorError.bufferAllocationFailed
        }
        placeholder = white
        var backgroundSlots: [Int] = []
        for slot in fragment.textures {
            let path = (slot.index < sceneTextures.count ? sceneTextures[slot.index] : nil)
                ?? slot.defaultPath
            guard let path else { continue }
            if path.hasPrefix("_rt_") { backgroundSlots.append(slot.index); continue }
            for candidate in EffectChain.textureCandidates(path, base: "") {
                guard let data = resolver.data(for: candidate),
                      let decoded = try? TexDecoder.decode(data),
                      let texture = try? makeTexture(decoded) else { continue }
                bound[slot.index] = texture
                break
            }
        }
        self.backgroundSlots = backgroundSlots
        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_DEBUG"] != nil {
            FileHandle.standardError.write(Data("""
            MODELDBG \(materialPath) shader=\(shaderName) 정점 \(model.vertexCount) 색인 \(model.indices.count) \
            속성 \(vertex.attributes.map { "\($0.slot):\($0.name)" }) 뒤화면 \(backgroundSlots) \
            텍스처 \(bound.keys.sorted()) 블렌딩 \(blending)

            """.utf8))
        }
    }

    /// 이름 → `.mdl` 정점 안의 자리. 배치는 `MDLModel` 문서와 같다.
    static func meshAttribute(_ name: String) -> (MTLVertexFormat, Int)? {
        switch name {
        case "a_Position": return (.float3, 0)
        case "a_Normal": return (.float3, 12)
        case "a_Tangent4", "a_Tangent": return (.float4, 24)
        case "a_TexCoord": return (.float2, 40)
        default: return nil
        }
    }

    private static func makeWhitePixel(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: UInt32 = 0xFFFF_FFFF
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &pixel, bytesPerRow: 4)
        return texture
    }

    /// 셰이더의 `mul(v, M)`은 행벡터 관례다. 우리 행렬은 `M * v`로 쓰는 열 우선이라
    /// **전치해서** 넘겨야 같은 변환이 된다. 이걸 놓치면 메시가 뒤집혀 사라진다.
    private static func floats(_ m: simd_float4x4) -> [Float] {
        let t = m.transpose
        return [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    func encode(into encoder: MTLRenderCommandEncoder, world: simd_float4x4,
                viewProjection: simd_float4x4, alpha: Float, time: Float) {
        guard indexCount > 0 else { return }
        if needsBackground, background == nil { return }
        let eye = eyeProvider()
        let engine: [String: [Float]] = [
            "g_ModelMatrix": Self.floats(world),
            "g_ViewProjectionMatrix": Self.floats(viewProjection),
            "g_ModelViewProjectionMatrix": Self.floats(viewProjection * world),
            "g_EyePosition": [eye.x, eye.y, eye.z],
            // 조명 레이어는 아직 없다. 원점의 빛 넷 — 실물 씬도 빛 레이어가 없다.
            "g_LightsPosition": [Float](repeating: 0, count: 12),
            // 씬의 ambientcolor. 실물 원근 씬이 0.302다. 아직 문서에서 읽지 않는다.
            "g_LightAmbientColor": [0.302, 0.302, 0.302],
            "g_LightSkylightColor": [1, 1, 1],
            "g_Time": [time],
            "g_Frametime": [1.0 / 60.0],
            "g_TexelSizeHalf": [0.5 / 1920, 0.5 / 1080],
            "g_TexelSize": [1.0 / 1920, 1.0 / 1080],
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(zeroBuffer, offset: 0, index: 2)
        for (layout, bytes, isVertex) in [(vertexLayout, vertexBytes, true),
                                           (fragmentLayout, fragmentBytes, false)] {
            var buffer = bytes
            let overlay = UniformPacker.pack(engine, into: layout)
            for field in layout.fields where engine[field.name] != nil {
                let end = min(field.offset + field.byteCount, buffer.count, overlay.count)
                guard field.offset < end else { continue }
                for offset in field.offset..<end { buffer[offset] = overlay[offset] }
            }
            guard !buffer.isEmpty else { continue }
            buffer.withUnsafeBytes { raw in
                if isVertex { encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0) }
                else { encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0) }
            }
        }
        for slot in textures {
            let texture = backgroundSlots.contains(slot.index)
                ? (background ?? placeholder) : (bound[slot.index] ?? placeholder)
            encoder.setFragmentTexture(texture, index: slot.index)
            encoder.setFragmentSamplerState(sampler, index: slot.index)
        }
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
}
