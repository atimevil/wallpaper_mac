import XCTest
@testable import WallflowKit

/// WE의 GLSL 셰이더를 MSL로 옮긴다. 판정 기준은 "번역했다"가 아니라
/// **Metal이 컴파일하는가**다. assets 셰이더 346개로 재면 339개(98%)가 통과한다.
/// 여기 테스트는 그 결과를 만든 각 규칙이 실제로 필요한지 하나씩 고정한다.
final class GLSLTranslatorTests: XCTestCase {
    private func translate(
        _ source: String, stage: GLSLTranslator.Stage = .fragment,
        includes: [String: String] = [:]
    ) throws -> GLSLTranslator.Result {
        try GLSLTranslator.translate(
            source, stage: stage, entryPoint: "main0", includes: includes)
    }

    /// GLSL의 전역은 어느 함수에서나 보인다. MSL에서는 함수 인자라
    /// `main` **앞에 정의된 헬퍼**가 그것들을 못 본다 — 실물 13개가 이 때문에
    /// 떨어졌다. 셰이더 전체를 구조체에 담아 전역을 멤버로 만든 것이 그 답이다.
    func testHelperDefinedBeforeMainSeesUniformsAndTextures() throws {
        let result = try translate("""
        uniform sampler2D g_Texture0;
        uniform float g_Time;
        varying vec2 v_TexCoord;

        vec4 helper() { return texSample2D(g_Texture0, v_TexCoord * g_Time); }

        void main() { gl_FragColor = helper(); }
        """)
        // 헬퍼가 구조체 안에 들어가야 한다. 밖에 남으면 이름을 못 본다.
        let context = try XCTUnwrap(result.source.range(of: "struct ShaderContext {"))
        let helper = try XCTUnwrap(result.source.range(of: "vec4 helper()"))
        let closing = try XCTUnwrap(result.source.range(of: "\n};\n\n\nfragment"))
        XCTAssertTrue(context.upperBound < helper.lowerBound,
                      "헬퍼가 컨텍스트 구조체 앞에 있다")
        XCTAssertTrue(helper.upperBound < closing.lowerBound,
                      "헬퍼가 컨텍스트 구조체 밖에 있다")
        XCTAssertTrue(result.source.contains("    float g_Time;"))
        XCTAssertTrue(result.source.contains("    texture2d<float> g_Texture0;"))
        XCTAssertTrue(result.source.contains("    sampler g_Texture0Sampler;"))
    }

    /// `stage_in` 구조체에는 배열을 못 넣는다. 블러 계열이
    /// `varying vec2 v_TexCoord[13];`을 쓰므로 경계에서 성분으로 펼치고
    /// 안에서는 진짜 배열로 둔다. 크기를 아예 잃으면 `v_TexCoord[0] = vec2(...)`가
    /// 벡터 성분에 벡터를 넣는 꼴이 되어 그 셰이더가 떨어진다.
    func testArrayVaryingIsFlattenedAtTheBoundaryAndKeptInside() throws {
        let result = try translate("""
        varying vec2 v_TexCoord[3];
        void main() { gl_FragColor = vec4(v_TexCoord[2], 0.0, 1.0); }
        """)
        XCTAssertTrue(
            result.source.contains("    vec2 v_TexCoord_0 [[user(v_TexCoord_0)]];"),
            result.source)
        XCTAssertTrue(result.source.contains("    vec2 v_TexCoord_2 [[user(v_TexCoord_2)]];"))
        XCTAssertTrue(result.source.contains("    vec2 v_TexCoord[3];"), "안에서는 배열")
        XCTAssertTrue(result.source.contains("context.v_TexCoord[2] = varyingsIn.v_TexCoord_2;"))
    }

    /// 같은 varying이 `#if` 가지마다 다른 크기로 선언된다(13/7/3).
    /// 우리는 전처리기를 돌리지 않고 선언만 걷으므로 셋 다 걸린다 —
    /// 가장 큰 것을 남겨야 어느 가지가 켜져도 자리가 모자라지 않는다.
    func testLargestArraySizeWinsAcrossPreprocessorBranches() throws {
        let result = try translate("""
        #if KERNEL == 2
        varying vec2 v_TexCoord[3];
        #endif
        #if KERNEL == 0
        varying vec2 v_TexCoord[13];
        #endif
        void main() { gl_FragColor = vec4(v_TexCoord[0], 0.0, 1.0); }
        """)
        XCTAssertTrue(result.source.contains("    vec2 v_TexCoord[13];"), result.source)
        XCTAssertTrue(result.source.contains("    vec2 v_TexCoord_12 [[user(v_TexCoord_12)]];"))
    }

