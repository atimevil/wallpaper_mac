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
        /// 배열이면 그 길이. `uniform float g_AudioSpectrum32Left[32]`가 이 꼴이다.
        public let count: Int?
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
        let modulo = rewritingModulo(stripped)
        let renamed = rewritingReservedIdentifiers(modulo)
        let arrays = rewritingArrayConstructors(renamed)
        let truncated = rewritingTruncation(arrays)
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
            varyingWidth[words[2]] = width
        }

        var out: [String] = []
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let rewritten = wrappedInitializer(line, widths: widths,
                                                     varyingWidth: varyingWidth)
            else { out.append(line); continue }
            out.append(rewritten)
        }
        return out.joined(separator: "\n")
    }

    /// 한 줄이 `TYPE NAME = EXPR;`이거나 `VARYING = EXPR;`이면 EXPR을 감싼다.
    /// 아니면 nil.
    private static func wrappedInitializer(
        _ line: String, widths: [String: Int], varyingWidth: [String: Int]
    ) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 한 문장만 다룬다. `;`가 둘이면 for 머리이거나 두 문장이다.
        guard trimmed.hasSuffix(";"), trimmed.filter({ $0 == ";" }).count == 1,
              !trimmed.contains("wfTo"), !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        // `==`, `<=`, `+=` 같은 것은 대입이 아니다.
        let afterEquals = trimmed.index(after: equals)
        guard afterEquals < trimmed.endIndex, trimmed[afterEquals] != "=" else { return nil }
        let before = trimmed.index(before: equals)
        guard !"+-*/<>!&|^%".contains(trimmed[before]) else { return nil }

        let lhs = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        var rhs = trimmed[afterEquals...].trimmingCharacters(in: .whitespaces)
        rhs.removeLast()  // `;`
        // 배열 초기화와 빈 값은 건드리지 않는다.
        guard !rhs.isEmpty, !rhs.hasPrefix("{"), !topLevelCommaOrAssignment(in: rhs) else {
            return nil
        }

        var lhsWords = lhs.split(whereSeparator: \.isWhitespace).map(String.init)
        if lhsWords.first == "const" { lhsWords.removeFirst() }
        let width: Int
        switch lhsWords.count {
        case 2:
            // `TYPE NAME`. 이름에 `[`가 있으면 배열 선언이다.
            guard let w = widths[lhsWords[0]], !lhsWords[1].contains("[") else { return nil }
            width = w
        case 1:
            // `NAME`. 스위즐(`v.xy = …`)이나 첨자는 받는 쪽 타입이 달라 건너뛴다.
            guard let w = varyingWidth[lhsWords[0]] else { return nil }
            width = w
        default:
            return nil
        }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return "\(indent)\(lhs) = wfTo\(width)(\(rhs));"
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
                    count: count))
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

        out += "struct Uniforms {\n"
        for uniform in parsed.uniforms {
            let array = uniform.count.map { "[\($0)]" } ?? ""
            out += "    \(uniform.type) \(uniform.name)\(array);\n"
        }
        // 빈 구조체는 MSL이 거부한다.
        if parsed.uniforms.isEmpty { out += "    float _unused;\n" }
        out += "};\n\n"

        // 셰이더 본문 전체를 담는 구조체. 여기서 전역이 멤버가 된다.
        out += "struct ShaderContext {\n"
        for uniform in parsed.uniforms {
            let array = uniform.count.map { "[\($0)]" } ?? ""
            out += "    \(uniform.type) \(uniform.name)\(array);\n"
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
            guard let count = uniform.count else {
                setup.append("    context.\(uniform.name) = uniforms.\(uniform.name);")
                continue
            }
            // 배열은 통째로 대입할 수 없다. 성분마다 옮긴다.
            for index in 0..<count {
                setup.append(
                    "    context.\(uniform.name)[\(index)] = uniforms.\(uniform.name)[\(index)];")
            }
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
