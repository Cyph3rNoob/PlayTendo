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
    float scale;     // agrandissement entier (pixels de l'écran par pixel de la console, au moins 1)
    float flip;      // 1 = image à l'envers verticalement (rendu OpenGL)
    float4 source;   // partie de l'image à afficher (x, y, largeur, hauteur), de 0 à 1
    float4 filter;   // x : 0 net, 1 lissé, 2 lignes CRT, 3 grille LCD (consoles 2D, FilterSettings)
};

// « Sharp bilinear » : les pixels restent nets comme en mode « plus proche voisin »,
// mais les bords sont lissés pour éviter les pixels de tailles inégales. Filtres des consoles 2D par-dessus.
fragment float4 gameFragment(VertexOut in [[stage_in]],
                             texture2d<float> frame [[texture(0)]],
                             sampler linearSampler [[sampler(0)]],
                             constant GameUniforms &uniforms [[buffer(0)]]) {
    float mode = uniforms.filter.x;
    float2 uvIn = in.uv;
    if (uniforms.flip > 0.5) uvIn.y = 1.0 - uvIn.y;
    float2 full = uniforms.source.xy + uvIn * uniforms.source.zw;
    float2 texel = full * uniforms.textureSize;
    float2 texelFloor = floor(texel);
    float2 offset = fract(texel) - 0.5;
    // Lissé : agrandissement bilinéaire ordinaire (comme un agrandissement de 1, sans bord net).
    float sharpness = (mode > 0.5 && mode < 1.5) ? 1.0 : uniforms.scale;
    float range = 0.5 - 0.5 / sharpness;
    float2 f = (offset - clamp(offset, -range, range)) * sharpness + 0.5;
    float2 uv = (texelFloor + f) / uniforms.textureSize;
    // Ne jamais déborder sur la partie voisine (l'autre écran de la DS).
    float2 low = (uniforms.source.xy * uniforms.textureSize + 0.5) / uniforms.textureSize;
    float2 high = ((uniforms.source.xy + uniforms.source.zw) * uniforms.textureSize - 0.5) / uniforms.textureSize;
    float3 color = frame.sample(linearSampler, clamp(uv, low, high)).rgb;

    float2 cell = fract(texel);  // position dans le pixel de la console, de 0 à 1
    if (mode > 1.5 && mode < 2.5) {
        // CRT : chaque ligne de la console est un trait de lumière, plus sombre entre deux lignes ; luminosité
        // remontée pour compenser.
        float d = cell.y - 0.5;
        color *= mix(0.45, 1.0, exp(-d * d * 14.0)) * 1.18;
    } else if (mode > 2.5) {
        // LCD : fine grille sombre entre les pixels, comme l'écran d'une Game Boy (environ un pixel de l'écran).
        float2 edge = min(cell, 1.0 - cell) * uniforms.scale;
        color *= mix(0.72, 1.0, smoothstep(0.0, 1.0, min(edge.x, edge.y)));
    }
    return float4(min(color, 1.0), 1.0);
}

// Lissage des bords (FXAA, d'après la version simple de Timothy Lottes), à la taille de l'image du jeu, avant son
// agrandissement par gameFragment. Sert à la PS1, dont le moteur n'a pas de lissage. Le résultat est à l'endroit.
fragment float4 fxaaFragment(VertexOut in [[stage_in]],
                             texture2d<float> frame [[texture(0)]],
                             sampler linearSampler [[sampler(0)]],
                             constant GameUniforms &uniforms [[buffer(0)]]) {
    float2 uvIn = in.uv;
    if (uniforms.flip > 0.5) uvIn.y = 1.0 - uvIn.y;
    float2 uv = uniforms.source.xy + uvIn * uniforms.source.zw;
    float2 px = 1.0 / uniforms.textureSize;
    float2 low = (uniforms.source.xy * uniforms.textureSize + 0.5) * px;
    float2 high = ((uniforms.source.xy + uniforms.source.zw) * uniforms.textureSize - 0.5) * px;
    const float3 luma = float3(0.299, 0.587, 0.114);

    float3 rgbNW = frame.sample(linearSampler, clamp(uv + float2(-1, -1) * px, low, high)).rgb;
    float3 rgbNE = frame.sample(linearSampler, clamp(uv + float2(1, -1) * px, low, high)).rgb;
    float3 rgbSW = frame.sample(linearSampler, clamp(uv + float2(-1, 1) * px, low, high)).rgb;
    float3 rgbSE = frame.sample(linearSampler, clamp(uv + float2(1, 1) * px, low, high)).rgb;
    float3 rgbM = frame.sample(linearSampler, clamp(uv, low, high)).rgb;
    float lumaNW = dot(rgbNW, luma);
    float lumaNE = dot(rgbNE, luma);
    float lumaSW = dot(rgbSW, luma);
    float lumaSE = dot(rgbSE, luma);
    float lumaM = dot(rgbM, luma);
    float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

    // Direction du bord, puis moyenne le long de lui.
    float2 dir = float2(-((lumaNW + lumaNE) - (lumaSW + lumaSE)), (lumaNW + lumaSW) - (lumaNE + lumaSE));
    float dirReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * (0.25 / 8.0), 1.0 / 128.0);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpDirMin, float2(-8.0), float2(8.0)) * px;

    float3 rgbA = 0.5 * (frame.sample(linearSampler, clamp(uv + dir * (1.0 / 3.0 - 0.5), low, high)).rgb
                         + frame.sample(linearSampler, clamp(uv + dir * (2.0 / 3.0 - 0.5), low, high)).rgb);
    float3 rgbB = rgbA * 0.5 + 0.25 * (frame.sample(linearSampler, clamp(uv - dir * 0.5, low, high)).rgb
                                       + frame.sample(linearSampler, clamp(uv + dir * 0.5, low, high)).rgb);
    float lumaB = dot(rgbB, luma);
    return float4((lumaB < lumaMin || lumaB > lumaMax) ? rgbA : rgbB, 1.0);
}
