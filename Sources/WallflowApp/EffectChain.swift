import Foundation
import Metal
import WallflowKit

/// 레이어 하나에 걸린 이펙트를 실제로 그린다.
///
/// 이펙트는 패스의 나열이다. 패스마다 전체 화면 사각형 하나를 그리는데, 읽는 것은
/// 직전 결과(`previous`)나 이름 붙은 렌더 타깃(`_rt_*`)이고, 쓰는 곳은 다음
/// 렌더 타깃이다. 마지막 패스의 결과가 레이어의 새 그림이 된다.
///
/// **실패하면 이펙트만 버린다.** 셰이더는 창작마당에서 온 텍스트라 컴파일이 안 될
/// 수 있는데, 그때 레이어까지 버리면 화면에서 그림이 사라진다. 원본 텍스처를
/// 그대로 쓰는 것이 언제나 더 나은 폴백이다.
@MainActor
final class EffectChain {
    /// 패스 하나를 그릴 준비가 끝난 상태.
    private struct CompiledPass {
        let pipeline: MTLRenderPipelineState
        let target: String?
        let bindings: [EffectBinding]
        let vertexLayout: UniformPacker.Layout
        let fragmentLayout: UniformPacker.Layout
        let vertexBytes: [UInt8]
        let fragmentBytes: [UInt8]
        /// 셰이더가 선언한 텍스처들. 슬롯마다 **반드시** 무엇이든 묶어야 한다 —
        /// Metal에서 안 묶인 텍스처를 샘플링하면 쓰레기가 나온다(자홍색 블록).
        let textures: [GLSLTranslator.Texture]
        /// 씬이 슬롯마다 지정한 텍스처 경로.
        let sceneTextures: [String?]
        /// 이 패스가 속한 이펙트 폴더. 텍스처의 상대 경로가 여기 기준일 수 있다.
        let base: String
        /// 시간처럼 매 프레임 바뀌는 값이 있는지. 없으면 한 번만 그리면 된다.
        let isAnimated: Bool
    }

    /// 렌더 타깃 이름에 붙는 크기 접두사. `_rt_Quarter*`는 1/4 해상도다.
    /// 무시하면 흐림이 원본 해상도에서 돌아 느리고, 흐려지지도 않는다.
    private static func scale(forTarget name: String) -> Int {
        if name.contains("Quarter") { return 4 }
        if name.contains("Half") { return 2 }
        return 1
    }

    /// 이펙트를 그리는 작업 해상도의 한 변 상한.
    ///
    /// 레이어 텍스처가 화면보다 훨씬 클 수 있다 — 실물에 9000픽셀짜리가 있어서
    /// 체인 하나가 텍스처만 973MB를 잡았다. 어차피 화면 크기로 축소되어 보이므로
    /// 그 해상도에서 이펙트를 돌릴 이유가 없다. 상시 구동 앱이라 이 낭비는
    /// 그대로 사용자 메모리다.
    static let maxWorkingSide = 2560

    /// 씬 하나가 이펙트에 쓸 수 있는 텍스처 총량.
    /// 파티클 예산과 같은 이유다 — 레이어 하나의 상한만으로는 여러 개를 못 막는다.
    static let maxSceneTextureBytes = 320 * 1_000_000

    private let device: MTLDevice
    private let passes: [CompiledPass]
    private var targets: [String: MTLTexture] = [:]
    private let output: MTLTexture
    /// 이펙트 패스가 번갈아 쓰는 두 버퍼. 하나는 체인 입구의 미리 곱한 사본이기도 하다.
    private let bufferA: MTLTexture
    private let bufferB: MTLTexture
    private let sampler: MTLSamplerState
    /// 입구·출구 패스용. 1:1 복사라 점 필터여야 한다 — 선형이면 그 패스 자체가 번진다.
    private let pointSampler: MTLSamplerState
    private let clean: MTLRenderPipelineState
    private let copy: MTLRenderPipelineState
    /// 슬롯을 채울 것이 없을 때 묶는 1x1 흰색. 마스크 자리에 검정을 묶으면
    /// 레이어가 통째로 사라지므로 흰색이 안전하다.
    private let placeholder: MTLTexture
    /// 셰이더 주석의 기본 텍스처(`util/noise` 등). 경로별로 한 번만 만든다.
    private var defaults: [String: MTLTexture] = [:]
    private let width: Int
    private let height: Int

