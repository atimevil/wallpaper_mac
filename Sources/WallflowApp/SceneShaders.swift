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
    };

    struct QuadUniforms {
        // 직교 공간에서의 중심과 크기
        float2 origin;
        float2 size;
        // 직교 공간의 전체 크기
        float2 projection;
        // 레이어 색과 투명도. 씬이 정한 alpha와 color다.
        float4 color;
        // 화면 평면 회전(라디안).
        float rotation;
        float _pad[3];
    };

    // 단위 쿼드(-0.5..0.5)를 직교 공간에 배치하고 클립 공간으로 옮긴다.
    vertex VertexOut quad_vertex(
        VertexIn in [[stage_in]],
        constant QuadUniforms &u [[buffer(1)]]
    ) {
        float2 scaled = in.position * u.size;
        // 회전이 0이면 cos=1, sin=0이라 그대로다. 분기하지 않는다.
        float c = cos(u.rotation), s = sin(u.rotation);
        float2 rotated = float2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
        float2 world = u.origin + rotated;
        // 직교 공간 원점은 좌상단, Y는 아래로 증가한다.
        float2 ndc = float2(
             (world.x / u.projection.x) * 2.0 - 1.0,
            1.0 - (world.y / u.projection.y) * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = in.position + 0.5;
        out.color = u.color;
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
    };

    struct ParticleUniforms {
        float2 projection;
        // 프레임 한 장이 시트에서 차지하는 비율. 시트가 아니면 (1,1)이다.
        float2 frameScale;
        float textureRatio;
        float framesPerRow;
        float2 _pad;
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
        particleTangents(float3(p.rotation), right, up);

        // ComputeParticlePosition 그대로.
        float3 world = float3(p.position)
            + p.size * right * (corner.x - 0.5)
            - p.size * up * (corner.y - 0.5) * u.textureRatio;

        float2 ndc = float2((world.x / u.projection.x) * 2.0 - 1.0,
                            1.0 - (world.y / u.projection.y) * 2.0);
        // 스프라이트 시트면 코너를 그 프레임의 칸으로 옮긴다. 안 그러면 파티클
        // 하나가 시트 전체(꽃잎 5장)를 한 칸에 뭉개 그린다.
        float col = fmod(p.frame, u.framesPerRow);
        float row = floor(p.frame / u.framesPerRow);

        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = (corner + float2(col, row)) * u.frameScale;
        out.color = p.color;
        return out;
    }

    fragment float4 particle_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return tex.sample(samp, in.uv) * in.color;
    }
    """
}
