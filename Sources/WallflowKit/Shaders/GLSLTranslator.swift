import Foundation

/// Wallpaper Engine의 GLSL 셰이더를 Metal 셰이딩 언어로 옮긴다.
///
/// **왜 직접 만드는가.** SPIRV-Cross나 MoltenVK를 쓰면 되지만, 이 저장소의 전제가
/// 외부 의존성 0개다. 대신 범위가 좁다 — assets 셰이더 466개를 전수 집계해 보면
/// 쓰이는 구문이 유한하고, 이펙트가 실제로 쓰는 것은 22개·1,244줄이다.
///
/// **본문은 건드리지 않는다.** `v_TexCoord`나 `g_EyeColor` 같은 이름을 찾아
/// 바꾸는 대신 `#define v_TexCoord in.v_TexCoord`를 앞에 붙인다. 문자열 치환은
/// 주석·문자열·부분 일치에서 조용히 틀리는데, 매크로는 컴파일러가 판단한다.
///
/// **`#if`/`#define`/`#ifdef`도 건드리지 않는다.** Metal의 전처리기가 GLSL의 것과
/// 같은 일을 한다. 우리가 할 일은 `#include` 해석과 WE 전용 `#require` 제거뿐이다.
public enum GLSLTranslator {
    public enum Stage: Equatable, Sendable {
        case vertex
        case fragment
    }

    public enum Failure: Error, Equatable {
        case tooLarge(Int)
        case includeTooDeep(String)
        case missingMain
        case unbalancedBraces
    }

    /// 셰이더 텍스트는 창작마당에서 온다. 상한이 없으면 이상한 파일 하나가
    /// 배경화면을 멈춘다.
    public static let maxSourceBytes = 2_000_000
    public static let maxIncludeDepth = 8

    /// 프리앰블이 이미 담고 있는 헤더들. 다시 펼치면 중복 정의가 된다.
    static let preludeHeaders: Set<String> = ["common.h"]

    /// `#require LightingV1`이 실제로 필요로 하는 것. 실물 7개(`generic4`·
    /// `chroma4`·`fur4`·`foliage4`·`genericparticle`·`genericimage4`·
    /// `genericropeparticle`)가 `PerformLighting_V1`을 부르는데 정의가 셰이더
    /// 파일 어디에도 없다 — WE 엔진이 씬의 빛 개수에 맞춰 이 함수와 빛 유니폼을
    /// 링크 시점에 만들어 붙이는 자리다. 우리는 그 자리를 직접 만든다.
    ///
    /// **근거.** `generic3.frag`가 자기 안에 `PerformLighting_Deprecated`라는
    /// 같은 일을 하는 함수를 두고 있고, 그 몸통이 정확히 이 꼴이다(빛 종류별
    /// `#if LIGHTS_*` 루프 + `ComputePBRLight`). `ComputePBRLight` 자체는
    /// `common_pbr.h`에 있는데, `PerformLighting_V1`을 부르는 7개는 전부 그 대신
    /// `common_pbr_2.h`를 include한다 — 그 헤더엔 `FresnelSchlick`·
    /// `Distribution_GGX`·`Schlick_GGX`·`GeoSmith`·`PointSegmentDelta`까지 같은
    /// 이름으로 다 있지만 `ComputePBRLight`로 감싼 것만 없다. 그래서 그 함수의
    /// 몸통(쿡-토런스 BRDF, 역제곱 감쇠)을 `common_pbr.h`에서 그대로 옮기고
    /// 이름만 바꿔(`wfComputePBRLight`, `ComputePBRLight`와의 재정의 충돌을
    /// 피하려고) 썼다. 빛 유니폼 선언도 `generic3.frag`가 쓰는 것과 글자
    /// 그대로다 — 재질의 `combos`가 실제 빛 개수를 `LIGHTS_POINT` 등으로 주면
    /// `#if`가 그 갯수만큼 켜진다. **가정한 것:** `GRADIENT_SAMPLER`·
    /// `RIMLIGHTING`·그림자(`ComputePBRLightShadow`)는 뺐다 — 이 7개 파일의
    /// 실제 재질에서 그 콤보가 켜진 예가 없었고, 그림자 맵 파이프라인 자체가
    /// 아직 없다.
    static let syntheticLightingV1 = """
    #if LIGHTS_POINT
    uniform vec4 g_LPoint_Color[LIGHTS_POINT];
    uniform vec4 g_LPoint_Origin[LIGHTS_POINT];
    #endif
    #if LIGHTS_SPOT
    uniform vec4 g_LSpot_Color[LIGHTS_SPOT];
    uniform vec4 g_LSpot_Origin[LIGHTS_SPOT];
    uniform vec4 g_LSpot_Direction[LIGHTS_SPOT];
    #endif
    #if LIGHTS_TUBE
    uniform vec4 g_LTube_Color[LIGHTS_TUBE];
    uniform vec4 g_LTube_OriginA[LIGHTS_TUBE];
    uniform vec4 g_LTube_OriginB[LIGHTS_TUBE];
    #endif
    #if LIGHTS_DIRECTIONAL
    uniform vec4 g_LDirectional_Color[LIGHTS_DIRECTIONAL];
    uniform vec4 g_LDirectional_Direction[LIGHTS_DIRECTIONAL];
    #endif

    vec3 wfComputePBRLight(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor,
        vec3 baseReflectance, float roughness, float metallic)
    {
        float wfLightDist = length(L);
        L = L / wfLightDist;
        vec3 H = normalize(V + L);
        float NDF = Distribution_GGX(N, H, roughness);
        float G = GeoSmith(N, V, L, roughness);
        vec3 F = FresnelSchlick(max(dot(H, V), 0.0), baseReflectance);
        vec3 numerator = NDF * G * F;
        float NL = max(dot(N, L), 0.0);
        float denominator = 4.0 * max(dot(N, V), 0.0) * NL;
        vec3 specular = numerator / max(denominator, 0.001);
        vec3 diffuse = (1.0 - metallic) * (CAST3(1.0) - F);
        vec3 radiance = lightColor.xyz / (wfLightDist * wfLightDist);
        return (diffuse * albedo / M_PI + specular) * radiance * NL;
    }

    vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewVector,
        vec3 specularTint, vec3 f0, float roughness, float metallic)
    {
        vec3 light = CAST3(0.0);
    #if LIGHTS_POINT
        for (uint l = 0u; l < CASTU(LIGHTS_POINT); ++l)
        {
            vec3 lightDelta = g_LPoint_Origin[l].xyz - worldPos;
            light += wfComputePBRLight(normal, lightDelta, viewVector, albedo,
                g_LPoint_Color[l].rgb, f0, roughness, metallic);
        }
    #endif
    #if LIGHTS_SPOT
        for (uint l = 0u; l < CASTU(LIGHTS_SPOT); ++l)
        {
            vec3 lightDelta = g_LSpot_Origin[l].xyz - worldPos;
            float spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[l].xyz);
            spotCookie = smoothstep(g_LSpot_Direction[l].w, g_LSpot_Origin[l].w, spotCookie);
            light += wfComputePBRLight(normal, lightDelta, viewVector, albedo,
                g_LSpot_Color[l].rgb * spotCookie, f0, roughness, metallic);
        }
    #endif
    #if LIGHTS_TUBE
        for (uint l = 0u; l < CASTU(LIGHTS_TUBE); ++l)
        {
            vec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[l].xyz, g_LTube_OriginB[l].xyz);
            light += wfComputePBRLight(normal, lightDelta, viewVector, albedo,
                g_LTube_Color[l].rgb, f0, roughness, metallic);
        }
    #endif
    #if LIGHTS_DIRECTIONAL
        for (uint l = 0u; l < CASTU(LIGHTS_DIRECTIONAL); ++l)
        {
            light += wfComputePBRLight(normal, g_LDirectional_Direction[l].xyz, viewVector, albedo,
                g_LDirectional_Color[l].rgb, f0, roughness, metallic);
        }
    #endif
        return light;
    }
    """

    /// 유니폼 하나. 씬이 주는 값과 이어 붙일 근거가 여기 다 있다.
    public struct Uniform: Equatable, Sendable {
        public let name: String
        public let type: String
        /// 셰이더 주석의 `{"material": "..."}`. 씬의 `constantshadervalues` 키다.
        /// 없으면 씬이 값을 줄 수 없는 유니폼이다(엔진이 채우는 것들).
        public let materialKey: String?
        /// 주석의 `default`. 씬이 값을 안 주면 이걸 쓴다.
        public let defaultValue: String?
        /// 배열이면 그 길이. `uniform float g_AudioSpectrum32Left[32]`가 이 꼴이다.
        public let count: Int?
        /// 배열 크기가 숫자가 아니라 매크로일 때(`uniform mat4x3 g_Bones[BONECOUNT]`).
        /// 재질의 `combos`가 이 이름에 값을 준다 — `count`와 동시에 차지 않는다.
        public let sizeMacro: String?

        public init(
            name: String, type: String, materialKey: String? = nil, defaultValue: String? = nil,
            count: Int? = nil, sizeMacro: String? = nil
        ) {
            self.name = name
            self.type = type
            self.materialKey = materialKey
            self.defaultValue = defaultValue
            self.count = count
            self.sizeMacro = sizeMacro
        }
    }

    public struct Texture: Equatable, Sendable {
        public let name: String
        /// `g_Texture0` → 0. 재질의 `textures` 배열 순서와 맞물린다.
        public let index: Int
        /// 주석의 `combo`. 씬이 이 슬롯에 텍스처를 주면 그 콤보를 켜야 한다 —
        /// 마스크는 `#if MASK`로 감싸여 있어서, 텍스처만 묶고 콤보를 안 켜면
        /// 그림에 아무 영향이 없다.
        public let comboName: String?
        /// 주석의 `default`. `util/noise` 같은 기본 텍스처 경로다.
        ///
        /// **모든 슬롯에 무엇이든 묶어야 한다.** Metal에서 안 묶인 텍스처를
        /// 샘플링하면 쓰레기가 나온다 — 화면에 자홍색 블록으로 보인다.
        public let defaultPath: String?
    }