    /// 콤보는 `#if`에만 쓰이는 게 아니라 `ApplyBlending(BLENDMODE, ...)`처럼
    /// **값으로도** 쓰인다. 정의가 없으면 그 셰이더가 통째로 떨어진다(실물 35개).
    func testComboDefaultsAreDefinedButYieldToTheMaterial() throws {
        let result = try translate("""
        // [COMBO] {"combo":"BLENDMODE","type":"imageblending","default":2}
        void main() { gl_FragColor = vec4(float(BLENDMODE)); }
        """)
        XCTAssertTrue(result.source.contains("#ifndef BLENDMODE"), result.source)
        XCTAssertTrue(result.source.contains("#define BLENDMODE 2"))
    }

    /// `in`/`out`/`inout`은 GLSL의 인자 한정자다. MSL에는 없고, 돌려주는 인자는
    /// `thread T&`다. 안 고치면 `in`이 타입 이름으로 읽혀 그 헤더를 쓰는
    /// 셰이더가 전부 떨어진다(실물 28개).
    func testParameterQualifiersBecomeReferences() {
        let rewritten = GLSLTranslator.rewritingParameterQualifiers(
            "void f(in vec3 a, out vec3 b, inout float c, const vec2 d) {}")
        XCTAssertEqual(
            rewritten, "void f(vec3 a, thread vec3& b, thread float& c, const vec2 d) {}")
    }

    /// 본문에 우연히 나온 같은 낱말은 건드리지 않는다. 인자 목록 안에서만 바꾼다.
    func testQualifierRewriteLeavesBodyAlone() {
        let source = "void f() { float in_between = 1.0; float out2 = in_between; }"
        XCTAssertEqual(GLSLTranslator.rewritingParameterQualifiers(source), source)
    }

    /// WE는 HLSL식 암묵적 벡터 절단을 허용한다. 실물 `shimmer`가
    /// `vec3 c = texSample2D(...)`로 쓰는데 샘플링은 float4를 준다.
    func testSampleResultIsTruncatedExplicitly() {
        XCTAssertEqual(
            GLSLTranslator.rewritingSampleTruncation("\tvec3 c = texSample2D(g_T, uv);"),
            "\tvec3 c = texSample2D(g_T, uv).xyz;")
    }

    /// 이미 스위즐이 붙어 있으면 또 붙이면 안 된다.
    func testExistingSwizzleIsNotDoubled() {
        let source = "\tvec3 c = texSample2D(g_T, uv).rgb;"
        XCTAssertEqual(GLSLTranslator.rewritingSampleTruncation(source), source)
    }

    /// `vec4`는 절단이 아니다. 건드리면 `.xyz`가 붙어 성분이 하나 사라진다.
    func testVec4AssignmentIsUntouched() {
        let source = "\tvec4 c = texSample2D(g_T, uv);"
        XCTAssertEqual(GLSLTranslator.rewritingSampleTruncation(source), source)
    }

    /// 유니폼 주석이 씬 값과 이어 붙일 **유일한** 근거다.
    /// 주석을 지우기 전에 읽어야 한다.
    func testUniformAnnotationBecomesTheBindingTable() throws {
        let result = try translate("""
        uniform vec3 g_EyeColor; // {"material":"color","type":"color","default":"1 1 1"}
        uniform float g_Speed; // {"material":"speed","default":0.5}
        uniform float g_Time;
        void main() { gl_FragColor = vec4(g_EyeColor * g_Speed * g_Time, 1.0); }
        """)
        XCTAssertEqual(result.uniforms.map(\.name), ["g_EyeColor", "g_Speed", "g_Time"])
        XCTAssertEqual(result.uniforms[0].materialKey, "color")
        XCTAssertEqual(result.uniforms[0].defaultValue, "1 1 1")
        XCTAssertEqual(result.uniforms[1].materialKey, "speed")
        XCTAssertEqual(result.uniforms[1].defaultValue, "0.5")
        // 주석이 없는 유니폼은 씬이 값을 줄 수 없다. 엔진이 채운다.
        XCTAssertNil(result.uniforms[2].materialKey)
    }

    /// 텍스처 번호는 재질의 `textures` 배열 순서와 맞물린다. 어긋나면
    /// 엉뚱한 그림을 샘플링한다.
    func testTextureIndicesFollowDeclarationOrder() throws {
        let result = try translate("""
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        void main() { gl_FragColor = texSample2D(g_Texture1, vec2(0.0)); }
        """)
        XCTAssertEqual(result.textures.map(\.index), [0, 1])
        XCTAssertTrue(result.source.contains("texture2d<float> g_Texture1 [[texture(1)]]"))
        XCTAssertTrue(result.source.contains("sampler g_Texture1Sampler [[sampler(1)]]"))
    }

