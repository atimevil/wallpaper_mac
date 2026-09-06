import Foundation

/// 씬이 레이어에 거는 이펙트 하나.
///
/// 이펙트는 **패스의 나열**이다. 패스마다 재질이 있고, 재질이 셰이더를 가리킨다.
/// 렌더 타깃(`_rt_*`)에 그려서 다음 패스가 그것을 읽는 식으로 이어진다.
///
/// ```json
/// { "passes": [
///     { "material": "materials/effects/blur_downsample4.json",
///       "target": "_rt_QuarterCompoBuffer1",
///       "bind": [ { "name": "previous", "index": 0 } ] } ] }
/// ```
///
/// 값은 두 군데서 온다. **재질**이 셰이더와 혼합 방식을 정하고, **씬**이
/// `combos`(컴파일 시점 스위치)와 `constantshadervalues`(유니폼)를 준다.
/// 씬 값과 유니폼을 잇는 근거는 셰이더 주석의 `{"material": "키"}`다.
public struct EffectDefinition: Equatable, Sendable {
    public let name: String
    public let passes: [EffectPass]

    public init(name: String, passes: [EffectPass]) {
        self.name = name
        self.passes = passes
    }
}

public struct EffectPass: Equatable, Sendable {
    /// `effects/lightshafts` — `.frag`/`.vert`를 붙이면 셰이더 경로다.
    public let shaderName: String
    /// 그려 넣을 렌더 타깃. nil이면 이 패스의 결과가 이펙트의 결과다.
    public let target: String?
    /// 텍스처 슬롯에 무엇을 묶을지. `previous`는 직전 결과다.
    public let bindings: [EffectBinding]
    /// 컴파일 시점 스위치. 셰이더 앞에 `#define`으로 붙는다.
    public let combos: [String: Int]
    /// 씬이 정한 유니폼 값. 키는 셰이더 주석의 `material` 이름이다.
    public let constants: [String: EffectConstant]
    /// 씬이 슬롯마다 지정한 텍스처 경로. `null`인 자리는 지정하지 않은 것이다.
    ///
    /// 실물 블러가 슬롯 1에 마스크를 준다 — 이걸 무시하면 흐림이 마스크 없이
    /// **화면 전체**에 걸린다.
    public let textures: [String?]
    public let blending: String

    public init(shaderName: String, target: String?, bindings: [EffectBinding],
                combos: [String: Int], constants: [String: EffectConstant],
                textures: [String?] = [], blending: String) {
        self.shaderName = shaderName
        self.target = target
        self.bindings = bindings
        self.combos = combos
        self.constants = constants
        self.textures = textures
        self.blending = blending
    }
}

public struct EffectBinding: Equatable, Sendable {
    public let name: String
    public let index: Int

    public init(name: String, index: Int) {
        self.name = name
        self.index = index
    }
}

/// 유니폼 값 하나. 씬은 수 하나이거나 `"1 1 1"` 같은 벡터 문자열을 준다.
public enum EffectConstant: Equatable, Sendable {
    case scalar(Double)
    case vector([Double])

    /// 셰이더가 기대하는 성분 수에 맞춘다. 모자라면 0으로 채우고 남으면 자른다.
    ///
    /// 스칼라를 벡터 자리에 주는 씬이 있어서, 그 경우에는 **모든 성분에 같은 값**을
    /// 넣는다 — GLSL의 `vec3(x)`와 같은 뜻이고, 0으로 채우면 색이 검게 죽는다.
    public func components(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        switch self {
        case .scalar(let value):
            return Array(repeating: Float(value), count: count)
        case .vector(let values):
            var out = values.prefix(count).map(Float.init)
            while out.count < count { out.append(0) }
            return out
        }
    }

    /// 씬 JSON의 값 하나를 읽는다. 비유한값은 없는 것으로 본다 —
    /// NaN이 셰이더까지 흘러가면 그 픽셀이 통째로 사라진다.
    public static func parse(_ raw: Any) -> EffectConstant? {
        if let number = raw as? NSNumber, !(raw is String) {
            let value = number.doubleValue
            return value.isFinite ? .scalar(value) : nil
        }
        if let text = raw as? String {
            // 값은 `"1 1 1"`처럼 공백으로 나뉘기도 하고 `"0.02, 0.02"`처럼
            // 쉼표로 나뉘기도 한다. 공백만 보면 `"0.0, 1.0"`이 성분 하나로 읽혀
            // 벡터가 스칼라가 된다 — 실물 주석 기본값이 이 꼴이다.
            let parts = text
                .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .compactMap(Double.init)
            guard !parts.isEmpty, parts.allSatisfy(\.isFinite) else { return nil }
            return parts.count == 1 ? .scalar(parts[0]) : .vector(parts)
        }
        return nil
    }
}

