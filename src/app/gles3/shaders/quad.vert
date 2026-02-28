#version 300 es

in vec4 vi_colorBL;
in vec4 vi_colorBR;
in vec4 vi_colorTL;
in vec4 vi_colorTR;
in vec4 vi_bottomLeftSize;
in vec4 vi_uvBottomLeftSize;
in vec2 vi_depthCornerRadius;
in float vi_shadowSize;
in vec4 vi_shadowColor;
in uvec2 vi_textureIndexMode;

out vec4 vo_color;
out vec4 vo_bottomLeftSize;
out vec2 vo_uv;
out float vo_cornerRadius;
out float vo_shadowSize;
out vec4 vo_shadowColor;
flat out uvec2 vo_textureIndexMode;

uniform vec2 u_screenSize;

vec2 QUAD_VERTICES[6] = vec2[](
    vec2(0, 0),
    vec2(1, 0),
    vec2(1, 1),
    vec2(1, 1),
    vec2(0, 1),
    vec2(0, 0)
);

vec2 pixelSizeToNdc(vec2 pixelSize, vec2 screenSize)
{
    return pixelSize * 2.0 / screenSize;
}

vec2 pixelPosToNdc(vec2 pixelPos, vec2 screenSize)
{
    vec2 sizeNdc = pixelSizeToNdc(pixelPos, screenSize);
    return sizeNdc - vec2(1.0, 1.0);
}

void main()
{
    vec4 vertexColors[6] = vec4[](
        vi_colorBL,
        vi_colorBR,
        vi_colorTL,
        vi_colorTL,
        vi_colorTR,
        vi_colorBL
    );
    vo_color = vertexColors[gl_VertexID];
    vo_bottomLeftSize = vi_bottomLeftSize;
    vec2 uvBl = vi_uvBottomLeftSize.xy;
    vec2 uvSize = vi_uvBottomLeftSize.zw;
    vo_uv = QUAD_VERTICES[gl_VertexID] * uvSize + uvBl;
    vo_cornerRadius = vi_depthCornerRadius.y;
    vo_shadowSize = vi_shadowSize;
    vo_shadowColor = vi_shadowColor;
    vo_textureIndexMode = vi_textureIndexMode;

    vec2 shadowSize2 = vec2(vi_shadowSize, vi_shadowSize);
    vec2 bottomLeftNdc = pixelPosToNdc(vi_bottomLeftSize.xy - shadowSize2, u_screenSize);
    vec2 sizeNdc = pixelSizeToNdc(vi_bottomLeftSize.zw + shadowSize2 * 2.0, u_screenSize);
    gl_Position = vec4(QUAD_VERTICES[gl_VertexID] * sizeNdc + bottomLeftNdc, vi_depthCornerRadius.x, 1.0);
}