    /// 프리앰블이 이미 담고 있는 헤더는 다시 펼치지 않는다.
    /// 둘 다 펼치면 `hsv2rgb`가 재정의되어 그 셰이더가 떨어진다(실물 67개).
    func testCommonHeaderIsNotExpandedTwice() throws {
        let result = try translate(
            """
            #include "common.h"
            void main() { gl_FragColor = vec4(hsv2rgb(vec3(1.0)), 1.0); }
            """,
            includes: ["common.h": "vec3 hsv2rgb(vec3 c) { return c; }"])
        XCTAssertFalse(result.source.contains("vec3 hsv2rgb(vec3 c) { return c; }"),
                       "common.h를 또 펼쳤다")
        XCTAssertTrue(result.source.contains("inline float3 hsv2rgb"), "프리앰블 것이 있어야 한다")
    }

    func testOtherIncludesAreExpandedOnce() throws {
        let result = try translate(
            """
            #include "a.h"
            #include "a.h"
            void main() { gl_FragColor = vec4(0.0); }
            """,
            includes: ["a.h": "float aHelper() { return 1.0; }"])
        XCTAssertEqual(
            result.source.components(separatedBy: "float aHelper()").count - 1, 1,
            "같은 헤더를 두 번 펼치면 함수가 중복 정의된다")
    }

    /// 셰이더는 창작마당에서 온다. 상한이 없으면 이상한 파일 하나가 앱을 멈춘다.
    func testAbsurdlyLargeSourceIsRejected() {
        let huge = String(repeating: "a", count: GLSLTranslator.maxSourceBytes + 1)
        XCTAssertThrowsError(try translate(huge))
    }

    /// 서로를 부르는 헤더가 오면 무한히 펼쳐진다.
    func testCircularIncludeTerminates() throws {
        let result = try translate(
            "#include \"a.h\"\nvoid main() { gl_FragColor = vec4(0.0); }",
            includes: ["a.h": "#include \"b.h\"\nfloat a() { return 1.0; }",
                       "b.h": "#include \"a.h\"\nfloat b() { return 2.0; }"])
        XCTAssertEqual(result.source.components(separatedBy: "float a()").count - 1, 1)
    }

    /// `main`이 없으면 진입점을 만들 수 없다. 조용히 이상한 것을 내놓는 대신 실패한다.
    func testMissingMainIsReported() {
        XCTAssertThrowsError(try translate("uniform float g_Time;")) { error in
            XCTAssertEqual(error as? GLSLTranslator.Failure, .missingMain)
        }
    }

    /// 정점 셰이더는 `gl_Position`을 쓰고 varying에 값을 넣는다.
    func testVertexStageWritesPositionAndVaryings() throws {
        let result = try translate("""
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """, stage: .vertex)
        XCTAssertTrue(result.source.contains("vec3 a_Position [[attribute(0)]]"), result.source)
        XCTAssertTrue(result.source.contains("vec2 a_TexCoord [[attribute(1)]]"))
        XCTAssertTrue(result.source.contains("context.a_Position = vertexIn.a_Position;"))
        XCTAssertTrue(result.source.contains("varyingsOut.position = context.gl_Position;"))
        XCTAssertTrue(result.source.contains("varyingsOut.v_TexCoord = context.v_TexCoord;"))
    }

    /// 주석 안의 `{`가 중괄호 짝을 흔들면 안 된다.
    func testCommentsAreStrippedBeforeBraceMatching() throws {
        let result = try translate("""
        void main() {
            // 여는 중괄호 { 가 주석에 있다
            /* 여기도 { */
            gl_FragColor = vec4(1.0);
        }
        """)
        XCTAssertTrue(result.source.contains("gl_FragColor = vec4(1.0);"))
        XCTAssertTrue(result.source.contains("return context.gl_FragColor;"))
    }

    /// 위 두 규칙이 **파이프라인에 실제로 걸려 있는지** 본다.
    /// 헬퍼만 따로 부르는 테스트는 규칙이 연결되지 않아도 통과한다.
    func testRewritesAreAppliedByTranslate() throws {
        let result = try translate("""
        uniform sampler2D g_Texture0;
        void scatter(in vec2 uv, out vec3 result) {
            vec3 c = texSample2D(g_Texture0, uv);
            result = c;
        }
        void main() {
            vec3 out3;
            scatter(vec2(0.0), out3);
            gl_FragColor = vec4(out3, 1.0);
        }
        """)
        XCTAssertTrue(result.source.contains("void scatter(vec2 uv, thread vec3& result)"),
                      "인자 한정자 변환이 파이프라인에 안 걸려 있다")
        XCTAssertTrue(result.source.contains("texSample2D(g_Texture0, uv).xyz;"),
                      "절단 변환이 파이프라인에 안 걸려 있다")
    }

