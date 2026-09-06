import Foundation

/// 번역한 셰이더 앞에 붙이는 MSL 조각.
///
/// Wallpaper Engine의 셰이더는 GLSL이지만, WE가 HLSL식 이름을 얹은 호환 계층
/// 위에서 쓰인다 — `mul`·`frac`·`saturate`·`texSample2D`·`CAST3` 같은 것들이다.
/// 이것들을 **번역하지 않는다.** 여기 한 번 써 두면 번역기는 선언과 진입점만
/// 다루면 된다. assets 셰이더 466개에서 가장 많이 불리는 것이
/// `texSample2D`(1026회)와 `mul`(318회)인데, 둘 다 여기서 끝난다.
public enum ShaderPrelude {
    /// 타입 별칭. GLSL의 `vec2`는 MSL의 `float2`다.
    /// 이름만 다르고 의미가 같아 별칭으로 끝난다 — 본문을 건드릴 이유가 없다.
    public static let types = """
    using namespace metal;

    #define vec2 float2
    #define vec3 float3
    #define vec4 float4
    #define ivec2 int2
    #define ivec3 int3
    #define ivec4 int4
    #define uvec2 uint2
    #define mat2 float2x2
    #define mat3 float3x3
    #define mat4 float4x4
    """

    /// WE 호환 헬퍼와 `shaders/common.h`(37줄)의 함수들.
    ///
    /// `mul(v, m)`은 **행벡터 관례**다. GLSL 쪽 셰이더가 전부
    /// `mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix)`로 쓰므로
    /// 벡터가 왼쪽이다. MSL에서 그 뜻은 `v * m`이고 `m * v`가 아니다 —
    /// 뒤집으면 행렬이 전치되어 모든 변환이 어긋난다.
    public static let helpers = """
    #define frac fract
    // GLSL의 `mod`는 MSL의 `fmod`다.
    #define mod fmod
    #define lerp mix
    // `atan2(y, x)`는 Metal에 이미 있다. `atan`으로 바꾸면 인자 둘짜리가 없어 떨어진다.
    #define ddx dfdx
    #define ddy dfdy
    #define clip(x) do { if ((x) < 0.0) { discard_fragment(); } } while (false)

    #define CASTF(x) float(x)
    #define CAST2(x) float2(x)
    #define CAST3(x) float3(x)
    #define CAST4(x) float4(x)
    #define CAST3X3(x) float3x3(x)
    #define CASTU(x) uint(x)

    // `saturate`는 Metal에 이미 있다. 우리가 또 만들면 호출이 모호해져
    // 그 셰이더가 통째로 컴파일에 실패한다(실물 8개가 이 때문에 떨어졌다).

    // 행벡터 관례. v가 왼쪽이다.
    inline float2 mul(float2 v, float2x2 m) { return v * m; }
    inline float3 mul(float3 v, float3x3 m) { return v * m; }
    inline float4 mul(float4 v, float4x4 m) { return v * m; }
    inline float3 mul(float3x3 m, float3 v) { return m * v; }
    inline float4 mul(float4x4 m, float4 v) { return m * v; }

    // `shaders/common.h`(37줄). 이 파일은 `#include`로 208곳에서 쓰이지만
    // 여기 이미 있으므로 번역기가 그 include를 건너뛴다 — 둘 다 펼치면
    // `hsv2rgb`가 재정의되어 그 셰이더가 통째로 떨어진다(실물 67개).
    // `M_PI`는 Metal이 이미 준다. 다시 정의하면 매크로 재정의 경고가 난다.
    // Metal은 `M_PI_F`를 주지만 셰이더는 `M_PI`라고 쓴다.
    #define M_PI 3.14159265359
    #define M_PI_HALF 1.57079632679
    #define M_PI_2 6.28318530718
    #define SQRT_2 1.41421356237
    #define SQRT_3 1.73205080756

    inline float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

    inline float3 rgb2hsv(float3 RGB) {
        float4 P = (RGB.g < RGB.b) ? float4(RGB.bg, -1.0, 2.0 / 3.0)
                                   : float4(RGB.gb, 0.0, -1.0 / 3.0);
        float4 Q = (RGB.r < P.x) ? float4(P.xyw, RGB.r) : float4(RGB.r, P.yzx);
        float C = Q.x - min(Q.w, Q.y);
        float H = abs((Q.w - Q.y) / (6.0 * C + 1e-10) + Q.z);
        float3 HCV = float3(H, C, Q.x);
        float S = HCV.y / (HCV.z + 1e-10);
        return float3(HCV.x, S, HCV.z);
    }

    inline float2 rotateVec2(float2 v, float r) {
        float2 cs = float2(cos(r), sin(r));
        return float2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
    }

    // GLSL의 `inverse()`. Metal에는 없다.
    inline float2x2 inverse(float2x2 m) {
        float d = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        return float2x2(float2(m[1][1], -m[0][1]), float2(-m[1][0], m[0][0])) * (1.0 / d);
    }

    inline float3x3 inverse(float3x3 m) {
        float3 a = cross(m[1], m[2]);
        float3 b = cross(m[2], m[0]);
        float3 c = cross(m[0], m[1]);
        float d = dot(m[2], c);
        return float3x3(float3(a.x, b.x, c.x), float3(a.y, b.y, c.y), float3(a.z, b.z, c.z))
            * (1.0 / d);
    }

    inline float greyscale(float3 color) {
        return dot(color, float3(0.11, 0.59, 0.3));
    }

    // WE의 셰이더 컴파일러는 HLSL식 **암묵적 벡터 절단**을 허용한다 —
    // 실물 `shimmer`가 `rotateVec2(v_TexCoord, ...)`를 vec4로 부른다.
    // C++에는 그런 변환이 없으므로 뜻을 그대로 적은 오버로드를 둔다.
    inline float2 rotateVec2(float3 v, float r) { return rotateVec2(v.xy, r); }
    inline float2 rotateVec2(float4 v, float r) { return rotateVec2(v.xy, r); }
    inline float greyscale(float4 color) { return greyscale(color.rgb); }
    """

    /// 텍스처 샘플링.
    ///
    /// MSL에서는 텍스처와 샘플러가 **분리된 인자**라 GLSL의 `sampler2D` 하나로는
    /// 표현되지 않는다. 번역기가 `uniform sampler2D g_Texture0`을 텍스처 인자
    /// `g_Texture0`과 샘플러 `g_Texture0Sampler` 둘로 쪼개고, 이 매크로가 둘을
    /// 다시 묶는다. 인자 이름 규칙이 매크로와 번역기 양쪽에 걸려 있다.
    public static let sampling = """
    #ifdef WF_FORCE_GREEN
    #define texSample2D(tex, uv) float4(0.0, 1.0, 0.0, 1.0)
    #else
    #define texSample2D(tex, uv) tex.sample(tex##Sampler, (uv))
    #endif
    #define texSample2DLod(tex, uv, lod) tex.sample(tex##Sampler, (uv), level(lod))
    #define texSample2DCompare(tex, uv, z) tex.sample(tex##Sampler, (uv))
    """

    /// 번역기가 셰이더 앞에 붙이는 전체 조각.
    public static var all: String { [types, helpers, sampling].joined(separator: "\n\n") }
}