    /// 정점 셰이더가 선언한 `attribute`. `VertexIn`의 `[[attribute(n)]]` 번호가
    /// 선언 순서 그대로라, 정점 버퍼를 묶는 쪽이 이 순서로 자리를 잡아야 한다.
    /// 이걸 안 내주면 그리는 쪽이 `a_Position`·`a_TexCoord`만 있다고 가정하게
    /// 되고, 법선과 접선을 쓰는 3D 모델 셰이더가 엉뚱한 바이트를 읽는다.
    public struct Attribute: Equatable, Sendable {
        public let name: String
        public let type: String
        public let slot: Int
    }

    public struct Result: Equatable, Sendable {
        public let source: String
        public let uniforms: [Uniform]
        public let textures: [Texture]
        public let attributes: [Attribute]

        public init(source: String, uniforms: [Uniform], textures: [Texture],
                    attributes: [Attribute] = []) {
            self.source = source
            self.uniforms = uniforms
            self.textures = textures
            self.attributes = attributes
        }
    }

    // MARK: - 진입점

    /// - Parameters:
    ///   - source: `#include`가 아직 안 풀린 원본.
    ///   - includes: 헤더 이름 → 본문. `shaders/common.h`가 대표적이다.
    public static func translate(
        _ source: String, stage: Stage, entryPoint: String,
        includes: [String: String] = [:]
    ) throws -> Result {
        guard source.utf8.count <= maxSourceBytes else {
            throw Failure.tooLarge(source.utf8.count)
        }
        let expanded = try expandIncludes(source, includes: includes, depth: 0)
        let combos = comboDefaults(in: expanded)
        let annotations = uniformAnnotations(in: expanded)
        let stripped = strippingComments(expanded)
        let precisionStripped = strippingPrecisionQualifiers(stripped)
        let definesFixed = strippingStrayDefineSemicolons(precisionStripped)
        let inoutFixed = rewritingInoutSwizzleCalls(definesFixed)
        let modulo = rewritingModulo(inoutFixed)
        let renamed = rewritingReservedIdentifiers(modulo)
        let arrays = rewritingArrayConstructors(renamed)
        let aliased = rewritingInferredSizeArrayAliases(arrays)
        let subscripted = rewritingFloatArraySubscripts(aliased)
        let truncated = rewritingTruncation(subscripted)
        let qualified = rewritingParameterQualifiers(truncated)
        let parsed = parseDeclarations(qualified, annotations: annotations)
        return try assemble(parsed, stage: stage, entryPoint: entryPoint, combos: combos)
    }

    // MARK: - 전처리

    /// `#include "x.h"`를 펼친다. 없는 헤더는 그냥 지운다 — 우리가 못 찾는 헤더
    /// 하나 때문에 셰이더 전체를 버리는 것보다, 컴파일러가 "그 이름이 없다"고
    /// 정확히 말하게 두는 편이 낫다.
    static func expandIncludes(
        _ source: String, includes: [String: String], depth: Int,
        seen: Set<String> = []
    ) throws -> String {
        var expanded = seen
        return try expandIncludes(source, includes: includes, depth: depth, seen: &expanded)
    }

