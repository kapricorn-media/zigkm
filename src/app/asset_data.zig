const std = @import("std");
const A = std.mem.Allocator;

const kb = @import("zigkm-kb");
const m = @import("zigkm").math;
const stb = @import("zigkm-stb");
const platform = @import("zigkm-platform");
const zigimg = @import("zigimg");

const platform_asset_data = switch (platform.platform) {
    .android => @import("android_asset_data.zig"),
    .ios => @import("ios_asset_data.zig"),
    .web => @import("wasm_asset_data.zig"),
    .server => unreachable,
};

pub const AssetLoader = platform_asset_data.AssetLoader;

pub const TextureWrapMode = enum {
    clampToEdge,
    repeat,
};

pub const TextureFilter = enum {
    linear,
    nearest,
};

pub const TextureLoadRequest = struct {
    path: []const u8,
    filter: TextureFilter,
    wrapMode: TextureWrapMode,
};

pub const TextureLoadResponse = struct {
    texId: u64,
    size: m.V2u,
    // Only used for .layer "images" (PSD layers).
    canvasSize: m.V2u,
    topLeft: m.V2i,
};

pub const TextureData = struct {
    texId: u64,
    size: m.V2u,
    // Only used for .layer "images" (PSD layers).
    canvasSize: m.V2u,
    topLeft: m.V2i,
};

pub const FontLoadRequest = struct {
    path: []const u8,
    atlasSize: usize,
    size: f32,
    scale: f32,
    lineHeight: f32,
    kerning: f32,
};

pub const FontLoadResponse = struct {
    fontData: *const FontLoadData,
};

pub const FontCharData = struct {
    offset: m.V2,
    size: m.V2,
    uvOffset: m.V2,
    advanceX: f32,
};

pub const FontLoadData = struct {
    size: f32,
    scale: f32,
    ascent: f32,
    descent: f32,
    lineGap: f32,
    charData: [256]FontCharData,
    // kbBuf: [256 * 1024]u8,
    // kbFont: kb.kbts_font,

    const Self = @This();

    pub fn load(self: *Self, atlasSize: usize, fontFileData: []const u8, size: f32, scale: f32, a: A) ![]u8
    {
        var tempArena = std.heap.ArenaAllocator.init(a);
        defer tempArena.deinit();
        var tempAllocator = tempArena.allocator();

        const fontFileDataCopy = try tempAllocator.dupe(u8, fontFileData);

        self.size = size;
        self.scale = scale;

        var fontInfo: stb.stbtt_fontinfo = undefined;
        if (stb.stbtt_InitFont(&fontInfo, &fontFileData[0], 0) == 0) {
            return error.stbtt_InitFont;
        }
        const stbScale = stb.stbtt_ScaleForMappingEmToPixels(&fontInfo, size / self.scale);

        var ascent: c_int = undefined;
        var descent: c_int = undefined;
        var lineGap: c_int = undefined;
        stb.stbtt_GetFontVMetrics(&fontInfo, &ascent, &descent, &lineGap);
        self.ascent = @as(f32, @floatFromInt(ascent)) * stbScale;
        self.descent = @as(f32, @floatFromInt(descent)) * stbScale;
        self.lineGap = @as(f32, @floatFromInt(lineGap)) * stbScale;

        const width = atlasSize;
        const height = atlasSize;
        var pixelBytes = try a.alloc(u8, width * height);
        @memset(pixelBytes, 0);
        var context: stb.stbtt_pack_context = undefined;
        if (stb.stbtt_PackBegin(&context, &pixelBytes[0], @intCast(width), @intCast(height), @intCast(width), 1, &tempAllocator) != 1) {
            return error.stbtt_PackBegin;
        }
        const oversampleN = 1;
        stb.stbtt_PackSetOversampling(&context, oversampleN, oversampleN);

        var charData = try tempAllocator.alloc(stb.stbtt_packedchar, self.charData.len);
        if (stb.stbtt_PackFontRange(&context, &fontFileData[0], 0, stb.STBTT_POINT_SIZE(size / scale), 0, @intCast(charData.len), &charData[0]) != 1) {
            return error.stbtt_PackFontRange;
        }

        stb.stbtt_PackEnd(&context);

        for (charData, 0..) |cd, i| {
            const sizeF: m.V2 = @floatFromInt(m.V2i{cd.x1 - cd.x0, cd.y1 - cd.y0});
            self.charData[i] = FontCharData {
                .offset = .{cd.xoff, -(sizeF.y + cd.yoff)},
                .size = sizeF,
                .uvOffset = .{
                    @as(f32, @floatFromInt(cd.x0)) / @as(f32, @floatFromInt(width)),
                    @as(f32, @floatFromInt(height - cd.y1)) / @as(f32, @floatFromInt(height)), // TODO should do -1 ?
                },
                .advanceX = cd.xadvance,
            };
        }

        // const alignment = 8;
        // @memset(std.mem.asBytes(&self.kbFont), 0);
        // const scratchSize = kb.kbts_ReadFontHeader(&self.kbFont, fontFileDataCopy.ptr, fontFileDataCopy.len);
        // const scratch = try tempAllocator.allocWithOptions(u8, @intCast(scratchSize), alignment, null);
        // const permSize = kb.kbts_ReadFontData(&self.kbFont, scratch.ptr, scratch.len);
        // if (permSize > self.kbBuf.len) {
        //     std.log.err("kb_text_shape font too big permSize={}", .{permSize});
        //     return error.kbts_fail;
        // }
        // _ = kb.kbts_PostReadFontInitialize(&self.kbFont, &self.kbBuf[0], permSize);
        // if (kb.kbts_FontIsValid(&self.kbFont) == 0) {
        //     std.log.err("kb_text_shape font read failed err={}", .{self.kbFont.Error});
        // }

        return pixelBytes;
    }
};

pub const FontData = struct {
    atlasData: TextureData,
    size: f32,
    scale: f32,
    ascent: f32,
    descent: f32,
    lineGap: f32,
    lineHeight: f32,
    kerning: f32,
    charData: [256]FontCharData,
    kbBuf: [256 * 1024]u8,
    kbFont: kb.kbts_font,
};
