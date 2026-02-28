#include <metal_stdlib>
#include <simd/simd.h>

#include "shader_defs.h"

using namespace metal;

constant const float2 QUAD_VERTICES[6] = {
    float2(0.0f, 0.0f),
    float2(1.0f, 0.0f),
    float2(1.0f, 1.0f),
    float2(1.0f, 1.0f),
    float2(0.0f, 1.0f),
    float2(0.0f, 0.0f)
};

float2 pixelSizeToNdc(float2 pixelSize, float2 screenSize)
{
    return pixelSize * 2.0 / screenSize;
}

float2 pixelPosToNdc(float2 pixelPos, float2 screenSize)
{
    const float2 sizeNdc = pixelSizeToNdc(pixelPos, screenSize);
    return sizeNdc - float2(1.0, 1.0);
}

float roundRectSDF(float2 pos, float2 halfSize, float radius)
{
    return length(max(abs(pos) - halfSize + radius, 0.0)) - radius;
}

float getRoundRectSmoothedAlpha(float4 position, float2 bottomLeft, float2 size, float2 screenSize, float cornerRadius)
{
    const float edgeSoftness = 1.0;

    const float2 halfSize = size / 2.0;
    const float2 pos = float2(position.x, screenSize.y - position.y);
    const float2 posCentered = pos - bottomLeft - halfSize;
    const float distance = roundRectSDF(posCentered, halfSize, cornerRadius);
    return 1.0 - smoothstep(0.0, edgeSoftness * 2.0, distance);
}

struct QuadVertOutFragIn {
    float4 position [[position]];
    float4 color;
    float2 bottomLeft;
    float2 size;
    float2 screenSize;
    float2 uv;
    float cornerRadius;
    float shadowSize;
    float4 shadowColor;
    uint32_t textureIndex;
    uint32_t textureMode;
};

vertex QuadVertOutFragIn quadVertMain(
    constant QuadInstanceData* instanceData [[buffer(0)]],
    constant QuadUniforms& uniforms [[buffer(1)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]])
{
    const QuadInstanceData data = instanceData[iid];
    const float4 vertexColors[6] = {
        data.colors[0],
        data.colors[1],
        data.colors[2],
        data.colors[2],
        data.colors[3],
        data.colors[0],
    };

    QuadVertOutFragIn out;
    const float2 bottomLeftNdc = pixelPosToNdc(data.bottomLeft, uniforms.screenSize);
    const float2 sizeNdc = pixelSizeToNdc(data.size, uniforms.screenSize);
    out.position = float4(QUAD_VERTICES[vid] * sizeNdc + bottomLeftNdc, data.depth, 1.0);
    out.color = vertexColors[vid];
    out.bottomLeft = data.bottomLeft;
    out.size = data.size;
    out.screenSize = uniforms.screenSize;
    out.uv = QUAD_VERTICES[vid] * data.uvSize + data.uvBottomLeft;
    out.cornerRadius = data.cornerRadius;
    out.shadowSize = data.shadowSize;
    out.shadowColor = data.shadowColor;
    out.textureIndex = data.textureIndex;
    out.textureMode = data.textureMode;
    return out;
}

fragment float4 quadFragMain(
    QuadVertOutFragIn in [[stage_in]],
    array<texture2d<half>, MAX_TEXTURES> textures [[texture(0)]])
{
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    const half4 colorSample = textures[in.textureIndex].sample(textureSampler, in.uv);

    const float smoothedAlpha = getRoundRectSmoothedAlpha(in.position, in.bottomLeft, in.size, in.screenSize, in.cornerRadius);
    const float4 colorFlat = float4(in.color.rgb, in.color.a * smoothedAlpha);

    if (in.textureMode == 1) {
        return float4(colorSample * half4(colorFlat));
    } else if (in.textureMode == 2) {
        return float4(colorFlat.rgb, colorFlat.a * colorSample.r);
    } else {
        return colorFlat;
    }
}
