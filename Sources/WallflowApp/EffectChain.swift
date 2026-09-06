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

    private let device: MTLDevice
    private let passes: [CompiledPass]
    private var targets: [String: MTLTexture] = [:]
    private let output: MTLTexture
    private let scratch: MTLTexture
    private let sampler: MTLSamplerState
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

    // MARK: - 만들기

    /// - Returns: 하나도 컴파일되지 않으면 nil. 호출자가 원본 텍스처를 그대로 쓴다.
    init?(device: MTLDevice, effects: [EffectDefinition], effectBases: [String],
          source: MTLTexture, resolver: ReferenceResolver, includes: [String: String],
          makeTexture: (TextureData) throws -> MTLTexture,
          diagnostics: inout [String]) {
        self.device = device
        self.width = source.width
        self.height = source.height
        guard width > 0, height > 0 else { return nil }

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
              let scratch = Self.makeTarget(device: device, width: width, height: height)
        else { return nil }
        self.output = output
        self.scratch = scratch

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        // 이펙트는 원본 밖을 자주 읽는다(흐림의 가장자리, 굴절). 반복하면 반대편
        // 그림이 새어 들어오므로 가장자리 색을 늘린다.
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { return nil }
        self.sampler = sampler
        guard let placeholder = Self.makeWhitePixel(device: device) else { return nil }
        self.placeholder = placeholder

        // 주석이 기본 텍스처를 지정한 슬롯(`util/noise` 등)을 미리 읽어 둔다.
        for pass in compiled {
            for slot in pass.textures {
                guard let path = slot.defaultPath, defaults[path] == nil,
                      !pass.bindings.contains(where: { $0.index == slot.index })
                else { continue }
                // 경로에는 확장자가 없다. 실물이 `.tex`다.
                for candidate in ["\(path).tex", path] {
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

    private static func makeTarget(
        device: MTLDevice, width: Int, height: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

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
        let defines = pass.combos
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
            let vs = vertex.uniforms.map { "\($0.type) \($0.name)" }.joined(separator: ", ")
            let fs = fragment.uniforms.map { "\($0.type) \($0.name)" }.joined(separator: ", ")
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
            for: vertex.uniforms.map { ($0.name, $0.type) })
        let fragmentLayout = UniformPacker.layout(
            for: fragment.uniforms.map { ($0.name, $0.type) })

        return CompiledPass(
            pipeline: pipeline,
            target: pass.target,
            bindings: pass.bindings,
            vertexLayout: vertexLayout,
            fragmentLayout: fragmentLayout,
            vertexBytes: values(for: vertex.uniforms, pass: pass, layout: vertexLayout),
            fragmentBytes: values(for: fragment.uniforms, pass: pass, layout: fragmentLayout),
            textures: fragment.textures,
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
    func render(commandBuffer: MTLCommandBuffer, source: MTLTexture, time: Float) {
        // 두 텍스처를 번갈아 쓴다. 패스가 자기가 읽는 텍스처에 쓰면 결과가 미정이다.
        if ProcessInfo.processInfo.environment["WALLFLOW_EFFECT_PASSTHROUGH"] != nil {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: source, to: output)
                blit.endEncoding()
            }
            return
        }
        var previous = source
        var back = scratch
        var front = output

        for (index, pass) in passes.enumerated() {
            let isLast = index == passes.count - 1
            // 이름 붙은 타깃이 있으면 거기 그리고, 없으면 번갈아 쓰는 쪽에 그린다.
            // 마지막 패스는 반드시 `output`에 남아야 레이어가 그것을 본다.
            let destination: MTLTexture = isLast
                ? front : (pass.target.flatMap { targets[$0] } ?? back)

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

            previous = destination
            // 이름 붙은 타깃에 그렸으면 번갈아 쓰는 짝은 그대로 둔다.
            if pass.target == nil, !isLast { swap(&back, &front) }
        }
        // 마지막 결과가 `output`이 아니면(이름 붙은 타깃으로 끝난 경우) 복사한다.
        if previous !== output {
            if let blit = commandBuffer.makeBlitCommandEncoder(),
               previous.width == output.width, previous.height == output.height {
                blit.copy(from: previous, to: output)
                blit.endEncoding()
            }
        }
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
            let overlay = UniformPacker.pack(engineValues, into: layout)
            // 엔진 값만 덮어쓴다. 씬이 준 값이 있는 자리는 건드리지 않는다.
            for field in layout.fields where engineValues[field.name] != nil {
                let size = UniformPacker.layout(of: field.type)?.size ?? 0
                for offset in field.offset..<Swift.min(field.offset + size, buffer.count) {
                    buffer[offset] = overlay[offset]
                }
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