    /// 이 체인이 그린 마지막 그림. 레이어가 이걸 텍스처로 쓴다.
    var texture: MTLTexture { output }
    /// 매 프레임 다시 그려야 하는지. 시간이 안 들어가면 한 번으로 끝난다.
    let isAnimated: Bool

    /// 이 체인의 패스 수. 진단용이다.
    var passCount: Int { passes.count }

    /// 이 체인이 잡은 텍스처 메모리(바이트). 상시 구동 예산을 재는 근거다.
    var textureBytes: Int {
        let full = width * height * 4
        return full * 3 + targets.values.reduce(0) { $0 + $1.width * $1.height * 4 }
    }

    // MARK: - 만들기

    /// - Returns: 하나도 컴파일되지 않으면 nil. 호출자가 원본 텍스처를 그대로 쓴다.
    init?(device: MTLDevice, effects: [EffectDefinition], effectBases: [String],
          source: MTLTexture, resolver: ReferenceResolver, includes: [String: String],
          makeTexture: (TextureData) throws -> MTLTexture,
          diagnostics: inout [String]) {
        self.device = device
        guard source.width > 0, source.height > 0 else { return nil }
        // 긴 변을 상한에 맞춰 줄인다. 비율은 지킨다 — 안 지키면 이펙트가
        // 늘어난 좌표계에서 돌아 무늬가 찌그러진다.
        let longest = Swift.max(source.width, source.height)
        let divisor = longest > Self.maxWorkingSide
            ? Double(longest) / Double(Self.maxWorkingSide) : 1
        self.width = Swift.max(1, Int((Double(source.width) / divisor).rounded()))
        self.height = Swift.max(1, Int((Double(source.height) / divisor).rounded()))

        var compiled: [CompiledPass] = []
        for (effect, base) in zip(effects, effectBases) {
            for pass in effect.passes {
                do {
                    compiled.append(try Self.compile(
                        pass, base: base, device: device,
                        resolver: resolver, includes: includes))
                } catch {
                    // 한 패스가 안 되면 그 이펙트는 반쪽이 된다. 통째로 버린다 —
                    // 절반만 적용한 그림은 원본보다 나쁘다.
                    diagnostics.append("\(effect.name): \(pass.shaderName) 컴파일 실패")
                    compiled.removeAll()
                    break
                }
            }
            if compiled.isEmpty { continue }
        }
        guard !compiled.isEmpty else { return nil }
        self.passes = compiled
        self.isAnimated = compiled.contains { $0.isAnimated }

        guard let output = Self.makeTarget(device: device, width: width, height: height),
              let bufferA = Self.makeTarget(device: device, width: width, height: height),
              let bufferB = Self.makeTarget(device: device, width: width, height: height)
        else { return nil }
        self.output = output
        self.bufferA = bufferA
        self.bufferB = bufferB

        // 입구·출구 파이프라인. 우리가 쓴 셰이더라 실패하면 코드가 틀린 것이다.
        guard let library = try? device.makeLibrary(source: Self.alphaShaders, options: nil),
              let vertexFunction = library.makeFunction(name: "alphaVertex"),
              let cleanFunction = library.makeFunction(name: "cleanFragment"),
              let copyFunction = library.makeFunction(name: "copyFragment")
        else { return nil }
        func makePipeline(_ fragment: MTLFunction) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let clean = makePipeline(cleanFunction),
              let copy = makePipeline(copyFunction) else { return nil }
        self.clean = clean
        self.copy = copy

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        // 이펙트는 원본 밖을 자주 읽는다(흐림의 가장자리, 굴절). 반복하면 반대편
        // 그림이 새어 들어오므로 가장자리 색을 늘린다.
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { return nil }
        self.sampler = sampler
        let pointDescriptor = MTLSamplerDescriptor()
        pointDescriptor.minFilter = .nearest
        pointDescriptor.magFilter = .nearest
        pointDescriptor.sAddressMode = .clampToEdge
        pointDescriptor.tAddressMode = .clampToEdge
        guard let pointSampler = device.makeSamplerState(descriptor: pointDescriptor)
        else { return nil }
        self.pointSampler = pointSampler
        guard let placeholder = Self.makeWhitePixel(device: device) else { return nil }
        self.placeholder = placeholder

        // 씬이 지정한 텍스처와, 주석이 기본으로 지정한 텍스처(`util/noise` 등)를
        // 미리 읽어 둔다. 슬롯마다 무엇이든 묶여 있어야 한다.
        for pass in compiled {
            for path in pass.sceneTextures.compactMap({ $0 }) where defaults[path] == nil {
                for candidate in Self.textureCandidates(path, base: pass.base) {
                    guard let data = resolver.data(for: candidate),
                          let decoded = try? TexDecoder.decode(data),
                          let texture = try? makeTexture(decoded) else { continue }
                    defaults[path] = texture
                    break
                }
                if defaults[path] == nil {
                    // 못 읽으면 그 슬롯에 흰색이 들어가 마스크가 무력해진다.
                    // 조용히 넘어가면 "왜 전체가 흐린가"를 알 수 없다.
                    diagnostics.append("이펙트 텍스처를 찾지 못했다: \(path)")
                }
            }
            for slot in pass.textures {
                guard let path = slot.defaultPath, defaults[path] == nil,
                      !pass.bindings.contains(where: { $0.index == slot.index })
                else { continue }
                // 경로에는 확장자가 없다. 실물이 `.tex`다.
                for candidate in Self.textureCandidates(path, base: pass.base) {
                    guard let data = resolver.data(for: candidate),
                          let decoded = try? TexDecoder.decode(data),
                          let texture = try? makeTexture(decoded) else { continue }
                    defaults[path] = texture
                    break
                }
            }
        }

        // 이름 붙은 렌더 타깃을 미리 잡는다. 패스마다 만들면 매 프레임 할당이 돈다.
        for pass in compiled {
            guard let name = pass.target, targets[name] == nil else { continue }
            let divisor = Self.scale(forTarget: name)
            guard let texture = Self.makeTarget(
                device: device,
                width: Swift.max(1, width / divisor),
                height: Swift.max(1, height / divisor)) else { return nil }
            targets[name] = texture
        }
    }

