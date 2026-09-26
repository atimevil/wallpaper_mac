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
    private var vertexBytes: [UInt8]
    private var fragmentBytes: [UInt8]
    private let vertexUniforms: [GLSLTranslator.Uniform]
    private let fragmentUniforms: [GLSLTranslator.Uniform]
    /// 재질이 정한 상수. 스크립트가 덮어쓰면 다시 싼다.
    private var constants: [String: EffectConstant]
    /// 재질 상수에 붙은 스크립트. 씬 스크립트 호스트가 돌린다.
    let constantScripts: [SceneScriptHost.MaterialScript]
    private let textures: [GLSLTranslator.Texture]
    private var bound: [Int: MTLTexture] = [:]
    /// `_rt_FullFrameBuffer` 슬롯. 뒤 화면 사본이 들어간다.
    private let backgroundSlots: [Int]
    private var background: MTLTexture?
    private let placeholder: MTLTexture
    /// `_rt_Reflection` 같은 나머지 `_rt_*` 슬롯에 주는 한 픽셀 텍스처.
    ///
    /// 반사 버퍼는 WE가 반사를 켠 레이어가 있을 때만 그린다. 이 씬들처럼 그런
    /// 레이어가 없으면 버퍼에는 **지운 색**만 남는다 — 실물 crystal 셰이더가 이
    /// 버퍼를 최대 8배로 곱해 굴절을 만드는데, 뒤 화면을 주면 하얗게 타고 지운
    /// 색(어두운 남색)을 주면 미리보기와 같은 푸른 면이 나온다. 이것은 실물
    /// 미리보기와 견준 추론이지 문서에 있는 규칙은 아니다. `WALLFLOW_REFLECTION=frame`이면
    /// 뒤 화면을 준다.
    private let reflection: MTLTexture
    private let reflectionSlots: [Int]
    private let reflectionUsesFrame = ProcessInfo.processInfo.environment["WALLFLOW_REFLECTION"] == "frame"
    private let eyeProvider: () -> SIMD3<Float>
    /// 씬의 `ambientcolor`·`skylightcolor`.
    private let ambient: SIMD3<Float>
    private let skylight: SIMD3<Float>
    /// WE `cullmode`. 카메라가 메시 경계 상자 **안**에 있으면(하늘상자처럼 안에서
    /// 보는 볼록 메시) `encode(into:)`에서 이 값 대신 `.none`을 준다 — 아래 문서
    /// 참고.
    private let cullMode: MTLCullMode
    /// 정점 감기 방향. 실물 전부(DirectX 툴체인에서 나온 메시) 이 방향으로
    /// 저장된 법선과 어긋나 Metal 기본(반시계=앞면)과 반대다 — `.clockwise`가
    /// 맞다(Saturn 몸체·space boi·`Three-Body`의 하늘상자까지 실측: 평균
    /// 삼각형 수백 개로 기하 법선과 저장 법선의 내적을 재 봐도 전부 같은
    /// 방향이다 — 메시마다 다르지 않다).
    private let frontFacing: MTLWinding = .clockwise
    /// 메시 경계 상자(로컬 공간). 카메라가 안에 있는지 매 프레임 잰다.
    private let boundsMin: SIMD3<Float>
    private let boundsMax: SIMD3<Float>
    /// 씬의 점광·방향광 하나씩(있으면). `PerformLighting_V1`(`generic4` 등)이나
    /// `generic3`의 인라인 광원 루프를 먹인다.
    private let pointLight: (origin: Vec3, angles: Vec3, info: LightInfo)?
    private let directionalLight: (origin: Vec3, angles: Vec3, info: LightInfo)?

    var needsBackground: Bool { !backgroundSlots.isEmpty }
    func setBackground(_ texture: MTLTexture?) { background = texture }

    /// - Parameters:
    ///   - model: 읽어 둔 메시.
    ///   - materialPath: `skin`이 고른 재질 JSON 경로.
    ///   - eye: 카메라 눈 위치. 매 프레임 물어본다.
    ///   - clearColor: 씬의 지운 색. 반사 버퍼 자리에 들어간다.
    init(
        device: MTLDevice, model: MDLModel, materialPath: String,
        resolver: ReferenceResolver, includes: [String: String],
        makeTexture: (TextureData) throws -> MTLTexture,
        sampler: MTLSamplerState, eye: @escaping () -> SIMD3<Float>,
        clearColor: SIMD4<Float> = SIMD4(0, 0, 0, 1),
        ambient: SIMD3<Float> = SIMD3(repeating: 0.302),
        skylight: SIMD3<Float> = SIMD3(repeating: 1),
        lights: [(origin: Vec3, angles: Vec3, info: LightInfo)] = [],
        /// 씬의 `general.hdr`. 켜져 있으면 재질 셰이더의 `HDR` 콤보를 켜고
        /// (`common_pbr_2.h`의 `CombineLighting` `#if HDR` 분기 — 밝기를 곱하고
        /// 이미시브 오버브라이트를 더한다), 파이프라인 색 포맷을 `rgba16Float`로
        /// 만들어 그 값이 1을 넘어도 오프스크린에서 안 잘리게 한다.
        hdr: Bool = false
    ) throws {
        self.ambient = ambient
        self.skylight = skylight
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
        var constantScripts: [SceneScriptHost.MaterialScript] = []
        for (key, raw) in pass["constantshadervalues"] as? [String: Any] ?? [:] {
            let unwrapped = (raw as? [String: Any])?["value"] ?? raw
            let constant = EffectConstant.parse(unwrapped)
            if let constant { constants[key] = constant }
            if let script = (raw as? [String: Any])?["script"] as? String {
                constantScripts.append(.init(key: key, source: script, value: constant))
            }
        }
        self.constants = constants
        self.constantScripts = constantScripts.sorted { $0.key < $1.key }
        var combos: [String: Int] = [:]
        for (key, value) in pass["combos"] as? [String: Any] ?? [:] {
            if let n = (value as? NSNumber)?.intValue { combos[key] = n }
        }
        let sceneTextures = (pass["textures"] as? [Any] ?? []).map { $0 as? String }
        let blending = pass["blending"] as? String ?? "normal"
        let cullMode: MTLCullMode
        switch (pass["cullmode"] as? String ?? "normal").lowercased() {
        case "none": cullMode = .none
        case "reverse": cullMode = .front
        default: cullMode = .back
        }
        self.cullMode = cullMode
        self.boundsMin = SIMD3(Float(model.boundsMin.x), Float(model.boundsMin.y), Float(model.boundsMin.z))
        self.boundsMax = SIMD3(Float(model.boundsMax.x), Float(model.boundsMax.y), Float(model.boundsMax.z))

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
        // 점광·방향광 하나씩만 먹인다. `g_LPoint_Color[LIGHTS_POINT]`는 배열
        // 크기를 모르는 유니폼이라 `UniformPacker`가 원소 하나 자리만 잡는다
        // (`GLSLTranslator.declared(in:)` 문서 참고) — 그 이상을 담으면
        // 버퍼 밖을 쓴다. 여러 빛을 쓰려면 패커부터 배열 크기를 실제 콤보값으로
        // 아는 쪽으로 고쳐야 한다.
        let pointLight = lights.first { $0.info.kind == .point }
        let directionalLight = lights.first { $0.info.kind == .directional }
        if pointLight != nil { combos["LIGHTS_POINT"] = 1 }
        if directionalLight != nil { combos["LIGHTS_DIRECTIONAL"] = 1 }
        // `#define HDR 0`은 절대 넣지 않는다 — `common_blending.h`는 `#ifdef HDR`를
        // 쓰므로, 0을 정의하면 정의 자체가 있다는 뜻이 되어 비HDR 씬의 동작이
        // 바뀐다. 값을 안 주는 것과 0을 주는 것이 다르다.
        if hdr { combos["HDR"] = 1 }
        self.pointLight = pointLight
        self.directionalLight = directionalLight
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
        descriptor.colorAttachments[0].pixelFormat = hdr ? .rgba16Float : MetalCompositor.colorPixelFormat
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
                //
                // **포맷은 셰이더가 선언한 타입을 따라야 한다.** 여기서 무조건
                // `.float4`를 쓰면, `#if SKINNING` 블록의 `a_BlendIndices`(GLSL
                // `uvec4` → MSL `uint4`)처럼 정수 타입 속성에서 Metal이 파이프라인
                // 생성 자체를 거부한다("... of type uint4 cannot be read using
                // MTLAttributeFormatFloat4") — SKINNING이 실제로 꺼져 있어도,
                // 번역기가 `#if`와 무관하게 선언을 전부 걷어 내므로 이 속성 자체는
                // 항상 나타난다(실물 Star1/2/3·Earth4 등, generic3/4 계열 전부).
                vertexDescriptor.attributes[attribute.slot].format =
                    Self.zeroFillFormat(for: attribute.type)
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
                  device.makeBuffer(bytes: raw.baseAddress!, length: max(raw.count, 4), options: []) }),
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
        vertexUniforms = vertex.uniforms
        fragmentUniforms = fragment.uniforms
        vertexBytes = Self.packed(vertex.uniforms, vertexLayout, constants: constants)
        fragmentBytes = Self.packed(fragment.uniforms, fragmentLayout, constants: constants)

        // 텍스처. 씬이 준 것 → 주석 기본값 → 흰색. `_rt_*`는 뒤 화면 사본이다.
        textures = fragment.textures
        guard let white = Self.makePixel(device: device, color: SIMD4(1, 1, 1, 1)),
              let clear = Self.makePixel(device: device, color: clearColor) else {
            throw CompositorError.bufferAllocationFailed
        }
        placeholder = white
        reflection = clear
        var backgroundSlots: [Int] = []
        var reflectionSlots: [Int] = []
        for slot in fragment.textures {
            let path = (slot.index < sceneTextures.count ? sceneTextures[slot.index] : nil)
                ?? slot.defaultPath
            guard let path else { continue }
            if path == "_rt_FullFrameBuffer" || reflectionUsesFrame && path.hasPrefix("_rt_") {
                backgroundSlots.append(slot.index); continue
            }
            if path.hasPrefix("_rt_") { reflectionSlots.append(slot.index); continue }
            for candidate in EffectChain.textureCandidates(path, base: "") {
                guard let data = resolver.data(for: candidate),
                      let decoded = try? TexDecoder.decode(data),
                      let texture = try? makeTexture(decoded) else { continue }
                bound[slot.index] = texture
                break
            }
        }
        self.backgroundSlots = backgroundSlots
        self.reflectionSlots = reflectionSlots
    }

    private static func packed(_ uniforms: [GLSLTranslator.Uniform], _ layout: UniformPacker.Layout,
                               constants: [String: EffectConstant]) -> [UInt8] {
        var values: [String: [Float]] = [:]
        for uniform in uniforms {
            guard let field = layout.field(named: uniform.name) else { continue }
            // 재질 키 대소문자 어긋남은 `EffectConstant.lookup` 문서 참고.
            let constant = uniform.materialKey.flatMap { EffectConstant.lookup(materialKey: $0, in: constants) }
                ?? uniform.defaultValue.flatMap { EffectConstant.parse($0) }
            if let constant { values[uniform.name] = constant.components(field.count) }
        }
        return UniformPacker.pack(values, into: layout)
    }

    /// 스크립트가 정한 재질 상수를 얹는다. 키는 재질의 `constantshadervalues` 키다.
    func setConstants(_ overrides: [String: EffectConstant]) {
        var changed = false
        for (key, value) in overrides where constants[key] != value {
            constants[key] = value
            changed = true
        }
        guard changed else { return }
        vertexBytes = Self.packed(vertexUniforms, vertexLayout, constants: constants)
        fragmentBytes = Self.packed(fragmentUniforms, fragmentLayout, constants: constants)
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

    /// 메시에 없는 속성을 0-버퍼로 채울 때 쓰는 포맷. GLSL 선언 타입(번역기가
    /// 돌려주는 `attribute.type`, 예: `uvec4`·`vec3`)을 그대로 따라가야 한다 —
    /// 0은 어느 타입으로 읽어도 0이라 값은 안 바뀌지만, **포맷 자체가 셰이더의
    /// 선언과 안 맞으면 Metal이 파이프라인을 통째로 거부한다.**
    static func zeroFillFormat(for glslType: String) -> MTLVertexFormat {
        switch glslType {
        case "float": return .float
        case "vec2": return .float2
        case "vec3": return .float3
        case "vec4": return .float4
        case "int": return .int
        case "ivec2": return .int2
        case "ivec3": return .int3
        case "ivec4": return .int4
        case "uint": return .uint
        case "uvec2": return .uint2
        case "uvec3": return .uint3
        case "uvec4": return .uint4
        default: return .float4
        }
    }

    private static func makePixel(device: MTLDevice, color: SIMD4<Float>) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: [UInt8] = [color.x, color.y, color.z, color.w].map {
            UInt8(min(max($0, 0), 1) * 255 + 0.5)
        }
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

    private static func linear3x3(_ world: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
            SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
            SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
    }

    /// `g_NormalModelMatrix`(`mat3`, `generic4.vert`가 `mul(localNormal, ...)`로
    /// 쓴다). world의 3x3(선형) 부분의 **역행렬**을 준다 — 전치는 안 한다.
    ///
    /// 이유: 보통 표기(열벡터 `M*v`)에서 법선은 `(M^-1)^T * n`으로 옮긴다(비균등
    /// 배율에서 법선이 안 비뚤어지려면 역전치가 필요하다). 그런데 이 셰이더는
    /// 행벡터 관례라 `n * G`로 곱한다 — `v*G`는 `G^T*v`(열벡터)와 같으므로,
    /// `G^T = (M^-1)^T`가 되려면 `G = M^-1`이어야 한다. `Self.floats(world)`가
    /// `g_ModelMatrix`에 전치를 **한 번만** 넣는 것과 같은 이유(같은 행벡터
    /// 관례)다. 이 유니폼을 빼먹으면(예전에 그랬다) 값이 0인 행렬로 남아
    /// `normalize(vec3(0))`가 NaN을 내고, 그 NaN이 조명 전체에 번져 구가 텍스처
    /// 없이 새하얗게 뜬다 — 토성 구가 그렇게 뜬 진짜 원인 중 하나였다(남은
    /// 밝기 편차는 별개 사안이다. 아래 커밋 메시지 참고).
    private static func normalMatrixFloats(_ world: simd_float4x4) -> [Float] {
        let m3 = linear3x3(world)
        // 특이 행렬(배율 0)은 못 뒤집는다 — 항등으로 물러나 NaN을 안 낸다.
        let inv = abs(simd_determinant(m3)) > 1e-8 ? simd_inverse(m3) : matrix_identity_float3x3
        return [inv.columns.0, inv.columns.1, inv.columns.2].flatMap { [$0.x, $0.y, $0.z] }
    }

    func encode(into encoder: MTLRenderCommandEncoder, world: simd_float4x4,
                viewProjection: simd_float4x4, alpha: Float, time: Float) {
        guard indexCount > 0 else { return }
        if needsBackground, background == nil { return }
        let eye = eyeProvider()
        var engine: [String: [Float]] = [
            "g_ModelMatrix": Self.floats(world),
            "g_NormalModelMatrix": Self.normalMatrixFloats(world),
            "g_ViewProjectionMatrix": Self.floats(viewProjection),
            "g_ModelViewProjectionMatrix": Self.floats(viewProjection * world),
            "g_EyePosition": [eye.x, eye.y, eye.z],
            // `g_LightsPosition`은 옛 셰이더(`PerformLighting_Deprecated` 이전)의
            // 자리라 실물 어디서도 안 쓴다 — 0으로만 채워 둔다.
            "g_LightsPosition": [Float](repeating: 0, count: 12),
            "g_LightAmbientColor": [ambient.x, ambient.y, ambient.z],
            "g_LightSkylightColor": [skylight.x, skylight.y, skylight.z],
            "g_Time": [time],
            "g_Frametime": [1.0 / 60.0],
            "g_TexelSizeHalf": [0.5 / 1920, 0.5 / 1080],
            "g_TexelSize": [1.0 / 1920, 1.0 / 1080],
        ]
        // `PerformLighting_V1`·`generic3`의 인라인 루프가 읽는 빛 유니폼.
        // `.rgb`에 밝기를 미리 곱한다 — `wfComputePBRLight`가 `.w`를 안 읽는다.
        if let pointLight {
            let c = pointLight.info.color, i = Float(pointLight.info.intensity)
            engine["g_LPoint_Color"] = [Float(c.x) * i, Float(c.y) * i, Float(c.z) * i, 0]
            engine["g_LPoint_Origin"] = [
                Float(pointLight.origin.x), Float(pointLight.origin.y), Float(pointLight.origin.z), 0,
            ]
        }
        if let directionalLight {
            let c = directionalLight.info.color, i = Float(directionalLight.info.intensity)
            let d = directionalLight.info.direction
            engine["g_LDirectional_Color"] = [Float(c.x) * i, Float(c.y) * i, Float(c.z) * i, 0]
            engine["g_LDirectional_Direction"] = [Float(d.x), Float(d.y), Float(d.z), 0]
        }
        encoder.setRenderPipelineState(pipeline)
        // 카메라가 메시 경계 상자 안에 있으면(하늘상자처럼 안에서 보는 볼록
        // 메시) 뒷면 컬링을 끈다 — 오목한 쪽이 아니라 볼록한 껍질 안에서 보는
        // 한 화면의 한 점은 늘 삼각형 하나만 지나므로(광선이 볼록체 표면을
        // 두 번 다시 지나지 않는다) 양면을 다 그려도 겹쳐 잘못 그릴 일이 없다
        // — 카메라 밖에서 볼 때 필요한 뒷면 제거만 빠질 뿐이다. 실물
        // `Three-Body`의 하늘상자(반지름 8~12, 카메라가 원점 근처라 안이다)가
        // 이 컬링 때문에 통째로 사라졌었다(실측: `cullMode=.none`으로 강제하면
        // 별밭·성운이 돌아온다) — Saturn 몸체도 카메라가 안이지만 그쪽은 이미
        // `.clockwise`(뒤집힌 정점 감기)로 안쪽 면이 "앞면"이 되어 정상 컬링이
        // 먹는다(2a10c59). 여기서는 컬링 자체를 끄는 쪽이 메시마다 감기를
        // 다시 재는 것보다 더 단순하고 안전하다(정점 감기는 실물 전부 같음을
        // 확인했다 — 위 `frontFacing` 문서 참고).
        let localEye4 = world.inverse * SIMD4(eye.x, eye.y, eye.z, 1)
        let localEye = SIMD3(localEye4.x, localEye4.y, localEye4.z)
        let insideBounds = boundsMin.x <= localEye.x && localEye.x <= boundsMax.x
            && boundsMin.y <= localEye.y && localEye.y <= boundsMax.y
            && boundsMin.z <= localEye.z && localEye.z <= boundsMax.z
        encoder.setCullMode(insideBounds ? .none : cullMode)
        encoder.setFrontFacing(frontFacing)
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
                ? (background ?? placeholder)
                : reflectionSlots.contains(slot.index) ? reflection
                : (bound[slot.index] ?? placeholder)
            encoder.setFragmentTexture(texture, index: slot.index)
            encoder.setFragmentSamplerState(sampler, index: slot.index)
        }
        // `MDLModel.indices`가 이제 늘 4바이트다(정점 65,536개 넘는 실물이 있어서 —
        // `MDLModel.swift` 문서 참고). 작은 메시도 그냥 4바이트로 통일해 쓴다 —
        // 몇 KB 아끼자고 폭을 또 가르면 여기서 다시 어긋날 자리가 생긴다.
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
}
