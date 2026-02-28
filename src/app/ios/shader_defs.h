#pragma once

#ifndef __METAL_VERSION__

#include <stddef.h>
#include <stdint.h>

typedef struct {
    float x;
    float y;
} float2;

typedef struct {
    float x;
    float y;
    float z;
} packed_float3;

typedef struct {
    float x;
    float y;
    float z;
    float w;
} float4;

#define MAX_QUADS 64 * 1024

#endif

#define MAX_TEXTURES 64

struct QuadUniforms {
    float2 screenSize;
};

struct QuadInstanceData {
    float4 colors[4]; // corner colors: 0,0 | 1,0 | 1,1 | 0,1
    float2 bottomLeft;
    float2 size;
    float2 uvBottomLeft;
    float2 uvSize;
    float4 shadowColor;
    float depth;
    float cornerRadius;
    float shadowSize;
    uint32_t textureIndex;
    uint32_t textureMode;
    float pad[3]; // float4 is 16-aligned in Metal but not in C, so we need a pad
};