    /// 1x1 흰색. 안 묶인 슬롯을 메운다.
    private static func makeWhitePixel(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: [UInt8] = [255, 255, 255, 255]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: &pixel, bytesPerRow: 4)
        return texture
    }

    /// 이펙트가 쓰는 텍스처 이름이 실제로 있을 만한 자리들.
    ///
    /// 씬은 `masks/blur_combine_mask_…`처럼 확장자도 접두사도 없이 준다.
    /// 실물 pkg에서는 `materials/masks/blur_combine_mask_….tex`에 있다 —
    /// 이미지 레이어의 텍스처 참조와 같은 규칙이다. assets 쪽 이펙트는
    /// 자기 폴더 아래 `materials/`에 둔다.
    static func textureCandidates(_ path: String, base: String) -> [String] {
        var out = ["materials/\(path).tex", "\(path).tex", path]
        if !base.isEmpty {
            out.insert("\(base)/materials/\(path).tex", at: 0)
        }
        return out
    }

    private static func makeTarget(
        device: MTLDevice, width: Int, height: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// 체인 입구·출구에서 쓰는 작은 셰이더.
    ///
    /// **왜 필요한가.** 창작마당 그림은 완전 투명한 텍셀에 아무 색이나 들어 있다
    /// (자홍색이 흔하다 — "여기는 절대 안 보인다"는 뜻이다). 컴포지터는 그 텍셀을
    /// 1:1로 그려서 알파 0으로 사라지지만, 이펙트는 **선형 필터로 좌표를 옮겨 가며**
    /// 다시 샘플링하므로 그 색이 이웃한 불투명 텍셀에 섞여 든다. 알파는 1로 남고
    /// RGB만 오염되어 자홍 자국이 남는다.
    ///
    /// 입구에서 **투명한 텍셀의 RGB만 0으로 지운다.** 번져도 검정이 섞일 뿐이라
    /// 자홍색보다 훨씬 눈에 안 띈다. 입구 패스는 점 필터로 1:1 복사라 그 자체로는
    /// 번지지 않는다.
    ///
    /// 알파를 미리 곱했다가 출구에서 되돌리는 방법도 해 봤는데 **더 나빴다.**
    /// 이펙트가 알파를 직접 정하는 경우가 많아서(마스크·합성), 그 알파로 나누면
    /// 색이 밝아져 화면이 하얘진다. 알파의 의미를 건드리지 않는 쪽이 안전하다.
    private static let alphaShaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varyings alphaVertex(uint id [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
        };
        const float2 uvs[4] = {
            float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0)
        };
        Varyings out;
        out.position = float4(positions[id], 0, 1);
        out.uv = uvs[id];
        return out;
    }

    fragment float4 cleanFragment(Varyings in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  sampler nearest [[sampler(0)]]) {
        float4 color = source.sample(nearest, in.uv);
        // 완전히 투명한 텍셀의 색은 아무 뜻이 없다. 지워 두면 이후 패스가
        // 선형 필터로 번져도 검정만 섞인다.
        return color.a > 0.004 ? color : float4(0);
    }

    fragment float4 copyFragment(Varyings in [[stage_in]],
                                 texture2d<float> source [[texture(0)]],
                                 sampler nearest [[sampler(0)]]) {
        return source.sample(nearest, in.uv);
    }
    """

    private enum CompileError: Error { case failed(String) }

    private static func compile(
        _ pass: EffectPass, base: String, device: MTLDevice,
        resolver: ReferenceResolver, includes: [String: String]
    ) throws -> CompiledPass {
        let paths = EffectDefinition.shaderPaths(for: pass.shaderName, base: base)
        guard let vertexSource = firstText(of: paths.vertex, resolver: resolver),
              let fragmentSource = firstText(of: paths.fragment, resolver: resolver)
        else { throw CompileError.failed("셰이더 파일을 못 찾음: \(pass.shaderName)") }

        let vertex = try GLSLTranslator.translate(
            vertexSource, stage: .vertex, entryPoint: "vertexMain", includes: includes)
        let fragment = try GLSLTranslator.translate(
            fragmentSource, stage: .fragment, entryPoint: "fragmentMain", includes: includes)

        // 씬이 정한 콤보를 셰이더 앞에 붙인다. 번역기가 넣은 기본값은 `#ifndef`라
        // 여기서 준 값이 이긴다.
        var combos = pass.combos
        // 씬이 슬롯에 텍스처를 줬으면 그 슬롯의 콤보도 켠다. 마스크는 `#if MASK`로
        // 감싸여 있어서, 텍스처만 묶고 콤보를 안 켜면 그림에 아무 영향이 없다.
        for texture in fragment.textures + vertex.textures {
            guard let combo = texture.comboName,
                  texture.index < pass.textures.count,
                  pass.textures[texture.index] != nil else { continue }
            combos[combo] = 1
        }
        let defines = combos
            .sorted { $0.key < $1.key }
            .map { "#define \($0.key) \($0.value)\n" }
            .joined()

        var extra = ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_GREEN"] != nil
            ? "#define WF_FORCE_GREEN 1\n" : ""
        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_FIXEDUV"] != nil {
            extra += "#define WF_FIXED_UV 1\n"
        }
        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_SHOWUV"] != nil {
            extra += "#define WF_SHOW_UV 1\n"
        }
        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_SHOWALPHA"] != nil {
            extra += "#define WF_SHOW_ALPHA 1\n"
        }
        let vertexLibrary = try device.makeLibrary(
            source: extra + defines + vertex.source, options: nil)
        let fragmentLibrary = try device.makeLibrary(
            source: extra + defines + fragment.source, options: nil)
        guard let vertexFunction = vertexLibrary.makeFunction(name: "vertexMain"),
              let fragmentFunction = fragmentLibrary.makeFunction(name: "fragmentMain")
        else { throw CompileError.failed("진입점을 못 찾음") }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        // 전체 화면 사각형을 위치와 uv만으로 그린다. 셰이더가 선언한 attribute
        // 순서는 번역기가 정한 것과 같다(`a_Position`, `a_TexCoord`).
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 1
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 3
        vertexDescriptor.attributes[1].bufferIndex = 1
        vertexDescriptor.layouts[1].stride = MemoryLayout<Float>.size * 5
        descriptor.vertexDescriptor = vertexDescriptor

        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_DEBUG"] != nil {
            // 배열 길이까지 찍는다. 길이를 잃으면 오디오 스펙트럼이 첫 성분만
            // 채워져 막대가 안 뜨는데, 이름만 봐서는 멀쩡해 보인다.
            func describe(_ u: GLSLTranslator.Uniform) -> String {
                u.count.map { "\(u.type) \(u.name)[\($0)]" } ?? "\(u.type) \(u.name)"
            }
            let vs = vertex.uniforms.map(describe).joined(separator: ", ")
            let fs = fragment.uniforms.map(describe).joined(separator: ", ")
            FileHandle.standardError.write(Data("""
            EFFECTDBG \(pass.shaderName)
              vert 유니폼: \(vs)
              frag 유니폼: \(fs)
              frag 텍스처: \(fragment.textures.map { "\($0.index):\($0.name)=\($0.defaultPath ?? "-")" })
              바인딩: \(pass.bindings.map { "\($0.index):\($0.name)" })
              콤보: \(pass.combos)

            """.utf8))
        }

        let vertexLayout = UniformPacker.layout(
            for: vertex.uniforms.map { ($0.name, $0.type, $0.count) })
        let fragmentLayout = UniformPacker.layout(
            for: fragment.uniforms.map { ($0.name, $0.type, $0.count) })

        return CompiledPass(
            pipeline: pipeline,
            target: pass.target,
            bindings: pass.bindings,
            vertexLayout: vertexLayout,
            fragmentLayout: fragmentLayout,
            vertexBytes: values(for: vertex.uniforms, pass: pass, layout: vertexLayout),
            fragmentBytes: values(for: fragment.uniforms, pass: pass, layout: fragmentLayout),
            textures: fragment.textures,
            sceneTextures: pass.textures,
            base: base,
            isAnimated: (vertex.uniforms + fragment.uniforms)
                .contains { $0.name == "g_Time" || $0.name == "g_Frametime" })
    }

    private static func firstText(
        of paths: [String], resolver: ReferenceResolver
    ) -> String? {
        for path in paths {
            if let data = resolver.data(for: path),
               let text = String(data: data, encoding: .utf8) { return text }
        }
        return nil
    }

    /// 씬이 준 값을 유니폼 자리에 채운다.
    ///
    /// 잇는 근거는 셰이더 주석의 `{"material": "키"}`다 — 씬의
    /// `constantshadervalues`가 그 키로 값을 준다. 씬이 값을 안 주면 주석의
    /// `default`를 쓴다. 둘 다 없으면 0인데, 그건 엔진이 채우는 유니폼
    /// (`g_Time` 등)이라 그리기 직전에 덮어쓴다.
    private static func values(
        for uniforms: [GLSLTranslator.Uniform], pass: EffectPass,
        layout: UniformPacker.Layout
    ) -> [UInt8] {
        var packed: [String: [Float]] = [:]
        for uniform in uniforms {
            guard let field = layout.field(named: uniform.name) else { continue }
            let constant = uniform.materialKey.flatMap { pass.constants[$0] }
                ?? uniform.defaultValue.flatMap { EffectConstant.parse($0) }
            guard let constant else { continue }
            packed[uniform.name] = constant.components(field.count)
        }
        return UniformPacker.pack(packed, into: layout)
    }

    // MARK: - 그리기

    /// 한 프레임을 그린다. 마지막 패스의 결과가 `texture`에 남는다.
    ///
    /// - Parameter source: 이펙트를 걸기 전 레이어의 그림. 첫 패스의 `previous`다.
    /// 지금 나고 있는 소리의 대역 크기. 오디오 비주얼라이저가 이걸 읽는다.
    /// 비어 있으면 셰이더의 스펙트럼 유니폼이 0으로 남아 막대가 잠잠하다.
    var audioBands: [Int: (left: [Float], right: [Float])] = [:]

    func render(commandBuffer: MTLCommandBuffer, source: MTLTexture, time: Float) {
        // 두 텍스처를 번갈아 쓴다. 패스가 자기가 읽는 텍스처에 쓰면 결과가 미정이다.
        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_PASSTHROUGH"] != nil {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: source, to: output)
                blit.endEncoding()
            }
            return
        }
        // 체인 입구에서 투명 텍셀의 색을 지운다. 이후 패스가 선형 필터로 번져도
        // 검정만 섞인다. 이 패스는 점 필터로 1:1 복사라 그 자체로는 번지지 않는다.
        blit(source, into: bufferA, with: clean, commandBuffer: commandBuffer)

        // 두 버퍼를 번갈아 쓴다. 패스가 자기가 읽는 텍스처에 쓰면 결과가 미정이다.
        var previous = bufferA
        var back = bufferB
        var front = bufferA
        _ = front

        // 진단용: 앞의 N개 패스만 돌린다. 어느 패스에서 그림이 무너지는지 가른다.
        // 15패스 체인에서 10번째(godrays_combine)가 범인임을 이걸로 찾았다.
        let limit = ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_MAXPASS"]
            .flatMap(Int.init) ?? passes.count
        for pass in passes.prefix(limit) {
            // 이름 붙은 타깃이 있으면 거기 그리고, 없으면 번갈아 쓰는 쪽에 그린다.
            let destination: MTLTexture = pass.target.flatMap { targets[$0] } ?? back

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = destination
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0)
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor) else { continue }

            encoder.setRenderPipelineState(pass.pipeline)
            encoder.setVertexBuffer(Self.quadBuffer(device), offset: 0, index: 1)
            bindUniforms(pass, encoder: encoder, time: time,
                         width: destination.width, height: destination.height)

            // 선언된 **모든** 슬롯을 채운다. 하나라도 비면 그 샘플링이 쓰레기를 준다.
            for slot in pass.textures {
                let bound = pass.bindings.first { $0.index == slot.index }
                let texture: MTLTexture
                if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_WHITE"] != nil {
                    texture = placeholder
                } else if let bound {
                    texture = bound.name == "previous"
                        ? previous : (targets[bound.name] ?? previous)
                } else if slot.index < pass.sceneTextures.count,
                          let path = pass.sceneTextures[slot.index],
                          let loaded = defaults[path] {
                    // 씬이 이 슬롯에 준 텍스처. 마스크가 여기로 온다.
                    texture = loaded
                } else if let path = slot.defaultPath, let loaded = defaults[path] {
                    texture = loaded
                } else {
                    texture = placeholder
                }
                encoder.setFragmentTexture(texture, index: slot.index)
                encoder.setFragmentSamplerState(sampler, index: slot.index)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            // `previous`는 **이름 없는 타깃에 그린 결과**만 이어받는다.
            // `_rt_*`는 곁버퍼라 그리로 그렸다고 "직전 결과"가 바뀌지 않는다.
            //
            // 블러가 이 구분을 요구한다: 축소 → 가로 → 세로까지는 전부 곁버퍼에
            // 그리고, 마지막 합치기 패스가 **흐린 곁버퍼와 원본을 함께** 읽는다.
            // 이걸 무시하면 합치기가 원본 대신 곁버퍼를 두 번 읽어 화면이 하얘진다
            // (실물 Star Wars 씬에서 확인).
            if pass.target == nil {
                previous = destination
                swap(&back, &front)
            }
        }
        // 마지막 결과를 출력으로 옮긴다. 어느 버퍼에 남았든 상관없어진다.
        blit(previous, into: output, with: copy, commandBuffer: commandBuffer)
    }

    /// 전체 화면 사각형 하나로 텍스처를 옮긴다. 입구·출구 패스에만 쓴다.
    private func blit(
        _ source: MTLTexture, into destination: MTLTexture,
        with pipeline: MTLRenderPipelineState, commandBuffer: MTLCommandBuffer
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(pointSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func bindUniforms(
        _ pass: CompiledPass, encoder: MTLRenderCommandEncoder,
        time: Float, width: Int, height: Int
    ) {
        for (layout, bytes, isVertex) in [
            (pass.vertexLayout, pass.vertexBytes, true),
            (pass.fragmentLayout, pass.fragmentBytes, false),
        ] {
            var buffer = bytes
            // 엔진이 채우는 유니폼. 씬은 이 값을 주지 않는다.
            var engineValues: [String: [Float]] = [
                "g_Time": [time],
                "g_Frametime": [1.0 / 60.0],
                "g_Texture0Resolution": [
                    Float(width), Float(height), Float(width), Float(height),
                ],
                "g_ScreenResolution": [Float(width), Float(height)],
                // 전체 화면 사각형은 이미 클립 공간 좌표라 항등 행렬이면 된다.
                "g_ModelViewProjectionMatrix": [
                    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
                ],
            ]
            engineValues["g_Texture1Resolution"] = engineValues["g_Texture0Resolution"]
            engineValues["g_Texture2Resolution"] = engineValues["g_Texture0Resolution"]
            // 오디오 비주얼라이저는 `g_AudioSpectrum32Left[32]` 같은 배열을 읽는다.
            // 소리를 안 듣고 있으면 채우지 않아 0으로 남는다 — 막대가 잠잠할 뿐
            // 그림이 깨지지는 않는다.
            for (resolution, channels) in audioBands {
                engineValues["g_AudioSpectrum\(resolution)Left"] = channels.left
                engineValues["g_AudioSpectrum\(resolution)Right"] = channels.right
            }
            let overlay = UniformPacker.pack(engineValues, into: layout)
            // 엔진 값만 덮어쓴다. 씬이 준 값이 있는 자리는 건드리지 않는다.
            for field in layout.fields where engineValues[field.name] != nil {
                // 필드가 실제로 차지하는 바이트 전부를 덮는다. 타입만 보고 재면
                // 배열의 첫 원소만 바뀐다.
                let end = Swift.min(field.offset + field.byteCount, buffer.count, overlay.count)
                guard field.offset < end else { continue }
                for offset in field.offset..<end { buffer[offset] = overlay[offset] }
            }
            guard !buffer.isEmpty else { continue }
            buffer.withUnsafeBytes { raw in
                if isVertex {
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
                } else {
                    encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                }
            }
        }
    }

    /// 전체 화면 사각형. 위치는 클립 공간, uv는 0~1이다.
    /// Metal의 텍스처 원점은 좌상단이라 v를 뒤집어 둔다 — 안 그러면 이펙트만
    /// 위아래가 뒤집힌 채 합성된다.
    private static var quadCache: [ObjectIdentifier: MTLBuffer] = [:]

    private static func quadBuffer(_ device: MTLDevice) -> MTLBuffer? {
        let key = ObjectIdentifier(device)
        if let cached = quadCache[key] { return cached }
        let vertices: [Float] = [
            -1, -1, 0, 0, 1,
             1, -1, 0, 1, 1,
            -1,  1, 0, 0, 0,
             1,  1, 0, 1, 0,
        ]
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Float>.size * vertices.count,
            options: .storageModeShared) else { return nil }
        quadCache[key] = buffer
        return buffer
    }
}
