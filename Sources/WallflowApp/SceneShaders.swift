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
    };

    struct QuadUniforms {
        // 직교 공간에서의 중심과 크기
        float2 origin;
        float2 size;
        // 직교 공간의 전체 크기
        float2 projection;
    };

    // 단위 쿼드(-0.5..0.5)를 직교 공간에 배치하고 클립 공간으로 옮긴다.
    vertex VertexOut quad_vertex(
        VertexIn in [[stage_in]],
        constant QuadUniforms &u [[buffer(1)]]
    ) {
        float2 world = u.origin + in.position * u.size;
        // 직교 공간 원점은 좌상단, Y는 아래로 증가한다.
        float2 ndc = float2(
             (world.x / u.projection.x) * 2.0 - 1.0,
            1.0 - (world.y / u.projection.y) * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = in.position + 0.5;
        return out;
    }

    fragment float4 quad_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return tex.sample(samp, in.uv);
    }
    """
}