    /// `seen`은 **한 번이라도 펼친 헤더 전부**다. 지금 사슬만 기억하면
    /// `#include "a.h"`가 형제로 두 번 나올 때 함수가 중복 정의된다 —
    /// 순환은 막히지만 중복은 안 막힌다. WE 헤더에는 include 가드가 없다.
    private static func expandIncludes(
        _ source: String, includes: [String: String], depth: Int, seen: inout Set<String>
    ) throws -> String {
        guard depth <= maxIncludeDepth else { throw Failure.includeTooDeep("깊이 \(depth)") }
        var out: [String] = []
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `#require`는 WE가 편집기에서 쓰는 지시자다. Metal은 모른다.
            // `LightingV1`만 예외다 — 엔진이 씬의 빛 개수에 맞춰 링크 시점에
            // `PerformLighting_V1`을 만들어 붙이는 자리인데, 그 몸통이 셰이더
            // 파일 어디에도 없다(`syntheticLightingV1` 참고). `#include`처럼
            // 한 번만 펼친다.
            if trimmed.hasPrefix("#require") {
                if trimmed.contains("LightingV1"), !seen.contains("LightingV1") {
                    seen.insert("LightingV1")
                    out.append(syntheticLightingV1)
                } else {
                    out.append("")
                }
                continue
            }
            guard trimmed.hasPrefix("#include") else { out.append(String(line)); continue }
            guard let name = quotedName(in: trimmed) else { out.append(""); continue }
            // 같은 헤더를 두 번 펼치면 함수가 중복 정의된다. 순환도 여기서 끊긴다.
            // 프리앰블이 이미 담고 있는 헤더는 펼치지 않는다. 둘 다 펼치면
            // `hsv2rgb`가 재정의되어 그 셰이더가 통째로 떨어진다.
            guard !preludeHeaders.contains((name as NSString).lastPathComponent) else {
                out.append(""); continue
            }
            guard !seen.contains(name), let body = includes[name] else { out.append(""); continue }
            seen.insert(name)
            out.append(try expandIncludes(
                body, includes: includes, depth: depth + 1, seen: &seen))
        }
        return out.joined(separator: "\n")
    }

    private static func quotedName(in line: String) -> String? {
        for quote in ["\"", "<"] {
            guard let start = line.range(of: quote) else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.rangeOfCharacter(from: CharacterSet(charactersIn: "\">"))
            else { continue }
            let name = String(rest[..<end.lowerBound])
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// 유니폼 주석의 JSON을 읽는다. 주석을 지우기 **전에** 해야 한다 —
    /// 이 주석이 씬 값과 이어 붙일 유일한 근거다.
    static func uniformAnnotations(in source: String) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("uniform "), let commentStart = trimmed.range(of: "//")
            else { continue }
            let declaration = String(trimmed[..<commentStart.lowerBound])
            guard let name = declaredName(in: declaration) else { continue }
            let comment = trimmed[commentStart.upperBound...]
            guard let braceStart = comment.firstIndex(of: "{"),
                  let braceEnd = comment.lastIndex(of: "}"), braceStart < braceEnd
            else { continue }
            let json = String(comment[braceStart...braceEnd])
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            out[name] = object
        }
        return out
    }

    /// `// [COMBO] {"combo":"BLENDMODE","default":0}` 주석에서 콤보 기본값을 읽는다.
    ///
    /// 콤보는 재질이 `#define`으로 넘기는 컴파일 시점 스위치다. 씬이 값을 안 주면
    /// 이 기본값이 쓰인다. `#if`에만 나오면 정의가 없어도 0으로 읽히지만,
    /// `ApplyBlending(BLENDMODE, ...)`처럼 값으로도 쓰여서 정의가 반드시 필요하다.
    static func comboDefaults(in source: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        var seen: Set<String> = []
        // 배열 크기 자리에 쓰이는 매크로 전부(주석이 있든 없든). C++은 배열 크기
        // 0을 안 받는다("zero-length arrays are not permitted") — `[COMBO]`
        // 주석은 있는데 `"default"`가 없어 0으로 떨어지는 것도 있다(실물
        // `shadowcaster.vert`의 `BONECOUNT`). 이 이름들은 끝에서 최소 1로 올린다.
        var arraySizeMacros: Set<String> = []
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("uniform"), trimmed.hasSuffix(";"),
                  let (_, count, macro) = declared(in: trimmed), count == nil, let macro
            else { continue }
            arraySizeMacros.insert(macro)
        }
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//"), trimmed.contains("[COMBO]"),
               let braceStart = trimmed.firstIndex(of: "{"),
               let braceEnd = trimmed.lastIndex(of: "}"), braceStart < braceEnd,
               let data = String(trimmed[braceStart...braceEnd]).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = object["combo"] as? String, !name.isEmpty, !seen.contains(name) {
                seen.insert(name)
                out.append((name, (object["default"] as? NSNumber)?.intValue ?? 0))
                continue
            }
            // `uniform sampler2D g_Texture8; // {"formatcombo":true, ...}`처럼
            // 이름이 아니라 텍스처 슬롯에 붙는 콤보도 있다 — 이름은 늘
            // `TEX<슬롯>FORMAT`이다(실물 `fur4.frag`의 `TEX8FORMAT`). 실제로
            // 묶이는 텍스처의 진짜 포맷은 로드 시점에만 아는데, 지금 디코더는
            // 그걸 셰이더에 넘기지 않는다 — 0(그대로 통과, `ConvertTextureFormat`이
            // 변환 없이 원본을 돌려주는 값)을 기본값으로 둔다.
            if trimmed.hasPrefix("uniform"), trimmed.contains("sampler2D"),
               trimmed.contains("\"formatcombo\":true"), let commentStart = trimmed.range(of: "//"),
               let name = declaredName(in: String(trimmed[..<commentStart.lowerBound])),
               let slot = textureSlot(for: name) {
                let comboName = "TEX\(slot)FORMAT"
                if !seen.contains(comboName) {
                    seen.insert(comboName)
                    out.append((comboName, 0))
                }
                continue
            }
            // `uniform vec4 g_LPoint_Color[LIGHTS_POINT];`처럼 배열 크기 자리에
            // 매크로 이름을 쓰는데 `[COMBO]` 주석이 아예 없는 경우도 있다(실물
            // `generic3.frag`의 `LIGHTS_POINT`·`LIGHTS_SPOT`·`LIGHTS_TUBE`·
            // `LIGHTS_DIRECTIONAL`). 기본값을 안 주면 선언 자체가 "정의 안 된
            // 식별자"로 떨어진다 — 우선 0으로 등록해 두고, 끝에서 배열 크기
            // 매크로는 전부 최소 1로 올린다. 씬이 그 유니폼에 값을 준 적이 없어
            // 항상 0으로 비어 있으므로(`UniformPacker`의 기본값), 빛 개수가 1이
            // 되어도 보태는 빛은 색이 0인 빛 하나뿐이라 그림은 그대로다.
            if trimmed.hasPrefix("uniform"), trimmed.hasSuffix(";"),
               let (_, count, macro) = declared(in: trimmed), count == nil, let macro,
               !seen.contains(macro) {
                seen.insert(macro)
                out.append((macro, 0))
            }
        }
        // `[COMBO]` 주석은 있지만 `"default"`가 없어 0으로 떨어진 것까지 포함해,
        // 배열 크기로 쓰이는 매크로는 전부 여기서 최소 1로 올린다.
        return out.map { name, value in
            arraySizeMacros.contains(name) ? (name, max(value, 1)) : (name, value)
        }
    }

    /// `uniform vec3 g_EyeColor;`에서 `g_EyeColor`.
    static func declaredName(in declaration: String) -> String? {
        declared(in: declaration)?.name
    }

    /// 이름과 배열 크기. `varying vec2 v_TexCoord[13];`는 이름 `v_TexCoord`,
    /// 크기 13이다. 크기를 버리면 구조체 멤버가 `float2` 하나가 되어
    /// `v_TexCoord[0] = vec2(...)`가 벡터 성분에 벡터를 넣는 꼴이 된다 —
    /// 실물 블러 계열 18개가 이 때문에 떨어졌다.
    ///
    /// 크기가 숫자가 아니라 매크로 이름(`uniform mat4x3 g_Bones[BONECOUNT]`,
    /// `uniform vec4 g_BlendMap[BLENDROWCOUNT]`)일 수도 있다 — 재질의 `combos`가
    /// 그 매크로를 값으로 준다(`#define BONECOUNT 64` 식으로 미리 붙는다).
    /// `count`는 숫자일 때만 채우고, 매크로 이름은 `sizeMacro`에 그대로 담는다.
    static func declared(
        in declaration: String
    ) -> (name: String, count: Int?, sizeMacro: String?)? {
        let cleaned = declaration.replacingOccurrences(of: ";", with: " ")
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        // `uniform` `타입` `이름` 순서다.
        guard words.count >= 3 else { return nil }
        let third = String(words[2])
        guard let bracket = third.firstIndex(of: "[") else {
            return third.isEmpty ? nil : (third, nil, nil)
        }
        let name = String(third[..<bracket])
        guard let closeBracket = third[bracket...].firstIndex(of: "]") else { return nil }
        let inside = third[third.index(after: bracket)..<closeBracket]
        guard !name.isEmpty, !inside.isEmpty else { return nil }
        if let count = Int(inside) { return (name, count, nil) }
        // 매크로 이름다운지만 본다 — 식별자 글자만 있어야 한다.
        guard inside.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              inside.first?.isNumber == false else { return nil }
        return (name, nil, String(inside))
    }

    /// 줄 주석과 블록 주석을 지운다. 문자열 리터럴은 셰이더에 없다.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var index = source.startIndex
        var inLine = false
        var inBlock = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let following = next < source.endIndex ? source[next] : nil
            if inLine {
                if character.isNewline { inLine = false; out.append(character) }
            } else if inBlock {
                if character == "*", following == "/" {
                    inBlock = false
                    index = next
                }
            } else if character == "/", following == "/" {
                inLine = true
                index = next
            } else if character == "/", following == "*" {
                inBlock = true
                index = next
            } else {
                out.append(character)
            }
            index = source.index(after: index)
        }
        return out
    }

    /// GLSL ES의 정밀도 한정자(`lowp`/`mediump`/`highp`)를 지운다. MSL엔 없는
    /// 낱말이라 `unknown type name`으로 떨어질 뿐 아니라, `attribute mediump vec2
    /// a_TexCoord`처럼 타입 앞에 끼면 `declared(in:)`가 `mediump`를 타입으로,
    /// `vec2`를 이름으로 잘못 읽는다(실물 `fade.vert` 등 7개). 값은 안 바뀐다 —
    /// Metal 셰이더는 정밀도를 따로 안 가른다.
    static func strippingPrecisionQualifiers(_ source: String) -> String {
        let qualifiers: Set<String> = ["lowp", "mediump", "highp"]
        var out = ""
        out.reserveCapacity(source.count)
        var word = ""
        func flush() {
            if !qualifiers.contains(word) { out += word }
            word = ""
        }
        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return out
    }

    /// `#define mask 1.0;`처럼 몸통에 군더더기 `;`가 붙은 한 줄짜리 매크로가
    /// 실물에 있다(crt_screen). `float opacity = wfTo1(u_alpha * mask);`로
    /// 감싸고 나면 그 `;`가 펼쳐지면서 감싼 괄호 **안에서** 문장이 끝나 버려
    /// 통째로 떨어진다. 함수형 매크로(`#define F(x) ...`)는 건드리지 않는다 —
    /// 괄호 안의 `;`는 do/while 관용구처럼 의도한 것일 수 있다.
    static func strippingStrayDefineSemicolons(_ source: String) -> String {
        var out: [String] = []
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#define"), trimmed.hasSuffix(";") else {
                out.append(line); continue
            }
            let afterDefine = trimmed.dropFirst("#define".count)
                .drop { $0 == " " || $0 == "\t" }
            // 매크로 이름 바로 뒤가 `(`면 함수형 매크로다 — 손대지 않는다.
            let name = afterDefine.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard afterDefine.dropFirst(name.count).first != "(" else {
                out.append(line); continue
            }
            var fixed = line
            fixed.removeLast()
            out.append(fixed)
        }
        return out.joined(separator: "\n")
    }

    /// `inout`/`out` 인자를 벡터 성분(`gl_FragColor.a`)으로 부르는 호출을 임시
    /// 변수로 감싼다.
    ///
    /// `void ApplyAlphaToCoverage(inout float alpha)`처럼 값을 되돌려주는 인자는
    /// MSL에서 `thread float&`가 된다. Metal은 **벡터 성분에 참조를 못 묶는다**
    /// (`gl_FragColor.a`, `c[3]` 전부) — 직접 확인했다: `bump(c[3])`도 "non-const
    /// reference cannot bind to vector element"로 떨어진다. 실물 `chroma4`·
    /// `foliage4`·`fur4.frag`가 `ApplyAlphaToCoverage(gl_FragColor.a);`로 이렇게
    /// 부른다. 함수 이름을 하드코딩하지 않는다 — 정의에서 `out`/`inout`이 있는
    /// 이름을 걷어(정의에만 그 낱말이 나온다) 그 이름을 부르는 자리를 전부 고친다.
    static func rewritingInoutSwizzleCalls(_ source: String) -> String {
        let definitionPattern = try! NSRegularExpression(
            pattern: #"([A-Za-z_]\w*)\s*\([^)]*\b(?:out|inout)\b"#)
        var inoutFunctions: Set<String> = []
        let fullRange = NSRange(source.startIndex..., in: source)
        for match in definitionPattern.matches(in: source, range: fullRange) {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            inoutFunctions.insert(String(source[range]))
        }
        guard !inoutFunctions.isEmpty else { return source }

        var out: [String] = []
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(");"), trimmed.filter({ $0 == ";" }).count == 1,
                  let open = trimmed.firstIndex(of: "(") else { out.append(line); continue }
            let name = String(trimmed[..<open])
            guard inoutFunctions.contains(name) else { out.append(line); continue }
            let closeIndex = trimmed.index(trimmed.endIndex, offsetBy: -2)
            let argsText = String(trimmed[trimmed.index(after: open)..<closeIndex])
            // 인자 하나에, 그게 벡터 성분(`x.a`)일 때만 고친다 — 그 밖의 호출은
            // 참조 바인딩 문제가 없어 손댈 이유가 없다.
            guard !argsText.contains(","), swizzleWidth(argsText) != nil else {
                out.append(line); continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            out.append(
                "\(indent){ auto wfRef = \(argsText); \(name)(wfRef); \(argsText) = wfRef; }")
        }
        return out.joined(separator: "\n")
    }

    /// WE의 셰이더 컴파일러는 HLSL식 **암묵적 벡터 절단**을 허용한다.
    /// 실물이 이렇게 쓴다:
    /// ```glsl
    /// vec3 shimmerColor = texSample2D(g_Texture3, uv);   // float4를 vec3에
    /// float mask = texSample2D(g_Texture1, uv);          // float4를 float에
    /// vec2 causticsCoords = v_TexCoord;                   // vec4 varying을 vec2에
    /// v_NoiseCoord = v_TexCoord;                          // 대입문에서도
    /// ```
    /// C++에는 그런 변환이 없다. 표현식의 타입을 알려면 파서가 필요한데, 그 대신
    /// **받는 쪽의 타입**을 안다는 점을 쓴다 — 선언이면 선언된 타입, 대입이면
    /// varying의 타입. 값을 `wfToN(...)`로 감싸면 프렐류드의 오버로드가 타입에
    /// 따라 자르거나(넓으면) 그대로 두거나(같으면) 펼친다(스칼라면).
    /// 같은 타입이면 항등이라, 모든 선언에 걸어도 뜻이 바뀌지 않는다.
    static func rewritingTruncation(_ source: String) -> String {
        let widths = ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4]
        // 대입문에서 받는 쪽을 알 수 있는 것은 varying뿐이다. 지역 변수는
        // 선언 자리에서 이미 감쌌고, 그 뒤의 대입은 흔치 않다.
        var varyingWidth: [String: Int] = [:]
        for line in source.split(whereSeparator: \.isNewline) {
            let words = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ";", with: " ")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 3, words[0] == "varying",
                  let width = widths[words[1]], !words[2].contains("[") else { continue }
            // `#if`/`#else` 양쪽에 같은 이름이 다른 타입으로 선언된 실물이 있다
            // (`generic.vert`의 `v_TexCoord`: vec4 다음 vec2). `parseDeclarations`가
            // 먼저 나온 선언을 구조체에 남기므로, 여기서도 먼저 온 것을 지킨다 —
            // 나중 것으로 덮으면 구조체의 진짜 타입(vec4)과 여기서 계산한 폭(vec2)이
            // 어긋나 `wfTo2`로 감싼 값을 vec4 멤버에 대입하다 떨어진다.
            if varyingWidth[words[2]] == nil { varyingWidth[words[2]] = width }
        }
        // varying·uniform과, 폭을 알아낼 수 있는 `#define` 상수까지. 식 안쪽에서
        // 폭이 다른 전역 둘이 바로 섞이는 자리(HLSL 암묵적 절단, pixelate·
        // clipping_mask 이펙트)를 고치는 데 쓴다.
        let identifierWidth = declaredIdentifierWidths(in: source)

        var out: [String] = []
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let rewritten = wrappedInitializer(
                line, widths: widths, varyingWidth: varyingWidth, identifierWidth: identifierWidth)
            else { out.append(line); continue }
            out.append(rewritten)
        }
        return out.joined(separator: "\n")
    }

    /// `name`이 `v.xy`·`albedo.rgb`처럼 스위즐로 끝나면 그 길이가 곧 폭이다 —
    /// 밑의 식이 무엇이든(지역 변수든 varying이든) 스위즐 자체가 정한다.
    private static func swizzleWidth(_ name: String) -> Int? {
        guard let lastDot = name.lastIndex(of: "."), lastDot != name.startIndex else { return nil }
        let suffix = name[name.index(after: lastDot)...]
        let swizzleLetters: Set<Character> = ["x", "y", "z", "w", "r", "g", "b", "a"]
        guard (1...4).contains(suffix.count), suffix.allSatisfy({ swizzleLetters.contains($0) })
        else { return nil }
        return suffix.count
    }

    /// 대입의 왼쪽 `lhs`(`TYPE NAME`·`NAME`·`NAME.swizzle`)에서 받는 쪽 폭을 찾는다.
    /// `allowDeclaration`이 거짓이면 `TYPE NAME` 꼴(새 선언)은 인정하지 않는다 —
    /// 복합 대입(`+=` 등)의 왼쪽은 반드시 **이미 있는** 변수라 새 선언일 수 없다.
    private static func assignmentTargetWidth(
        _ lhs: String, widths: [String: Int], varyingWidth: [String: Int],
        allowDeclaration: Bool
    ) -> Int? {
        var lhsWords = lhs.split(whereSeparator: \.isWhitespace).map(String.init)
        if lhsWords.first == "const" { lhsWords.removeFirst() }
        switch lhsWords.count {
        case 2 where allowDeclaration:
            // `TYPE NAME`. 이름에 `[`가 있으면 배열 선언이다.
            guard !lhsWords[1].contains("[") else { return nil }
            return widths[lhsWords[0]]
        case 1:
            // `NAME`이나 `NAME.swizzle`. 첨자(`[0]`)는 받는 쪽 타입이 달라 건너뛴다.
            guard !lhsWords[0].contains("[") else { return nil }
            return varyingWidth[lhsWords[0]] ?? swizzleWidth(lhsWords[0])
        default:
            return nil
        }
    }

    /// 한 줄이 `TYPE NAME = EXPR;`·`VARYING = EXPR;`·`NAME.swizzle = EXPR;`거나
    /// 그 복합 대입(`*=`·`+=`·`-=`·`/=`)이면 EXPR을 감싼다. 아니면 nil.
    private static func wrappedInitializer(
        _ line: String, widths: [String: Int], varyingWidth: [String: Int],
        identifierWidth: [String: Int]
    ) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 한 문장만 다룬다. `;`가 둘이면 for 머리이거나 두 문장이다.
        guard trimmed.hasSuffix(";"), trimmed.filter({ $0 == ";" }).count == 1,
              !trimmed.contains("wfTo"), !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        // `==`, `<=` 같은 것은 대입이 아니다.
        let afterEquals = trimmed.index(after: equals)
        guard afterEquals < trimmed.endIndex, trimmed[afterEquals] != "=" else { return nil }
        let before = trimmed.index(before: equals)
        let beforeChar = trimmed[before]
        guard !"<>!&|^%".contains(beforeChar) else { return nil }

        // `*=`·`+=`·`-=`·`/=`는 받는 쪽이 `=` 앞의 연산자 한 글자 전까지다.
        // `albedo.rgb *= g_Color4 * max(...)`(puppettexturechannels 이펙트)가 이 꼴이다.
        let isCompound = "+-*/".contains(beforeChar)
        let lhs = String(trimmed[..<(isCompound ? before : equals)])
            .trimmingCharacters(in: .whitespaces)
        guard let width = assignmentTargetWidth(
            lhs, widths: widths, varyingWidth: varyingWidth, allowDeclaration: !isCompound)
        else { return nil }

        var rhs = trimmed[afterEquals...].trimmingCharacters(in: .whitespaces)
        rhs.removeLast()  // `;`
        // 배열 초기화와 빈 값은 건드리지 않는다.
        guard !rhs.isEmpty, !rhs.hasPrefix("{"), !topLevelCommaOrAssignment(in: rhs) else {
            return nil
        }
        // 식 안쪽에서 폭이 다른 전역끼리 바로 섞이는 자리를 먼저 고친다. 바깥
        // `wfTo\(width)(...)`는 받는 쪽(LHS) 하나만 보므로, `v_TexCoord - texScaleCenter`
        // 처럼 안쪽 뺄셈 자체가 이미 Metal에서 타입 불일치인 경우를 못 잡는다.
        let (fixedRhs, _) = rewriteWithWidth(rhs, widths: identifierWidth)
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let op = isCompound ? "\(beforeChar)=" : "="
        return "\(indent)\(lhs) \(op) wfTo\(width)(\(fixedRhs));"
    }

    /// 괄호 밖에 `,`나 `=`가 있는지. `float a = 1, b = 2;`나 `a = b = c;`는
    /// 한 값이 아니라 감싸면 깨진다.
    private static func topLevelCommaOrAssignment(in expression: String) -> Bool {
        var depth = 0
        var previous: Character = " "
        for character in expression {
            switch character {
            case "(", "[": depth += 1
            case ")", "]": depth -= 1
            case ",": if depth == 0 { return true }
            case "=":
                // `==`는 비교다. 앞 글자가 `=`이거나 비교 연산자면 넘어간다.
                if depth == 0, !"=<>!".contains(previous) { return true }
            default: break
            }
            previous = character
        }
        return false
    }

    /// C++의 대체 토큰을 이름으로 쓴 것을 바꾼다.
    ///
    /// `or`·`and`·`not` 같은 낱말은 C++에서 연산자다(`||`·`&&`·`!`). GLSL에서는
    /// 그냥 이름이라 실물 창작마당 셰이더가 `vec2 or = mul(o, _rot);`로 쓴다.
    /// Metal은 그 줄에서 통째로 떨어진다. 뒤에 밑줄을 붙여 이름으로 만든다.
    static func rewritingReservedIdentifiers(_ source: String) -> String {
        let reserved: Set<String> = [
            "or", "and", "not", "xor", "bitand", "bitor", "compl",
            "and_eq", "or_eq", "xor_eq", "not_eq",
        ]
        var out = ""
        out.reserveCapacity(source.count)
        var word = ""
        func flush() {
            out += reserved.contains(word) ? word + "_" : word
            word = ""
        }
        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return out
    }

    /// GLSL의 배열 생성자 `vec3[](a, b, c)`·`vec3[4](…)`를 C++ 초기화 목록
    /// `{a, b, c}`로 바꾼다. 실물 창작마당 셰이더가 잡음 상수표를 이렇게 적는다.
    static func rewritingArrayConstructors(_ source: String) -> String {
        var characters = Array(source)
        var index = 0
        while index < characters.count {
            // `[`를 찾고, 그 앞이 타입 이름이며 `]` 뒤에 `(`가 오는지 본다.
            guard characters[index] == "[" else { index += 1; continue }
            var close = index + 1
            while close < characters.count, characters[close].isNumber { close += 1 }
            guard close < characters.count, characters[close] == "]" else { index += 1; continue }
            var open = close + 1
            while open < characters.count, characters[open] == " " { open += 1 }
            guard open < characters.count, characters[open] == "(" else { index += 1; continue }
            // 앞의 타입 이름.
            var typeStart = index
            while typeStart > 0,
                  characters[typeStart - 1].isLetter || characters[typeStart - 1].isNumber
                    || characters[typeStart - 1] == "_" {
                typeStart -= 1
            }
            guard typeStart < index else { index += 1; continue }
            // 짝이 맞는 `)`를 찾는다.
            var depth = 0
            var end = open
            var found = false
            while end < characters.count {
                if characters[end] == "(" { depth += 1 }
                if characters[end] == ")" {
                    depth -= 1
                    if depth == 0 { found = true; break }
                }
                end += 1
            }
            guard found else { index += 1; continue }
            characters[end] = "}"
            characters.replaceSubrange(typeStart...open, with: Array("{"))
            index = typeStart + 1
        }
        return String(characters)
    }

    /// `TYPE NAME[] = EXPR;`(GLSL의 크기 추론 배열 별칭)을 참조로 바꾼다.
    ///
    /// 실물 오디오 막대 이펙트가 `float g_AudioSpectrumLeft[] = g_AudioSpectrum32Left;`
    /// 로 32/64/16짜리 유니폼 배열 중 하나를 짧은 이름에 잇는다. C++엔 이런 초기화가
    /// 없다("array initializer must be an initializer list") — 직접 검증해 보니
    /// `thread auto&`(주소 공간을 밝힌 참조)로 바꾸면 통과한다. `auto`라 크기·
    /// 원소 타입을 몰라도 된다.
    static func rewritingInferredSizeArrayAliases(_ source: String) -> String {
        var out: [String] = []
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(";"), trimmed.filter({ $0 == ";" }).count == 1,
                  let equals = trimmed.firstIndex(of: "=") else { out.append(line); continue }
            let lhs = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let words = lhs.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count == 2, words[1].hasSuffix("[]") else { out.append(line); continue }
            let name = String(words[1].dropLast(2))
            var rhs = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            rhs.removeLast()  // `;`
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            out.append("\(indent)thread auto& \(name) = \(rhs);")
        }
        return out.joined(separator: "\n")
    }

    /// 배열 첨자에 소수점이 있으면 `int(...)`로 감싼다.
    ///
    /// HLSL은 `arr[a_BlendIndices.x / 4.0]`처럼 나눗셈이 낀 첨자도 받아 암묵적으로
    /// 정수로 자른다(실물 puppettexturechannels.vert). C++은 첨자가 정수 타입이어야
    /// 한다("array subscript is not an integer"). 소수점이 있는 첨자만 골라 감싼다 —
    /// `[32]`·`[BONECOUNT]`처럼 선언 자리의 배열 크기는 소수점이 없어 안 건드린다.
    static func rewritingFloatArraySubscripts(_ source: String) -> String {
        var out: [Character] = []
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            guard characters[index] == "[" else {
                out.append(characters[index]); index += 1; continue
            }
            var depth = 0
            var end = index
            while end < characters.count {
                if characters[end] == "[" { depth += 1 }
                if characters[end] == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            guard end < characters.count else {
                out.append(characters[index]); index += 1; continue
            }
            let inner = String(characters[(index + 1)..<end])
            if inner.contains(".") {
                out.append(contentsOf: "[int(\(inner))]")
            } else {
                out.append(contentsOf: "[\(inner)]")
            }
            index = end + 1
        }
        return String(out)
    }

    /// `a % b`를 `wfMod(a, b)` 호출로 바꾼다.
    ///
    /// HLSL은 실수에도 `%`를 쓴다 — 실물 오디오 막대 셰이더가
    /// `uint barFreq = frequency % RESOLUTION;`처럼 쓴다. C++에서는 실수에 `%`를
    /// 못 쓰고, **내장 타입끼리는 연산자 오버로드도 안 된다.** 그래서 함수로 바꾼다.
    ///
    /// assets 셰이더 466개에는 `%`가 하나도 없다. 창작마당 셰이더에만 나오므로
    /// 이 변환이 건드리는 범위가 좁다.
    static func rewritingModulo(_ source: String) -> String {
        let characters = Array(source)
        var index = 0
        var out: [Character] = []
        out.reserveCapacity(characters.count)
        while index < characters.count {
            guard characters[index] == "%" else {
                out.append(characters[index])
                index += 1
                continue
            }
            // `%=`는 복합 대입이라 그대로 둔다. 전처리기 줄도 건드리지 않는다.
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            guard next != "=", !isPreprocessorLine(out) else {
                out.append(characters[index])
                index += 1
                continue
            }
            guard let left = takeOperand(from: &out) else {
                out.append(characters[index])
                index += 1
                continue
            }
            index += 1
            guard let right = readOperand(characters, from: &index) else {
                out.append(contentsOf: left)
                out.append("%")
                continue
            }
            out.append(contentsOf: "wfMod(\(String(left)), \(right))")
        }
        return String(out)
    }

    /// `round(v_PixelCoord) * v_PixelSize`처럼 폭이 다른 varying/uniform 둘을
    /// 연산자 하나로 바로 묶는 실물이 있다(pixelate 이펙트, `vec2 * vec4`).
    /// HLSL은 이런 이항 연산에서도 넓은 쪽을 조용히 잘라 좁은 쪽에 맞춘다.
    /// C++/Metal은 크기가 다른 벡터끼리 연산자를 아예 허용하지 않는다.
    ///
    /// `rewritingTruncation`의 감싸기는 **받는 쪽**(선언·대입의 왼쪽)만 본다 — 식
    /// 안쪽에서 벌어지는 이 불일치는 못 잡는다. 여기서는 연산자 바로 양옆(피연산자
    /// 하나씩, `%` 재작성과 같은 방식으로 괄호까지 통째로 집는다)의 폭을 실제로
    /// 비교해서, 다를 때만 넓은 쪽을 좁힌다 — `length(a - b)`처럼 폭이 같은
    /// 자리는 건드리지 않으므로 그 결과(스칼라)를 다시 잘못 좁히지 않는다.
    /// `varying`·`uniform` 선언과, 폭을 알아낼 수 있는 `#define` 상수의 이름 → 폭(1~4).
    /// 배열·행렬·샘플러는 뺀다.
    ///
    /// 실물 clipping_mask 이펙트가 `#define texScaleCenter (u_texScaleCenter * 2.0 - 1.0)`
    /// 처럼 uniform을 그대로 감싼 매크로를 만들고, 그 매크로를 `v_TexCoord`(vec4)와
    /// 바로 섞어 쓴다. `#define`은 위에서 아래로 먼저 온 것부터 펼쳐지므로,
    /// 한 줄씩 내려가며 지금까지 안 이름으로 다음 매크로의 폭을 잰다.
    static func declaredIdentifierWidths(in source: String) -> [String: Int] {
        let typeWidths = ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4]
        var out: [String: Int] = [:]
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#define") {
                let afterDefine = trimmed.dropFirst("#define".count)
                    .drop { $0 == " " || $0 == "\t" }
                let name = String(afterDefine.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                let rest = afterDefine.dropFirst(name.count)
                // 함수형 매크로(`NAME(args) ...`)는 인자마다 폭이 다를 수 있어 건너뛴다.
                guard !name.isEmpty, rest.first != "(" else { continue }
                if let width = rewriteWithWidth(String(rest), widths: out).width { out[name] = width }
                continue
            }
            let words = trimmed.replacingOccurrences(of: ";", with: " ")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count >= 3, ["varying", "uniform"].contains(words[0]),
               let width = typeWidths[words[1]], !words[2].contains("[") {
                if out[words[2]] == nil { out[words[2]] = width }  // 먼저 온 선언이 이긴다.
                continue
            }
            // 지역 변수 선언(`vec3 newAlbedo = ...;`, `float mask = ...;`)도 잰다 —
            // `mix(albedo, newAlbedo, mask)`(hue_shift 이펙트)처럼 인자가 전부
            // 지역이면 전역만 보는 스캔으론 폭을 하나도 못 알아낸다. 이름 바로 뒤가
            // `=`나 `;`여야 한다 — `(`면 함수 정의(`vec3 f(...)`)라 건너뛴다.
            if words.count >= 2, let width = typeWidths[words[0]] {
                let name = String(words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                let isPlainDeclaration = !name.isEmpty && words[1].dropFirst(name.count).first != "("
                if isPlainDeclaration, out[name] == nil { out[name] = width }
            }
        }
        return out
    }

    /// 폭이 다른 전역 둘이 식 안에서 바로 섞이는 자리(HLSL 암묵적 절단)를 찾아
    /// 넓은 쪽을 `wfToN`으로 좁힌다.
    ///
    /// `rewritingTruncation`의 감싸기는 **받는 쪽**(선언·대입의 왼쪽)만 본다 —
    /// `v_TexCoord*2.0-1.0-texScaleCenter`처럼 실제 불일치가 여러 항을 지나서야
    /// 나타나면(clipping_mask 이펙트, vec4 - vec2) 못 잡는다. 연산자 하나만
    /// 보는 게 아니라 `+`/`-`(낮은 우선순위)부터 `*`/`/`까지 실제 계산 순서를 따라
    /// 왼쪽 결합으로 접으면서 HLSL의 규칙(스칼라는 투명, 벡터끼리 폭이 다르면
    /// 좁은 쪽에 맞춘다)을 그대로 재현한다. 폭을 모르는 자리는 손대지 않는다
    /// (nil을 그대로 전파) — 확신 없는 곳을 고치면 오히려 새 버그가 된다
    /// (`length(a - b)`의 `a - b`처럼 폭이 같은 자리를 잘못 좁히면 그렇게 된다).
    static func rewriteWithWidth(
        _ expression: String, widths: [String: Int]
    ) -> (text: String, width: Int?) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if let segments = splitTopLevel(trimmed, operators: Set("+-")) {
            return foldChain(segments, widths: widths)
        }
        if let segments = splitTopLevel(trimmed, operators: Set("*/")) {
            return foldChain(segments, widths: widths)
        }
        if trimmed.hasPrefix("("), trimmed.hasSuffix(")"), isSingleParenGroup(trimmed) {
            let inner = String(trimmed.dropFirst().dropLast())
            let (text, width) = rewriteWithWidth(inner, widths: widths)
            return ("(\(text))", width)
        }
        if trimmed.hasSuffix(")"), let open = trimmed.firstIndex(of: "(") {
            let name = String(trimmed[..<open])
            let argsText = String(
                trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            let argSegments = splitTopLevel(argsText, operators: Set(","))
                ?? [(text: argsText, op: "")]
            let rewrittenArgs = argSegments.map { rewriteWithWidth($0.text, widths: widths) }
            // GLSL 내장 중 인자가 **서로 같은 폭이어야만 하는** 것들만 맞춘다
            // (`mix(albedo, newAlbedo, mask)`처럼, hue_shift·procedural_noise 이펙트).
            // `rotateVec2(v, angle)`처럼 인자마다 역할이 다른(폭이 달라도 되는)
            // 함수까지 맞추면 `g_Direction`(스칼라 각도)을 보고 `vec2(0,1)`을
            // `wfTo1`로 깎아 호출 자체를 바꿔 버린다(실물 waterwaves 이펙트가
            // 이렇게 깨졌었다) — 그래서 이름을 딱 이 목록으로만 좁힌다.
            // 인자는 **저마다 따로** 감싼다 — `foldChain`처럼 왼쪽으로 누적해
            // 감싸면 `wfTo1(a, b)`처럼 인자 둘이 하나로 뭉개져 호출이 깨진다
            // (실물 blurRadial13a가 처음엔 이렇게 떨어졌었다).
            let homogeneousArgFunctions: Set<String> = [
                "mix", "lerp", "clamp", "min", "max", "step", "smoothstep",
            ]
            let text: String
            if homogeneousArgFunctions.contains(name) {
                // 폭 0(리터럴)·1(`float`)은 스칼라라 맞출 대상에서 뺀다 —
                // `clamp(v, 0.0, 1.0)`의 `0.0`·`1.0`을 건드리면 안 된다.
                let knownWidths = Set(rewrittenArgs.compactMap { $0.width }.filter { $0 > 1 })
                if let target = knownWidths.min(), knownWidths.contains(where: { $0 != target }) {
                    let wrapped = rewrittenArgs.map { arg -> String in
                        guard let width = arg.width, width > target else { return arg.text }
                        return "wfTo\(target)(\(arg.text))"
                    }
                    text = "\(name)(\(wrapped.joined(separator: ", ")))"
                } else {
                    text = "\(name)(\(rewrittenArgs.map(\.text).joined(separator: ", ")))"
                }
            } else {
                text = "\(name)(\(rewrittenArgs.map(\.text).joined(separator: ", ")))"
            }
            let elementwiseUnary: Set<String> = [
                "round", "floor", "ceil", "fract", "frac", "abs", "sign",
                "normalize", "saturate", "trunc",
            ]
            if rewrittenArgs.count == 1, elementwiseUnary.contains(name) {
                return (text, rewrittenArgs[0].width)
            }
            if ["vec2", "vec3", "vec4", "CAST2", "CAST3", "CAST4"].contains(name) {
                return (text, name.hasSuffix("2") ? 2 : name.hasSuffix("3") ? 3 : 4)
            }
            // `CASTF(x)`/`CASTU(x)`는 스칼라로 깎는 WE 매크로다.
            if ["CASTF", "CASTU"].contains(name) { return (text, 0) }
            return (text, nil)
        }
        // 숫자 리터럴은 스칼라다 — 벡터 어느 폭과 섞여도 걸리지 않는다(폭 0으로 표시).
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == "." }) {
            return (trimmed, 0)
        }
        // 스위즐(`.rgb`·`.xy`)은 그 자체로 폭을 정한다 — 밑의 식이 뭐든 상관없다.
        // `albedo.rgb`·`v_TexCoord.xy`가 이 꼴이다(editorpaintbrush·hue_shift 등).
        if let lastDot = trimmed.lastIndex(of: "."), lastDot != trimmed.startIndex {
            let suffix = trimmed[trimmed.index(after: lastDot)...]
            let swizzleLetters: Set<Character> = ["x", "y", "z", "w", "r", "g", "b", "a"]
            if (1...4).contains(suffix.count), suffix.allSatisfy({ swizzleLetters.contains($0) }) {
                return (trimmed, suffix.count)
            }
        }
        if let width = widths[trimmed] { return (trimmed, width) }
        return (trimmed, nil)
    }

    /// `A op1 B op2 C ...`를 왼쪽 결합으로 접는다. 폭이 다른 이웃(스칼라 제외)이
    /// 만나면 넓은 쪽을 `wfToN`으로 좁힌다.
    private static func foldChain(
        _ segments: [(text: String, op: String)], widths: [String: Int]
    ) -> (text: String, width: Int?) {
        var text = ""
        var width: Int?
        for (index, segment) in segments.enumerated() {
            let (termText, termWidth) = rewriteWithWidth(segment.text, widths: widths)
            if index == 0 {
                text = termText
                width = termWidth
                continue
            }
            let combined = combineWidths(width, termWidth)
            let left = narrowed(text, from: width, to: combined)
            let right = narrowed(termText, from: termWidth, to: combined)
            text = "\(left)\(segment.op)\(right)"
            width = combined
        }
        return (text, width)
    }

    /// 스칼라(리터럴 폭 0, `float` 폭 1)는 아무 폭과도 섞인다 — Metal이 `vecN op
    /// float`를 네이티브로 지원한다(성분마다 곱/나눔). `or_(vec2) / u_scale(float)`
    /// 를 폭이 다르다고 `wfTo1`로 좁히면 진짜 vec2였던 값이 스칼라로 깎여
    /// 버린다(실물 dot_matrix_mobile_fix 이펙트가 이렇게 떨어질 뻔했다) — `float`도
    /// 리터럴과 똑같이 투명해야 한다. 둘 다 진짜 벡터(2 이상)인데 폭이 다르면
    /// HLSL처럼 좁은 쪽으로 — 이 자리가 바로 `wfToN`으로 감싸야 하는 자리다.
    private static func combineWidths(_ left: Int?, _ right: Int?) -> Int? {
        guard let left, let right else { return nil }
        if left <= 1 { return right }
        if right <= 1 { return left }
        return min(left, right)
    }

    private static func narrowed(_ text: String, from width: Int?, to target: Int?) -> String {
        guard let width, let target, target > 1, width > target else { return text }
        return "wfTo\(target)(\(text))"
    }

    /// `expression`을 괄호 깊이 0인 자리에서만 `operators`로 나눈다. `+`/`-`는
    /// 단항(맨 앞이거나 다른 연산자·여는 괄호 바로 뒤)이면 나누지 않는다.
    /// 나눌 자리가 없으면 nil — "이 우선순위의 사슬이 아니다"라는 뜻이다.
    private static func splitTopLevel(
        _ expression: String, operators: Set<Character>
    ) -> [(text: String, op: String)]? {
        let characters = Array(expression)
        func isOperandEnd(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == ")" || c == "]" || c == "."
        }
        var depth = 0
        var segments: [(String, String)] = []
        var start = 0
        var pendingOp = ""
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c == "(" || c == "[" {
                depth += 1
            } else if c == ")" || c == "]" {
                depth -= 1
            } else if depth == 0, operators.contains(c) {
                let isSign = c == "+" || c == "-"
                var precededByOperand = false
                if isSign {
                    var j = index - 1
                    while j >= 0, characters[j] == " " { j -= 1 }
                    precededByOperand = j >= 0 && isOperandEnd(characters[j])
                }
                if !isSign || precededByOperand {
                    let text = String(characters[start..<index]).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return nil }
                    segments.append((text, pendingOp))
                    // 쉼표(함수 인자)는 읽기 좋게 뒤에 공백을 하나 둔다. 산술
                    // 연산자는 기존 테스트가 공백 없는 형태를 이미 고정해 뒀다.
                    pendingOp = c == "," ? ", " : String(c)
                    start = index + 1
                }
            }
            index += 1
        }
        guard !segments.isEmpty else { return nil }
        let lastText = String(characters[start...]).trimmingCharacters(in: .whitespaces)
        guard !lastText.isEmpty else { return nil }
        segments.append((lastText, pendingOp))
        return segments
    }

    /// `trimmed`가 통째로 괄호 한 겹인지. `(a)+(b)`처럼 두 조각이면 아니다.
    private static func isSingleParenGroup(_ trimmed: String) -> Bool {
        var depth = 0
        let characters = Array(trimmed)
        for (index, character) in characters.enumerated() {
            if character == "(" { depth += 1 }
            else if character == ")" {
                depth -= 1
                if depth == 0 { return index == characters.count - 1 }
            }
        }
        return false
    }

    /// 지금 쓰고 있는 줄이 전처리기 지시자인지. `#if A % B` 같은 것은 건드리지 않는다.
    private static func isPreprocessorLine(_ written: [Character]) -> Bool {
        for character in written.reversed() {
            if character.isNewline { return false }
            if character == "#" { return true }
        }
        return false
    }

    /// 이미 써 둔 쪽에서 왼쪽 피연산자를 떼어 낸다.
    /// 괄호로 끝나면 짝을 맞춰 통째로 가져온다.
    private static func takeOperand(from written: inout [Character]) -> [Character]? {
        var trailing: [Character] = []
        while let last = written.last, last == " " || last == "\t" {
            trailing.append(written.removeLast())
        }
        guard let last = written.last else { return nil }
        var operand: [Character] = []
        if last == ")" || last == "]" {
            let open: Character = last == ")" ? "(" : "["
            var depth = 0
            while let character = written.last {
                written.removeLast()
                operand.append(character)
                if character == last { depth += 1 }
                if character == open {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            // 괄호 앞이 함수 이름이면 그것까지 피연산자다.
            while let ahead = written.last, ahead.isLetter || ahead.isNumber || ahead == "_"
                || ahead == "." {
                operand.append(written.removeLast())
            }
        } else if last.isLetter || last.isNumber || last == "_" || last == "." {
            while let ahead = written.last, ahead.isLetter || ahead.isNumber || ahead == "_"
                || ahead == "." {
                operand.append(written.removeLast())
            }
        } else {
            written.append(contentsOf: trailing.reversed())
            return nil
        }
        return operand.reversed()
    }

    /// 오른쪽 피연산자를 읽는다.
    private static func readOperand(_ characters: [Character], from index: inout Int) -> String? {
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            index += 1
        }
        guard index < characters.count else { return nil }
        var operand = ""
        if characters[index] == "(" {
            var depth = 0
            while index < characters.count {
                let character = characters[index]
                operand.append(character)
                index += 1
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            return operand
        }
        while index < characters.count {
            let character = characters[index]
            guard character.isLetter || character.isNumber || character == "_"
                || character == "." else { break }
            operand.append(character)
            index += 1
        }
        return operand.isEmpty ? nil : operand
    }

    /// GLSL의 함수 인자 한정자를 MSL로 옮긴다.
    ///
    /// GLSL은 `void f(in vec3 a, out vec3 b, inout vec3 c)`를 쓴다. MSL에는 그런
    /// 한정자가 없고, 돌려주는 인자는 `thread T&` 참조다. `in`은 그냥 값이라 지운다.
    /// 안 고치면 `in`이 타입 이름으로 읽혀 그 헤더를 쓰는 셰이더가 전부 떨어진다
    /// (실물 28개). 인자 목록 안(여는 괄호나 쉼표 뒤)에서만 바꿔서, 본문에 우연히
    /// 나온 같은 낱말을 건드리지 않는다.
    static func rewritingParameterQualifiers(_ source: String) -> String {
        // 실물 창작마당 셰이더가 GLSL 타입 대신 HLSL 이름(`float2`)을 그대로 쓰기도
        // 한다(`in float2 uv`, contrast_based_sharpness 이펙트). 정해진 타입 목록
        // 대신 아무 식별자나 받는다 — 여는 괄호·쉼표 바로 뒤의 `in`/`out`/`inout`은
        // 인자 한정자일 수밖에 없어 안전하다.
        let types = "[A-Za-z_]\\w*"
        var out = source
        for (pattern, template) in [
            ("([(,]\\s*)in\\s+((?:const\\s+)?\\b\(types)\\b)", "$1$2"),
            ("([(,]\\s*)(?:out|inout)\\s+((?:const\\s+)?\\b\(types)\\b)",
             "$1thread $2&"),
        ] {
            out = out.replacingOccurrences(
                of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    // MARK: - 선언 수집

    struct Parsed {
        var uniforms: [Uniform] = []
        var textures: [Texture] = []
        /// 정점 출력 = 프래그먼트 입력.
        var varyings: [(type: String, name: String, count: Int?)] = []
        /// 정점 입력.
        var attributes: [(type: String, name: String, count: Int?)] = []
        /// GLSL 4.x식 `in uint gl_InstanceID;`(전역, 인자 목록 밖) — 정점 하나당
        /// 엔진이 주는 시스템 값이다. `[[instance_id]]` 같은 Metal 특성으로
        /// 진입점 인자가 된다. 아는 이름만 담는다 — 모르는 `in` 선언은 조용히 뺀다.
        var systemValues: [(type: String, name: String)] = []
        /// 선언을 뺀 나머지 전부(함수, `#if`, `#define`).
        var body: String = ""
    }

    /// GLSL의 정점당 시스템 값 → MSL 특성. WE 셰이더가 `in uint gl_InstanceID;`
    /// 처럼 전역에 선언해 쓴다(실물 `shadowcaster.vert`·`fur4.vert`). 목록에 없는
    /// 이름은 우리가 채워 줄 값이 없어 조용히 지운다 — 셰이더가 실제로 그 값을
    /// 안 쓰면(다른 콤보로 꺼져 있으면) 몰라도 무방하다.
    static let systemValueAttributes: [String: String] = [
        "gl_InstanceID": "instance_id",
        "gl_VertexID": "vertex_id",
    ]

    static func parseDeclarations(
        _ source: String, annotations: [String: [String: Any]]
    ) -> Parsed {
        var parsed = Parsed()
        var bodyLines: [String] = []
        var textureIndex = 0
        var declaredNames: [String: Int?] = [:]
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            // `in TYPE NAME;`(전역 시스템 값). 함수 인자 목록 안의 `in`은
            // `rewritingParameterQualifiers`가 이미 걷어 냈으므로 여기 남는 `in`은
            // 전부 이 꼴이다.
            if words.count == 3, words[0] == "in", trimmed.hasSuffix(";"),
               let (name, _, _) = declared(in: trimmed) {
                if systemValueAttributes[name] != nil {
                    parsed.systemValues.append((words[1], name))
                }
                bodyLines.append("")
                continue
            }
            // 선언은 한 줄에 끝난다. 그렇지 않은 줄은 본문으로 넘긴다.
            guard words.count >= 3, trimmed.hasSuffix(";"),
                  ["uniform", "varying", "attribute"].contains(words[0]),
                  let (name, count, sizeMacro) = declared(in: trimmed)
            else {
                bodyLines.append(String(line))
                continue
            }
            let type = words[1]
            // 같은 이름이 `#if`/`#else` 양쪽에 선언된 셰이더가 있다. 우리는 전처리기를
            // 돌리지 않고 선언만 걷어 내므로 둘 다 걸린다 — 구조체 멤버가 중복되어
            // 그 셰이더가 떨어진다(실물 22개). 먼저 나온 것을 남긴다.
            // 같은 varying이 `#if` 가지마다 다른 크기로 선언된다(13/7/3).
            // 가장 큰 것을 남겨야 어느 가지가 켜져도 자리가 모자라지 않는다.
            if let existing = declaredNames[name] {
                if let count, let existingCount = existing, count > existingCount {
                    declaredNames[name] = count
                    if let at = parsed.varyings.firstIndex(where: { $0.name == name }) {
                        parsed.varyings[at].count = count
                    }
                }
                bodyLines.append("")
                continue
            }
            declaredNames[name] = count
            switch words[0] {
            case "uniform" where type.hasPrefix("sampler"):
                // 샘플러는 버퍼가 아니라 텍스처 인자다. 이름 규칙이
                // `texSample2D` 매크로와 맞물린다(`<이름>Sampler`).
                //
                // **번호는 선언 순서가 아니라 이름에서 온다.** 실물
                // `godrays_combine.frag`는 `g_Texture2`를 먼저 선언한다. 순서로
                // 매기면 이펙트의 `bind`가 가리키는 슬롯과 어긋나 텍스처가 통째로
                // 뒤섞이고, 합치기 셰이더가 엉뚱한 것을 읽어 화면이 하얘진다.
                parsed.textures.append(Texture(
                    name: name, index: textureSlot(for: name) ?? textureIndex,
                    comboName: annotations[name]?["combo"] as? String,
                    defaultPath: annotations[name].flatMap { stringValue($0["default"]) }))
                textureIndex += 1
            case "uniform":
                let annotation = annotations[name]
                parsed.uniforms.append(Uniform(
                    name: name, type: type,
                    materialKey: annotation?["material"] as? String,
                    defaultValue: annotation.flatMap { stringValue($0["default"]) },
                    count: count, sizeMacro: sizeMacro))
            case "varying":
                parsed.varyings.append((type, name, count))
            default:
                parsed.attributes.append((type, name, count))
            }
            // 줄 수를 지켜야 컴파일 오류의 줄 번호가 원본과 맞는다.
            bodyLines.append("")
        }
        parsed.body = bodyLines.joined(separator: "\n")
        return parsed
    }

    /// `g_Texture2` → 2. WE의 텍스처 슬롯 번호는 이름에 적혀 있다.
    /// 규칙에 안 맞는 이름이면 nil — 그때만 선언 순서로 매긴다.
    static func textureSlot(for name: String) -> Int? {
        let prefix = "g_Texture"
        guard name.hasPrefix(prefix) else { return nil }
        let digits = name.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        // 슬롯이 터무니없이 크면 바인딩 배열을 벗어난다.
        guard let slot = Int(digits), slot >= 0, slot < 32 else { return nil }
        return slot
    }

    /// 주석의 `default`는 수일 수도 `"1 1 1"` 같은 문자열일 수도 있다.
    static func stringValue(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: - 조립

    /// GLSL의 전역(유니폼·텍스처·varying)은 어느 함수에서나 보인다. MSL에서는
    /// 함수 인자라 `main` **앞에 정의된 헬퍼 함수**가 그것들을 볼 수 없다 —
    /// 매크로로 이름만 묶는 방법이 여기서 무너진다(실물 13개가 이 때문에 떨어졌다).
    ///
    /// 그래서 셰이더 전체를 구조체 하나에 담는다. 전역이 멤버가 되고 헬퍼가
    /// 멤버 함수가 되면, GLSL의 가시성 규칙이 그대로 재현된다. C++의 멤버 함수
    /// 본문은 클래스가 완성된 뒤에 해석되므로 선언 순서도 문제되지 않는다.
    ///
    /// 덤으로 배열 varying도 풀린다. `stage_in` 구조체에는 배열을 못 넣지만
    /// (블러 계열의 `v_TexCoord[13]`), 컨텍스트 구조체 안에서는 진짜 배열이라
    /// `v_TexCoord[i]`가 그대로 동작한다. 경계에서만 성분으로 펼친다.
    private static func assemble(
        _ parsed: Parsed, stage: Stage, entryPoint: String, combos: [(String, Int)]
    ) throws -> Result {
        guard let mainRange = parsed.body.range(of: "void main") else {
            throw Failure.missingMain
        }
        guard let braceStart = parsed.body[mainRange.upperBound...].firstIndex(of: "{")
        else { throw Failure.missingMain }
        let braceEnd = try matchingBrace(in: parsed.body, from: braceStart)

        let prologue = String(parsed.body[..<mainRange.lowerBound])
        let mainBody = String(parsed.body[parsed.body.index(after: braceStart)..<braceEnd])
        let epilogue = String(parsed.body[parsed.body.index(after: braceEnd)...])

        var out = ShaderPrelude.all + "\n\n"
        // 콤보 기본값. 재질이 값을 주면 그것이 이긴다(`#ifndef`).
        // `#if RAYMODE`뿐 아니라 `ApplyBlending(BLENDMODE, ...)`처럼 **값으로도**
        // 쓰이므로, 정의가 없으면 그 셰이더가 통째로 떨어진다(실물 35개).
        for (name, value) in combos {
            out += "#ifndef \(name)\n#define \(name) \(value)\n#endif\n"
        }
        out += "\n"

        // 단계 사이를 오가는 구조체. 배열은 성분으로 펼친다.
        //
        // 정점과 프래그먼트는 **따로 번역해 따로 컴파일한다**(Metal은 두 함수가 다른
        // 라이브러리에 있어도 된다). 그래서 두 구조체가 필드 순서로 맞물리면 안 된다 —
        // 같은 varying이 `.vert`와 `.frag`에서 다른 순서로 선언될 수 있고, 그러면
        // 값이 조용히 뒤바뀐다. `[[user(이름)]]`으로 **이름으로** 맞물리게 한다.
        out += "struct Varyings {\n    float4 position [[position]];\n"
        for varying in parsed.varyings {
            // 행렬은 `stage_in`에 못 들어간다. 열마다 벡터 하나로 펼친다.
            if let columns = matrixColumns(varying.type) {
                for column in 0..<columns.count {
                    let name = "\(varying.name)_c\(column)"
                    out += "    \(columns.type) \(name) [[user(\(name))]];\n"
                }
                continue
            }
            for name in flattenedNames(varying.name, count: varying.count) {
                out += "    \(varying.type) \(name) [[user(\(name))]];\n"
            }
        }
        out += "};\n\n"

        if stage == .vertex {
            out += "struct VertexIn {\n"
            var slot = 0
            for attribute in parsed.attributes {
                for name in flattenedNames(attribute.name, count: attribute.count) {
                    out += "    \(attribute.type) \(name) [[attribute(\(slot))]];\n"
                    slot += 1
                }
            }
            if parsed.attributes.isEmpty { out += "    float4 _unused [[attribute(0)]];\n" }
            out += "};\n\n"
        }

        // 배열 크기: 숫자면 그대로, 매크로 이름이면 그 글자를 그대로 대괄호에
        // 넣는다 — 재질의 `combos`가 `#define BONECOUNT 64`로 미리 붙여 주므로
        // Metal의 전처리기가 우리 대신 펼친다.
        func arraySuffix(_ uniform: Uniform) -> String {
            if let count = uniform.count { return "[\(count)]" }
            if let macro = uniform.sizeMacro { return "[\(macro)]" }
            return ""
        }
        out += "struct Uniforms {\n"
        for uniform in parsed.uniforms {
            out += "    \(uniform.type) \(uniform.name)\(arraySuffix(uniform));\n"
        }
        // 빈 구조체는 MSL이 거부한다.
        if parsed.uniforms.isEmpty { out += "    float _unused;\n" }
        out += "};\n\n"

        // 셰이더 본문 전체를 담는 구조체. 여기서 전역이 멤버가 된다.
        out += "struct ShaderContext {\n"
        for uniform in parsed.uniforms {
            out += "    \(uniform.type) \(uniform.name)\(arraySuffix(uniform));\n"
        }
        for texture in parsed.textures {
            out += "    texture2d<float> \(texture.name);\n"
            out += "    sampler \(texture.name)Sampler;\n"
        }
        for varying in parsed.varyings {
            let array = varying.count.map { "[\($0)]" } ?? ""
            out += "    \(varying.type) \(varying.name)\(array);\n"
        }
        if stage == .vertex {
            for attribute in parsed.attributes {
                let array = attribute.count.map { "[\($0)]" } ?? ""
                out += "    \(attribute.type) \(attribute.name)\(array);\n"
            }
            for systemValue in parsed.systemValues {
                out += "    \(systemValue.type) \(systemValue.name);\n"
            }
            out += "    float4 gl_Position;\n"
        } else {
            out += "    float4 gl_FragColor;\n"
        }
        out += "\n" + prologue + "\n"
        out += "    void shaderMain() {\n" + mainBody + "\n    }\n"
        out += "};\n\n"

        // 진입점. 경계에서만 값을 옮긴다.
        var arguments: [String] = []
        arguments.append(stage == .vertex
            ? "VertexIn vertexIn [[stage_in]]" : "Varyings varyingsIn [[stage_in]]")
        arguments.append("constant Uniforms& uniforms [[buffer(0)]]")
        if stage == .vertex {
            for systemValue in parsed.systemValues {
                let attribute = systemValueAttributes[systemValue.name] ?? "vertex_id"
                arguments.append("\(systemValue.type) \(systemValue.name) [[\(attribute)]]")
            }
        }
        for texture in parsed.textures {
            arguments.append("texture2d<float> \(texture.name) [[texture(\(texture.index))]]")
            arguments.append("sampler \(texture.name)Sampler [[sampler(\(texture.index))]]")
        }

        var setup: [String] = []
        for uniform in parsed.uniforms {
            if let count = uniform.count {
                // 배열은 통째로 대입할 수 없다. 성분마다 옮긴다.
                for index in 0..<count {
                    setup.append(
                        "    context.\(uniform.name)[\(index)] = uniforms.\(uniform.name)[\(index)];"
                    )
                }
                continue
            }
            if let macro = uniform.sizeMacro {
                // 크기를 몰라(매크로 이름뿐) 성분마다 펼쳐 쓸 수 없다 — 실행 시점
                // for문으로 옮긴다. `#define BONECOUNT 64`가 이미 앞에 붙어 있어
                // Metal 전처리기가 이 매크로도 똑같이 펼친다.
                setup.append(
                    "    for (int i = 0; i < \(macro); ++i) "
                        + "{ context.\(uniform.name)[i] = uniforms.\(uniform.name)[i]; }")
                continue
            }
            setup.append("    context.\(uniform.name) = uniforms.\(uniform.name);")
        }
        for texture in parsed.textures {
            setup.append("    context.\(texture.name) = \(texture.name);")
            setup.append("    context.\(texture.name)Sampler = \(texture.name)Sampler;")
        }

        switch stage {
        case .vertex:
            for attribute in parsed.attributes {
                for (offset, name) in flattenedNames(
                    attribute.name, count: attribute.count).enumerated() {
                    let target = attribute.count == nil
                        ? attribute.name : "\(attribute.name)[\(offset)]"
                    setup.append("    context.\(target) = vertexIn.\(name);")
                }
            }
            for systemValue in parsed.systemValues {
                setup.append("    context.\(systemValue.name) = \(systemValue.name);")
            }
            var copyOut: [String] = ["    varyingsOut.position = context.gl_Position;"]
            for varying in parsed.varyings {
                if let columns = matrixColumns(varying.type) {
                    for column in 0..<columns.count {
                        copyOut.append(
                            "    varyingsOut.\(varying.name)_c\(column) = context.\(varying.name)[\(column)];")
                    }
                    continue
                }
                for (offset, name) in flattenedNames(
                    varying.name, count: varying.count).enumerated() {
                    let source = varying.count == nil
                        ? varying.name : "\(varying.name)[\(offset)]"
                    copyOut.append("    varyingsOut.\(name) = context.\(source);")
                }
            }
            out += """

            vertex Varyings \(entryPoint)(
                \(arguments.joined(separator: ",\n    "))) {
                ShaderContext context;
                context.gl_Position = float4(0.0, 0.0, 0.0, 1.0);
            \(setup.joined(separator: "\n"))
                context.shaderMain();
                Varyings varyingsOut;
            \(copyOut.joined(separator: "\n"))
                return varyingsOut;
            }

            """
        case .fragment:
            for varying in parsed.varyings {
                if let columns = matrixColumns(varying.type) {
                    let parts = (0..<columns.count)
                        .map { "varyingsIn.\(varying.name)_c\($0)" }
                        .joined(separator: ", ")
                    setup.append("    context.\(varying.name) = \(varying.type)(\(parts));")
                    continue
                }
                for (offset, name) in flattenedNames(
                    varying.name, count: varying.count).enumerated() {
                    let target = varying.count == nil
                        ? varying.name : "\(varying.name)[\(offset)]"
                    setup.append("    context.\(target) = varyingsIn.\(name);")
                }
            }
            out += """

            fragment float4 \(entryPoint)(
                \(arguments.joined(separator: ",\n    "))) {
                ShaderContext context;
                context.gl_FragColor = float4(0.0, 0.0, 0.0, 1.0);
            \(setup.joined(separator: "\n"))
                context.shaderMain();
                return context.gl_FragColor;
            }

            """
        }
        out += epilogue + "\n"

        var attributes: [Attribute] = []
        var slot = 0
        for attribute in parsed.attributes {
            for name in flattenedNames(attribute.name, count: attribute.count) {
                attributes.append(Attribute(name: name, type: attribute.type, slot: slot))
                slot += 1
            }
        }
        return Result(source: out, uniforms: parsed.uniforms, textures: parsed.textures,
                      attributes: attributes)
    }

    /// 배열이면 `v_TexCoord_0`처럼 성분 이름으로 펼친다. 아니면 이름 하나.
    /// `stage_in` 구조체는 배열을 못 담는다 — 경계에서만 펼치고 안에서는 배열로 쓴다.
    /// 행렬 varying의 열 수와 열 타입. 행렬이 아니면 nil.
    ///
    /// Metal의 `stage_in`에는 행렬을 못 넣는다. 실물 커서 물결 이펙트가
    /// `varying mat3 v_XForm`을 쓴다 — 열마다 벡터로 나눠 나르고 받는 쪽에서
    /// 다시 붙인다. 컨텍스트 구조체 안에서는 진짜 행렬이라 본문은 그대로다.
    static func matrixColumns(_ type: String) -> (count: Int, type: String)? {
        switch type {
        case "mat2": return (2, "vec2")
        case "mat3": return (3, "vec3")
        case "mat4": return (4, "vec4")
        default: return nil
        }
    }

    static func flattenedNames(_ name: String, count: Int?) -> [String] {
        guard let count, count > 0 else { return [name] }
        return (0..<count).map { "\(name)_\($0)" }
    }



    /// `{`에 맞는 `}`를 찾는다. 주석은 이미 지워졌고 셰이더에 문자열 리터럴은 없다.
    static func matchingBrace(in source: String, from start: String.Index) throws -> String.Index {
        var depth = 0
        var index = start
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = source.index(after: index)
        }
        throw Failure.unbalancedBraces
    }
}
