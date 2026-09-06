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

    /// 유니폼 하나. 씬이 주는 값과 이어 붙일 근거가 여기 다 있다.
    public struct Uniform: Equatable, Sendable {
        public let name: String
        public let type: String
        /// 셰이더 주석의 `{"material": "..."}`. 씬의 `constantshadervalues` 키다.
        /// 없으면 씬이 값을 줄 수 없는 유니폼이다(엔진이 채우는 것들).
        public let materialKey: String?
        /// 주석의 `default`. 씬이 값을 안 주면 이걸 쓴다.
        public let defaultValue: String?
    }

    public struct Texture: Equatable, Sendable {
        public let name: String
        /// `g_Texture0` → 0. 재질의 `textures` 배열 순서와 맞물린다.
        public let index: Int
        /// 주석의 `default`. `util/noise` 같은 기본 텍스처 경로다.
        ///
        /// **모든 슬롯에 무엇이든 묶어야 한다.** Metal에서 안 묶인 텍스처를
        /// 샘플링하면 쓰레기가 나온다 — 화면에 자홍색 블록으로 보인다.
        public let defaultPath: String?
    }

    public struct Result: Equatable, Sendable {
        public let source: String
        public let uniforms: [Uniform]
        public let textures: [Texture]
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
        let truncated = rewritingSampleTruncation(stripped)
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
            if trimmed.hasPrefix("#require") { out.append(""); continue }
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
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//"), trimmed.contains("[COMBO]"),
                  let braceStart = trimmed.firstIndex(of: "{"),
                  let braceEnd = trimmed.lastIndex(of: "}"), braceStart < braceEnd,
                  let data = String(trimmed[braceStart...braceEnd]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["combo"] as? String, !name.isEmpty, !seen.contains(name)
            else { continue }
            seen.insert(name)
            out.append((name, (object["default"] as? NSNumber)?.intValue ?? 0))
        }
        return out
    }

    /// `uniform vec3 g_EyeColor;`에서 `g_EyeColor`.
    static func declaredName(in declaration: String) -> String? {
        declared(in: declaration)?.name
    }

    /// 이름과 배열 크기. `varying vec2 v_TexCoord[13];`는 이름 `v_TexCoord`,
    /// 크기 13이다. 크기를 버리면 구조체 멤버가 `float2` 하나가 되어
    /// `v_TexCoord[0] = vec2(...)`가 벡터 성분에 벡터를 넣는 꼴이 된다 —
    /// 실물 블러 계열 18개가 이 때문에 떨어졌다.
    static func declared(in declaration: String) -> (name: String, count: Int?)? {
        let cleaned = declaration.replacingOccurrences(of: ";", with: " ")
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        // `uniform` `타입` `이름` 순서다.
        guard words.count >= 3 else { return nil }
        let third = String(words[2])
        guard let bracket = third.firstIndex(of: "[") else {
            return third.isEmpty ? nil : (third, nil)
        }
        let name = String(third[..<bracket])
        let inside = third[third.index(after: bracket)...].prefix { $0.isNumber }
        guard !name.isEmpty else { return nil }
        return (name, Int(inside))
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

    /// WE의 셰이더 컴파일러는 HLSL식 **암묵적 벡터 절단**을 허용한다.
    /// 실물 `shimmer`가 이렇게 쓴다:
    /// ```glsl
    /// vec3 shimmerColor = texSample2D(g_Texture3, frac(shimmerCoord));  // float4를 vec3에
    /// ```
    /// C++에는 그런 변환이 없다. 실제로 나타나는 형태 — **샘플링 결과를 그대로
    /// 좁은 벡터에 넣는 선언** — 만 명시적 스위즐로 바꾼다. 표현식 전체를 이해하는
    /// 변환은 파서가 필요하고, 그건 이 번역기의 범위가 아니다. 못 고치는 형태는
    /// 컴파일 실패로 남고, 그 이펙트만 건너뛰면 된다.
    static func rewritingSampleTruncation(_ source: String) -> String {
        let swizzles = ["vec2": ".xy", "vec3": ".xyz"]
        var out: [String] = []
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 4, let swizzle = swizzles[words[0]], words[2] == "=",
                  words[3].hasPrefix("texSample2D"), trimmed.hasSuffix(");")
            else { out.append(String(line)); continue }
            // 이미 스위즐이 붙어 있으면(`).rgb;`) 위 검사에서 걸러진다 — 끝이 `);`가 아니다.
            let cut = String(line).index(String(line).endIndex, offsetBy: -1)
            out.append(String(String(line)[..<cut]) + swizzle + ";")
        }
        return out.joined(separator: "\n")
    }

    /// GLSL의 함수 인자 한정자를 MSL로 옮긴다.
    ///
    /// GLSL은 `void f(in vec3 a, out vec3 b, inout vec3 c)`를 쓴다. MSL에는 그런
    /// 한정자가 없고, 돌려주는 인자는 `thread T&` 참조다. `in`은 그냥 값이라 지운다.
    /// 안 고치면 `in`이 타입 이름으로 읽혀 그 헤더를 쓰는 셰이더가 전부 떨어진다
    /// (실물 28개). 인자 목록 안(여는 괄호나 쉼표 뒤)에서만 바꿔서, 본문에 우연히
    /// 나온 같은 낱말을 건드리지 않는다.
    static func rewritingParameterQualifiers(_ source: String) -> String {
        let types = "(?:vec[234]|mat[234]|float|int|uint|bool|ivec[234]|uvec[234])"
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
        /// 선언을 뺀 나머지 전부(함수, `#if`, `#define`).
        var body: String = ""
    }

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
            // 선언은 한 줄에 끝난다. 그렇지 않은 줄은 본문으로 넘긴다.
            guard words.count >= 3, trimmed.hasSuffix(";"),
                  ["uniform", "varying", "attribute"].contains(words[0]),
                  let (name, count) = declared(in: trimmed)
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
                parsed.textures.append(Texture(
                    name: name, index: textureIndex,
                    defaultPath: annotations[name].flatMap { stringValue($0["default"]) }))
                textureIndex += 1
            case "uniform":
                let annotation = annotations[name]
                parsed.uniforms.append(Uniform(
                    name: name, type: type,
                    materialKey: annotation?["material"] as? String,
                    defaultValue: annotation.flatMap { stringValue($0["default"]) }))
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

        out += "struct Uniforms {\n"
        for uniform in parsed.uniforms { out += "    \(uniform.type) \(uniform.name);\n" }
        // 빈 구조체는 MSL이 거부한다.
        if parsed.uniforms.isEmpty { out += "    float _unused;\n" }
        out += "};\n\n"

        // 셰이더 본문 전체를 담는 구조체. 여기서 전역이 멤버가 된다.
        out += "struct ShaderContext {\n"
        for uniform in parsed.uniforms { out += "    \(uniform.type) \(uniform.name);\n" }
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
        for texture in parsed.textures {
            arguments.append("texture2d<float> \(texture.name) [[texture(\(texture.index))]]")
            arguments.append("sampler \(texture.name)Sampler [[sampler(\(texture.index))]]")
        }

        var setup: [String] = []
        for uniform in parsed.uniforms {
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
            var copyOut: [String] = ["    varyingsOut.position = context.gl_Position;"]
            for varying in parsed.varyings {
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

        return Result(source: out, uniforms: parsed.uniforms, textures: parsed.textures)
    }

    /// 배열이면 `v_TexCoord_0`처럼 성분 이름으로 펼친다. 아니면 이름 하나.
    /// `stage_in` 구조체는 배열을 못 담는다 — 경계에서만 펼치고 안에서는 배열로 쓴다.
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
