#version 300 es

#define NUM_TEXTURES 8

precision highp float;

in vec4 vo_color;
in vec4 vo_bottomLeftSize;
in float vo_cornerRadius;
in float vo_shadowSize;
in vec4 vo_shadowColor;
in vec2 vo_uv;
flat in uvec2 vo_textureIndexMode;

out vec4 fo_color;

uniform sampler2D u_textures[NUM_TEXTURES];

// TODO: this effectively samples ALL textures and masks the result, which is not great. Options:
// - split into multiple draw calls
// - use array textures, potentially blowing up individual texture sizes
// - use a combination of array textures + atlases, to combine smaller textures into 1
vec4 sampleTextureIndex(uint index, vec2 uv)
{
    vec4 samples[NUM_TEXTURES] = vec4[](
        texture(u_textures[0], uv),
        texture(u_textures[1], uv),
        texture(u_textures[2], uv),
        texture(u_textures[3], uv),
        texture(u_textures[4], uv),
        texture(u_textures[5], uv),
        texture(u_textures[6], uv),
        texture(u_textures[7], uv)
    );
    return samples[index];
}

float roundRectSDF(vec2 pos, vec2 halfSize, float cornerRadius)
{
    vec2 posRelative = abs(pos) - halfSize + cornerRadius;
    return length(max(posRelative, 0.0)) + min(max(posRelative.x, posRelative.y), 0.0) - cornerRadius;
}

void main()
{
    vec2 pos = gl_FragCoord.xy;
    vec2 bottomLeft = vo_bottomLeftSize.xy;
    vec2 size = vo_bottomLeftSize.zw;
    float sdf = roundRectSDF(pos - bottomLeft - size / 2.0, size / 2.0, vo_cornerRadius);

    float smoothedAlpha = clamp(1.0 - smoothstep(0.0, 2.0, sdf), 0.0, 1.0);
    float shadowAlpha = clamp(1.0 - smoothstep(0.0, vo_shadowSize, sdf), 0.0, 1.0);
    shadowAlpha = shadowAlpha * shadowAlpha;

    vec4 colorSample = sampleTextureIndex(vo_textureIndexMode.x, vo_uv);
    vec4 colorFlat = vec4(vo_color.rgb, vo_color.a * smoothedAlpha);
    if (sdf > 0.01) {
        colorFlat = vec4(vo_shadowColor.rgb, vo_shadowColor.a * shadowAlpha);
    }

    if (vo_textureIndexMode.y == uint(1)) {
        fo_color = colorSample * colorFlat;
    } else if (vo_textureIndexMode.y == uint(2)) {
        fo_color = vec4(colorFlat.rgb, colorFlat.a * colorSample.r);
    } else {
        fo_color = colorFlat;
    }
}
