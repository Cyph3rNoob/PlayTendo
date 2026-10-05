#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Un rectangle plein écran tracé avec 4 sommets générés à la volée.
vertex VertexOut gameVertex(uint vid [[vertex_id]]) {
    float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

struct GameUniforms {
    float2 textureSize;
    float scale;
};

// « Sharp bilinear » : les pixels restent nets comme en mode « plus proche voisin »,
// mais les bords sont lissés pour éviter les pixels de tailles inégales.
fragment float4 gameFragment(VertexOut in [[stage_in]],
                             texture2d<float> frame [[texture(0)]],
                             sampler linearSampler [[sampler(0)]],
                             constant GameUniforms &uniforms [[buffer(0)]]) {
    float2 texel = in.uv * uniforms.textureSize;
    float2 texelFloor = floor(texel);
    float2 offset = fract(texel) - 0.5;
    float range = 0.5 - 0.5 / uniforms.scale;
    float2 f = (offset - clamp(offset, -range, range)) * uniforms.scale + 0.5;
    float2 uv = (texelFloor + f) / uniforms.textureSize;
    return float4(frame.sample(linearSampler, uv).rgb, 1.0);
}