extension EffectDefinition {
    /// 이펙트 하나를 읽어 패스로 편다.
    ///
    /// - Parameters:
    ///   - path: 씬이 가리키는 `effect.json` 경로.
    ///   - sceneePasses: 씬의 `effects[].passes` — 패스 **순서대로** 짝지어진다.
    ///     씬이 준 것이 더 적으면 나머지는 재질의 기본값으로 간다.
    ///   - resolver: pkg와 assets를 함께 보는 참조 해석기.
    public static func load(
        path: String, scenePasses: [[String: Any]], resolver: ReferenceResolver
    ) -> EffectDefinition? {
        guard let root = resolver.json(for: path),
              let rawPasses = root["passes"] as? [Any] else { return nil }
        // `effects/blur/effect.json` → `effects/blur`. 재질 경로가 여기 기준이다.
        let base = (path as NSString).deletingLastPathComponent

        var passes: [EffectPass] = []
        for (index, rawPass) in rawPasses.enumerated() {
            guard let pass = rawPass as? [String: Any],
                  let materialPath = pass["material"] as? String,
                  let material = resolveJSON(materialPath, base: base, resolver: resolver),
                  let materialPasses = material["passes"] as? [Any],
                  let firstPass = materialPasses.first as? [String: Any],
                  let shader = firstPass["shader"] as? String
            else { continue }

            var bindings: [EffectBinding] = []
            for rawBinding in (pass["bind"] as? [Any] ?? []) {
                guard let binding = rawBinding as? [String: Any],
                      let name = binding["name"] as? String,
                      let slot = (binding["index"] as? NSNumber)?.intValue, slot >= 0
                else { continue }
                bindings.append(EffectBinding(name: name, index: slot))
            }
            // 바인딩을 안 적은 패스가 많다. 그때는 직전 결과를 0번에 묶는 것이 기본이다 —
            // 안 그러면 첫 패스가 아무것도 못 읽어 화면이 검게 나온다.
            if bindings.isEmpty { bindings = [EffectBinding(name: "previous", index: 0)] }

            let scenePass = index < scenePasses.count ? scenePasses[index] : [:]
            var combos: [String: Int] = [:]
            for (key, value) in (scenePass["combos"] as? [String: Any] ?? [:]) {
                guard let number = (value as? NSNumber)?.intValue else { continue }
                combos[key] = number
            }
            var constants: [String: EffectConstant] = [:]
            for (key, value) in (scenePass["constantshadervalues"] as? [String: Any] ?? [:]) {
                // 스크립트에 묶인 값은 `{"value": …}` 객체로 온다.
                let unwrapped = (value as? [String: Any])?["value"] ?? value
                guard let constant = EffectConstant.parse(unwrapped) else { continue }
                constants[key] = constant
            }

            // 씬이 슬롯마다 텍스처를 지정할 수 있다. `null`은 지정 안 한 자리다.
            let sceneTextures = (scenePass["textures"] as? [Any] ?? []).map { $0 as? String }

            passes.append(EffectPass(
                shaderName: shader,
                target: pass["target"] as? String,
                bindings: bindings,
                combos: combos,
                constants: constants,
                textures: sceneTextures,
                blending: firstPass["blending"] as? String ?? "normal"))
        }
        guard !passes.isEmpty else { return nil }
        return EffectDefinition(
            name: root["name"] as? String ?? (base as NSString).lastPathComponent,
            passes: passes)
    }

    /// 재질 경로는 이펙트 폴더 기준일 수도, 루트 기준일 수도 있다.
    /// 실물이 둘 다 쓴다 — 한쪽만 보면 절반이 안 풀린다.
    static func resolveJSON(
        _ path: String, base: String, resolver: ReferenceResolver
    ) -> [String: Any]? {
        if !base.isEmpty, let json = resolver.json(for: base + "/" + path) { return json }
        return resolver.json(for: path)
    }

    /// 셰이더 짝의 경로. 재질은 확장자 없는 이름을 준다.
    public static func shaderPaths(
        for name: String, base: String
    ) -> (vertex: [String], fragment: [String]) {
        let candidates = base.isEmpty
            ? ["shaders/\(name)"] : ["\(base)/shaders/\(name)", "shaders/\(name)"]
        return (candidates.map { $0 + ".vert" }, candidates.map { $0 + ".frag" })
    }
}