    /// 헬퍼는 컨텍스트 구조체 **안**에 있어야 유니폼과 텍스처를 본다.
    /// 진입점은 구조체 밖이어야 한다.
    func testEntryPointIsOutsideTheContextStruct() throws {
        let result = try translate("""
        uniform float g_Time;
        vec4 helper() { return vec4(g_Time); }
        void main() { gl_FragColor = helper(); }
        """)
        let source = result.source
        let contextStart = try XCTUnwrap(source.range(of: "struct ShaderContext {")).lowerBound
        let helper = try XCTUnwrap(source.range(of: "vec4 helper()")).lowerBound
        let mainWrapper = try XCTUnwrap(source.range(of: "void shaderMain()")).lowerBound
        let entry = try XCTUnwrap(source.range(of: "fragment float4 main0(")).lowerBound
        XCTAssertTrue(contextStart < helper, "헬퍼가 구조체 앞에 있다")
        // 순서만 보면 부족하다. 구조체가 헬퍼 **앞에서 닫혀** 있어도 순서는 그대로다.
        XCTAssertNil(source.range(of: "};", range: contextStart..<helper),
                     "구조체가 헬퍼 앞에서 닫혔다 — 헬퍼가 유니폼을 못 본다")
        XCTAssertTrue(helper < mainWrapper, "헬퍼가 shaderMain 뒤에 있다")
        XCTAssertTrue(mainWrapper < entry, "진입점이 구조체 안에 있다")
        // 구조체가 진입점 앞에서 닫혀야 한다.
        let closing = try XCTUnwrap(source.range(of: "};", range: mainWrapper..<entry))
        XCTAssertTrue(closing.lowerBound < entry)
    }

    /// 셰이더는 창작마당에서 온다. 어떤 쓰레기가 와도 **던지거나 지나가야** 하고
    /// 죽으면 안 된다. 상시 구동 앱에서 트랩 하나가 배경화면을 끝낸다.
    func testMalformedSourcesDoNotTrap() {
        let nasty = [
            "", "{", "}", "void main() {", "void main() }", "void main() {{{{",
            "uniform", "uniform vec3", "uniform vec3 x[", "uniform vec3 x[999999999999;",
            "varying vec2 v[;\nvoid main() { gl_FragColor = vec4(0.0); }",
            "// [COMBO] {\nvoid main() { gl_FragColor = vec4(0.0); }",
            "/* 안 닫힌 주석\nvoid main() { gl_FragColor = vec4(0.0); }",
            "#include \"\nvoid main() { gl_FragColor = vec4(0.0); }",
            "#include\nvoid main() { gl_FragColor = vec4(0.0); }",
        ]
        for source in nasty {
            for stage in [GLSLTranslator.Stage.vertex, .fragment] {
                // 결과가 무엇이든 좋다. 죽지만 않으면 된다.
                _ = try? GLSLTranslator.translate(source, stage: stage, entryPoint: "main0")
            }
        }
    }

    /// 정점과 프래그먼트는 **따로 컴파일된다**(Metal은 두 함수가 다른 라이브러리에
    /// 있어도 된다). 필드 순서로 맞물리면, 같은 varying이 `.vert`와 `.frag`에서
    /// 다른 순서로 선언될 때 값이 조용히 뒤바뀐다. 이름으로 맞물려야 한다.
    func testVaryingsAreMatchedByNameNotOrder() throws {
        let vertexSource = """
        attribute vec3 a_Position;
        varying vec2 v_A;
        varying vec4 v_B;
        void main() { gl_Position = vec4(a_Position, 1.0); v_A = vec2(0.0); v_B = vec4(0.0); }
        """
        // 프래그먼트는 순서가 반대다. 실물에서도 순서가 다른 짝이 있다.
        let fragmentSource = """
        varying vec4 v_B;
        varying vec2 v_A;
        void main() { gl_FragColor = v_B + vec4(v_A, 0.0, 0.0); }
        """
        let vertex = try translate(vertexSource, stage: .vertex)
        let fragment = try translate(fragmentSource)
        for source in [vertex.source, fragment.source] {
            XCTAssertTrue(source.contains("v_A [[user(v_A)]]"), source)
            XCTAssertTrue(source.contains("v_B [[user(v_B)]]"))
        }
    }

