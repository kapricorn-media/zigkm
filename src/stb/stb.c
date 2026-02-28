#include <stddef.h>

void stb_zig_assert(int expression);

size_t stb_zig_strlen(const char* str);

void* stb_zig_memcpy(void* dest, const void* src, size_t n);
void* stb_zig_memset(void* str, int c, size_t n);

int stb_zig_ifloor(double x);
int stb_zig_iceil(double x);
double stb_zig_sqrt(double x);
double stb_zig_pow(double x, double y);
double stb_zig_fmod(double x, double y);
double stb_zig_cos(double x);
double stb_zig_acos(double x);
double stb_zig_fabs(double x);

void* stb_zig_malloc(size_t size, void* userData);
void stb_zig_free(void* ptr, void* userData);

void stb_zig_sort(void* base, size_t n, size_t size, int(*compare)(const void *, const void*));

#define STBRP_SORT(b,n,s,c) stb_zig_sort(b, n, s, c)
#define STBRP_ASSERT(x)     stb_zig_assert(x)

#define STBTT_ifloor(x)     stb_zig_ifloor(x)
#define STBTT_iceil(x)      stb_zig_iceil(x)
#define STBTT_sqrt(x)       stb_zig_sqrt(x)
#define STBTT_pow(x,y)      stb_zig_pow(x, y)
#define STBTT_fmod(x,y)     stb_zig_fmod(x, y)
#define STBTT_cos(x)        stb_zig_cos(x)
#define STBTT_acos(x)       stb_zig_acos(x)
#define STBTT_fabs(x)       stb_zig_fabs(x)

#define STBTT_malloc(x,u)   stb_zig_malloc(x, u)
#define STBTT_free(x,u)     stb_zig_free(x, u)
#define STBTT_assert(x)     stb_zig_assert(x)
#define STBTT_strlen(x)     stb_zig_strlen(x)
#define STBTT_memcpy        stb_zig_memcpy
#define STBTT_memset        stb_zig_memset

#define STB_RECT_PACK_IMPLEMENTATION
#include <stb_rect_pack.h>

#define STB_TRUETYPE_IMPLEMENTATION
#include <stb_truetype.h>
