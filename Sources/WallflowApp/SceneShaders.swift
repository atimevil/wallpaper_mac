enum SceneShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        // 파티클마다 다른 색·알파를 프래그먼트로 나른다.
        // quad_vertex도 반드시 채워야 한다 — 안 채우면 쓰레기 값이 넘어간다.
        float4 color;
        // 빌보드의 right/up을 **화면 uv 단위로** 옮긴 것. 굴절이 법선 지도를
        // 화면 좌표로 풀 때 쓴다. 굴절이 아닌 경로는 0으로 채운다.
        float4 screenTangents;
    };

    struct QuadUniforms {
        // 직교 공간에서의 중심과 크기
        float2 origin;
        float2 size;
        // 직교 공간의 전체 크기
        float2 projection;
        // 화면 맞춤(T6)이 캔버스에서 실제로 보이는 사각형. NDC는 world를 이걸로
        // 맞춰 잰다 — projection 그대로 나누면 늘이기(예전 동작)가 된다.
        // 화면을 꽉 채우기만 할 자리(합성 떠내기 목적지, 최종 표시)는 origin
        // (0,0)·size를 목적지 크기 그대로 줘 항등으로 만든다. 그러지 않으면
        // 맞춤이 두 번 걸린다.
        float2 visibleOrigin;
        float2 visibleSize;
        // 스프라이트 시트 프레임의 UV 사각형(0~1). 시트가 아니면 (0,0)/(1,1)이라
        // quad_vertex가 텍스처 전체를 그대로 읽는다.
        float2 uvOrigin;
        float2 uvScale;
        // 레이어 색과 투명도. 씬이 정한 alpha와 color다.
        float4 color;
        // 화면 평면 회전(라디안).
        float rotation;
        float _pad[3];
    };

    /// 원근 씬의 쿼드. 세계 변환과 카메라의 뷰·투영을 그대로 곱한다.
    /// 직교 경로와 달리 화면 크기로 나누지 않는다 — 크기는 세계 단위다.
    struct Quad3DUniforms {
        float4x4 model;
        float4x4 viewProjection;
        float4 color;
    };

    vertex VertexOut quad3d_vertex(
        VertexIn in [[stage_in]],
        constant Quad3DUniforms &u [[buffer(1)]]
    ) {
        // 단위 쿼드(-0.5..0.5)에 크기·회전·자리는 model 행렬에 들어 있다.
        float4 world = u.model * float4(in.position, 0.0, 1.0);
        VertexOut out;
        out.position = u.viewProjection * world;
        out.uv = float2(in.position.x + 0.5, 0.5 - in.position.y);
        out.color = u.color;
        out.screenTangents = float4(0.0);
        return out;
    }

    // 단위 쿼드(-0.5..0.5)를 직교 공간에 배치하고 클립 공간으로 옮긴다.
    vertex VertexOut quad_vertex(
        VertexIn in [[stage_in]],
        constant QuadUniforms &u [[buffer(1)]]
    ) {
        float2 scaled = in.position * u.size;
        // 회전이 0이면 cos=1, sin=0이라 그대로다. 분기하지 않는다.
        float c = cos(u.rotation), s = sin(u.rotation);
        float2 rotated = float2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
        // 씬의 직교 공간은 원점이 좌하단이고 Y가 위로 증가한다. 화면은 반대다.
        // **원점만** 뒤집는다 — NDC 자체를 뒤집으면 쿼드의 로컬 좌표까지 뒤집혀
        // 그림과 글자가 상하로 뒤집힌다.
        float2 world = float2(u.origin.x, u.projection.y - u.origin.y) + rotated;
        // 직교 공간 원점은 좌상단, Y는 아래로 증가한다. 화면 맞춤이 자른/남긴
        // 사각형(visibleOrigin·visibleSize) 기준으로 재므로, 채우기는 캔버스
        // 가장자리가 클립 공간 밖으로 나가 잘리고 전체 보기는 안쪽에 남는다.
        float2 ndc = float2(
            ((world.x - u.visibleOrigin.x) / u.visibleSize.x) * 2.0 - 1.0,
            1.0 - ((world.y - u.visibleOrigin.y) / u.visibleSize.y) * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        // 스프라이트 시트 한 칸만 읽는다. uvOrigin/uvScale이 기본값(0,0)/(1,1)이면
        // 예전과 똑같이 텍스처 전체를 읽는다.
        out.uv = u.uvOrigin + (in.position + 0.5) * u.uvScale;
        out.color = u.color;
        out.screenTangents = float4(0.0);
        return out;
    }

    /// 퍼펫 워프 메시. 정점은 단위 쿼드와 같은 공간(-0.5..0.5, +y가 화면 아래)에
    /// 있고 uv는 정점이 들고 있다 — 자리는 움직여도 그림의 어느 점인지는 그대로다.
    struct PuppetVertexIn {
        float2 position [[attribute(0)]];
        float2 uv [[attribute(1)]];
    };

    vertex VertexOut puppet_vertex(
        PuppetVertexIn in [[stage_in]],
        constant QuadUniforms &u [[buffer(1)]]
    ) {
        float2 scaled = in.position * u.size;
        float c = cos(u.rotation), s = sin(u.rotation);
        float2 rotated = float2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
        float2 world = float2(u.origin.x, u.projection.y - u.origin.y) + rotated;
        float2 ndc = float2(
            ((world.x - u.visibleOrigin.x) / u.visibleSize.x) * 2.0 - 1.0,
            1.0 - ((world.y - u.visibleOrigin.y) / u.visibleSize.y) * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = in.uv;
        out.color = u.color;
        out.screenTangents = float4(0.0);
        return out;
    }

    fragment float4 quad_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        // 레이어의 alpha와 color를 곱한다. 무시하면 반투명하게 설계된 UI가
        // 불투명한 상자로 그려진다.
        return tex.sample(samp, in.uv) * in.color;
    }

    // ---- 레이어 색 섞기 ----
    //
    // 값과 식은 WE 자신의 `shaders/common_blending.h`를 그대로 옮긴 것이다.
    // 눈으로 비슷하게 맞춘 근사가 아니다 — `BlendSoftLightf`의 `sqrt`나
    // `BlendColorDodgef`의 `blend == 1.0` 예외 같은 것은 지어낼 수 없다.
    //
    // `A`가 아래 화면, `B`가 이 레이어다. `opacity`는 이 레이어의 알파다.

    inline float wfScreenf(float a, float b) { return 1.0 - ((1.0 - a) * (1.0 - b)); }
    inline float wfOverlayf(float a, float b) {
        return a < 0.5 ? (2.0 * a * b) : (1.0 - 2.0 * (1.0 - a) * (1.0 - b));
    }
    inline float wfSoftLightf(float a, float b) {
        return (b < 0.5) ? (2.0 * a * b + a * a * (1.0 - 2.0 * b))
                         : (sqrt(a) * (2.0 * b - 1.0) + 2.0 * a * (1.0 - b));
    }
    inline float wfColorDodgef(float a, float b) {
        return (b == 1.0) ? b : min(a / (1.0 - b), 1.0);
    }
    inline float wfColorBurnf(float a, float b) {
        return (b == 0.0) ? b : max((1.0 - ((1.0 - a) / b)), 0.0);
    }
    inline float wfLinearBurnf(float a, float b) { return max(a + b - 1.0, 0.0); }
    inline float wfLinearLightf(float a, float b) {
        return b < 0.5 ? wfLinearBurnf(a, 2.0 * b) : (a + 2.0 * (b - 0.5));
    }
    inline float wfVividLightf(float a, float b) {
        return (b < 0.5) ? wfColorBurnf(a, 2.0 * b) : wfColorDodgef(a, 2.0 * (b - 0.5));
    }
    inline float wfPinLightf(float a, float b) {
        return (b < 0.5) ? min(a, 2.0 * b) : max(a, 2.0 * (b - 0.5));
    }
    inline float wfReflectf(float a, float b) {
        return (b == 1.0) ? b : min(a * a / (1.0 - b), 1.0);
    }
    inline float3 wfPerChannel3(float3 a, float3 b, float (*f)(float, float)) {
        return float3(f(a.r, b.r), f(a.g, b.g), f(a.b, b.b));
    }

    // HSL 계열(26~29). 헤더의 RGBToHSL/HSLToRGB를 그대로 옮긴다.
    inline float3 wfRGBToHSL(float3 color) {
        float3 hsl;
        float fmin = min(min(color.r, color.g), color.b);
        float fmax = max(max(color.r, color.g), color.b);
        float delta = fmax - fmin;
        hsl.z = (fmax + fmin) / 2.0;
        if (delta == 0.0) { hsl.x = 0.0; hsl.y = 0.0; return hsl; }
        hsl.y = hsl.z < 0.5 ? delta / (fmax + fmin) : delta / (2.0 - fmax - fmin);
        float dR = (((fmax - color.r) / 6.0) + (delta / 2.0)) / delta;
        float dG = (((fmax - color.g) / 6.0) + (delta / 2.0)) / delta;
        float dB = (((fmax - color.b) / 6.0) + (delta / 2.0)) / delta;
        if (color.r == fmax) hsl.x = dB - dG;
        else if (color.g == fmax) hsl.x = (1.0 / 3.0) + dR - dB;
        else hsl.x = (2.0 / 3.0) + dG - dR;
        if (hsl.x < 0.0) hsl.x += 1.0; else if (hsl.x > 1.0) hsl.x -= 1.0;
        return hsl;
    }

    inline float wfHueToRGB(float f1, float f2, float hue) {
        if (hue < 0.0) hue += 1.0; else if (hue > 1.0) hue -= 1.0;
        if ((6.0 * hue) < 1.0) return f1 + (f2 - f1) * 6.0 * hue;
        if ((2.0 * hue) < 1.0) return f2;
        if ((3.0 * hue) < 2.0) return f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0;
        return f1;
    }

    inline float3 wfHSLToRGB(float3 hsl) {
        if (hsl.y == 0.0) return float3(hsl.z);
        float f2 = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : (hsl.z + hsl.y) - (hsl.y * hsl.z);
        float f1 = 2.0 * hsl.z - f2;
        return float3(wfHueToRGB(f1, f2, hsl.x + (1.0 / 3.0)),
                      wfHueToRGB(f1, f2, hsl.x),
                      wfHueToRGB(f1, f2, hsl.x - (1.0 / 3.0)));
    }

    inline float3 wfBlend(int mode, float3 A, float3 B, float opacity) {
        switch (mode) {
        case 1: return mix(A, min(B, A), opacity);
        case 2: return mix(A, A * B, opacity);
        case 3: return mix(A, wfPerChannel3(A, B, wfColorBurnf), opacity);
        case 4: return mix(A, max(A + B - 1.0, 0.0), opacity);
        // 5와 10은 헤더에서도 불투명도를 쓰지 않는다.
        case 5: return min(A, B);
        case 6: return mix(A, max(B, A), opacity);
        case 7: return mix(A, wfPerChannel3(A, B, wfScreenf), opacity);
        case 8: return mix(A, wfPerChannel3(A, B, wfColorDodgef), opacity);
        case 9: return mix(A, min(A + B, float3(1.0)), opacity);
        case 10: return max(A, B);
        case 11: return mix(A, wfPerChannel3(A, B, wfOverlayf), opacity);
        case 12: return mix(A, wfPerChannel3(A, B, wfSoftLightf), opacity);
        // 하드라이트는 오버레이의 인자를 뒤집은 것이다.
        case 13: return mix(A, wfPerChannel3(B, A, wfOverlayf), opacity);
        case 14: return mix(A, wfPerChannel3(A, B, wfVividLightf), opacity);
        case 15: return mix(A, wfPerChannel3(A, B, wfLinearLightf), opacity);
        case 16: return mix(A, wfPerChannel3(A, B, wfPinLightf), opacity);
        case 17: return mix(A, float3(
            wfVividLightf(A.r, B.r) < 0.5 ? 0.0 : 1.0,
            wfVividLightf(A.g, B.g) < 0.5 ? 0.0 : 1.0,
            wfVividLightf(A.b, B.b) < 0.5 ? 0.0 : 1.0), opacity);
        case 18: return mix(A, abs(A - B), opacity);
        case 19: return mix(A, A + B - 2.0 * A * B, opacity);
        // 20은 헤더에서 4와 같은 식이다(Substract).
        case 20: return mix(A, max(A + B - 1.0, 0.0), opacity);
        case 21: return mix(A, wfPerChannel3(A, B, wfReflectf), opacity);
        // 글로우는 리플렉트의 인자를 뒤집은 것이다.
        case 22: return mix(A, wfPerChannel3(B, A, wfReflectf), opacity);
        case 23: return mix(A, min(A, B) - max(A, B) + float3(1.0), opacity);
        case 24: return mix(A, (A + B) / 2.0, opacity);
        case 25: return mix(A, float3(1.0) - abs(float3(1.0) - A - B), opacity);
        case 26: {
            float3 hsl = wfRGBToHSL(A);
            return mix(A, wfHSLToRGB(float3(wfRGBToHSL(B).r, hsl.g, hsl.b)), opacity);
        }
        case 27: {
            float3 hsl = wfRGBToHSL(A);
            return mix(A, wfHSLToRGB(float3(hsl.r, wfRGBToHSL(B).g, hsl.b)), opacity);
        }
        case 28: {
            float3 hsl = wfRGBToHSL(B);
            return mix(A, wfHSLToRGB(float3(hsl.r, hsl.g, wfRGBToHSL(A).b)), opacity);
        }
        case 29: {
            float3 hsl = wfRGBToHSL(A);
            return mix(A, wfHSLToRGB(float3(hsl.r, hsl.g, wfRGBToHSL(B).b)), opacity);
        }
        case 30: return mix(A, float3(max(A.x, max(A.y, A.z))) * B, opacity);
        case 31: return A + B * opacity;
        case 32: return mix(A, A + A * B, opacity);
        // 0과 모르는 번호는 보통 합성이다.
        default: return mix(A, B, opacity);
        }
    }

    /// 아래 화면을 읽어 직접 섞는다.
    ///
    /// `dst`는 이미 이 자리에 그려진 색이다(타일 메모리에서 그대로 읽는다).
    /// 그래서 이 파이프라인은 **고정 블렌딩을 끄고** 결과를 그대로 쓴다 —
    /// 켜 두면 우리가 섞은 것을 GPU가 한 번 더 섞는다.
    fragment float4 quad_blend_fragment(
        VertexOut in [[stage_in]],
        float4 dst [[color(0)]],
        constant int &mode [[buffer(0)]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 src = tex.sample(samp, in.uv) * in.color;
        float3 blended = wfBlend(mode, dst.rgb, src.rgb, saturate(src.a));
        // 알파는 아래가 이미 정한 것을 지키되, 이 레이어가 더 진하면 올린다.
        return float4(blended, max(dst.a, src.a));
    }

    fragment float4 solid_blend_fragment(
        VertexOut in [[stage_in]],
        float4 dst [[color(0)]],
        constant int &mode [[buffer(0)]],
        constant float4 &color [[buffer(1)]]
    ) {
        float3 blended = wfBlend(mode, dst.rgb, color.rgb, saturate(color.a));
        return float4(blended, max(dst.a, color.a));
    }

    /// 합성 레이어가 읽을 그림을 **레이어 좌표계로** 떠낸다.
    ///
    /// 입력은 그 지점까지 그려진 화면 전체다. 그대로 넘기면 이펙트가 화면
    /// 전체를 상대로 돌아, 상자 안에 그려야 할 오디오 막대가 화면 아래쪽에
    /// 그려지고 상자에는 배경만 비친다(실물 "Audio Visualizer"가 그랬다).
    ///
    /// 그래서 상자 크기의 텍스처를 만들고, 그 uv를 레이어의 자리·크기·회전으로
    /// 화면 좌표에 되돌려 읽는다. `quad_vertex`가 하는 배치의 역이다. 이렇게
    /// 뜨면 아무것도 안 하는 통과 레이어는 화면과 이어져 **보이지 않고**,
    /// 이펙트는 상자를 화면 삼아 돈다.
    fragment float4 composition_extract_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant QuadUniforms &u [[buffer(0)]]
    ) {
        float2 local = (in.uv - 0.5) * u.size;
        float c = cos(u.rotation), s = sin(u.rotation);
        float2 rotated = float2(local.x * c - local.y * s, local.x * s + local.y * c);
        float2 world = float2(u.origin.x, u.projection.y - u.origin.y) + rotated;
        // tex는 드로어블 크기 오프스크린이다 — 화면 맞춤으로 자른/남긴 사각형
        // 기준으로 읽어야 그 안에 실제로 그려진 그림을 짚는다.
        return tex.sample(samp, (world - u.visibleOrigin) / u.visibleSize);
    }

    fragment float4 solid_fragment(
        VertexOut in [[stage_in]],
        constant float4 &color [[buffer(0)]]
    ) {
        return color;
    }

    // ---- 파티클 ----

    struct ParticleInstance {
        packed_float3 position;
        float size;
        packed_float3 rotation;
        // 스프라이트 시트의 프레임 번호. 시트가 아니면 0이다.
        float frame;
        float4 color;
        // spritetrail이 속도 방향(레이어 배율 걸림, 거울상 반영)으로 늘여
        // 그리는 데 쓴다. 다른 렌더러는 무시한다.
        packed_float3 velocity;
        // 배율 걸기 **전** 속력 — clamp 크기는 이 값으로 잰다(size에 이미
        // 배율이 있어 velocity 크기까지 쓰면 두 번 걸린다). ParticleInstance.swift
        // 필드 주석 참고.
        float localSpeed;
    };

    struct ParticleUniforms {
        // 화면 맞춤(T6)이 캔버스에서 실제로 보이는 사각형. quad_vertex의
        // visibleOrigin/visibleSize와 같은 뜻이다.
        float2 visibleOrigin;
        float2 visibleSize;
        // 프레임 한 장이 시트에서 차지하는 비율. 시트가 아니면 (1,1)이다.
        float2 frameScale;
        float textureRatio;
        float framesPerRow;
        // 원근 씬이면 1. 그때는 visibleOrigin/visibleSize 대신 transform으로
        // 클립 공간에 놓는다.
        float useTransform;
        // spritetrail이면 1 — 속도 기반 트레일 축을 쓴다. 아니면(sprite·rope·
        // ropetrail, 후자 둘은 T8 전까지 스프라이트로 그린다) 회전 기반 축이다.
        float isTrail;
        // `g_RenderVar0`(length, maxlength, minlength). isTrail이 0이면 안 쓴다.
        float trailLength;
        float trailMaxLength;
        float trailMinLength;
        // 레이어의 세계 변환 × 카메라 뷰·투영. 파티클 좌표는 레이어 기준이다.
        float4x4 transform;
    };

    // common_particles.h의 ComputeParticleTangents를 옮긴 것.
    // 회전 행렬 세 축을 곱해 빌보드의 right/up을 만든다.
    static void particleTangents(float3 rotation, thread float3 &right, thread float3 &up) {
        float3 c = cos(rotation);
        float3 s = sin(rotation);
        float3x3 rz = float3x3(float3(c.z, -s.z, 0), float3(s.z, c.z, 0), float3(0, 0, 1));
        float3x3 rx = float3x3(float3(1, 0, 0), float3(0, c.x, -s.x), float3(0, s.x, c.x));
        float3x3 ry = float3x3(float3(c.y, 0, s.y), float3(0, 1, 0), float3(-s.y, 0, c.y));
        float3x3 m = rz * rx * ry;
        right = m[0];
        up = m[1];
    }

    // common_particles.h의 ComputeParticleTrailTangents를 옮긴 것.
    // velocity는 방향(레이어 배율 걸림)용, localSpeed는 clamp 크기(배율 걸기
    // 전, WE가 로컬 공간에서 계산하는 것과 같다)용으로 나뉜다 — 하나로 합치면
    // 레이어 배율이 clamp에 두 번 걸린다. 속도 0·NaN이거나 velocity가
    // eyeDirection과 평행(3D spritetrail에서 순수 z 속도)이면 false를 돌려
    // 호출자가 스프라이트 경로(회전 기반 축)로 떨어지게 한다 — Kit의
    // ParticleTrailTangent.compute와 같은 분기다.
    static bool particleTrailTangents(
        float3 velocity, float localSpeed, float trailLength, float trailMaxLength,
        float trailMinLength, thread float3 &right, thread float3 &up
    ) {
        // `speed <= 0`이 아니라 `!(speed > 0)`을 쓴다 — NaN과의 비교는 항상
        // false라 `<=`는 NaN을 통과시키지만 `!(>)`은 막는다.
        if (!(localSpeed > 0)) return false;
        float dirLength = length(velocity);
        if (!(dirLength > 0)) return false;
        // 직교 2D 시선. 카메라가 +z에 있고 -z를 보는 쪽으로 뒀다 — 세로 속도
        // (0,1,0)일 때 cross((0,0,-1),(0,1,0)) = (1,0,0)이 스프라이트 기본
        // right(회전 0일 때 (1,0,0))와 같은 부호라 텍스처가 안 뒤집힌다.
        // (right,up) 기저의 행렬식이 vx²+vy² > 0이라 z 평면 위 속도에서는
        // 항상 오른손 방향 — 거울상이 될 일이 없다.
        float3 eyeDirection = float3(0, 0, -1);
        float3 rawRight = cross(eyeDirection, velocity);
        float rightLength = length(rawRight);
        // velocity가 eyeDirection과 평행하면(3D spritetrail의 순수 z 속도)
        // cross가 0이라 나눗셈이 NaN을 낳는다 — 그 전에 막는다.
        if (!(rightLength > 0)) return false;
        right = rawRight / rightLength;
        up = (velocity / dirLength)
            * max(trailMinLength, min(localSpeed * trailLength, trailMaxLength));
        return true;
    }

    // 인스턴스마다 정점 4개를 펼친다. 지오메트리 셰이더가 필요 없다 —
    // genericparticle의 GS_ENABLED = 0 경로와 같은 방식이다.
    vertex VertexOut particle_vertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        constant ParticleInstance *instances [[buffer(2)]],
        constant ParticleUniforms &u [[buffer(3)]]
    ) {
        // 삼각형 스트립 코너: (0,0) (1,0) (0,1) (1,1)
        float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
        ParticleInstance p = instances[iid];

        float3 right, up;
        bool drewTrail = false;
        if (u.isTrail > 0.5) {
            drewTrail = particleTrailTangents(
                float3(p.velocity), p.localSpeed, u.trailLength, u.trailMaxLength,
                u.trailMinLength, right, up);
        }
        if (!drewTrail) {
            particleTangents(float3(p.rotation), right, up);
        }

        // ComputeParticlePosition 그대로.
        float3 world = float3(p.position)
            + p.size * right * (corner.x - 0.5)
            - p.size * up * (corner.y - 0.5) * u.textureRatio;

        // 파티클 위치 계산은 씬 좌표계(Y가 위로 증가)에서 이뤄진다. 중력이 -Y인
        // 것도 그래서다. quad_vertex와 달리 Y를 뒤집지 않는다 — 파티클 world는
        // 이미 y-up이라 NDC의 y-up과 방향이 같다(화면 맞춤 사각형만 끼운다).
        float2 ndc = float2(((world.x - u.visibleOrigin.x) / u.visibleSize.x) * 2.0 - 1.0,
                            ((world.y - u.visibleOrigin.y) / u.visibleSize.y) * 2.0 - 1.0);
        // 스프라이트 시트면 코너를 그 프레임의 칸으로 옮긴다. 안 그러면 파티클
        // 하나가 시트 전체(꽃잎 5장)를 한 칸에 뭉개 그린다.
        float col = fmod(p.frame, u.framesPerRow);
        float row = floor(p.frame / u.framesPerRow);

        VertexOut out;
        // 원근 씬에서는 파티클이 레이어의 세계 공간에 놓인 판이다. 실물 시계의
        // 오브가 그것이다 — 스크립트가 레이어 원점을 3D로 돌린다.
        out.position = u.useTransform > 0.5
            ? u.transform * float4(world, 1.0)
            : float4(ndc, 0.0, 1.0);
        out.uv = (corner + float2(col, row)) * u.frameScale;
        out.color = p.color;
        // `common_particles.h`의 `ComputeScreenRefractionTangents` 그대로다.
        //
        //   right = normalize(right); up = normalize(up);
        //   tangents.xy = (dot(right, g_ViewRight), dot(up, g_ViewRight));
        //   tangents.zw = (dot(right, g_ViewUp),    dot(up, g_ViewUp));
        //
        // **크기가 곱해지지 않는다.** 빌보드의 축을 화면 축에 투영한 방향일
        // 뿐이고, 미는 정도는 재질의 `refract_amount` 하나가 정한다. 크기를
        // 곱하면 큰 물방울이 화면을 통째로 밀어 얼굴이 뭉개진다(실물에서 확인).
        // 직교 2D라 g_ViewRight/g_ViewUp은 (1,0,0)/(0,1,0)이다.
        float3 nRight = normalize(right);
        float3 nUp = normalize(up);
        out.screenTangents = float4(nRight.x, nUp.x, nRight.y, nUp.y);
        return out;
    }

    // 로프·로프 트레일 정점. CPU(`RopeGeometry` + `ParticleRenderer.updateRope`)가
    // 씬 좌표(레이어 원점·배율까지 적용)로 이미 옮긴 점을 그대로 받아, particle_vertex와
    // 같은 T6 화면 맞춤((world - visibleOrigin)/visibleSize)만 한 번 더 건다.
    // Swift의 `RopeVertex`와 배치가 같아야 한다 — 48바이트.
    struct RopeVertex {
        packed_float3 position;
        float u;
        float v;
        float4 color;
    };

    vertex VertexOut rope_vertex(
        uint vid [[vertex_id]],
        constant RopeVertex *verts [[buffer(2)]],
        constant ParticleUniforms &u [[buffer(3)]]
    ) {
        RopeVertex in = verts[vid];
        float3 world = float3(in.position);

        float2 ndc = float2(((world.x - u.visibleOrigin.x) / u.visibleSize.x) * 2.0 - 1.0,
                            ((world.y - u.visibleOrigin.y) / u.visibleSize.y) * 2.0 - 1.0);

        VertexOut out;
        out.position = u.useTransform > 0.5
            ? u.transform * float4(world, 1.0)
            : float4(ndc, 0.0, 1.0);
        out.uv = float2(in.u, in.v);
        out.color = in.color;
        out.screenTangents = float4(0, 0, 0, 0);
        return out;
    }

    fragment float4 particle_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return tex.sample(samp, in.uv) * in.color;
    }

    /// 굴절 파티클. `genericparticle.frag`의 `REFRACT` 경로를 옮긴 것이다.
    ///
    /// 법선 지도로 화면 좌표를 밀어 **뒤에 이미 그려진 화면**을 그 자리에서
    /// 읽고, 파티클 색에 곱한다. 그래서 유리구슬처럼 배경이 휜다.
    /// 원문:
    ///   screenRefractionOffset = v_ScreenTangents.xy * normal.x
    ///                          + v_ScreenTangents.zw * normal.y;
    ///   screenRefractionOffset *= normal.a * v_Color.a;
    ///   color.rgb *= texSample2D(g_Texture3, refractTexCoord).rgb;
    fragment float4 particle_refract_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        texture2d<float> normalMap [[texture(1)]],
        texture2d<float> background [[texture(2)]],
        sampler samp [[sampler(0)]],
        // x·y는 화면 픽셀 크기, z는 재질의 refract_amount.
        constant float3 &screen [[buffer(0)]]
    ) {
        float4 color = tex.sample(samp, in.uv) * in.color;
        float4 n = normalMap.sample(samp, in.uv);
        // `common_fragment.h`의 `DecompressNormalWithMask` 그대로다. **x는 알파에서
        // 오고, 마스크는 빨강에서 온다**(`normal.xw = normal.wx`) — 흔한
        // "법선은 AG, 마스크는 R" 포장이다. 빨강을 x로 읽으면 마스크가 법선
        // 자리로 들어가 물방울마다 화면이 통째로 밀린다(실물에서 확인).
        float2 normal = float2(n.a, n.g) * 2.0 - 1.0;
        float mask = n.r;
        float2 offset = (in.screenTangents.xy * normal.x + in.screenTangents.zw * normal.y)
            * screen.z * mask * in.color.a;
        // 원문은 GL에서 offset.y를 뒤집는다. 그쪽 화면 uv는 y가 위로 증가하고
        // 우리 것은 아래로 증가하니, 뒤집기가 한 번 더 걸려 서로 지워진다.
        float2 screenUV = in.position.xy / max(screen.xy, float2(1.0)) + offset;
        color.rgb *= background.sample(samp, saturate(screenUV)).rgb;
        return color;
    }
    """
}