    /// **텍스처 번호는 선언 순서가 아니라 이름에서 온다.**
    /// 실물 `godrays_combine.frag`는 `g_Texture2`를 먼저 선언한다. 순서로 매기면
    /// 이펙트의 `bind`가 가리키는 슬롯과 어긋나 텍스처가 통째로 뒤섞이고,
    /// 합치기 셰이더가 엉뚱한 것을 읽어 화면이 하얘진다(실물에서 확인).
    func testTextureSlotComesFromTheNameNotDeclarationOrder() throws {
        let result = try translate("""
        uniform sampler2D g_Texture2;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.0)); }
        """)
        let slots = Dictionary(uniqueKeysWithValues: result.textures.map { ($0.name, $0.index) })
        XCTAssertEqual(slots["g_Texture0"], 0)
        XCTAssertEqual(slots["g_Texture1"], 1)
        XCTAssertEqual(slots["g_Texture2"], 2)
        XCTAssertTrue(result.source.contains("texture2d<float> g_Texture2 [[texture(2)]]"),
                      result.source)
    }

    /// 이름이 규칙에 안 맞으면 선언 순서로 매긴다. 그때만이다.
    func testUnnamedSamplersFallBackToDeclarationOrder() throws {
        let result = try translate("""
        uniform sampler2D myTexture;
        uniform sampler2D another;
        void main() { gl_FragColor = texSample2D(myTexture, vec2(0.0)); }
        """)
        XCTAssertEqual(result.textures.map(\.index), [0, 1])
    }

    /// 마스크는 `#if MASK`로 감싸여 있다. 씬이 그 슬롯에 텍스처를 주면 콤보를
    /// 켜야 하므로, 콤보 이름을 주석에서 들고 나와야 한다.
    func testTextureCarriesItsComboName() throws {
        let result = try translate("""
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"mode":"opacitymask","combo":"MASK"}
        void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.0)); }
        """)
        XCTAssertNil(result.textures[0].comboName)
        XCTAssertEqual(result.textures[1].comboName, "MASK")
    }

    /// HLSL은 실수에도 `%`를 쓴다 — 실물 오디오 막대가
    /// `uint barFreq = frequency % RESOLUTION;`처럼 쓴다. C++에서는 실수에 `%`를
    /// 못 쓰고 **내장 타입끼리는 연산자 오버로드도 안 되므로** 함수로 바꾼다.
    func testModuloBecomesAFunctionCall() {
        XCTAssertEqual(
            GLSLTranslator.rewritingModulo("uint a = frequency % RESOLUTION;"),
            "uint a = wfMod(frequency, RESOLUTION);")
        XCTAssertEqual(
            GLSLTranslator.rewritingModulo("uint b = (a + 1) % N;"),
            "uint b = wfMod((a + 1), N);")
    }

    /// 그 규칙이 **파이프라인에 실제로 걸려 있는지** 본다.
    /// 헬퍼만 따로 부르는 테스트는 연결이 끊겨도 통과한다.
    func testModuloRewriteIsAppliedByTranslate() throws {
        let result = try translate("""
        void main() {
            float frequency = 4.0;
            uint band = frequency % 32;
            gl_FragColor = vec4(float(band));
        }
        """)
        XCTAssertTrue(result.source.contains("wfMod(frequency, 32)"), result.source)
    }

    /// `%=`는 복합 대입이라 건드리면 안 된다.
    func testCompoundModuloIsUntouched() {
        let source = "x %= 4;"
        XCTAssertEqual(GLSLTranslator.rewritingModulo(source), source)
    }

    /// 전처리기 줄은 그대로 둔다. Metal의 전처리기가 처리한다.
    func testPreprocessorLineIsUntouched() {
        let source = "#if A % 2\nfloat x = 1.0;\n#endif"
        XCTAssertEqual(GLSLTranslator.rewritingModulo(source), source)
    }

    /// 배열 유니폼. 오디오 스펙트럼이 `uniform float g_AudioSpectrum32Left[32]`로 온다.
    func testArrayUniformKeepsItsLength() throws {
        let result = try translate("""
        uniform float g_AudioSpectrum32Left[32];
        void main() { gl_FragColor = vec4(g_AudioSpectrum32Left[3]); }
        """)
        XCTAssertEqual(result.uniforms.first?.count, 32)
        XCTAssertTrue(result.source.contains("float g_AudioSpectrum32Left[32];"), result.source)
        // 배열은 통째로 대입할 수 없다. 성분마다 옮겨야 한다.
        XCTAssertTrue(result.source.contains(
            "context.g_AudioSpectrum32Left[31] = uniforms.g_AudioSpectrum32Left[31];"))
    }
}
